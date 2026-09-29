import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public enum ReencodeError: Error, LocalizedError {
    case cannotStartWriter(String)
    case cannotStartReader(String)
    case writerFailed(String)
    case readerFailed(String)
    case audioFailed(OSStatus)
    case audioTruncated(samples: Int64)
    case missingFrame
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotStartWriter(let m): return "Could not start the encoder: \(m)"
        case .cannotStartReader(let m): return "Could not read a clip: \(m)"
        case .readerFailed(let m): return "Reading a clip failed: \(m)"
        case .audioTruncated(let n): return "A clip's audio ends \(n) samples early."
        case .writerFailed(let m): return "Encoding failed: \(m)"
        case .audioFailed(let s): return "Audio processing failed (\(s))."
        case .missingFrame: return "A source frame could not be decoded."
        case .cancelled: return "Cancelled."
        }
    }
}

/// One clip's grid segments to re-encode, with its tracks already loaded.
public struct ReencodeJob {
    public let asset: AVAsset
    public let videoTrack: AVAssetTrack
    public let audioTrack: AVAssetTrack?
    public let frames: FrameTable
    public let segments: [GridSegment]

    public static func load(asset: AVAsset, frames: FrameTable, segments: [GridSegment]) async throws -> ReencodeJob {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return ReencodeJob(asset: asset, videoTrack: video, audioTrack: audio, frames: frames, segments: segments)
    }
}

public struct VideoEncodeSettings: Equatable {
    public var codec: AVVideoCodecType
    public var width: Int
    public var height: Int
    public var bitsPerSecond: Int

    /// Same codec and size as the project. Bitrate ≈ 2× source, floor 20 Mbit/s at 1080p (scaled by pixels).
    public static func matching(_ media: ClipMedia) -> VideoEncodeSettings {
        let isHEVC = media.codec == fourCC("hvc1") || media.codec == fourCC("hev1")
        let floor = 20_000_000.0 * Double(media.width * media.height) / Double(1920 * 1080)
        let bitrate = max(2.0 * Double(media.estimatedDataRate), floor)
        return VideoEncodeSettings(codec: isHEVC ? .hevc : .h264, width: media.width, height: media.height,
                                   bitsPerSecond: Int(bitrate))
    }
}

/// Decodes kept ranges, retimes them onto the d grid, and encodes into one file.
/// Several jobs go back to back into the same file ("Re-encode all").
public final class ClipReencoder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func encode(jobs: [ReencodeJob], frameDuration d: Rational, timescale: Int32,
                       video: VideoEncodeSettings, audio: AudioFormat?, outputURL: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        if isCancelled { throw ReencodeError.cancelled }
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.movieTimeScale = timescale
        let fps = Int((Rational(1) / d).seconds.rounded())
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: video.codec,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: video.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: fps,
                // No B-frames: presentation order = decode order, no composition offsets.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ReencodeError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = jobs.flatMap(\.segments).reduce(0) { $0 + $1.frameCount }
        let videoSource = VideoFrameSource(jobs: jobs, frameDuration: d, timescale: timescale)
        let audioSource = audio.map { AudioSampleSource(jobs: jobs, format: $0) }
        // Fixed (non-var) capture: the detached task below runs concurrently and cannot
        // capture `var audioInput` from the enclosing scope.
        let fixedAudioInput = audioInput

        do {
            try await Task.detached(priority: .userInitiated) { [self] in
                var videoDone = false
                var audioDone = fixedAudioInput == nil
                while !(videoDone && audioDone) {
                    if self.isCancelled { throw ReencodeError.cancelled }
                    if writer.status == .failed {
                        throw ReencodeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                    }
                    var didWork = false
                    if !videoDone, videoInput.isReadyForMoreMediaData {
                        didWork = true
                        if try videoSource.appendNext(to: adaptor) {
                            progress(Double(videoSource.written) / Double(max(totalFrames, 1)))
                        } else {
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                    }
                    if !audioDone, let fixedAudioInput, let audioSource, fixedAudioInput.isReadyForMoreMediaData {
                        didWork = true
                        if try !audioSource.appendNext(to: fixedAudioInput) {
                            fixedAudioInput.markAsFinished()
                            audioDone = true
                        }
                    }
                    // Both inputs wait for interleaving; poll instead of blocking.
                    if !didWork { Thread.sleep(forTimeInterval: 0.002) }
                }
            }.value
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ReencodeError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}

/// Streams decoded source frames and appends retimed output frames.
final class VideoFrameSource {
    private let jobs: [ReencodeJob]
    private let d: Rational
    private let timescale: Int32
    private var jobIndex = 0
    private var segIndex = 0
    private var frameInSeg = 0
    private var indices: [Int] = []
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CVPixelBuffer?
    private var currentIndex = -1
    private var nextOutputPTS = Rational.zero
    private(set) var written = 0

    init(jobs: [ReencodeJob], frameDuration: Rational, timescale: Int32) {
        self.jobs = jobs
        self.d = frameDuration
        self.timescale = timescale
    }

    /// Appends one output frame. Returns false when every frame is written.
    func appendNext(to adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> Bool {
        if output == nil {
            guard try openNextSegment() else { return false }
        }
        let job = jobs[jobIndex]
        let seg = job.segments[segIndex]
        try advance(to: indices[frameInSeg], frames: job.frames)
        guard let buffer = current else { throw ReencodeError.missingFrame }
        let pts = nextOutputPTS.cmTime(timescale: timescale) ?? nextOutputPTS.cmTime
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw ReencodeError.writerFailed("video append failed at \(nextOutputPTS)")
        }
        nextOutputPTS = nextOutputPTS + d
        frameInSeg += 1
        written += 1
        if frameInSeg == seg.frameCount {
            reader?.cancelReading()
            reader = nil
            output = nil
            segIndex += 1
        }
        return true
    }

    private func openNextSegment() throws -> Bool {
        while jobIndex < jobs.count {
            let job = jobs[jobIndex]
            guard segIndex < job.segments.count else {
                jobIndex += 1
                segIndex = 0
                continue
            }
            let seg = job.segments[segIndex]
            indices = FrameRetimer.sourceFrameIndices(frames: job.frames, sourceStart: seg.sourceStart,
                                                      frameDuration: d, count: seg.frameCount)
            let f = job.frames
            let first = indices[0]
            let last = indices[indices.count - 1]
            let reader = try AVAssetReader(asset: job.asset)
            reader.timeRange = CMTimeRange(start: f.pts[first].cmTime, end: (f.pts[last] + f.durations[last]).cmTime)
            let out = AVAssetReaderTrackOutput(track: job.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw ReencodeError.cannotStartReader("cannot add video output") }
            reader.add(out)
            guard reader.startReading() else {
                throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
            }
            self.reader = reader
            self.output = out
            current = nil
            currentIndex = -1
            frameInSeg = 0
            return true
        }
        return false
    }

    /// Read forward until the decoded frame is exactly the wanted source frame.
    /// A frame is shown again only when the retimer picks the same index again.
    /// A failed, cancelled or early-ending reader, or a skipped frame, is an error.
    private func advance(to want: Int, frames: FrameTable) throws {
        while currentIndex < want {
            guard let buffer = output?.copyNextSampleBuffer() else {
                try throwIfReaderFailed(reader)
                throw ReencodeError.missingFrame
            }
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let pts = Rational(CMSampleBufferGetPresentationTimeStamp(buffer))
            current = image
            currentIndex = frames.lastFrameIndex(atOrBefore: pts) ?? -1
        }
        if currentIndex != want { throw ReencodeError.missingFrame }
    }
}

/// Turns a reader that stopped for a bad reason into an error. Normal completion returns.
func throwIfReaderFailed(_ reader: AVAssetReader?) throws {
    guard let reader else { return }
    switch reader.status {
    case .failed: throw ReencodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    case .cancelled: throw ReencodeError.cancelled
    default: return
    }
}

/// Tracks which source samples of one audio piece actually arrived. Pure; public for checks.
/// Gaps in the middle and a short end both count as missing. More than
/// `allowedMissing` (one AAC packet) in total is an error.
public struct AudioCoverage {
    public let start: Int64
    public let count: Int64
    public let allowedMissing: Int64
    /// Next wanted sample, relative to `start`.
    public private(set) var cursor: Int64 = 0
    public private(set) var missing: Int64 = 0

    public init(start: Int64, count: Int64, allowedMissing: Int64 = 1024) {
        self.start = start
        self.count = count
        self.allowedMissing = allowedMissing
    }

    public var isComplete: Bool { cursor >= count }

    /// A decoded buffer covers source samples [first, first + n). Returns the absolute
    /// range to keep, or nil when nothing of it is wanted.
    public mutating func accept(first: Int64, count n: Int64) throws -> (Int64, Int64)? {
        let wantFrom = start + cursor
        let lo = max(first, wantFrom)
        let hi = min(first + n, start + count)
        guard hi > lo else { return nil }
        if lo > wantFrom {
            missing += lo - wantFrom
            try check()
        }
        cursor = hi - start
        return (lo, hi)
    }

    /// The source ended. Whatever is still wanted is missing.
    public mutating func finish() throws {
        if cursor < count {
            missing += count - cursor
            cursor = count
        }
        try check()
    }

    private func check() throws {
        if missing > allowedMissing { throw ReencodeError.audioTruncated(samples: missing) }
    }
}

/// Streams decoded PCM for each grid segment, trimmed to exact sample ranges and
/// retimed onto the output clock. The AAC encoder in AVAssetWriter adds priming.
final class AudioSampleSource {
    private struct Piece {
        let job: Int
        let sourceStartSample: Int64
        let outStartSample: Int64
        let count: Int64
    }

    private let jobs: [ReencodeJob]
    private let format: AudioFormat
    private let rate: Int64
    private var pieces: [Piece] = []
    private var pieceIndex = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var coverage: AudioCoverage?

    init(jobs: [ReencodeJob], format: AudioFormat) {
        self.jobs = jobs
        self.format = format
        self.rate = Int64(format.sampleRate.rounded())
        let r = Rational(rate)
        var localOut = Rational.zero
        for (j, job) in jobs.enumerated() {
            for seg in job.segments {
                let outStart = (localOut * r).rounded()
                let outEnd = ((localOut + seg.outputDuration) * r).rounded()
                pieces.append(Piece(job: j, sourceStartSample: (seg.sourceStart * r).rounded(),
                                    outStartSample: outStart, count: outEnd - outStart))
                localOut = localOut + seg.outputDuration
            }
        }
    }

    /// Appends one trimmed buffer. Returns false when all audio is written.
    func appendNext(to input: AVAssetWriterInput) throws -> Bool {
        while pieceIndex < pieces.count {
            let piece = pieces[pieceIndex]
            if output == nil { try open(piece) }
            if coverage!.isComplete {
                closePiece()
                continue
            }
            guard let buffer = output?.copyNextSampleBuffer() else {
                try throwIfReaderFailed(reader)
                // Normal end of the source audio: the rest counts as missing.
                try coverage!.finish()
                closePiece()
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let n = Int64(CMSampleBufferGetNumSamples(buffer))
            guard pts.isNumeric, n > 0 else { continue }
            let first = (Rational(pts) * Rational(rate)).rounded()
            if first >= piece.sourceStartSample + piece.count {
                try coverage!.finish()
                closePiece()
                continue
            }
            // Counts any gap before this buffer as missing; throws past one AAC packet.
            guard let kept = try coverage!.accept(first: first, count: n) else { continue }
            let (lo, hi) = kept
            var sub: CMSampleBuffer?
            let status = CMSampleBufferCopySampleBufferForRange(
                allocator: nil, sampleBuffer: buffer,
                sampleRange: CFRange(location: CFIndex(lo - first), length: CFIndex(hi - lo)),
                sampleBufferOut: &sub)
            guard status == noErr, let sub else { throw ReencodeError.audioFailed(status) }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: Int32(rate)),
                presentationTimeStamp: CMTime(value: piece.outStartSample + (lo - piece.sourceStartSample),
                                              timescale: Int32(rate)),
                decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            let status2 = CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: sub, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &retimed)
            guard status2 == noErr, let retimed else { throw ReencodeError.audioFailed(status2) }
            guard input.append(retimed) else { throw ReencodeError.writerFailed("audio append failed") }
            return true
        }
        return false
    }

    private func open(_ piece: Piece) throws {
        let job = jobs[piece.job]
        guard let track = job.audioTrack else { throw ReencodeError.cannotStartReader("clip has no audio track") }
        let reader = try AVAssetReader(asset: job.asset)
        // A little slack at the end; exact trimming happens per buffer.
        reader.timeRange = CMTimeRange(start: CMTime(value: piece.sourceStartSample, timescale: Int32(rate)),
                                       duration: CMTime(value: piece.count + rate / 10, timescale: Int32(rate)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
        ])
        guard reader.canAdd(out) else { throw ReencodeError.cannotStartReader("cannot add audio output") }
        reader.add(out)
        guard reader.startReading() else {
            throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
        }
        self.reader = reader
        self.output = out
        coverage = AudioCoverage(start: piece.sourceStartSample, count: piece.count)
    }

    private func closePiece() {
        reader?.cancelReading()
        reader = nil
        output = nil
        coverage = nil
        pieceIndex += 1
    }
}

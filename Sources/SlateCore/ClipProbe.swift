import Foundation
import AVFoundation
import CoreMedia

public enum ClipProbeError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .readerFailed(let m): return "Could not read the file: \(m)"
        case .noFrames: return "The video track has no frames."
        }
    }
}

public enum ClipProbe {
    public static func probe(url: URL) async throws -> ClipMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let (size, fps, rate, formats) = try await track.load(
            .naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let frames = try await readFrameTable(asset: asset, track: track)

        var audio: AudioFormat?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            if let f = audioFormats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                audio = AudioFormat(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
            }
        }

        return ClipMedia(frames: frames, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                         codec: codec, nominalFPS: Double(fps), estimatedDataRate: rate, audio: audio)
    }

    /// Every video sample's presentation time and duration, sorted by pts.
    /// Only samples inside the track's time range (after edit lists) are kept.
    public static func readFrameTable(asset: AVAsset, track: AVAssetTrack) async throws -> FrameTable {
        let (timescale, trackRange) = try await track.load(.naturalTimeScale, .timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipProbeError.readerFailed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        let rangeStart = Rational(trackRange.start)
        let rangeEnd = Rational(trackRange.end)
        var entries: [(pts: Rational, duration: Rational)] = []
        while let buffer = output.copyNextSampleBuffer() {
            // AVAssetReader can vend "empty" sample buffers (no samples) at track
            // boundaries to mark gaps; they carry one dangling, meaningless timing
            // entry and must not be read as a real frame.
            let samples = CMSampleBufferGetNumSamples(buffer)
            guard samples > 0 else { continue }
            var needed: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
            guard needed > 0 else { continue }
            var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: needed, arrayToFill: &infos, entriesNeededOut: &needed)
            if infos.count == 1 && samples > 1 {
                // One timing entry shared by several samples.
                let info = infos[0]
                guard info.presentationTimeStamp.isNumeric, info.duration.isNumeric else { continue }
                let d = Rational(info.duration)
                for k in 0..<samples {
                    entries.append((Rational(info.presentationTimeStamp) + d * k, d))
                }
            } else {
                for info in infos where info.presentationTimeStamp.isNumeric && info.duration.isNumeric {
                    entries.append((Rational(info.presentationTimeStamp), Rational(info.duration)))
                }
            }
        }
        if reader.status == .failed {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        entries = entries.filter { $0.pts >= rangeStart && $0.pts < rangeEnd }
        guard !entries.isEmpty else { throw ClipProbeError.noFrames }
        entries.sort { $0.pts < $1.pts }
        return FrameTable(pts: entries.map(\.pts), durations: entries.map(\.duration), timescale: timescale)
    }
}

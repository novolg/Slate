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

    /// One edit segment's media-timeline (source) to track-timeline (target) time mapping,
    /// in `Rational`. Only non-empty segments with a 1:1 rate (source and target durations
    /// equal) are supported.
    private struct EditMapping {
        let sourceStart: Rational
        let sourceEnd: Rational
        let targetStart: Rational
    }

    /// Every video sample's presentation time and duration, sorted by pts.
    ///
    /// `AVAssetReaderTrackOutput` passthrough (outputSettings: nil) reports each sample's
    /// presentation time in the track's *media* timeline. When the file has an edit list
    /// (elst) — for example because B-frames gave the encoder's first packets a negative
    /// DTS — that media timeline is not the same as the *track* timeline that
    /// `AVMutableCompositionTrack.insertTimeRange` and a decoded `AVAssetReaderTrackOutput`
    /// (with pixel-format outputSettings) both use. Each sample must be mapped through the
    /// track's edit segments before it means anything as a frame table; samples the edit
    /// list hides (matching no segment) are dropped.
    /// Only samples inside the track's time range are kept.
    public static func readFrameTable(asset: AVAsset, track: AVAssetTrack) async throws -> FrameTable {
        let (timescale, trackRange, segments) = try await track.load(.naturalTimeScale, .timeRange, .segments)
        let mappings: [EditMapping] = try segments.compactMap { segment in
            guard !segment.isEmpty else { return nil }
            let mapping = segment.timeMapping
            let sourceStart = Rational(mapping.source.start)
            let sourceEnd = Rational(mapping.source.end)
            let targetStart = Rational(mapping.target.start)
            let targetEnd = Rational(mapping.target.end)
            guard (sourceEnd - sourceStart) == (targetEnd - targetStart) else {
                throw ClipProbeError.readerFailed("scaled edit segments are not supported")
            }
            return EditMapping(sourceStart: sourceStart, sourceEnd: sourceEnd, targetStart: targetStart)
        }

        /// Media-timeline pts -> track-timeline pts, or nil if hidden by the edit list.
        func mapToTrackTime(_ p: Rational) -> Rational? {
            for m in mappings where p >= m.sourceStart && p < m.sourceEnd {
                return m.targetStart + (p - m.sourceStart)
            }
            return nil
        }

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
                    let p = Rational(info.presentationTimeStamp) + d * k
                    if let mapped = mapToTrackTime(p) {
                        entries.append((mapped, d))
                    }
                }
            } else {
                for info in infos where info.presentationTimeStamp.isNumeric && info.duration.isNumeric {
                    let p = Rational(info.presentationTimeStamp)
                    if let mapped = mapToTrackTime(p) {
                        entries.append((mapped, Rational(info.duration)))
                    }
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

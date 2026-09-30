import Foundation
import AVFoundation
import CoreMedia

/// One source range placed at an output time.
public struct CompositionInsert {
    public let asset: AVAsset
    public let sourceStart: Rational
    public let duration: Rational
    public let outputStart: Rational
    public let clipID: UUID?

    public init(asset: AVAsset, sourceStart: Rational, duration: Rational, outputStart: Rational,
                clipID: UUID? = nil) {
        self.asset = asset
        self.sourceStart = sourceStart
        self.duration = duration
        self.outputStart = outputStart
        self.clipID = clipID
    }
}

public enum CompositionError: Error, LocalizedError {
    case cannotAddTrack
    case noVideoTrack
    case missingAsset(UUID)
    case offGrid(Rational)
    case audioTruncated(clip: UUID?, seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .cannotAddTrack: return "Could not create a composition track."
        case .noVideoTrack: return "A clip has no video track."
        case .missingAsset(let id): return "No asset for clip \(id)."
        case .offGrid(let t): return "A clip cannot be placed exactly at \(t) s on the output timeline."
        case .audioTruncated(let clip, let s):
            return "The audio of clip \(clip.map { $0.uuidString } ?? "?") ends \(String(format: "%.2f", s)) s before its video."
        }
    }
}

public enum CompositionBuilder {
    /// One insert per grid segment, reading from the clip's own file.
    /// Used for Project preview, Mixed export and copied clips.
    /// Throws `CompositionError.missingAsset` if a grid segment's clip has no asset —
    /// silently dropping it would leave a gap at its `outputStart` that later inserts
    /// would not fill, and the composition's total duration would still match the plan.
    public static func inserts(for grid: [GridSegment], assets: [UUID: AVAsset]) throws -> [CompositionInsert] {
        try grid.map { g in
            guard let asset = assets[g.clipID] else { throw CompositionError.missingAsset(g.clipID) }
            return CompositionInsert(asset: asset, sourceStart: g.sourceStart,
                                     duration: g.outputDuration, outputStart: g.outputStart,
                                     clipID: g.clipID)
        }
    }

    public static func build(inserts: [CompositionInsert], includeAudio: Bool,
                             timescale: Int32) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.cannotAddTrack
        }
        video.naturalTimeScale = timescale
        var audio: AVMutableCompositionTrack?
        if includeAudio {
            audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            if audio == nil { throw CompositionError.cannotAddTrack }
        }

        for ins in inserts {
            guard let srcVideo = try await ins.asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.noVideoTrack
            }
            let range = CMTimeRange(start: ins.sourceStart.cmTime, duration: ins.duration.cmTime)
            guard let at = ins.outputStart.cmTime(timescale: timescale) else {
                throw CompositionError.offGrid(ins.outputStart)
            }
            try video.insertTimeRange(range, of: srcVideo, at: at)

            if let audio, let srcAudio = try await ins.asset.loadTracks(withMediaType: .audio).first {
                // Audio may end a few ms before video. Insert only the overlapping part,
                // but never more than one AAC packet (1024 samples) short.
                let audioRange = try await srcAudio.load(.timeRange)
                let clipped = range.intersection(audioRange)
                let covered = clipped.duration > .zero ? Rational(clipped.duration) : Rational.zero
                let missing = Rational(range.duration) - covered
                let rate = try await Self.sampleRate(of: srcAudio)
                if missing > Rational(1024, Int64(rate.rounded())) {
                    throw CompositionError.audioTruncated(clip: ins.clipID, seconds: missing.seconds)
                }
                if clipped.duration > .zero {
                    let offset = CMTimeSubtract(clipped.start, range.start)
                    try audio.insertTimeRange(clipped, of: srcAudio, at: CMTimeAdd(at, offset))
                }
            }
        }
        return comp
    }

    private static func sampleRate(of track: AVAssetTrack) async throws -> Double {
        let formats = try await track.load(.formatDescriptions)
        if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee,
           asbd.mSampleRate > 0 {
            return asbd.mSampleRate
        }
        return 44100
    }
}

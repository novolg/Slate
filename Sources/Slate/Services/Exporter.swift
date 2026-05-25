import Foundation
import AVFoundation
import CoreMedia

enum ExporterError: Error, LocalizedError {
    case noVideoTrack
    case noSegments
    case cannotCreateSession
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Source has no video track."
        case .noSegments: return "No keep-segments to export."
        case .cannotCreateSession: return "Could not create AVAssetExportSession."
        case .exportFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Export cancelled."
        }
    }
}

actor Exporter {
    private var session: AVAssetExportSession?

    func cancel() {
        session?.cancelExport()
    }

    func export(
        asset: AVAsset,
        segments: [Segment],
        outputURL: URL,
        progress: @Sendable @escaping (Float) -> Void
    ) async throws {
        guard !segments.isEmpty else { throw ExporterError.noSegments }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let srcVideo = videoTracks.first else { throw ExporterError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let srcAudio = audioTracks.first

        let comp = AVMutableComposition()
        let videoTrack = comp.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let audioTrack: AVMutableCompositionTrack? = srcAudio != nil
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        let sortedSegments = segments.sorted { CMTimeCompare($0.start, $1.start) < 0 }
        for seg in sortedSegments {
            try videoTrack?.insertTimeRange(seg.range, of: srcVideo, at: cursor)
            if let srcA = srcAudio, let audioTrack {
                // Audio may be shorter than video on tail; tolerate failure.
                do {
                    try audioTrack.insertTimeRange(seg.range, of: srcA, at: cursor)
                } catch {
                    // Continue with video-only at this segment.
                }
            }
            cursor = CMTimeAdd(cursor, seg.range.duration)
        }

        guard let session = AVAssetExportSession(
            asset: comp,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ExporterError.cannotCreateSession
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        // Make sure no stale file exists at output path.
        try? FileManager.default.removeItem(at: outputURL)

        self.session = session

        // Poll progress on a background task while export runs.
        let progressTask = Task { @Sendable in
            while !Task.isCancelled {
                let p = session.progress
                progress(p)
                if session.status == .completed || session.status == .failed || session.status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        await session.export()
        progressTask.cancel()
        progress(session.progress)

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw ExporterError.cancelled
        case .failed:
            throw ExporterError.exportFailed(session.error?.localizedDescription ?? "unknown")
        default:
            throw ExporterError.exportFailed("unexpected status \(session.status.rawValue)")
        }
    }
}

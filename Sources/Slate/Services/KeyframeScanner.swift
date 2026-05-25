import Foundation
import AVFoundation
import CoreMedia

enum KeyframeScannerError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Asset has no video track."
        case .readerFailed(let m): return "AVAssetReader failed: \(m)"
        }
    }
}

enum KeyframeScanner {
    /// Scan sync-sample timestamps of the first video track without decoding frames.
    static func scan(asset: AVAsset) async throws -> KeyframeIndex {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw KeyframeScannerError.noVideoTrack }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw KeyframeScannerError.readerFailed("cannot add track output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw KeyframeScannerError.readerFailed(reader.error?.localizedDescription ?? "startReading returned false")
        }

        return try await Task.detached(priority: .userInitiated) {
            var times: [CMTime] = []
            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                defer { /* CMSampleBuffer is auto-released by ARC */ _ = sample }
                if Self.isSync(sample) {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts.isValid && !pts.isIndefinite {
                        times.append(pts)
                    }
                }
            }
            if reader.status == .failed {
                throw KeyframeScannerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
            }
            // Samples are already in decode order; sort ascending by PTS for safety.
            times.sort { CMTimeCompare($0, $1) < 0 }
            return KeyframeIndex(times: times)
        }.value
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachmentsCF = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachmentsCF) > 0
        else {
            // No attachment array: AVAssetReader treats the sample as a sync sample.
            return true
        }
        let attachments = attachmentsCF as! [CFDictionary]
        let dict = attachments[0] as NSDictionary
        let key = kCMSampleAttachmentKey_NotSync as String
        if let notSync = dict[key] as? Bool {
            return !notSync
        }
        // Key absent → sync sample.
        return true
    }
}

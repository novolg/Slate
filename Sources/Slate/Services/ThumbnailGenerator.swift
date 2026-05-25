import Foundation
import AVFoundation
import AppKit
import CoreGraphics

struct Thumbnail {
    let time: CMTime
    let image: NSImage
}

enum ThumbnailGenerator {
    /// Generate `count` thumbnails evenly distributed across the asset duration.
    /// `pointHeight` is the desired display height; we render at 2x for retina.
    static func generate(asset: AVAsset, count: Int, pointHeight: CGFloat) async throws -> [Thumbnail] {
        guard count > 0 else { return [] }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { return [] }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 0, height: pointHeight * 2)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let totalSeconds = duration.seconds
        let step = totalSeconds / Double(count)
        let timestamps: [CMTime] = (0..<count).map { i in
            let t = (Double(i) + 0.5) * step
            return CMTime(seconds: min(t, totalSeconds - 0.001), preferredTimescale: 600)
        }

        var results: [Thumbnail] = []
        results.reserveCapacity(count)

        for t in timestamps {
            do {
                let result = try await gen.image(at: t)
                let cg = result.image
                let size = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
                let nsImage = NSImage(cgImage: cg, size: size)
                results.append(Thumbnail(time: result.actualTime, image: nsImage))
            } catch {
                // Skip failed timestamps; continue with the rest.
                continue
            }
        }
        return results
    }
}

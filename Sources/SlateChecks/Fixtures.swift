import Foundation
import CoreMedia
import SlateCore

/// URL of a generated fixture. Skips the check when fixtures were not generated.
func fixture(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/fixtures/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SkipCheck(reason: "missing \(name) — run scripts/make-test-clips.sh")
    }
    return url
}

/// Fresh directory for files written by checks.
func checksOutputDirectory() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/checks-out", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Probe a fixture and keep the given second ranges.
func loadClip(_ name: String, keep: [(Double, Double)]) async throws -> Clip {
    let url = try fixture(name)
    let media = try await ClipProbe.probe(url: url)
    let segments = keep.map { r in
        Segment(range: CMTimeRangeFromTimeToTime(start: CMTime(seconds: r.0, preferredTimescale: 600),
                                                 end: CMTime(seconds: r.1, preferredTimescale: 600)))
    }
    return Clip(url: url, segments: segments, media: media)
}

import Foundation
import CoreMedia
import SlateCore

/// Writes the Phase 0 files into build/phase0 and prints an automatic report.
enum Phase0 {
    struct Case {
        let file: String
        let mode: FPSMode
        let strategy: ConstantStrategy
        let audio: Bool
    }

    /// Arguments: optional `--clip24 <path> --clip48 <path>` to run the video-only cases
    /// on the user's own clips, locally. Paths are never copied into the repo.
    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let real24 = value("--clip24")
        let real48 = value("--clip48")
        if (real24 == nil) != (real48 == nil) {
            print("Pass both --clip24 and --clip48, or neither.")
            return 2
        }
        let usingRealClips = real24 != nil

        func load(_ generated: String, real: String?, keep: [(Double, Double)]) async throws -> Clip {
            guard let real else { return try await loadClip(generated, keep: keep) }
            let url = URL(fileURLWithPath: (real as NSString).expandingTildeInPath)
            let media = try await ClipProbe.probe(url: url)
            let segments = keep.map { r in
                Segment(range: CMTimeRangeFromTimeToTime(start: CMTime(seconds: r.0, preferredTimescale: 600),
                                                         end: CMTime(seconds: r.1, preferredTimescale: 600)))
            }
            return Clip(url: url, segments: segments, media: media)
        }

        let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
        let d48 = FPSMode.constant(frameDuration: Rational(1, 48))
        let cases = [
            Case(file: "phase0-mixed.mp4", mode: .mixed, strategy: .selective, audio: false),
            Case(file: "phase0-mixed-audio.mp4", mode: .mixed, strategy: .selective, audio: true),
            Case(file: "phase0-selective-24.mp4", mode: d24, strategy: .selective, audio: false),
            Case(file: "phase0-all-24.mp4", mode: d24, strategy: .reencodeAll, audio: false),
            Case(file: "phase0-selective-48.mp4", mode: d48, strategy: .selective, audio: false),
            Case(file: "phase0-all-48.mp4", mode: d48, strategy: .reencodeAll, audio: false),
            Case(file: "phase0-selective-24-audio.mp4", mode: d24, strategy: .selective, audio: true),
            Case(file: "phase0-all-24-audio.mp4", mode: d24, strategy: .reencodeAll, audio: true),
        ]
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outDir = root.appendingPathComponent("build/phase0", isDirectory: true)
        let tmpDir = outDir.appendingPathComponent("tmp", isDirectory: true)
        var failures = 0
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            print("Phase 0 → \(outDir.path)  (video-only cases: \(usingRealClips ? "user clips" : "generated fixtures"))\n")
            for c in cases {
                // Both clips are cut mid-GOP (the fixtures have one keyframe at 0).
                // Audio cases always use the generated fixtures (supplemental AAC coverage).
                let a = try await load(c.audio ? "c24_a.mp4" : "c24.mp4", real: c.audio ? nil : real24,
                                       keep: [(0.7, 2.3), (3.1, 4.4)])
                let b = try await load(c.audio ? "c48_a.mp4" : "c48.mp4", real: c.audio ? nil : real48,
                                       keep: [(1.05, 3.6)])
                let project = Project(clips: [a, b], fpsMode: c.mode, constantStrategy: c.strategy)
                let plan = ExportPlanner.plan(project)
                let actions = plan.clips.map { "\($0.action)" }.joined(separator: ", ")
                // A file that fails validation is kept as *-INVALID.mp4 for ffprobe/Resolve.
                let exporter = ProjectExporter()
                exporter.keepInvalidAt = outDir.appendingPathComponent(
                    c.file.replacingOccurrences(of: ".mp4", with: "-INVALID.mp4"))
                do {
                    let report = try await exporter.export(
                        project: project, outputURL: outDir.appendingPathComponent(c.file),
                        tempDirectory: tmpDir, progress: { _ in })
                    print("PASS  \(c.file)  frames=\(report.frameCount)  duration=\(report.videoDuration.seconds)s  [\(actions)]")
                } catch ProjectExportError.validationFailed(let report) {
                    failures += 1
                    print("FAIL  \(c.file)  frames=\(report.frameCount)  [\(actions)]  (kept as -INVALID.mp4)")
                    for issue in report.issues { print("      - \(issue)") }
                } catch {
                    failures += 1
                    print("FAIL  \(c.file)  error: \(error.localizedDescription)  [\(actions)]")
                }
            }
        } catch {
            print("Phase 0 could not start: \(error)")
            return 2
        }
        print("\n\(failures == 0 ? "All automatic checks passed." : "\(failures) case(s) failed.")")
        print("Next: scripts/phase0-ffprobe.sh, then (optional) import build/phase0/*.mp4 into DaVinci Resolve.")
        return failures == 0 ? 0 : 1
    }
}

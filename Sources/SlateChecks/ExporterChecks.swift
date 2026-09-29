import Foundation
import CoreMedia
import SlateCore

private func exportProject(_ project: Project, name: String) async throws -> (CadenceReport, ExportPlan) {
    let out = try checksOutputDirectory().appendingPathComponent(name)
    let temp = try checksOutputDirectory().appendingPathComponent("tmp", isDirectory: true)
    let report = try await ProjectExporter().export(project: project, outputURL: out, tempDirectory: temp,
                                                    progress: { _ in })
    return (report, ExportPlanner.plan(project))
}

func runExporterChecks() async {
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
    let d48 = FPSMode.constant(frameDuration: Rational(1, 48))

    await checkAsync("exporter: mixed 24 + 48 copies everything") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let (report, _) = try await exportProject(Project(clips: [a, b], fpsMode: .mixed), name: "ex-mixed.mp4")
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("exporter: constant 24 selective and re-encode all agree") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let (sel, _) = try await exportProject(Project(clips: [a, b], fpsMode: d24, constantStrategy: .selective),
                                               name: "ex-c24-selective.mp4")
        expect(sel.ok, "selective: \(sel.issues)")
        let (all, _) = try await exportProject(Project(clips: [a, b], fpsMode: d24, constantStrategy: .reencodeAll),
                                               name: "ex-c24-all.mp4")
        expect(all.ok, "re-encode all: \(all.issues)")
        expectEqual(sel.frameCount, all.frameCount)
    }

    await checkAsync("exporter: constant 48 selective with audio") {
        let a = try await loadClip("c24_a.mp4", keep: [(0.7, 2.3)])
        let b = try await loadClip("c48_a.mp4", keep: [(1.05, 3.6)])
        let (report, _) = try await exportProject(Project(clips: [a, b], fpsMode: d48), name: "ex-c48-a.mp4")
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("exporter: the same file twice as two clips") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let b = try await loadClip("c24.mp4", keep: [(3.0, 4.0)])
        let (report, plan) = try await exportProject(Project(clips: [a, b], fpsMode: d24), name: "ex-dup.mp4")
        expect(report.ok, "\(report.issues)")
        expectEqual(plan.totalFrames, 48)
    }

    await checkAsync("exporter: a failed validation never replaces an existing export") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let out = try checksOutputDirectory().appendingPathComponent("ex-invalid.mp4")
        try Data("previous export".utf8).write(to: out)
        let exporter = ProjectExporter()
        exporter.validator = { _, _ in
            CadenceReport(frameCount: 0, videoDuration: .zero, issues: ["simulated failure"])
        }
        do {
            _ = try await exporter.export(project: Project(clips: [a], fpsMode: d24), outputURL: out,
                                          tempDirectory: try checksOutputDirectory(), progress: { _ in })
            expect(false, "expected validationFailed")
        } catch ProjectExportError.validationFailed(let report) {
            expectEqual(report.issues, ["simulated failure"])
        }
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
    }

    await checkAsync("exporter: keepInvalidAt aliasing a source or the destination is refused") {
        let fm = FileManager.default
        let dir = try checksOutputDirectory().appendingPathComponent("keep-invalid", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("src.mp4")
        try fm.copyItem(at: try fixture("c24.mp4"), to: src)
        let srcBytes = try Data(contentsOf: src)
        let out = dir.appendingPathComponent("out.mp4")
        try Data("previous export".utf8).write(to: out)
        let media = try await ClipProbe.probe(url: src)
        let clip = Clip(url: src, segments: [Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))],
                        media: media)
        let alias = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: dir)
        for target in [src, out, alias.appendingPathComponent("src.mp4"), alias.appendingPathComponent("out.mp4")] {
            let exporter = ProjectExporter()
            exporter.keepInvalidAt = target
            exporter.validator = { _, _ in CadenceReport(frameCount: 0, videoDuration: .zero, issues: ["simulated"]) }
            do {
                _ = try await exporter.export(project: Project(clips: [clip], fpsMode: d24), outputURL: out,
                                              tempDirectory: dir, progress: { _ in })
                expect(false, "keepInvalidAt \(target.lastPathComponent) not refused")
            } catch ProjectExportError.outputIsSource {
                // expected
            }
        }
        expectEqual(try Data(contentsOf: src), srcBytes)
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
    }

    await checkAsync("exporter: blocked project throws and writes nothing") {
        let a = try await loadClip("c24.mp4", keep: [(0, 1)])
        let small = try await loadClip("small24.mp4", keep: [(0, 1)])
        let out = try checksOutputDirectory().appendingPathComponent("ex-blocked.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [a, small]), outputURL: out,
                                                   tempDirectory: try checksOutputDirectory(), progress: { _ in })
            expect(false, "expected blocked")
        } catch ProjectExportError.blocked(let blockers) {
            expect(blockers.contains(.clip(small.id, .frameSizeMismatch)))
        }
        expect(!FileManager.default.fileExists(atPath: out.path))
    }

    await checkAsync("exporter: output path equal to a source is refused") {
        let a = try await loadClip("c24.mp4", keep: [(0, 1)])
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [a]), outputURL: a.url,
                                                   tempDirectory: try checksOutputDirectory(), progress: { _ in })
            expect(false, "expected outputIsSource")
        } catch ProjectExportError.outputIsSource {
            // expected
        }
        expect(FileManager.default.fileExists(atPath: a.url.path), "source must survive")
    }

    await checkAsync("exporter: a symlinked parent or a case alias of a source is refused") {
        let fm = FileManager.default
        let base = try checksOutputDirectory().appendingPathComponent("alias-test", isDirectory: true)
        try? fm.removeItem(at: base)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let realClip = real.appendingPathComponent("clip.mp4")
        try fm.copyItem(at: try fixture("c24.mp4"), to: realClip)
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let media = try await ClipProbe.probe(url: realClip)
        let whole = [Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))]

        // Input through the symlink, output through the real path.
        let viaAlias = Clip(url: alias.appendingPathComponent("clip.mp4"), segments: whole, media: media)
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [viaAlias]), outputURL: realClip,
                                                   tempDirectory: base, progress: { _ in })
            expect(false, "symlink parent not detected")
        } catch ProjectExportError.outputIsSource {
            // expected
        }
        expect(fm.fileExists(atPath: realClip.path), "source must survive (symlink case)")

        // Case alias, only meaningful on a case-insensitive volume.
        let caseSensitive = (try? real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        if !caseSensitive {
            let direct = Clip(url: realClip, segments: whole, media: media)
            do {
                _ = try await ProjectExporter().export(project: Project(clips: [direct]),
                                                       outputURL: real.appendingPathComponent("CLIP.MP4"),
                                                       tempDirectory: base, progress: { _ in })
                expect(false, "case alias not detected")
            } catch ProjectExportError.outputIsSource {
                // expected
            }
            expect(fm.fileExists(atPath: realClip.path), "source must survive (case alias)")
        }
    }

    await checkAsync("exporter: cancel during re-encode leaves no temp files and keeps an existing export") {
        let a = try await loadClip("c48.mp4", keep: [(0, 4.9)])
        let temp = try checksOutputDirectory().appendingPathComponent("tmp-cancel", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let out = try checksOutputDirectory().appendingPathComponent("ex-cancel.mp4")
        try Data("previous export".utf8).write(to: out)
        let exporter = ProjectExporter()
        let task = Task {
            try await exporter.export(project: Project(clips: [a], fpsMode: d24), outputURL: out,
                                      tempDirectory: temp, progress: { stage in
                if case .reencoding(_, _, let p) = stage, p > 0.1 { exporter.cancel() }
            })
        }
        do {
            _ = try await task.value
            expect(false, "expected cancellation")
        } catch ProjectExportError.cancelled {
            // expected
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        expect(leftovers.isEmpty, "leftovers: \(leftovers)")
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
        expect(!siblings.contains { $0.hasPrefix(".slate-") }, "staging file left next to the output")
    }
}

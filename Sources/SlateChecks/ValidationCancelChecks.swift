import Foundation
import SlateCore

func runValidationCancelChecks() async {
    await checkAsync("exporter: cancel during validation ends as cancelled and keeps an existing export") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let dir = try checksOutputDirectory()
        let out = dir.appendingPathComponent("ex-cancel-validate.mp4")
        try Data("previous export".utf8).write(to: out)
        let exporter = ProjectExporter()
        exporter.validator = { _, _ in
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return CadenceReport(frameCount: 0, videoDuration: .zero, issues: [])
        }
        let started = Date()
        do {
            _ = try await exporter.export(project: Project(clips: [a]), outputURL: out, tempDirectory: dir,
                                          progress: { stage in
                if stage == .validating {
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        exporter.cancel()
                    }
                }
            })
            expect(false, "expected cancelled")
        } catch ProjectExportError.cancelled {
            // expected
        }
        expect(Date().timeIntervalSince(started) < 15, "cancel did not interrupt the validation")
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
    }
}

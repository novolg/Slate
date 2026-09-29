import Foundation
import AVFoundation
import SlateCore

private func reencode(_ clip: Clip, to d: Rational, name: String) async throws -> (URL, ExportPlan) {
    let plan = ExportPlanner.plan(Project(clips: [clip], fpsMode: .constant(frameDuration: d)))
    let media = clip.media!
    let job = try await ReencodeJob.load(asset: AVURLAsset(url: clip.url), frames: media.frames,
                                         segments: plan.grid)
    let out = try checksOutputDirectory().appendingPathComponent(name)
    try await ClipReencoder().encode(jobs: [job], frameDuration: d, timescale: plan.outputTimescale,
                                     video: .matching(media), audio: media.audio,
                                     outputURL: out, progress: { _ in })
    return (out, plan)
}

func runReencoderChecks() async {
    check("reencoder: a missing middle audio buffer is detected") {
        // 4096 wanted samples; buffers cover [0, 1024) and [3072, 4096) → 2048 missing.
        var c = AudioCoverage(start: 0, count: 4096)
        expect(try c.accept(first: 0, count: 1024) != nil)
        do {
            _ = try c.accept(first: 3072, count: 1024)
            expect(false, "a 2048-sample gap must throw")
        } catch ReencodeError.audioTruncated(let n) {
            expectEqual(n, 2048)
        }
    }

    check("reencoder: a short end within one AAC packet is allowed, more is not") {
        var ok = AudioCoverage(start: 100, count: 4096)
        _ = try ok.accept(first: 0, count: 100 + 4096 - 500)
        try ok.finish()
        expectEqual(ok.missing, 500)
        var bad = AudioCoverage(start: 0, count: 4096)
        _ = try bad.accept(first: 0, count: 2000)
        do {
            try bad.finish()
            expect(false, "2096 missing samples must throw")
        } catch ReencodeError.audioTruncated {
            // expected
        }
    }

    await checkAsync("reencoder: 48→24 output has exact cadence") {
        let clip = try await loadClip("c48.mp4", keep: [(0.3, 2.9)])
        let (url, plan) = try await reencode(clip, to: Rational(1, 24), name: "re-48to24.mp4")
        let report = try await CadenceValidator.validate(url: url, frameDuration: Rational(1, 24),
                                                         expectedFrames: plan.totalFrames,
                                                         expectedDuration: plan.totalDuration, audioSampleRate: nil)
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("reencoder: 24→48 with two kept ranges and audio") {
        let clip = try await loadClip("c24_a.mp4", keep: [(0.5, 1.5), (2.5, 4.0)])
        let (url, plan) = try await reencode(clip, to: Rational(1, 48), name: "re-24to48-a.mp4")
        let report = try await CadenceValidator.validate(url: url, frameDuration: Rational(1, 48),
                                                         expectedFrames: plan.totalFrames,
                                                         expectedDuration: plan.totalDuration, audioSampleRate: 44100)
        expect(report.ok, "\(report.issues)")
        expectEqual(report.frameCount, 120)
    }

    await checkAsync("reencoder: a truncated source fails instead of freezing, and leaves no output") {
        // Frame table from the intact file; media data from the cut copy.
        let good = try await loadClip("c48_fs.mp4", keep: [(0, 4.9)])
        let d = Rational(1, 24)
        let plan = ExportPlanner.plan(Project(clips: [good], fpsMode: .constant(frameDuration: d)))
        let job = try await ReencodeJob.load(asset: AVURLAsset(url: try fixture("c48_trunc.mp4")),
                                             frames: good.media!.frames, segments: plan.grid)
        let out = try checksOutputDirectory().appendingPathComponent("re-trunc.mp4")
        do {
            try await ClipReencoder().encode(jobs: [job], frameDuration: d, timescale: plan.outputTimescale,
                                             video: .matching(good.media!), audio: nil,
                                             outputURL: out, progress: { _ in })
            expect(false, "expected a decode error, got a successful (frozen) export")
        } catch ReencodeError.missingFrame {
            // expected
        } catch ReencodeError.readerFailed {
            // expected
        } catch ReencodeError.cannotStartReader {
            // expected
        }
        expect(!FileManager.default.fileExists(atPath: out.path), "partial output must be removed")
    }

    await checkAsync("reencoder: cancel throws cancelled") {
        let clip = try await loadClip("c48.mp4", keep: [(0, 4.9)])
        let plan = ExportPlanner.plan(Project(clips: [clip], fpsMode: .constant(frameDuration: Rational(1, 24))))
        let job = try await ReencodeJob.load(asset: AVURLAsset(url: clip.url), frames: clip.media!.frames, segments: plan.grid)
        let encoder = ClipReencoder()
        encoder.cancel()
        do {
            try await encoder.encode(jobs: [job], frameDuration: Rational(1, 24), timescale: plan.outputTimescale,
                                     video: .matching(clip.media!), audio: nil,
                                     outputURL: try checksOutputDirectory().appendingPathComponent("re-cancel.mp4"),
                                     progress: { _ in })
            expect(false, "expected cancellation")
        } catch ReencodeError.cancelled {
            // expected
        }
    }
}

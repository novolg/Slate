import Foundation
import AVFoundation
import CoreMedia
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

/// Precise decoded audio edges: first sample's pts and the end (last sample's pts +
/// duration), both exact `Rational`. Used where `CadenceValidator.audioIssues`' one-AAC-
/// packet tolerance (1024 samples) is too loose — the I1 regression check needs the
/// output's audio end to match the video end within one sample.
func preciseAudioRange(_ url: URL) async throws -> (first: Rational, end: Rational) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw ReencodeError.cannotStartReader("no audio track")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ReencodeError.cannotStartReader("cannot add audio output") }
    reader.add(output)
    guard reader.startReading() else {
        throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
    }
    var first: Rational?
    var end = Rational.zero
    while let buffer = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isNumeric else { continue }
        let p = Rational(pts)
        if first == nil { first = p }
        let dur = CMSampleBufferGetDuration(buffer)
        end = p + (dur.isNumeric ? Rational(dur) : .zero)
    }
    if reader.status == .failed {
        throw ReencodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    }
    guard let first else { throw ReencodeError.cannotStartReader("no decodable audio") }
    return (first, end)
}

/// Cheap AVFoundation-only pin for the Re-encode-all output shape: exactly one video
/// format description (a single encoder pass, unlike the two-`stsd` Mixed/Selective
/// passthrough outputs — see fable-review.md I3), and decode order == presentation
/// order (no B-frames / frame reordering, per `AVVideoAllowFrameReorderingKey: false`).
/// Reads samples with `outputSettings: nil` (no pixel decode) so this stays cheap.
private func assertNoFrameReordering(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw ReencodeError.cannotStartReader("no video track")
    }
    let formats = try await track.load(.formatDescriptions)
    expectEqual(formats.count, 1, "expected exactly one video format description")

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ReencodeError.cannotStartReader("cannot add video output") }
    reader.add(output)
    guard reader.startReading() else {
        throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
    }
    var mismatches = 0
    var prevPTS: Rational?
    while let buffer = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isNumeric else { continue }
        let p = Rational(pts)
        let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
        // An invalid DTS means the format has no separate decode order (DTS == PTS).
        let d = dts.isNumeric ? Rational(dts) : p
        if d != p { mismatches += 1 }
        if let prevPTS, p < prevPTS { mismatches += 1 }
        prevPTS = p
    }
    if reader.status == .failed {
        throw ReencodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    }
    expectEqual(mismatches, 0, "\(mismatches) frame(s) with decode order != presentation order")
}

func runReencoderChecks() async {
    check("reencoder: a missing middle audio buffer is detected") {
        // 4096 wanted samples; buffers cover [0, 1024) and [3072, 4096) → 2048 missing.
        var c = AudioCoverage(start: 0, count: 4096)
        expect(try c.accept(first: 0, count: 1024).range != nil)
        do {
            _ = try c.accept(first: 3072, count: 1024)
            expect(false, "a 2048-sample gap must throw")
        } catch ReencodeError.audioTruncated(let n) {
            expectEqual(n, 2048)
        }
    }

    check("reencoder: AudioCoverage.accept reports the gap it just counted") {
        // 4096 wanted samples; a buffer arriving at 100 instead of 0 is a 100-sample gap.
        var c = AudioCoverage(start: 0, count: 4096)
        let accepted = try c.accept(first: 100, count: 924)
        expectEqual(accepted.gapBefore, 100)
        expect(accepted.range.map { $0 == (100, 1024) } ?? false, "range was \(String(describing: accepted.range))")
        expectEqual(c.missing, 100)
        // A buffer that ends before what's still wanted keeps nothing and reports no gap.
        let stale = try c.accept(first: 0, count: 50)
        expectEqual(stale.gapBefore, 0)
        expect(stale.range == nil)
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

    // I1 (fable-review.md): two clips whose audio is a few hundred samples shorter than
    // their kept video, exported Constant 24 / Re-encode all. Before the fix, the
    // shortfall was only counted, never filled — AVAssetWriter's AAC input collapses the
    // resulting timestamp gap, so the second clip's audio (and everything after it in a
    // longer project) plays early and the drift accumulates. The fix pads each gap with
    // silence at the correct output position, so the track's total length matches the
    // video's exactly.
    await checkAsync("reencoder: re-encode all pads a short-audio gap with silence instead of shifting later clips") {
        let a = try await loadClip("c24_short_a.mp4", keep: [(0, 5.0)])
        let b = try await loadClip("c24_short_a.mp4", keep: [(0, 5.0)])
        let project = Project(clips: [a, b], fpsMode: .constant(frameDuration: Rational(1, 24)),
                              constantStrategy: .reencodeAll)
        let plan = ExportPlanner.plan(project)
        let out = try checksOutputDirectory().appendingPathComponent("re-short-audio-all.mp4")
        let report = try await ProjectExporter().export(project: project, outputURL: out,
                                                        tempDirectory: try checksOutputDirectory(), progress: { _ in })
        expect(report.ok, "export must succeed: \(report.issues)")

        let rate = Int64((plan.audio?.sampleRate ?? 44100).rounded())
        let (first, end) = try await preciseAudioRange(out)
        expect(first.magnitude <= Rational(1024, rate),
              "first audio sample at \(first.seconds) s, expected within one AAC packet of 0")
        let videoEnd = plan.totalDuration
        expect((end - videoEnd).magnitude <= Rational(1, rate),
              "audio ends at \(end.seconds) s, video ends at \(videoEnd.seconds) s — more than one sample off")
    }

    // I3 (fable-review.md, "Missing check" in Minor): pins the properties that make
    // Re-encode all the safe default — one sample description (no mid-stream codec
    // parameter switch) and no frame reordering (decode order == presentation order) —
    // so an encoder-settings regression would be caught here instead of only by chance.
    await checkAsync("reencoder: re-encode all output has one format description and no frame reordering") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let project = Project(clips: [a, b], fpsMode: .constant(frameDuration: Rational(1, 24)),
                              constantStrategy: .reencodeAll)
        let out = try checksOutputDirectory().appendingPathComponent("re-shape-all.mp4")
        let report = try await ProjectExporter().export(project: project, outputURL: out,
                                                        tempDirectory: try checksOutputDirectory(), progress: { _ in })
        expect(report.ok, "\(report.issues)")
        try await assertNoFrameReordering(out)
    }

    check("progress: the clip index follows the written frames") {
        let counts = [24, 48]
        expectEqual(ReencodeProgress.clipIndex(fraction: 0, frameCounts: counts), 1)
        expectEqual(ReencodeProgress.clipIndex(fraction: 23.0 / 72.0, frameCounts: counts), 1)
        expectEqual(ReencodeProgress.clipIndex(fraction: 24.0 / 72.0, frameCounts: counts), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 1, frameCounts: counts), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 0, frameCounts: [0, 10]), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 0.5, frameCounts: []), 1)
    }

    check("encoder settings: bitrate comes from the fastest clip, not the first") {
        let lo = TestData.media(TestData.c24)
        var hi = TestData.media(TestData.c24)
        hi.estimatedDataRate = 30_000_000
        let mixed = VideoEncodeSettings.matching([lo, hi])
        expectEqual(mixed.bitsPerSecond, VideoEncodeSettings.matching(hi).bitsPerSecond)
        expect(mixed.bitsPerSecond > VideoEncodeSettings.matching(lo).bitsPerSecond)
        expectEqual(mixed.codec, VideoEncodeSettings.matching(lo).codec)
    }

    await checkAsync("exporter: Re-encode all reports the real clip index") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let b = try await loadClip("c48.mp4", keep: [(0.5, 1.5)])
        let out = try checksOutputDirectory().appendingPathComponent("ex-progress-index.mp4")
        let seen = SeenClips()
        _ = try await ProjectExporter().export(project: Project(clips: [a, b]), outputURL: out,
                                               tempDirectory: try checksOutputDirectory(), progress: { stage in
            if case .reencoding(let k, let n, _) = stage { seen.add(k, of: n) }
        })
        expectEqual(seen.of, 2)
        expect(seen.indices.contains(1) && seen.indices.contains(2), "saw \(seen.indices)")
    }

    await checkAsync("reencoder: stereo short audio is padded and the export still ends with the video") {
        let a = try await loadClip("c24_st_short_a.mp4", keep: [(0, 5.0)])
        let b = try await loadClip("c24_st_short_a.mp4", keep: [(0, 5.0)])
        expectEqual(a.media?.audio?.channels, 2)
        let project = Project(clips: [a, b])
        let plan = ExportPlanner.plan(project)
        expect(plan.canExport, "\(plan.blockers)")
        let out = try checksOutputDirectory().appendingPathComponent("re-stereo-short-audio.mp4")
        let report = try await ProjectExporter().export(project: project, outputURL: out,
                                                        tempDirectory: try checksOutputDirectory(), progress: { _ in })
        expect(report.ok, "\(report.issues)")
        let rate = Int64((plan.audio?.sampleRate ?? 44100).rounded())
        let (first, end) = try await preciseAudioRange(out)
        expect(first.magnitude <= Rational(1024, rate), "first audio sample at \(first.seconds) s")
        expect((end - plan.totalDuration).magnitude <= Rational(1, rate),
               "audio ends at \(end.seconds) s, video at \(plan.totalDuration.seconds) s")
    }
}

final class SeenClips: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<Int>()
    private var total = 0
    func add(_ k: Int, of n: Int) { lock.withLock { set.insert(k); total = n } }
    var indices: Set<Int> { lock.withLock { set } }
    var of: Int { lock.withLock { total } }
}

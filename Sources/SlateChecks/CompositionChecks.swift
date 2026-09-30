import Foundation
import AVFoundation
import SlateCore

func runCompositionChecks() async {
    await checkAsync("composition: duration equals the plan exactly (mixed 24 + 48)") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        expect(plan.canExport, "\(plan.blockers)")
        let assets: [UUID: AVAsset] = [a.id: AVURLAsset(url: a.url), b.id: AVURLAsset(url: b.url)]
        let comp = try await CompositionBuilder.build(
            inserts: CompositionBuilder.inserts(for: plan.grid, assets: assets),
            includeAudio: false, timescale: plan.outputTimescale)
        expectEqual(Rational(comp.duration), plan.totalDuration)
    }

    await checkAsync("composition: audio a few ms shorter than video does not throw") {
        let a = try await loadClip("c24_a.mp4", keep: [(0, 5)])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        let comp = try await CompositionBuilder.build(
            inserts: CompositionBuilder.inserts(for: plan.grid, assets: [a.id: AVURLAsset(url: a.url)]),
            includeAudio: true, timescale: plan.outputTimescale)
        expectEqual(comp.tracks(withMediaType: .audio).count, 1)
        expectEqual(Rational(comp.duration), Rational(5))
    }

    await checkAsync("composition: a grid segment without an asset throws") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        do {
            _ = try CompositionBuilder.inserts(for: plan.grid, assets: [:])
            expect(false, "expected missingAsset")
        } catch CompositionError.missingAsset(let id) {
            expectEqual(id, a.id)
        }
    }

    await checkAsync("composition: every grid segment lands at its planned output start") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        let comp = try await CompositionBuilder.build(
            inserts: CompositionBuilder.inserts(for: plan.grid, assets: [a.id: AVURLAsset(url: a.url), b.id: AVURLAsset(url: b.url)]),
            includeAudio: false, timescale: plan.outputTimescale)
        let track = comp.tracks(withMediaType: .video)[0]
        let starts = track.segments.filter { !$0.isEmpty }.map { Rational($0.timeMapping.target.start) }
        expectEqual(starts, plan.grid.map(\.outputStart))
    }
}

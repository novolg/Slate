import Foundation
import SlateCore

func runPlannerChecks() {
    let whole = [(Rational.zero, Rational(5))]
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))

    check("planner: constant 24 copies exact 24 and re-encodes 48") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: d24))
        expect(plan.canExport, "\(plan.blockers)")
        expectEqual(plan.plan(for: a.id)?.action, .copy)
        expectEqual(plan.plan(for: b.id)?.action, .reencode(.fpsDiffers))
        expectEqual(plan.outputTimescale, 12288)
        expectEqual(plan.totalFrames, 240)
    }

    check("planner: jittered 23.976 re-encodes in constant, copies in mixed") {
        let jit = TestData.jittered23976(count: 240)
        let c = TestData.clip(TestData.media(jit), keep: [(.zero, jit.clipEnd)])
        let constant = ExportPlanner.plan(Project(clips: [c], fpsMode: .constant(frameDuration: Rational(1001, 24000))))
        expectEqual(constant.plan(for: c.id)?.action, .reencode(.timingNotExact))
        expectEqual(constant.outputTimescale, 360000)
        let mixed = ExportPlanner.plan(Project(clips: [c], fpsMode: .mixed))
        expectEqual(mixed.plan(for: c.id)?.action, .copy)
    }

    check("planner: drift clip (3754 then 3753 ticks) re-encodes in constant") {
        let drift = TestData.drift(first: 3754, second: 3753, count: 100)
        let c = TestData.clip(TestData.media(drift), keep: [(.zero, drift.clipEnd)])
        let plan = ExportPlanner.plan(Project(clips: [c], fpsMode: .constant(frameDuration: Rational(1001, 24000))))
        expectEqual(plan.plan(for: c.id)?.action, .reencode(.timingNotExact))
    }

    check("planner: re-encode all gives the same grid as selective (random projects)") {
        var rng = LCG(state: 7)
        for _ in 0..<100 {
            var clips: [Clip] = []
            for _ in 0..<(1 + rng.next(4)) {
                let frames = rng.next(2) == 0 ? TestData.c24 : TestData.c48
                let s = Rational(Int64(rng.next(300)), 100)
                let e = s + Rational(Int64(rng.next(250)), 100)
                clips.append(TestData.clip(TestData.media(frames), keep: [(s, min(e, Rational(5)))]))
            }
            let sel = ExportPlanner.plan(Project(clips: clips, fpsMode: d24, constantStrategy: .selective))
            let all = ExportPlanner.plan(Project(clips: clips, fpsMode: d24, constantStrategy: .reencodeAll))
            expectEqual(sel.grid, all.grid)
            for cp in all.clips where !cp.segments.isEmpty {
                expectEqual(cp.action, .reencode(.reencodeAll))
            }
        }
    }

    check("planner: blocks missing file, size, codec and audio mismatch") {
        let ref = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let missing = TestData.clip(nil, keep: whole)
        let small = TestData.clip(TestData.media(TestData.c24, width: 320, height: 180), keep: whole)
        let hevc = TestData.clip(TestData.media(TestData.c24, codec: "hvc1"), keep: whole)
        let loud = TestData.clip(TestData.media(TestData.c24, audio: true), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [missing, ref, small, hevc, loud], fpsMode: .mixed))
        expect(!plan.canExport)
        expectEqual(plan.plan(for: missing.id)?.action, .blocked(.missingFile))
        expectEqual(plan.plan(for: ref.id)?.action, .copy)
        expectEqual(plan.plan(for: small.id)?.action, .blocked(.frameSizeMismatch))
        expectEqual(plan.plan(for: hevc.id)?.action, .blocked(.codecMismatch))
        expectEqual(plan.plan(for: loud.id)?.action, .blocked(.audioMismatch))
        expect(plan.blockers.contains(.clip(missing.id, .missingFile)))
    }

    check("planner: clip with no segments is skipped, not blocked") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
        let plan = ExportPlanner.plan(Project(clips: [a, empty], fpsMode: d24))
        expect(plan.canExport)
        expectEqual(plan.plan(for: empty.id)?.action, .skipped)
    }

    check("planner: only a sub-frame selection blocks with noFrames in every strategy") {
        let c = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1, 100))])
        for strategy in [ConstantStrategy.selective, .reencodeAll] {
            let plan = ExportPlanner.plan(Project(clips: [c], fpsMode: d24, constantStrategy: strategy))
            expect(plan.blockers.contains(.noFrames), "\(strategy)")
            expectEqual(plan.plan(for: c.id)?.droppedSegmentIDs, c.segments.map(\.id))
        }
        expect(ExportPlanner.plan(Project()).blockers.contains(.noClips))
    }
}

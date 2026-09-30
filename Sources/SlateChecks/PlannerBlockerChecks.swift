import Foundation
import SlateCore

func runPlannerBlockerChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("planner: an unsupported codec blocks only that clip, even when it is first") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let good = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores, good]))
        expectEqual(plan.plan(for: prores.id)?.action, ClipAction.blocked(.unsupportedCodec))
        expect(plan.plan(for: good.id)?.action != ClipAction.blocked(.codecMismatch), "good clip must not be a mismatch")
        expect(plan.blockers.contains(.clip(prores.id, .unsupportedCodec)))
        expectEqual(plan.reference?.codec, fourCC("avc1"))
    }

    check("planner: unsupported codec is blocked in Mixed mode too, and hvc1/hev1 are allowed") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores], fpsMode: .mixed))
        expectEqual(plan.plan(for: prores.id)?.action, ClipAction.blocked(.unsupportedCodec))
        expect(!plan.canExport)
        for codec in ["avc1", "hvc1", "hev1"] {
            let c = TestData.clip(TestData.media(TestData.c24, codec: codec), keep: whole)
            expect(ExportPlanner.plan(Project(clips: [c], fpsMode: .mixed)).canExport, codec)
        }
    }

    check("planner: only unsupported clips gives no reference and no crash") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores]))
        expect(plan.reference == nil)
        expect(!plan.canExport)
    }

    check("planner: different audio sample rate or channel count is blocked") {
        var stereo = TestData.media(TestData.c24, audio: true)
        stereo.audio = AudioFormat(sampleRate: 44100, channels: 2)
        var rate48 = TestData.media(TestData.c24, audio: true)
        rate48.audio = AudioFormat(sampleRate: 48000, channels: 1)
        let ref = TestData.clip(TestData.media(TestData.c24, audio: true), keep: whole)
        let st = TestData.clip(stereo, keep: whole)
        let hi = TestData.clip(rate48, keep: whole)
        for mode in [FPSMode.mixed, .constant(frameDuration: Rational(1, 24))] {
            let plan = ExportPlanner.plan(Project(clips: [ref, st, hi], fpsMode: mode))
            expectEqual(plan.plan(for: st.id)?.action, ClipAction.blocked(.audioFormatMismatch), "\(mode)")
            expectEqual(plan.plan(for: hi.id)?.action, ClipAction.blocked(.audioFormatMismatch), "\(mode)")
            expect(plan.plan(for: ref.id)?.action != ClipAction.blocked(.audioFormatMismatch))
        }
    }

    check("planner: Mixed clips whose timescales cannot share one timeline are blocked") {
        let odd = FrameTable.uniform(count: 50, frameDuration: Rational(1, 25), timescale: 2_147_483_629) // large prime
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        let b = TestData.clip(TestData.media(odd), keep: [(.zero, Rational(1))])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        expect(plan.blockers.contains(.timescaleOverflow), "\(plan.blockers)")
        expect(!plan.canExport)
    }
}

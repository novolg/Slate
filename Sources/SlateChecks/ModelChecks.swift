import Foundation
import SlateCore

func runModelChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("model: a new project starts in Constant 24 + Re-encode all") {
        let p = Project()
        expectEqual(p.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        expectEqual(p.constantStrategy, ConstantStrategy.reencodeAll)
    }

    check("model: a default project re-encodes every clip (hidden Selective is never used)") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b]))
        expect(plan.canExport, "\(plan.blockers)")
        for cp in plan.clips { expectEqual(cp.action, ClipAction.reencode(.reencodeAll)) }
    }

    check("model: picker lists exact frame durations, fastest first, no duplicates") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let c = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        expectEqual(FrameRateChoice.candidates(for: [a, gone, b, c]), [Rational(1, 48), Rational(1, 24)])
        expectEqual(FrameRateChoice.highest(for: [a, b]), Rational(1, 48))
        expectEqual(FrameRateChoice.highest(for: [gone]), nil)
        expectEqual(FrameRateChoice.highest(for: []), nil)
    }

    check("model: picker falls back to the nominal fps when no clip is exact CFR") {
        var m = TestData.media(TestData.jittered23976(count: 240))
        m.nominalFPS = 24000.0 / 1001.0
        let jit = TestData.clip(m, keep: [(.zero, Rational(5))])
        expectEqual(FrameRateChoice.candidates(for: [jit]), [Rational(1001, 24000)])
    }

    check("model: exact clips win over the nominal fallback of jittered clips") {
        var m = TestData.media(TestData.jittered23976(count: 240))
        m.nominalFPS = 24000.0 / 1001.0
        let jit = TestData.clip(m, keep: [(.zero, Rational(5))])
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        expectEqual(FrameRateChoice.candidates(for: [jit, a]), [Rational(1, 24)])
    }

    check("model: picker ignores jittered clips with an unusable nominal fps") {
        func jitter(_ fps: Double) -> Clip {
            var m = TestData.media(TestData.jittered23976(count: 240))
            m.nominalFPS = fps
            return TestData.clip(m, keep: [(.zero, Rational(5))])
        }
        for bad in [0.0, Double.nan, Double.infinity, -24.0] {
            expectEqual(FrameRateChoice.candidates(for: [jitter(bad)]), [], "\(bad)")
            expectEqual(FrameRateChoice.highest(for: [jitter(bad)]), nil, "\(bad)")
        }
        let good = jitter(24000.0 / 1001.0)
        expectEqual(FrameRateChoice.candidates(for: [jitter(0), jitter(.nan), jitter(.infinity), good]),
                    [Rational(1001, 24000)])
    }
}

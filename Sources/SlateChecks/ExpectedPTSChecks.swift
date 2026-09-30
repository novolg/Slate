import Foundation
import SlateCore

func runExpectedPTSChecks() {
    check("expected pts: Mixed 24 then 48 gives the source frames moved onto the output timeline") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        let b = TestData.clip(TestData.media(TestData.c48), keep: [(.zero, Rational(1))])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        let expected = plan.expectedPTS ?? []
        expectEqual(expected.count, 72)
        expectEqual(expected.count, plan.totalFrames)
        expectEqual(Array(expected[0..<24]), (0..<24).map { Rational(Int64($0), 24) })
        expectEqual(Array(expected[24...]), (0..<48).map { Rational(1) + Rational(Int64($0), 48) })
    }

    check("expected pts: a mid-clip selection starts at its snapped source frame, shifted to the output start") {
        // keep [1.0, 1.5) of the 24 fps clip → frames 24…35 land at 0…11/24.
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(Rational(1), Rational(3, 2))])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        expectEqual(plan.expectedPTS ?? [], (0..<12).map { Rational(Int64($0), 24) })
    }

    check("expected pts: only Mixed plans that can export carry the list") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        expect(ExportPlanner.plan(Project(clips: [a])).expectedPTS == nil, "Constant plan")
        let blocked = TestData.clip(nil, keep: [(.zero, Rational(1))])
        expect(ExportPlanner.plan(Project(clips: [a, blocked], fpsMode: .mixed)).expectedPTS == nil, "blocked plan")
    }

    check("validator: Mixed exact check reports a shifted frame and stays quiet on a perfect list") {
        let expected = (0..<10).map { Rational(Int64($0), 24) }
        let ok = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(10, 24),
                                              expectedDuration: Rational(10, 24), pts: expected, expectedPTS: expected)
        expect(ok.isEmpty, "\(ok)")
        var shifted = expected
        for i in 5..<10 { shifted[i] = shifted[i] - Rational(1, 16) }
        let bad = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(10, 24),
                                               expectedDuration: Rational(10, 24), pts: shifted, expectedPTS: expected)
        expect(bad.count >= 1 && bad[0].contains("frame 5"), "\(bad)")
    }

    check("validator: Mixed duration must match exactly (no 1 ms tolerance)") {
        let issues = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10,
                                                  duration: Rational(1) + Rational(1, 2000), expectedDuration: Rational(1))
        expect(!issues.isEmpty)
    }
}

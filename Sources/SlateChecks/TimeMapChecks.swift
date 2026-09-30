import Foundation
import SlateCore

func runTimeMapChecks() {
    let a = TestData.clip(TestData.media(TestData.c24), keep: [(Rational(2), Rational(3)), (Rational(4), Rational(5))])
    let b = TestData.clip(TestData.media(TestData.c48), keep: [(Rational(1), Rational(2))])
    let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
    let plan = ExportPlanner.plan(Project(clips: [a, empty, b], fpsMode: .constant(frameDuration: Rational(1, 24))))
    let map = ProjectTimeMap(grid: plan.grid)

    check("timemap: total equals the plan") {
        expectEqual(map.totalDuration, plan.totalDuration)
        expectEqual(map.totalDuration, Rational(3))
    }

    check("timemap: segment edges map to the right clip") {
        expectEqual(map.locate(.zero)?.sourceTime, Rational(2))
        expectEqual(map.locate(Rational(1))?.sourceTime, Rational(4))
        expectEqual(map.locate(Rational(1))?.clipID, a.id)
        expectEqual(map.locate(Rational(2))?.clipID, b.id)
        expectEqual(map.locate(Rational(2))?.sourceTime, Rational(1))
        expectEqual(map.locate(Rational(3))?.sourceTime, Rational(2), "end maps to the last source end")
        expectEqual(map.locate(Rational(-1))?.sourceTime, Rational(2))
    }

    check("timemap: round trip for every output frame") {
        for (i, g) in plan.grid.enumerated() {
            for f in 0..<g.frameCount {
                let t = g.outputStart + Rational(1, 24) * f
                guard let loc = map.locate(t) else { expect(false, "no location at \(t)"); continue }
                expectEqual(loc.gridIndex, i)
                expectEqual(map.projectTime(clipID: loc.clipID, sourceTime: loc.sourceTime), t)
            }
        }
    }

    check("timemap: clip with no kept frames has no output time") {
        expect(map.firstOutputStart(of: empty.id) == nil)
        expect(map.projectTime(clipID: empty.id, sourceTime: .zero) == nil)
        expectEqual(map.firstOutputStart(of: b.id), Rational(2))
        expect(map.projectTime(clipID: a.id, sourceTime: Rational(7, 2)) == nil, "removed interval")
        expect(ProjectTimeMap(grid: []).locate(.zero) == nil)
    }
}

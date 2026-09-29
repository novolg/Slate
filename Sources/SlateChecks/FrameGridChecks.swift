import Foundation
import CoreMedia
import SlateCore

private func seg(_ a: Rational, _ b: Rational) -> Segment {
    Segment(range: CMTimeRange(start: a.cmTime, end: b.cmTime))
}

private func input(_ frames: FrameTable, _ segs: [Segment]) -> FrameGrid.ClipInput {
    FrameGrid.ClipInput(clipID: UUID(), frames: frames, segments: segs)
}

/// Deterministic pseudo-random generator for property checks.
struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

func runFrameGridChecks() {
    let c24 = FrameTable.uniform(count: 120, frameDuration: Rational(1, 24), timescale: 12288)
    let c48 = FrameTable.uniform(count: 240, frameDuration: Rational(1, 48), timescale: 12288)
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
    let d48 = FPSMode.constant(frameDuration: Rational(1, 48))

    check("framegrid: constant full clip keeps every frame") {
        let r = FrameGrid.build([input(c24, [seg(.zero, Rational(5))])], mode: d24)
        expectEqual(r.segments.count, 1)
        expectEqual(r.segments[0].frameCount, 120)
        expectEqual(r.totalDuration, Rational(5))
        let r48 = FrameGrid.build([input(c24, [seg(.zero, Rational(5))])], mode: d48)
        expectEqual(r48.segments[0].frameCount, 240)
    }

    check("framegrid: mixed full 5-frame clip keeps all 5 frames") {
        let five = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)
        let r = FrameGrid.build([input(five, [seg(.zero, five.clipEnd)])], mode: .mixed)
        expectEqual(r.totalFrames, 5)
        let jit = TestData.jittered23976(count: 50)
        let rj = FrameGrid.build([input(jit, [seg(.zero, jit.clipEnd)])], mode: .mixed)
        expectEqual(rj.totalFrames, 50)
        expectEqual(rj.totalDuration, jit.clipEnd)
    }

    check("framegrid: selection shorter than one frame is dropped") {
        let s = seg(.zero, Rational(1, 100))
        let r = FrameGrid.build([input(c24, [s])], mode: d24)
        expect(r.segments.isEmpty)
        expectEqual(r.dropped, [s.id])
        expectEqual(r.totalFrames, 0)
    }

    check("framegrid: clamps at clip end") {
        let r = FrameGrid.build([input(c24, [seg(Rational(49, 10), Rational(53, 10))])], mode: d24)
        expectEqual(r.segments.count, 1)
        expectEqual(r.segments[0].sourceStart, Rational(118, 24))
        expectEqual(r.segments[0].frameCount, 2)
        expect(r.segments[0].sourceEnd <= c24.clipEnd)
    }

    check("framegrid: gaps between kept ranges are skipped") {
        let six = FrameTable.uniform(count: 144, frameDuration: Rational(1, 24), timescale: 12288)
        let r = FrameGrid.build([input(six, [seg(Rational(2), Rational(3)), seg(Rational(4), Rational(5))])], mode: d48)
        expectEqual(r.segments.map(\.outputStart), [Rational(0), Rational(1)])
        expectEqual(r.segments.map(\.sourceStart), [Rational(2), Rational(4)])
        expectEqual(r.segments.map(\.frameCount), [48, 48])
    }

    check("framegrid: adjacent selections never share a frame") {
        // s1 snaps up to 1/24 and rounds to 2 frames → ends at 3/24.
        // s2 starts at 0.085, whose nearest boundary 2/24 is inside s1's output.
        let s1 = seg(Rational(21, 1000), Rational(84, 1000))
        let s2 = seg(Rational(85, 1000), Rational(1))
        let r = FrameGrid.build([input(c24, [s1, s2])], mode: d24)
        expectEqual(r.segments.count, 2)
        expect(r.segments[1].sourceStart >= r.segments[0].sourceEnd,
               "second starts at \(r.segments[1].sourceStart), first ends at \(r.segments[0].sourceEnd)")
    }

    check("framegrid: a pushed start lands on a source boundary") {
        let s1 = seg(Rational(21, 1000), Rational(51, 1000))
        let s2 = seg(Rational(52, 1000), Rational(100, 1000))
        let r = FrameGrid.build([input(c24, [s1, s2])], mode: d48)
        expectEqual(r.segments.count, 2)
        expectEqual(r.segments[1].sourceStart, Rational(2, 24))
        expectEqual(r.segments[1].frameCount, 2, "pushing the start keeps N")
    }

    check("framegrid: constant offsets are multiples of d (random projects)") {
        var rng = LCG(state: 42)
        for _ in 0..<200 {
            var clips: [FrameGrid.ClipInput] = []
            for _ in 0..<(1 + rng.next(4)) {
                let frames = rng.next(2) == 0 ? c24 : c48
                var segs: [Segment] = []
                var t = Rational(Int64(rng.next(50)), 100)
                while t < Rational(5) {
                    let len = Rational(Int64(1 + rng.next(150)), 100)
                    segs.append(seg(t, min(t + len, Rational(5))))
                    t = t + len + Rational(Int64(1 + rng.next(80)), 100)
                }
                clips.append(input(frames, segs))
            }
            let r = FrameGrid.build(clips, mode: d24)
            for g in r.segments {
                expectEqual((g.outputStart / Rational(1, 24)).den, 1)
                expectEqual(g.outputDuration, Rational(1, 24) * g.frameCount)
            }
        }
    }

    check("framegrid: 23.976 rational math") {
        let ideal = TestData.ideal23976(count: 240)
        let r = FrameGrid.build([input(ideal, [seg(.zero, ideal.clipEnd)])],
                                mode: .constant(frameDuration: Rational(1001, 24000)))
        expectEqual(r.totalFrames, 240)
        expectEqual(r.totalDuration, Rational(1001, 100))
    }
}

import Foundation
import CoreMedia
import SlateCore

func runRetimerChecks() {
    check("retimer: 24→48 doubles each frame, even at timescale 24") {
        let five = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)
        let picks = FrameRetimer.sourceFrameIndices(frames: five, sourceStart: .zero,
                                                    frameDuration: Rational(1, 48), count: 10)
        expectEqual(picks, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    check("retimer: 48→24 keeps every second frame") {
        let ten = FrameTable.uniform(count: 10, frameDuration: Rational(1, 48), timescale: 12288)
        let picks = FrameRetimer.sourceFrameIndices(frames: ten, sourceStart: .zero,
                                                    frameDuration: Rational(1, 24), count: 5)
        expectEqual(picks, [0, 2, 4, 6, 8])
    }

    check("retimer: same rate is identity") {
        let c = FrameTable.uniform(count: 30, frameDuration: Rational(1, 30), timescale: 30000)
        let picks = FrameRetimer.sourceFrameIndices(frames: c, sourceStart: .zero,
                                                    frameDuration: Rational(1, 30), count: 30)
        expectEqual(picks, Array(0..<30))
    }

    check("retimer: VFR input with a hole holds the previous frame") {
        let vfr = FrameTable(pts: [Rational(0), Rational(1, 24), Rational(3, 24), Rational(4, 24)],
                             durations: [Rational(1, 24), Rational(2, 24), Rational(1, 24), Rational(1, 24)],
                             timescale: 24)
        let picks = FrameRetimer.sourceFrameIndices(frames: vfr, sourceStart: .zero,
                                                    frameDuration: Rational(1, 24), count: 5)
        expectEqual(picks, [0, 1, 1, 2, 3])
    }

    check("retimer: kept ranges with a gap map each segment on its own") {
        let six = FrameTable.uniform(count: 144, frameDuration: Rational(1, 24), timescale: 12288)
        let grid = FrameGrid.build([FrameGrid.ClipInput(clipID: UUID(), frames: six, segments: [
            Segment(range: CMTimeRange(start: Rational(2).cmTime, end: Rational(3).cmTime)),
            Segment(range: CMTimeRange(start: Rational(4).cmTime, end: Rational(5).cmTime)),
        ])], mode: .constant(frameDuration: Rational(1, 48)))
        let first = FrameRetimer.sourceFrameIndices(frames: six, sourceStart: grid.segments[0].sourceStart,
                                                    frameDuration: Rational(1, 48), count: grid.segments[0].frameCount)
        let second = FrameRetimer.sourceFrameIndices(frames: six, sourceStart: grid.segments[1].sourceStart,
                                                     frameDuration: Rational(1, 48), count: grid.segments[1].frameCount)
        expectEqual(Array(first.prefix(4)), [48, 48, 49, 49])
        expectEqual(first.last, 71)
        expectEqual(Array(second.prefix(2)), [96, 96])
        expectEqual(second.last, 119)
    }

    check("retimer: adjacent selections share no source frame (24→48 and VFR)") {
        let vfr = FrameTable(pts: [0, 1, 3, 4, 5, 6].map { Rational(Int64($0), 24) },
                             durations: [1, 2, 1, 1, 1, 1].map { Rational(Int64($0), 24) }, timescale: 24)
        let d = Rational(1, 48)
        for frames in [TestData.c24, vfr] {
            // Review case: without boundary pushing, starts are 1/24 and 1/16 and both show frame 1.
            let s1 = Segment(range: CMTimeRange(start: Rational(21, 1000).cmTime, end: Rational(51, 1000).cmTime))
            let s2 = Segment(range: CMTimeRange(start: Rational(52, 1000).cmTime, end: Rational(100, 1000).cmTime))
            let r = FrameGrid.build([FrameGrid.ClipInput(clipID: UUID(), frames: frames, segments: [s1, s2])],
                                    mode: .constant(frameDuration: d))
            expectEqual(r.segments.count, 2)
            let picks = r.segments.map {
                Set(FrameRetimer.sourceFrameIndices(frames: frames, sourceStart: $0.sourceStart,
                                                    frameDuration: d, count: $0.frameCount))
            }
            expect(picks[0].isDisjoint(with: picks[1]), "shared: \(picks[0].intersection(picks[1]))")
            expect(frames.boundaries.contains(r.segments[1].sourceStart), "start must be a source boundary")
        }
    }

    check("retimer: jittered 23.976 with τ matches exact picks on the ideal source") {
        let jit = TestData.jittered23976(count: 2400)
        let ideal = TestData.ideal23976(count: 2400)
        for d in [Rational(1, 24), Rational(1, 30), Rational(1, 48)] {
            let n = Int(((ideal.pts.last!) / d).floor())
            let exact = FrameRetimer.sourceFrameIndices(frames: ideal, sourceStart: .zero,
                                                        frameDuration: d, count: n, tolerance: .zero)
            let withTau = FrameRetimer.sourceFrameIndices(frames: jit, sourceStart: .zero,
                                                          frameDuration: d, count: n)
            expectEqual(withTau, exact, "d = \(d)")
        }
    }
}

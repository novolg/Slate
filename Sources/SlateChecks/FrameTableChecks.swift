import Foundation
import SlateCore

func runFrameTableChecks() {
    let five24 = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)

    check("frametable: boundaries include clip end") {
        expectEqual(five24.clipEnd, Rational(5, 24))
        expectEqual(five24.boundaries.count, 6)
        expectEqual(five24.boundaries.last, Rational(5, 24))
    }

    check("frametable: exact CFR detection") {
        expectEqual(five24.exactFrameDuration, Rational(1, 24))
        expectEqual(TestData.ideal23976(count: 240).exactFrameDuration, Rational(1001, 24000))
        expect(TestData.jittered23976(count: 240).exactFrameDuration == nil, "jittered 23.976 must not be exact")
        expect(TestData.drift(first: 3754, second: 3753, count: 100).exactFrameDuration == nil)
        // Equal durations but a hole in the pts sequence is not CFR either.
        let holed = FrameTable(pts: [Rational(0), Rational(1, 24), Rational(3, 24)],
                               durations: Array(repeating: Rational(1, 24), count: 3), timescale: 24)
        expect(holed.exactFrameDuration == nil)
    }

    check("frametable: pick tolerance is one tick only when a tick is ≤ 1% of a frame") {
        expectEqual(five24.pickTolerance, Rational.zero)
        expectEqual(TestData.jittered23976(count: 10).pickTolerance, Rational(1, 90000))
        expectEqual(FrameTable.uniform(count: 3, frameDuration: Rational(1, 24), timescale: 12288).pickTolerance,
                    Rational(1, 12288))
    }

    check("frametable: nearest boundary, ties go earlier") {
        expectEqual(five24.nearestBoundaryIndex(to: Rational(5, 24)), 5)
        expectEqual(five24.nearestBoundaryIndex(to: Rational(1, 5)), 5)     // 0.2 is nearer 5/24 than 4/24
        expectEqual(five24.nearestBoundaryIndex(to: Rational(1, 48)), 0)    // exact tie → earlier
        expectEqual(five24.nearestBoundaryIndex(to: Rational(-1)), 0)
        expectEqual(five24.nearestBoundaryIndex(to: Rational(10)), 5)
    }

    check("frametable: last frame at or before") {
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(1, 48)), 0)
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(1, 24)), 1)
        expect(five24.lastFrameIndex(atOrBefore: Rational(-1, 100)) == nil)
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(99)), 4)
    }

    check("frametable: first boundary at or after") {
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(1, 16)), 2)   // 1/16 is between 1/24 and 2/24
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(1, 24)), 1)   // exact boundary
        expectEqual(five24.firstBoundaryIndex(atOrAfter: .zero), 0)
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(9)), 5)      // clamps to clip end
    }
}

import Foundation
import SlateCore

enum TestData {
    /// 23.976 fps stored at timescale 90000: ticks_k = round(k · 3753.75), so
    /// durations alternate 3753/3754. Not exact CFR.
    static func jittered23976(count: Int) -> FrameTable {
        let step = Rational(15015, 4) // 90000 · 1001 / 24000 = 3753.75 ticks
        let ticks = (0...count).map { (Rational(Int64($0)) * step).rounded() }
        let pts = (0..<count).map { Rational(ticks[$0], 90000) }
        let durations = (0..<count).map { Rational(ticks[$0 + 1] - ticks[$0], 90000) }
        return FrameTable(pts: pts, durations: durations, timescale: 90000)
    }

    /// Ideal rational 23.976 source (exact CFR at 1001/24000).
    static func ideal23976(count: Int) -> FrameTable {
        FrameTable.uniform(count: count, frameDuration: Rational(1001, 24000), timescale: 24000)
    }

    /// `count` frames of `first` ticks then `count` frames of `second` ticks (timescale 90000).
    static func drift(first: Int64, second: Int64, count: Int) -> FrameTable {
        var pts: [Rational] = []
        var durations: [Rational] = []
        var t: Int64 = 0
        for i in 0..<(2 * count) {
            let d = i < count ? first : second
            pts.append(Rational(t, 90000))
            durations.append(Rational(d, 90000))
            t += d
        }
        return FrameTable(pts: pts, durations: durations, timescale: 90000)
    }
}

import Foundation

/// Actual video sample timing of one clip, in presentation order.
public struct FrameTable: Equatable {
    public let pts: [Rational]
    public let durations: [Rational]
    /// Track timescale (ticks per second) the times came from.
    public let timescale: Int32

    public init(pts: [Rational], durations: [Rational], timescale: Int32) {
        precondition(!pts.isEmpty && pts.count == durations.count, "FrameTable: bad input")
        self.pts = pts
        self.durations = durations
        self.timescale = timescale
    }

    public static func uniform(count: Int, frameDuration: Rational, timescale: Int32,
                               start: Rational = .zero) -> FrameTable {
        FrameTable(pts: (0..<count).map { start + frameDuration * $0 },
                   durations: Array(repeating: frameDuration, count: count),
                   timescale: timescale)
    }

    public var count: Int { pts.count }

    public var clipEnd: Rational { pts[pts.count - 1] + durations[durations.count - 1] }

    /// Valid cut points: every frame start plus the clip end.
    public var boundaries: [Rational] { pts + [clipEnd] }

    /// The frame duration when every duration and every pts gap are exactly equal. No tolerance.
    public var exactFrameDuration: Rational? {
        let d = durations[0]
        guard d > .zero else { return nil }
        for i in 0..<count {
            if durations[i] != d { return nil }
            if i + 1 < count, pts[i + 1] - pts[i] != d { return nil }
        }
        return d
    }

    /// Retimer tolerance τ: one tick when a tick is at most 1% of the shortest frame, else 0.
    public var pickTolerance: Rational {
        let tick = Rational(1, Int64(timescale))
        guard let shortest = durations.min() else { return .zero }
        return tick * 100 <= shortest ? tick : .zero
    }

    /// First index i in `xs` with xs[i] >= t (xs.count if none).
    private func lowerBound(in xs: [Rational], _ t: Rational) -> Int {
        var lo = 0
        var hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index into `boundaries` (0...count) nearest to `t`. Ties go to the earlier boundary.
    public func nearestBoundaryIndex(to t: Rational) -> Int {
        let b = boundaries
        let lo = lowerBound(in: b, t)
        if lo == 0 { return 0 }
        if lo == b.count { return b.count - 1 }
        return (t - b[lo - 1]) <= (b[lo] - t) ? lo - 1 : lo
    }

    /// Largest frame index whose pts ≤ `t`, or nil if `t` is before the first frame.
    public func lastFrameIndex(atOrBefore t: Rational) -> Int? {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Smallest index into `boundaries` whose value is ≥ `t` (count when `t` > clipEnd is clamped to count).
    public func firstBoundaryIndex(atOrAfter t: Rational) -> Int {
        let b = boundaries
        let lo = lowerBound(in: b, t)
        return min(lo, b.count - 1)
    }
}

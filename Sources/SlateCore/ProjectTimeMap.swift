import Foundation

/// Converts between project time (assembled output) and source time (one clip file).
/// Built from the planner's grid, so it matches the export exactly.
public struct ProjectTimeMap: Equatable {
    public struct Location: Equatable {
        public let clipID: UUID
        public let segmentID: UUID
        public let gridIndex: Int
        public let sourceTime: Rational
    }

    public let grid: [GridSegment]

    public init(grid: [GridSegment]) {
        self.grid = grid
    }

    public var totalDuration: Rational { grid.last?.outputEnd ?? .zero }

    /// Project time → clip and source time. Times before 0 clamp to the start;
    /// times at or past the end map to the end of the last segment.
    public func locate(_ t: Rational) -> Location? {
        guard !grid.isEmpty else { return nil }
        var lo = 0
        var hi = grid.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if grid[mid].outputStart <= t { lo = mid + 1 } else { hi = mid }
        }
        let k = max(lo - 1, 0)
        let g = grid[k]
        let source: Rational
        if t <= g.outputStart {
            source = g.sourceStart
        } else if t >= g.outputEnd {
            source = g.sourceEnd
        } else {
            source = g.sourceStart + (t - g.outputStart)
        }
        return Location(clipID: g.clipID, segmentID: g.segmentID, gridIndex: k, sourceTime: source)
    }

    /// Source time in a clip → project time, or nil if that source time is not kept.
    public func projectTime(clipID: UUID, sourceTime st: Rational) -> Rational? {
        for g in grid where g.clipID == clipID && g.sourceStart <= st && st < g.sourceEnd {
            return g.outputStart + (st - g.sourceStart)
        }
        return nil
    }

    public func firstOutputStart(of clipID: UUID) -> Rational? {
        grid.first { $0.clipID == clipID }?.outputStart
    }
}

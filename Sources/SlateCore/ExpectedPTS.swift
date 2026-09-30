import Foundation

/// The exact decoded presentation times a passthrough (Mixed) export must have.
/// Mixed copies frames, so the list is known before export: for every grid segment,
/// the source frames with pts in [sourceStart, sourceEnd), moved by outputStart − sourceStart.
public enum ExpectedPTS {
    public static func mixed(grid: [GridSegment], tables: [UUID: FrameTable]) -> [Rational] {
        var out: [Rational] = []
        for g in grid {
            guard let table = tables[g.clipID] else { continue }
            let shift = g.outputStart - g.sourceStart
            let end = g.sourceEnd
            for p in table.pts where p >= g.sourceStart && p < end {
                out.append(p + shift)
            }
        }
        return out
    }
}

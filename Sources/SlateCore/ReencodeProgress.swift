import Foundation

public enum ReencodeProgress {
    /// The 1-based clip the encoder is working on when `fraction` of all frames are written.
    /// `frameCounts` has one entry per re-encode job, in order.
    public static func clipIndex(fraction: Double, frameCounts: [Int]) -> Int {
        guard !frameCounts.isEmpty else { return 1 }
        let total = frameCounts.reduce(0, +)
        guard total > 0 else { return 1 }
        let written = Int((fraction * Double(total)).rounded(.down))
        var upTo = 0
        for (i, n) in frameCounts.enumerated() {
            upTo += n
            if written < upTo { return i + 1 }
        }
        return frameCounts.count
    }
}

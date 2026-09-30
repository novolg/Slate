import Foundation

public enum FrameRetimer {
    /// For output frames 0..<count of one grid segment, the source frame index to show.
    /// Output frame i shows the source frame with the largest pts ≤ s' + i·d + τ.
    /// τ defaults to `frames.pickTolerance` (0 when a tick is coarse, so it never
    /// moves the choice to a later frame).
    public static func sourceFrameIndices(frames: FrameTable, sourceStart: Rational,
                                          frameDuration d: Rational, count: Int,
                                          tolerance: Rational? = nil) -> [Int] {
        let tau = tolerance ?? frames.pickTolerance
        return (0..<count).map { i in
            frames.lastFrameIndex(atOrBefore: sourceStart + d * i + tau) ?? 0
        }
    }
}

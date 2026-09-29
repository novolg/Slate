import Foundation
import CoreMedia

/// One kept range after quantization, placed on the output timeline.
public struct GridSegment: Equatable {
    public let clipID: UUID
    public let segmentID: UUID
    /// s' — where reading starts in the source clip.
    public let sourceStart: Rational
    /// N — output frames for this range.
    public let frameCount: Int
    /// O_k — where this range starts in the output.
    public let outputStart: Rational
    /// N · d (Constant), N · srcD (Mixed exact CFR), or e' − s' (Mixed non-exact).
    public let outputDuration: Rational

    public init(clipID: UUID, segmentID: UUID, sourceStart: Rational, frameCount: Int,
                outputStart: Rational, outputDuration: Rational) {
        self.clipID = clipID
        self.segmentID = segmentID
        self.sourceStart = sourceStart
        self.frameCount = frameCount
        self.outputStart = outputStart
        self.outputDuration = outputDuration
    }

    /// Source and output ranges always have the same length.
    public var sourceEnd: Rational { sourceStart + outputDuration }
    public var outputEnd: Rational { outputStart + outputDuration }
}

public struct QuantizedRange: Equatable {
    public let sourceStart: Rational
    public let frameCount: Int
    public let duration: Rational
}

/// The single quantization policy. It runs before any copy/re-encode decision,
/// so the export strategy can never change the edit.
public enum FrameGrid {
    /// Quantize one kept range `[s, e)`.
    /// - unit: d in Constant mode, the clip's exact srcD in Mixed mode, nil for a
    ///   non-exact-CFR clip in Mixed mode.
    /// - notBefore: end of the previous quantized range of the same clip. The start
    ///   is pushed to the first source-frame boundary at or after it, so two
    ///   selections never share a source frame (also at 24→48 and for VFR).
    ///   Pushing the start keeps the wanted frame count N (the output length the user
    ///   selected); only the clip-end clamp can shorten it.
    public static func quantize(start s: Rational, end e: Rational, frames: FrameTable,
                                unit: Rational?, notBefore: Rational = .zero) -> QuantizedRange? {
        let b = frames.boundaries
        let floorIndex = frames.firstBoundaryIndex(atOrAfter: notBefore)
        let a = max(frames.nearestBoundaryIndex(to: s), floorIndex)
        if let unit {
            let sp = b[a]
            let wanted = ((e - s) / unit).rounded()
            let fits = ((frames.clipEnd - sp) / unit).floor()
            let n = min(wanted, fits)
            guard n > 0 else { return nil }
            return QuantizedRange(sourceStart: sp, frameCount: Int(n), duration: unit * Int(n))
        }
        let z = frames.nearestBoundaryIndex(to: e)
        guard z > a else { return nil }
        return QuantizedRange(sourceStart: b[a], frameCount: z - a, duration: b[z] - b[a])
    }

    public struct ClipInput {
        public let clipID: UUID
        public let frames: FrameTable
        public let segments: [Segment]

        public init(clipID: UUID, frames: FrameTable, segments: [Segment]) {
            self.clipID = clipID
            self.frames = frames
            self.segments = segments
        }
    }

    public struct Result: Equatable {
        public let segments: [GridSegment]
        /// Ids of kept segments that quantized to zero frames.
        public let dropped: [UUID]
        public let totalDuration: Rational

        public var totalFrames: Int { segments.reduce(0) { $0 + $1.frameCount } }
    }

    public static func build(_ clips: [ClipInput], mode: FPSMode) -> Result {
        var out: [GridSegment] = []
        var dropped: [UUID] = []
        var cursor = Rational.zero
        for clip in clips {
            let unit: Rational?
            switch mode {
            case .constant(let d): unit = d
            case .mixed: unit = clip.frames.exactFrameDuration
            }
            var notBefore = Rational.zero
            let sorted = clip.segments.sorted { CMTimeCompare($0.start, $1.start) < 0 }
            for seg in sorted {
                guard let q = quantize(start: Rational(seg.start), end: Rational(seg.end),
                                       frames: clip.frames, unit: unit, notBefore: notBefore) else {
                    dropped.append(seg.id)
                    continue
                }
                out.append(GridSegment(clipID: clip.clipID, segmentID: seg.id, sourceStart: q.sourceStart,
                                       frameCount: q.frameCount, outputStart: cursor, outputDuration: q.duration))
                cursor = cursor + q.duration
                notBefore = q.sourceStart + q.duration
            }
        }
        return Result(segments: out, dropped: dropped, totalDuration: cursor)
    }
}

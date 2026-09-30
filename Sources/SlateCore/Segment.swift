import Foundation
import CoreMedia

public struct Segment: Identifiable, Equatable {
    public let id: UUID
    public var range: CMTimeRange
    /// True only for the automatic "whole clip" segment a new clip starts with.
    public var isAuto: Bool

    public init(range: CMTimeRange, id: UUID = UUID(), isAuto: Bool = false) {
        self.id = id
        self.range = range
        self.isAuto = isAuto
    }

    public var start: CMTime { range.start }
    public var end: CMTime { range.end }
    public var duration: CMTime { range.duration }

    /// The segment a newly added clip gets: the whole clip, marked auto.
    public static func wholeClip(duration: CMTime) -> Segment {
        Segment(range: CMTimeRange(start: .zero, duration: duration), isAuto: true)
    }
}

public enum SegmentOps {
    /// Sort + merge any overlapping/adjacent segments. When merging, the survivor's id is
    /// `preferredID` if either input had it, otherwise the earlier (lower-start) segment's id
    /// is preserved. This is critical for live-drag stability — without preferring the dragged
    /// segment's id, every drag step would replace the segment with a new UUID and the next
    /// mouseDragged call would find nothing to update. A merged segment is never auto.
    public static func merge(_ segments: [Segment], preferredID: UUID? = nil) -> [Segment] {
        let sorted = segments.sorted { CMTimeCompare($0.start, $1.start) < 0 }
        var result: [Segment] = []
        for s in sorted {
            if let last = result.last, CMTimeCompare(s.start, last.end) <= 0 {
                let endCandidate = CMTimeCompare(s.end, last.end) > 0 ? s.end : last.end
                let newRange = CMTimeRangeFromTimeToTime(start: last.start, end: endCandidate)
                let survivorID: UUID
                if let p = preferredID, last.id == p || s.id == p {
                    survivorID = p
                } else {
                    survivorID = last.id
                }
                result[result.count - 1] = Segment(range: newRange, id: survivorID)
            } else {
                result.append(s)
            }
        }
        return result
    }

    /// Insert a new segment, merging with overlapping neighbours.
    public static func insert(_ range: CMTimeRange, into segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else { return segments }
        return merge(segments + [Segment(range: range)])
    }

    /// `O` commit. While the clip holds only its auto whole-clip segment, the marked
    /// range replaces it. Otherwise the range is inserted and merged as before.
    public static func commitMarked(_ range: CMTimeRange, into segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else { return segments }
        if segments.count == 1, segments[0].isAuto {
            return [Segment(range: range)]
        }
        return insert(range, into: segments)
    }

    /// Update the range of segment `id` and re-merge with `id` as the preferred survivor.
    /// The updated segment stops being auto.
    public static func updateRange(of id: UUID, to range: CMTimeRange, in segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else {
            return segments.filter { $0.id != id }
        }
        let updated = segments.map { seg -> Segment in
            seg.id == id ? Segment(range: range, id: id, isAuto: false) : seg
        }
        return merge(updated, preferredID: id)
    }

    public static func remove(id: UUID, from segments: [Segment]) -> [Segment] {
        segments.filter { $0.id != id }
    }

    public static func isValid(_ segments: [Segment]) -> Bool {
        for i in segments.indices {
            if CMTimeCompare(segments[i].start, segments[i].end) >= 0 { return false }
            if i + 1 < segments.count {
                if CMTimeCompare(segments[i].end, segments[i + 1].start) > 0 { return false }
            }
        }
        return true
    }
}

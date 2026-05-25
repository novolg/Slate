import Foundation
import CoreMedia

struct Segment: Identifiable, Equatable {
    let id: UUID
    var range: CMTimeRange

    init(range: CMTimeRange, id: UUID = UUID()) {
        self.id = id
        self.range = range
    }

    var start: CMTime { range.start }
    var end: CMTime { range.end }
    var duration: CMTime { range.duration }
}

enum SegmentOps {
    /// Sort + merge any overlapping/adjacent segments. When merging, the survivor's id is
    /// `preferredID` if either input had it, otherwise the earlier (lower-start) segment's id
    /// is preserved. This is critical for live-drag stability — without preferring the dragged
    /// segment's id, every drag step would replace the segment with a new UUID and the next
    /// mouseDragged call would find nothing to update.
    static func merge(_ segments: [Segment], preferredID: UUID? = nil) -> [Segment] {
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

    /// Insert a new segment, merging with overlapping neighbours. Returns the resulting array.
    static func insert(_ range: CMTimeRange, into segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else { return segments }
        return merge(segments + [Segment(range: range)])
    }

    /// Update the range of segment `id` and re-merge with `id` as the preferred survivor.
    static func updateRange(of id: UUID, to range: CMTimeRange, in segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else {
            return segments.filter { $0.id != id }
        }
        let updated = segments.map { seg -> Segment in
            seg.id == id ? Segment(range: range, id: id) : seg
        }
        return merge(updated, preferredID: id)
    }

    static func remove(id: UUID, from segments: [Segment]) -> [Segment] {
        segments.filter { $0.id != id }
    }

    static func isValid(_ segments: [Segment]) -> Bool {
        for i in segments.indices {
            if CMTimeCompare(segments[i].start, segments[i].end) >= 0 { return false }
            if i + 1 < segments.count {
                if CMTimeCompare(segments[i].end, segments[i + 1].start) > 0 { return false }
            }
        }
        return true
    }
}

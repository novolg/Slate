import Foundation
import CoreMedia
import SlateCore

private func r(_ a: Double, _ b: Double) -> CMTimeRange {
    CMTimeRangeFromTimeToTime(start: CMTime(seconds: a, preferredTimescale: 600),
                              end: CMTime(seconds: b, preferredTimescale: 600))
}

func runSegmentChecks() {
    check("segments: drag keeps the dragged id through merges") {
        let a = Segment(range: r(0, 1))
        let b = Segment(range: r(2, 3))
        var segs = [a, b]
        // Drag b's start left across a's end in several steps.
        for start in [1.8, 1.4, 1.0, 0.6] {
            segs = SegmentOps.updateRange(of: b.id, to: r(start, 3), in: segs)
            expect(segs.contains { $0.id == b.id }, "dragged id lost at start \(start)")
        }
        expectEqual(segs.count, 1)
    }

    check("segments: first O replaces the auto whole-clip segment") {
        let auto = Segment.wholeClip(duration: CMTime(seconds: 5, preferredTimescale: 600))
        expect(auto.isAuto)
        let out = SegmentOps.commitMarked(r(1, 2), into: [auto])
        expectEqual(out.count, 1)
        expectEqual(out[0].range, r(1, 2))
        expect(!out[0].isAuto)
    }

    check("segments: O without an auto segment inserts and merges") {
        let s = Segment(range: r(0, 1))
        let out = SegmentOps.commitMarked(r(0.5, 2), into: [s])
        expectEqual(out.count, 1)
        expectEqual(out[0].range, r(0, 2))
        let out2 = SegmentOps.commitMarked(r(3, 4), into: out)
        expectEqual(out2.count, 2)
    }

    check("segments: dragging an auto segment edge makes it normal") {
        let auto = Segment.wholeClip(duration: CMTime(seconds: 5, preferredTimescale: 600))
        let out = SegmentOps.updateRange(of: auto.id, to: r(0.5, 5), in: [auto])
        expectEqual(out.count, 1)
        expectEqual(out[0].id, auto.id)
        expect(!out[0].isAuto)
    }

    check("segments: removing the last segment leaves none") {
        let s = Segment(range: r(0, 1))
        expect(SegmentOps.remove(id: s.id, from: [s]).isEmpty)
    }
}

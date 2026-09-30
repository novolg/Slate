import Foundation
import CoreMedia
import SlateCore

private func clip24(_ name: String = "a.mp4") -> Clip {
    ProjectEditor.makeClip(url: URL(fileURLWithPath: "/tmp/\(name)"), media: TestData.media(TestData.c24))
}

private func clip48(_ name: String = "b.mp4") -> Clip {
    ProjectEditor.makeClip(url: URL(fileURLWithPath: "/tmp/\(name)"), media: TestData.media(TestData.c48))
}

private func secs(_ s: Int32) -> CMTime { CMTime(value: CMTimeValue(s), timescale: 1) }

func runProjectEditorChecks() {
    check("editor: a new project follows the highest fps until the user picks one") {
        var e = ProjectEditor()
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        e.addClips([clip24()])
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        e.addClips([clip48()])
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 48)))
        e.useConstant(Rational(1, 24))
        e.addClips([clip48("c.mp4")])
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)), "a picked target is sticky")
        e.useConstant(nil)
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 48)))
    }

    check("editor: a loaded project keeps its stored target, and Mixed is never rewritten") {
        var e = ProjectEditor(project: Project(fpsMode: .constant(frameDuration: Rational(1, 24))),
                              targetFollowsHighest: false)
        e.addClips([clip48()])
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        e.useMixed()
        e.addClips([clip24()])
        expectEqual(e.project.fpsMode, FPSMode.mixed)
    }

    check("editor: a new clip starts with one auto segment; the first O replaces it, the next O adds") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        let c = e.selectedClip!
        expectEqual(c.segments.count, 1)
        expect(c.segments[0].isAuto)
        expectEqual(Rational(c.segments[0].end), Rational(5))
        e.setInPoint(secs(1))
        expect(e.commitOut(at: secs(2)))
        var segs = e.selectedClip!.segments
        expectEqual(segs.count, 1)
        expect(!segs[0].isAuto)
        expectEqual(Rational(segs[0].start), Rational(1))
        expectEqual(Rational(segs[0].end), Rational(2))
        e.setInPoint(secs(3))
        expect(e.commitOut(at: secs(4)))
        segs = e.selectedClip!.segments
        expectEqual(segs.count, 2)
        expect(e.inPoint == nil, "the in-point is consumed")
    }

    check("editor: O without an in-point or with out <= in does nothing") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        expect(!e.commitOut(at: secs(2)))
        e.setInPoint(secs(3))
        expect(!e.commitOut(at: secs(2)))
        expect(e.selectedClip!.segments[0].isAuto)
    }

    check("editor: dragging an edge turns the auto segment into a normal one, clamps to the clip, and is one undo step") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        let id = e.selectedClip!.segments[0].id
        e.beginSegmentDrag()
        e.dragEdge(id: id, edge: .start, to: secs(1))
        e.dragEdge(id: id, edge: .end, to: secs(100))
        e.endSegmentDrag()
        let seg = e.selectedClip!.segments[0]
        expect(!seg.isAuto)
        expectEqual(Rational(seg.start), Rational(1))
        expectEqual(Rational(seg.end), Rational(5), "clamped to the clip end")
        expectEqual(seg.id, id, "the dragged id survives")
        e.undo()
        let back = e.selectedClip!.segments[0]
        expect(back.isAuto)
        expectEqual(Rational(back.start), Rational(0))
    }

    check("editor: a no-op click on an edge leaves no undo step") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        let id = e.selectedClip!.segments[0].id
        e.beginSegmentDrag()
        e.endSegmentDrag()
        _ = id
        e.undo()
        expect(e.project.clips.isEmpty, "the single undo step must undo the add, not a no-op drag")
    }

    check("editor: deleting the last segment leaves the clip skipped; undo restores it") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        let clipID = e.selectedClipID!
        e.selectedSegmentID = e.selectedClip!.segments[0].id
        expect(e.deleteSelectedSegment())
        expectEqual(e.selectedClip!.segments.count, 0)
        expectEqual(e.plan.plan(for: clipID)?.action, ClipAction.skipped)
        expect(!e.plan.canExport, "nothing to export")
        e.undo()
        expectEqual(e.selectedClip!.segments.count, 1)
        expect(e.plan.canExport)
    }

    check("editor: add, duplicate, move and remove keep ids, order and selection sensible") {
        var e = ProjectEditor()
        let a = clip24("a.mp4"), b = clip48("b.mp4")
        e.addClips([a, b])
        expectEqual(e.project.clips.map(\.id), [a.id, b.id])
        expectEqual(e.selectedClipID, a.id, "the first added clip is selected")
        e.duplicateClip(a.id)
        expectEqual(e.project.clips.count, 3)
        let dup = e.project.clips[1]
        expect(dup.id != a.id)
        expectEqual(dup.url, a.url)
        expect(dup.segments[0].id != a.segments[0].id, "segments get fresh ids")
        expectEqual(e.selectedClipID, dup.id)
        e.moveClip(dup.id, to: 2)
        expectEqual(e.project.clips.map(\.id), [a.id, b.id, dup.id])
        e.removeClip(dup.id)
        expectEqual(e.project.clips.map(\.id), [a.id, b.id])
        expectEqual(e.selectedClipID, b.id, "removing the selected clip selects its neighbour")
    }

    check("editor: selecting another clip clears the in-point and the segment selection; next/previous stop at the ends") {
        var e = ProjectEditor()
        let a = clip24("a.mp4"), b = clip24("b.mp4")
        e.addClips([a, b])
        e.setInPoint(secs(1))
        e.selectedSegmentID = e.selectedClip!.segments[0].id
        e.selectNextClip()
        expectEqual(e.selectedClipID, b.id)
        expect(e.inPoint == nil)
        expect(e.selectedSegmentID == nil)
        e.selectNextClip()
        expectEqual(e.selectedClipID, b.id)
        e.selectPreviousClip()
        e.selectPreviousClip()
        expectEqual(e.selectedClipID, a.id)
    }

    check("editor: undo and redo cover clips and fps mode; revision moves on every change") {
        var e = ProjectEditor()
        e.addClips([clip24()])
        let r0 = e.revision
        e.useMixed()
        expect(e.revision > r0)
        expectEqual(e.project.fpsMode, FPSMode.mixed)
        e.undo()
        expectEqual(e.project.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        e.redo()
        expectEqual(e.project.fpsMode, FPSMode.mixed)
        expect(e.canUndo)
        expect(!e.canRedo)
    }

    check("editor: removing every clip leaves an empty, unexportable project; undo brings the clips back") {
        var e = ProjectEditor()
        let a = clip24()
        e.addClips([a])
        e.removeClip(a.id)
        expect(e.selectedClipID == nil)
        expect(e.selectedClip == nil)
        expect(e.plan.blockers.contains(.noClips))
        e.undo()
        expectEqual(e.project.clips.map(\.id), [a.id])
        expectEqual(e.selectedClipID, a.id)
    }

    check("editor: relinking a clip swaps url and media in place") {
        var e = ProjectEditor()
        let a = clip24()
        e.addClips([a])
        let media = TestData.media(TestData.c48)
        let url = URL(fileURLWithPath: "/tmp/other.mp4")
        e.relinkClip(a.id, url: url, media: media)
        expectEqual(e.project.clips[0].url, url)
        expectEqual(e.project.clips[0].media, media)
        expectEqual(e.project.clips[0].id, a.id)
    }
}

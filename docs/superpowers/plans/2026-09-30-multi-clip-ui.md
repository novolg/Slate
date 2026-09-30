# Multi-clip Plan 2B — Project editor, clip strip, Project player, export sheet, `.slate` in the app

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single-clip Slate app into the multi-clip editor of the spec: a clip strip, per-clip trimming with auto "whole clip" segments, a Clip/Project player, a Constant/Mixed toolbar, a new export sheet on `ProjectExporter`, and `.slate` open/save/autosave.

**Architecture:** All decisions that can be tested live in `Sources/SlateCore` and are covered by `swift run SlateChecks`: `ProjectEditor` (clips, selection, undo, fps target policy), `ClipPresentation` (card badges, plan rows, texts, default file name) and `ProjectDocument` (file identity, dirty flag, save/autosave/restore). The app target only adds a thin `@Observable` `ProjectViewModel` (players, thumbnails, panels, export task) and SwiftUI/AppKit views. The old single-clip `EditorViewModel`, `Exporter` and `ExportSheet` are kept until Task 7 replaces them in one switch, so every task leaves `swift build` green.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit, AVFoundation, SPM (no Xcode, no XCTest, no SwiftUI previews).

**Spec:** `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md` (section "Plan 2 decisions" wins). Hand-off: `docs/superpowers/handoffs/2026-09-30-plan2b-handoff.md`. Plan 2A (what exists): `docs/superpowers/plans/2026-09-30-multi-clip-core-fixes-and-project-file.md`.

## Global Constraints

- macOS 14+, Swift 5.9, no external dependencies, no XCTest.
- `swift build` / `swift run` need the sandbox disabled (`dangerouslyDisableSandbox: true`). Shell heredocs fail in the sandbox: create files with the Write/Edit tools. The GUI cannot be launched from the sandbox: UI tasks are verified by `swift build` + `scripts/build-app.sh debug`; the user does the manual smoke test in Task 8.
- Baseline: `swift run SlateChecks --strict` prints `125 passed, 0 failed, 0 skipped`; `swift build` is green.
- UI code in this plan is the intended design, written without a compiler. Implementers transcribe it, fix compile errors with the smallest change that keeps the behaviour, and list every deviation in their report.
- Mouse handling for the clip strip and the timeline goes through `NSViewRepresentable` mouse capture, not SwiftUI gestures (the timeline already does; the strip follows the same pattern).
- New project: Constant 1/24 + Re-encode all; the target follows the highest fps present until the user picks one, then it is sticky; a loaded `.slate` keeps its stored target. Mixed is opt-in and shows exactly this label: "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."
- Selective and the "Re-encode everything" checkbox are never shown.
- Validation failure = export refused, the destination is untouched; the sheet shows the issues.
- Cmd+O adds the chosen video files to the open project (multi-select); choosing a `.slate` replaces the project (ask to save first). Cmd+E exports the whole project; the old `Exporter` is removed.
- Edit commands (I, O, edge drag, segment delete, timeline click) work in source time only. In Project mode any of them first switches to Clip mode, pauses, and seeks the clip to the mapped source time, then runs.
- `Autosaver` write closures capture the owner weakly. Call `flush()` before `UntitledAutosaveStore.discard()` when discarding while a timer may be pending.
- The user's clips are private; never copy them into the repo. NLE (Resolve) compatibility stays UNVERIFIED.
- `MASTER_PLAN.md` is gitignored: update it on disk only. Commit style `type(scope): text`.
- Work on a branch `feat/multi-clip-2b` created from `main`.

## Review Focus

Failure modes the spec implies that no single task's happy path exercises. Each has a test where the logic is pure (marked ✔) or a line in the Task 8 manual checklist (marked ☐).

1. ✔ Deleting the last segment, then removing every clip: empty timeline, no crash, Export disabled, undo restores. [Task 1]
2. ☐ A dropped file that is not readable video must not lose the open project; other dropped files still load; the error names each failed file. [Task 4 `addFiles`; Task 8 step 15]
3. ✔ A no-op click on a segment edge must not add an undo step; a real drag is one undo step. [Task 1]
4. ☐ Pressing `I` during Project playback marks the exact frame the user saw (Clip mode, mapped source time). [Task 4, Task 8]
5. ✔ Unsaved changes: New / Open / quit paths ask first; an untitled project is autosaved and offered back on next launch; a corrupt autosave is ignored. [Task 3 pure part; Task 4]
6. ☐ A clip whose audio ends more than 1024 samples before its video must not kill the Project preview (falls back to video-only with a note) and is refused at export with the clip named. [Task 4, Task 8]

## File Structure

Create (SlateCore): `ProjectEditor.swift`, `ClipPresentation.swift`, `ProjectDocument.swift`.
Create (checks): `ProjectEditorChecks.swift`, `PresentationChecks.swift`, `ProjectDocumentChecks.swift`.
Create (app): `ViewModels/ProjectViewModel.swift`, `Views/ClipStripView.swift`, `Views/ClipStripMouseCapture.swift`, `Views/ClipCardView.swift`, `Views/ProjectExportSheet.swift`, `Views/DroppedFiles.swift`.
Rewrite (app): `Views/EditorView.swift`, `Views/TimelineView.swift`, `SlateApp.swift`; edit `scripts/Info.plist`.
Delete (Task 7): `ViewModels/EditorViewModel.swift`, `Services/Exporter.swift`, `Views/ExportSheet.swift`.
Modify (SlateCore): `ProjectFile.swift` (one public helper), `SlateChecks/main.swift` (register).

Run one check group with `swift run SlateChecks "<prefix>"`.

---

### Task 1: `ProjectEditor` — clips, selection, segments, undo, fps target

**Files:**
- Create: `Sources/SlateCore/ProjectEditor.swift`, `Sources/SlateChecks/ProjectEditorChecks.swift`
- Modify: `Sources/SlateChecks/main.swift` (register `runProjectEditorChecks()` after `runModelChecks()`)

**Interfaces:**
- Produces:
  - `public enum SegmentEdge { case start, end }`
  - `public struct ProjectEditor: Equatable` with `init(project: Project = Project(), targetFollowsHighest: Bool = true)`; read: `project`, `selectedClipID`, `selectedSegmentID` (settable), `inPoint`, `targetFollowsHighest`, `revision`, `plan`, `selectedIndex`, `selectedClip`, `clipEnd`, `canUndo`, `canRedo`; `static func makeClip(url:media:) -> Clip` (one auto whole-clip segment).
  - mutating: `addClips(_:at:)`, `removeClip(_:)`, `duplicateClip(_:)`, `moveClip(_:to:)` (final index), `relinkClip(_:url:media:)`, `selectClip(_:)`, `selectNextClip()`, `selectPreviousClip()`, `setInPoint(_:)`, `clearInPoint()`, `commitOut(at:) -> Bool`, `deleteSelectedSegment() -> Bool`, `beginSegmentDrag()`, `dragEdge(id:edge:to:)`, `endSegmentDrag()`, `useMixed()`, `useConstant(_ d: Rational?)` (nil = follow the highest fps), `undo()`, `redo()`.
  - `revision` increases by one on every change of clips or fps mode (drag steps, undo and redo included); selection and in-point changes do not touch it.
- Consumes: `Project`, `Clip`, `ClipMedia`, `Segment`, `SegmentOps`, `FrameRateChoice`, `ExportPlanner`, `FPSMode` (Plan 2A).

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ProjectEditorChecks.swift`:

```swift
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
```

Register in `Sources/SlateChecks/main.swift`: add `runProjectEditorChecks()` on the line after `runModelChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks editor`
Expected: build error `cannot find 'ProjectEditor' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SlateCore/ProjectEditor.swift`:

```swift
import Foundation
import CoreMedia

public enum SegmentEdge: Equatable { case start, end }

/// The editing state of a project: clips, selection, in-point, undo. A pure value type with no
/// UI and no media access, so every rule is testable with `SlateChecks`. All segment times are
/// SOURCE times of the selected clip.
public struct ProjectEditor: Equatable {
    public struct Snapshot: Equatable {
        public var clips: [Clip]
        public var fpsMode: FPSMode
    }

    public private(set) var project: Project
    public private(set) var selectedClipID: UUID?
    public var selectedSegmentID: UUID?
    public private(set) var inPoint: CMTime?
    /// True until the user picks a target fps (or loads a saved project).
    public private(set) var targetFollowsHighest: Bool
    /// Bumped by every change of clips or fps mode (drag steps, undo and redo included).
    public private(set) var revision = 0
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    public init(project: Project = Project(), targetFollowsHighest: Bool = true) {
        self.project = project
        self.targetFollowsHighest = targetFollowsHighest
        self.selectedClipID = project.clips.first?.id
    }

    // MARK: Reading

    public var plan: ExportPlan { ExportPlanner.plan(project) }
    public var selectedIndex: Int? { project.clips.firstIndex { $0.id == selectedClipID } }
    public var selectedClip: Clip? { selectedIndex.map { project.clips[$0] } }
    /// End of the selected clip in source time (nil when the file is missing).
    public var clipEnd: CMTime? { selectedClip?.media?.frames.clipEnd.cmTime }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private var snapshot: Snapshot { Snapshot(clips: project.clips, fpsMode: project.fpsMode) }

    /// A clip for a probed file: one auto "whole clip" segment.
    public static func makeClip(url: URL, media: ClipMedia) -> Clip {
        Clip(url: url, segments: [Segment.wholeClip(duration: media.frames.clipEnd.cmTime)], media: media)
    }

    // MARK: Change plumbing

    private mutating func recordUndo() {
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    /// Apply the follow-the-highest-fps policy, repair the selection, bump the revision.
    private mutating func changed() {
        if targetFollowsHighest, case .constant = project.fpsMode,
           let highest = FrameRateChoice.highest(for: project.clips) {
            let want = FPSMode.constant(frameDuration: highest)
            if project.fpsMode != want { project.fpsMode = want }
        }
        if let id = selectedClipID, !project.clips.contains(where: { $0.id == id }) {
            selectedClipID = project.clips.first?.id
            selectedSegmentID = nil
            inPoint = nil
        }
        if selectedClipID == nil { selectedClipID = project.clips.first?.id }
        if let sid = selectedSegmentID,
           selectedClip?.segments.contains(where: { $0.id == sid }) != true {
            selectedSegmentID = nil
        }
        revision += 1
    }

    private mutating func edit(_ body: (inout Project) -> Void) {
        recordUndo()
        body(&project)
        changed()
    }

    // MARK: Clips

    public mutating func addClips(_ new: [Clip], at index: Int? = nil) {
        guard !new.isEmpty else { return }
        edit { p in
            let i = min(max(index ?? p.clips.count, 0), p.clips.count)
            p.clips.insert(contentsOf: new, at: i)
        }
        selectedClipID = new[0].id
        selectedSegmentID = nil
        inPoint = nil
    }

    public mutating func removeClip(_ id: UUID) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let neighbour: UUID? = project.clips.indices.contains(i + 1)
            ? project.clips[i + 1].id : (i > 0 ? project.clips[i - 1].id : nil)
        let wasSelected = selectedClipID == id
        edit { $0.clips.remove(at: i) }
        if wasSelected {
            selectedClipID = neighbour
            selectedSegmentID = nil
            inPoint = nil
        }
    }

    public mutating func duplicateClip(_ id: UUID) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let original = project.clips[i]
        let copy = Clip(id: UUID(), url: original.url,
                        segments: original.segments.map { Segment(range: $0.range, id: UUID(), isAuto: $0.isAuto) },
                        media: original.media)
        edit { $0.clips.insert(copy, at: i + 1) }
        selectedClipID = copy.id
        selectedSegmentID = nil
        inPoint = nil
    }

    /// Move a clip so that it ends up at `newIndex` in the resulting order.
    public mutating func moveClip(_ id: UUID, to newIndex: Int) {
        guard let from = project.clips.firstIndex(where: { $0.id == id }),
              project.clips.indices.contains(newIndex), newIndex != from else { return }
        edit { p in
            let clip = p.clips.remove(at: from)
            p.clips.insert(clip, at: newIndex)
        }
    }

    public mutating func relinkClip(_ id: UUID, url: URL, media: ClipMedia?) {
        guard project.clips.contains(where: { $0.id == id }) else { return }
        edit { p in
            if let i = p.clips.firstIndex(where: { $0.id == id }) {
                p.clips[i].url = url
                p.clips[i].media = media
            }
        }
    }

    // MARK: Selection

    public mutating func selectClip(_ id: UUID) {
        guard id != selectedClipID, project.clips.contains(where: { $0.id == id }) else { return }
        selectedClipID = id
        selectedSegmentID = nil
        inPoint = nil
    }

    public mutating func selectNextClip() { stepSelection(1) }
    public mutating func selectPreviousClip() { stepSelection(-1) }

    private mutating func stepSelection(_ delta: Int) {
        guard let i = selectedIndex else { return }
        let j = i + delta
        guard project.clips.indices.contains(j) else { return }
        selectClip(project.clips[j].id)
    }

    // MARK: Segments (source time of the selected clip)

    private func clamped(_ t: CMTime) -> CMTime {
        guard t.isNumeric else { return .zero }
        var r = t
        if CMTimeCompare(r, .zero) < 0 { r = .zero }
        if let end = clipEnd, CMTimeCompare(r, end) > 0 { r = end }
        return r
    }

    public mutating func setInPoint(_ t: CMTime) { inPoint = clamped(t) }
    public mutating func clearInPoint() { inPoint = nil }

    /// `O`: commit in-point → `t`. The first commit on an untouched clip replaces its auto segment.
    @discardableResult
    public mutating func commitOut(at t: CMTime) -> Bool {
        guard let inP = inPoint, let idx = selectedIndex else { return false }
        let out = clamped(t)
        guard CMTimeCompare(out, inP) > 0 else { return false }
        let range = CMTimeRangeFromTimeToTime(start: inP, end: out)
        edit { $0.clips[idx].segments = SegmentOps.commitMarked(range, into: $0.clips[idx].segments) }
        inPoint = nil
        return true
    }

    @discardableResult
    public mutating func deleteSelectedSegment() -> Bool {
        guard let sid = selectedSegmentID, let idx = selectedIndex,
              project.clips[idx].segments.contains(where: { $0.id == sid }) else { return false }
        edit { $0.clips[idx].segments = SegmentOps.remove(id: sid, from: $0.clips[idx].segments) }
        selectedSegmentID = nil
        return true
    }

    /// Mouse down on an edge: one undo step for the whole drag.
    public mutating func beginSegmentDrag() { recordUndo() }

    /// Live drag step: no undo entry of its own. Clamped to the clip; the dragged id survives merges.
    public mutating func dragEdge(id: UUID, edge: SegmentEdge, to time: CMTime) {
        guard let idx = selectedIndex,
              let seg = project.clips[idx].segments.first(where: { $0.id == id }) else { return }
        let t = clamped(time)
        let range: CMTimeRange
        switch edge {
        case .start:
            guard CMTimeCompare(t, seg.end) < 0 else { return }
            range = CMTimeRangeFromTimeToTime(start: t, end: seg.end)
        case .end:
            guard CMTimeCompare(t, seg.start) > 0 else { return }
            range = CMTimeRangeFromTimeToTime(start: seg.start, end: t)
        }
        project.clips[idx].segments = SegmentOps.updateRange(of: id, to: range, in: project.clips[idx].segments)
        selectedSegmentID = id
        changed()
    }

    /// Mouse up: if nothing changed since `beginSegmentDrag`, drop the empty undo step.
    public mutating func endSegmentDrag() {
        if let last = undoStack.last, last == snapshot { undoStack.removeLast() }
    }

    // MARK: Frame rate

    public mutating func useMixed() {
        edit { $0.fpsMode = .mixed }
    }

    /// `nil` = follow the highest fps present; a value = the user's pick (sticky).
    public mutating func useConstant(_ d: Rational?) {
        targetFollowsHighest = (d == nil)
        let chosen = d ?? FrameRateChoice.highest(for: project.clips) ?? Rational(1, 24)
        edit { $0.fpsMode = .constant(frameDuration: chosen) }
    }

    // MARK: Undo / redo

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        apply(previous)
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        apply(next)
    }

    private mutating func apply(_ s: Snapshot) {
        project.clips = s.clips
        project.fpsMode = s.fpsMode
        inPoint = nil
        changed()
    }
}
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `137 passed, 0 failed, 0 skipped` (125 + 12).

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ProjectEditor.swift Sources/SlateChecks/ProjectEditorChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ProjectEditor — clips, selection, segments, undo, fps target policy"
```

---

### Task 2: `ClipPresentation` — badges, plan rows, texts, default file name

**Files:**
- Create: `Sources/SlateCore/ClipPresentation.swift`, `Sources/SlateChecks/PresentationChecks.swift`
- Modify: `Sources/SlateChecks/main.swift` (register `runPresentationChecks()` after `runProjectEditorChecks()`)

**Interfaces:**
- Produces: `ClipCardInfo` (`index` 1-based, `fileName`, `keptText`, `fpsText`, `hasAudio`, `tone: Tone {normal, warning, error}`, `tooltip`), `PlanRow`, and `ClipPresentation` with `mixedLabel`, `fpsText(_:)`, `seconds(_:)`, `blockText(_:)`, `actionText(_:plan:)`, `card(for:index:plan:)`, `rows(_:project:)`, `blockerTexts(_:project:)`, `summary(_:)`, `modeText(_:)`, `defaultOutputName(project:documentName:)`.
- Consumes: `ExportPlan`, `ClipPlan`, `ClipAction`, `BlockReason`, `PlanBlocker`, `Rational`, `Clip`, `Project`.

Badge rule (spec, refined by the 2A hand-off): the badge is yellow (`warning`) only when the clip's OWN timing would not copy in Constant mode — its exact frame duration differs from the target, or it has none (not exact CFR). In Constant mode every clip is re-encoded, so the badge must not mirror the plan action. Red (`error`) when the file is missing or the clip is blocked. Mixed: never yellow.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/PresentationChecks.swift`:

```swift
import Foundation
import SlateCore

func runPresentationChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("presentation: fps text is exact and short") {
        expectEqual(ClipPresentation.fpsText(Rational(1, 24)), "24 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1, 48)), "48 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1001, 24000)), "23.976 fps")
        expectEqual(ClipPresentation.fpsText(Rational(1001, 30000)), "29.97 fps")
    }

    check("presentation: card shows kept / total seconds, index and audio") {
        let a = TestData.clip(TestData.media(TestData.c24, audio: true), keep: [(.zero, Rational(5, 2))])
        let plan = ExportPlanner.plan(Project(clips: [a]))
        let card = ClipPresentation.card(for: a, index: 3, plan: plan)
        expectEqual(card.index, 3)
        expectEqual(card.keptText, "2.5 / 5.0 s")
        expectEqual(card.fpsText, "24 fps")
        expect(card.hasAudio)
        expectEqual(card.tone, ClipCardInfo.Tone.normal)
    }

    check("presentation: in Constant mode only clips whose own timing would not copy are yellow") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        var jm = TestData.media(TestData.jittered23976(count: 120))
        jm.nominalFPS = 24000.0 / 1001.0
        let j = TestData.clip(jm, keep: [(.zero, Rational(4))])
        let plan = ExportPlanner.plan(Project(clips: [a, b, j], fpsMode: .constant(frameDuration: Rational(1, 24))))
        expectEqual(ClipPresentation.card(for: a, index: 1, plan: plan).tone, ClipCardInfo.Tone.normal)
        let cb = ClipPresentation.card(for: b, index: 2, plan: plan)
        expectEqual(cb.tone, ClipCardInfo.Tone.warning)
        expect(cb.tooltip.contains("48 fps") && cb.tooltip.contains("24 fps"), cb.tooltip)
        let cj = ClipPresentation.card(for: j, index: 3, plan: plan)
        expectEqual(cj.tone, ClipCardInfo.Tone.warning)
        expect(cj.tooltip.contains("not exact"), cj.tooltip)
    }

    check("presentation: Mixed mode has no yellow badges") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        for (i, c) in [a, b].enumerated() {
            expectEqual(ClipPresentation.card(for: c, index: i + 1, plan: plan).tone, ClipCardInfo.Tone.normal)
        }
    }

    check("presentation: missing or blocked clips are red with a reason") {
        let ok = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        let small = TestData.clip(TestData.media(TestData.c24, width: 320, height: 180), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [ok, gone, small]))
        let cg = ClipPresentation.card(for: gone, index: 2, plan: plan)
        expectEqual(cg.tone, ClipCardInfo.Tone.error)
        expectEqual(cg.fpsText, "—")
        let cs = ClipPresentation.card(for: small, index: 3, plan: plan)
        expectEqual(cs.tone, ClipCardInfo.Tone.error)
        expect(cs.tooltip.contains("Frame size"), cs.tooltip)
    }

    check("presentation: a clip with an unusable nominal fps does not crash the card") {
        var jm = TestData.media(TestData.jittered23976(count: 120))
        jm.nominalFPS = 0
        let j = TestData.clip(jm, keep: [(.zero, Rational(4))])
        let plan = ExportPlanner.plan(Project(clips: [j]))
        expectEqual(ClipPresentation.card(for: j, index: 1, plan: plan).fpsText, "—")
    }

    check("presentation: plan rows explain each clip and count sub-frame selections") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let tiny = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1, 100)), (Rational(1), Rational(2))])
        let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
        let plan = ExportPlanner.plan(Project(clips: [a, tiny, empty]))
        let rows = ClipPresentation.rows(plan, project: Project(clips: [a, tiny, empty]))
        expectEqual(rows.count, 3)
        expect(rows[0].text.hasPrefix("Re-encode"), rows[0].text)
        expect(rows[1].text.contains("shorter than one frame"), rows[1].text)
        expect(rows[2].text.contains("Skipped"), rows[2].text)
    }

    check("presentation: blocker texts name the clip; summary and mode text read well") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        let project = Project(clips: [a, gone])
        let plan = ExportPlanner.plan(project)
        let texts = ClipPresentation.blockerTexts(plan, project: project)
        expect(texts.contains { $0.contains(gone.url.lastPathComponent) }, "\(texts)")
        expectEqual(ClipPresentation.blockerTexts(ExportPlanner.plan(Project()), project: Project()), ["Add at least one clip."])
        let ok = ExportPlanner.plan(Project(clips: [a]))
        expectEqual(ClipPresentation.summary(ok), "5.0 s · 120 frames")
        expect(ClipPresentation.modeText(ok).hasPrefix("Constant 24 fps"))
        expect(ClipPresentation.modeText(ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))).hasPrefix("Mixed"))
    }

    check("presentation: default output name") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c24), keep: whole)
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a]), documentName: nil),
                    "\(a.url.deletingPathExtension().lastPathComponent) — trimmed.mp4")
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a, b]), documentName: nil), "Slate export.mp4")
        expectEqual(ClipPresentation.defaultOutputName(project: Project(clips: [a, b]), documentName: "Trailer"), "Trailer.mp4")
    }

    check("presentation: the Mixed label is the ruled text") {
        expectEqual(ClipPresentation.mixedLabel,
                    "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant.")
    }
}
```

Register `runPresentationChecks()` in `main.swift` after `runProjectEditorChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks presentation`
Expected: build error `cannot find 'ClipPresentation' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SlateCore/ClipPresentation.swift`:

```swift
import Foundation

public struct ClipCardInfo: Equatable {
    public enum Tone: Equatable { case normal, warning, error }

    public let index: Int
    public let fileName: String
    public let keptText: String
    public let fpsText: String
    public let hasAudio: Bool
    public let tone: Tone
    public let tooltip: String
}

public struct PlanRow: Equatable {
    public let index: Int
    public let fileName: String
    public let text: String
    public let tone: ClipCardInfo.Tone
}

/// Text and badge decisions for the clip strip and the export sheet. Pure, so the rules are checked.
public enum ClipPresentation {
    public static let mixedLabel =
        "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."

    /// "24 fps", "23.976 fps", "29.97 fps".
    public static func fpsText(_ d: Rational) -> String {
        var s = String(format: "%.3f", 1 / d.seconds)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " fps"
    }

    /// One decimal, no unit: "2.5".
    public static func seconds(_ r: Rational) -> String { String(format: "%.1f", r.seconds) }

    public static func blockText(_ reason: BlockReason) -> String {
        switch reason {
        case .missingFile: return "File is missing or unreadable."
        case .frameSizeMismatch: return "Frame size differs from the first clip."
        case .codecMismatch: return "Codec differs from the first clip."
        case .unsupportedCodec: return "Codec is not supported (H.264 or HEVC only)."
        case .audioMismatch: return "Some clips have audio and some do not."
        case .audioFormatMismatch: return "Audio sample rate or channels differ (allowed only in Constant mode)."
        }
    }

    public static func actionText(_ action: ClipAction, plan: ExportPlan) -> String {
        switch action {
        case .copy:
            return "Copied without re-encoding"
        case .reencode(let reason):
            let target = plan.frameDuration.map { " to \(fpsText($0))" } ?? ""
            switch reason {
            case .fpsDiffers: return "Re-encoded\(target): fps differs"
            case .timingNotExact: return "Re-encoded\(target): frame timing is not exact"
            case .reencodeAll: return "Re-encoded\(target)"
            }
        case .skipped:
            return "Skipped: nothing is kept"
        case .blocked(let reason):
            return blockText(reason)
        }
    }

    public static func card(for clip: Clip, index: Int, plan: ExportPlan) -> ClipCardInfo {
        let name = clip.url.lastPathComponent
        guard let media = clip.media else {
            return ClipCardInfo(index: index, fileName: name, keptText: "— / — s", fpsText: "—",
                                hasAudio: false, tone: .error, tooltip: blockText(.missingFile))
        }
        let clipPlan = plan.plan(for: clip.id)
        let kept = clipPlan?.segments.reduce(Rational.zero) { $0 + $1.outputDuration } ?? .zero
        let exact = media.frames.exactFrameDuration
        let shown: Rational? = exact ?? (media.nominalFPS.isFinite && media.nominalFPS > 0
            ? Rational.frameDuration(fps: media.nominalFPS) : nil)
        let fps = shown.map(fpsText) ?? "—"

        var tone = ClipCardInfo.Tone.normal
        var tip = "Copied as is."
        if case .blocked(let reason)? = clipPlan?.action {
            tone = .error
            tip = blockText(reason)
        } else if case .skipped? = clipPlan?.action {
            tip = "Nothing is kept: this clip is skipped."
        } else if case .constant(let target) = plan.mode {
            if exact == nil {
                tone = .warning
                tip = "Frame timing is not exact, so this clip is re-encoded to \(fpsText(target))."
            } else if exact != target {
                tone = .warning
                tip = "This clip is \(fps); it is re-encoded to \(fpsText(target))."
            } else {
                tip = "Matches the output frame rate."
            }
        }
        return ClipCardInfo(index: index, fileName: name,
                            keptText: "\(seconds(kept)) / \(seconds(media.frames.clipEnd)) s",
                            fpsText: fps, hasAudio: media.hasAudio, tone: tone, tooltip: tip)
    }

    public static func rows(_ plan: ExportPlan, project: Project) -> [PlanRow] {
        project.clips.enumerated().map { i, clip in
            let card = card(for: clip, index: i + 1, plan: plan)
            var text = plan.plan(for: clip.id).map { actionText($0.action, plan: plan) } ?? ""
            let dropped = plan.plan(for: clip.id)?.droppedSegmentIDs.count ?? 0
            if dropped > 0 { text += " · \(dropped) selection(s) shorter than one frame skipped" }
            return PlanRow(index: i + 1, fileName: clip.url.lastPathComponent, text: text, tone: card.tone)
        }
    }

    public static func blockerTexts(_ plan: ExportPlan, project: Project) -> [String] {
        func name(_ id: UUID) -> String {
            project.clips.first { $0.id == id }?.url.lastPathComponent ?? "A clip"
        }
        return plan.blockers.map { b in
            switch b {
            case .noClips: return "Add at least one clip."
            case .noFrames: return "All selections are shorter than one frame."
            case .clip(let id, let reason): return "\(name(id)): \(blockText(reason))"
            case .duplicateClipID(let id): return "\(name(id)): the same clip id appears twice."
            case .timescaleOverflow: return "Clip timescales cannot share one exact timeline."
            }
        }
    }

    /// "12.3 s · 296 frames".
    public static func summary(_ plan: ExportPlan) -> String {
        "\(seconds(plan.totalDuration)) s · \(plan.totalFrames) frames"
    }

    public static func modeText(_ plan: ExportPlan) -> String {
        switch plan.mode {
        case .mixed: return "Mixed frame rates · copied without re-encoding"
        case .constant(let d): return "Constant \(fpsText(d)) · every clip is re-encoded"
        }
    }

    public static func defaultOutputName(project: Project, documentName: String?) -> String {
        if let documentName { return "\(documentName).mp4" }
        if project.clips.count == 1, let only = project.clips.first {
            return "\(only.url.deletingPathExtension().lastPathComponent) — trimmed.mp4"
        }
        return "Slate export.mp4"
    }
}
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `147 passed, 0 failed, 0 skipped` (137 + 10). If a text assertion fails because of a wording difference (for example the jittered 23.976 clip's `fps` text), fix the code or the expectation to the single consistent wording and note it in the report; never weaken a tone or count assertion.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ClipPresentation.swift Sources/SlateChecks/PresentationChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ClipPresentation — card badges, plan rows, texts, default file name"
```

---

### Task 3: `ProjectDocument` — file identity, dirty flag, save, autosave, restore

**Files:**
- Modify: `Sources/SlateCore/ProjectFile.swift` (replace `load(from:)` by two functions)
- Create: `Sources/SlateCore/ProjectDocument.swift`, `Sources/SlateChecks/ProjectDocumentChecks.swift`
- Modify: `Sources/SlateChecks/main.swift` (register `await runProjectDocumentChecks()` after `await runAutosaveChecks()`)

**Interfaces:**
- Produces:
  - `ProjectFile.attachMedia(to: Project) async -> Project` (probes every clip whose file exists; unreadable files keep `media == nil`); `ProjectFile.load(from:)` now calls it.
  - `ProjectDocument`: `init(fileURL:savedRevision:untitledStore:)`, `fileURL`, `isUntitled`, `displayName` ("Untitled" or the file name without extension), `savedRevision`, `hasUnsavedChanges(revision:)`, `opened(from:revision:)`, `startedNew(revision:)`, `restoredUntitled()` (marks the document dirty), `save(_:revision:) throws` (throws `ProjectDocumentError.noFile` when untitled), `saveAs(_:to:revision:) throws` (also discards the untitled autosave), `autosave(_:revision:) throws` (titled: write in place and mark saved; untitled: write the store, or discard when the project has no clips), `restorableProject() async -> Project?`, `discardUntitledAutosave()`.
- Consumes: `ProjectFile`, `UntitledAutosaveStore`, `Project`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ProjectDocumentChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

func runProjectDocumentChecks() async {
    func freshDirectory(_ name: String) throws -> URL {
        let dir = try checksOutputDirectory().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func project(in dir: URL) -> Project {
        let seg = Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)))
        return Project(clips: [Clip(url: dir.appendingPathComponent("a.mp4"), segments: [seg], media: nil)])
    }

    await checkAsync("document: save as, dirty flag, save") {
        let dir = try freshDirectory("doc-save")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        expect(doc.isUntitled)
        expectEqual(doc.displayName, "Untitled")
        let p = project(in: dir)
        do {
            try doc.save(p, revision: 1)
            expect(false, "an untitled document cannot Save")
        } catch ProjectDocumentError.noFile {
            // expected
        }
        let url = dir.appendingPathComponent("Trailer.slate")
        try doc.saveAs(p, to: url, revision: 3)
        expect(!doc.isUntitled)
        expectEqual(doc.displayName, "Trailer")
        expect(!doc.hasUnsavedChanges(revision: 3))
        expect(doc.hasUnsavedChanges(revision: 4))
        try doc.save(p, revision: 4)
        expect(!doc.hasUnsavedChanges(revision: 4))
        let loaded = try await ProjectFile.load(from: url)
        expectEqual(loaded.clips.map(\.id), p.clips.map(\.id))
    }

    await checkAsync("document: autosave of a titled project writes in place and counts as saved") {
        let dir = try freshDirectory("doc-titled")
        let doc = ProjectDocument(untitledStore: UntitledAutosaveStore(directory: dir.appendingPathComponent("auto")))
        let url = dir.appendingPathComponent("p.slate")
        var p = project(in: dir)
        try doc.saveAs(p, to: url, revision: 1)
        p.clips.append(Clip(url: dir.appendingPathComponent("b.mp4"), segments: [], media: nil))
        try doc.autosave(p, revision: 2)
        expect(!doc.hasUnsavedChanges(revision: 2))
        let loaded = try await ProjectFile.load(from: url)
        expectEqual(loaded.clips.count, 2)
    }

    await checkAsync("document: an untitled project autosaves to the store, is offered back, and Save As discards it") {
        let dir = try freshDirectory("doc-untitled")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        let p = project(in: dir)
        try doc.autosave(p, revision: 1)
        expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        let restored = await doc.restorableProject()
        expectEqual(restored?.clips.map(\.id), p.clips.map(\.id))
        try doc.saveAs(p, to: dir.appendingPathComponent("kept.slate"), revision: 1)
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "Save As discards the untitled autosave")
        let none = await doc.restorableProject()
        expect(none == nil)
    }

    await checkAsync("document: an empty untitled project writes nothing and clears an old autosave") {
        let dir = try freshDirectory("doc-empty")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        try doc.autosave(project(in: dir), revision: 1)
        expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        try doc.autosave(Project(), revision: 2)
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    await checkAsync("document: a corrupt untitled autosave is not offered") {
        let dir = try freshDirectory("doc-corrupt")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL)
        let doc = ProjectDocument(untitledStore: store)
        let none = await doc.restorableProject()
        expect(none == nil)
    }

    await checkAsync("document: a restored untitled project is dirty until it is saved; New and Open reset the flag") {
        let dir = try freshDirectory("doc-flags")
        let doc = ProjectDocument(untitledStore: UntitledAutosaveStore(directory: dir.appendingPathComponent("auto")))
        doc.restoredUntitled()
        expect(doc.isUntitled)
        expect(doc.hasUnsavedChanges(revision: 0))
        doc.opened(from: dir.appendingPathComponent("x.slate"), revision: 0)
        expect(!doc.isUntitled)
        expect(!doc.hasUnsavedChanges(revision: 0))
        doc.startedNew(revision: 0)
        expect(doc.isUntitled)
        expect(!doc.hasUnsavedChanges(revision: 0))
    }

    await checkAsync("project file: attachMedia probes existing files and leaves missing ones without media") {
        let dir = try freshDirectory("doc-attach")
        let real = dir.appendingPathComponent("c24.mp4")
        try FileManager.default.copyItem(at: try fixture("c24.mp4"), to: real)
        let p = Project(clips: [
            Clip(url: real, segments: [], media: nil),
            Clip(url: dir.appendingPathComponent("gone.mp4"), segments: [], media: nil),
        ])
        let out = await ProjectFile.attachMedia(to: p)
        expect(out.clips[0].media != nil)
        expect(out.clips[1].media == nil)
    }
}
```

Register `await runProjectDocumentChecks()` in `main.swift` after `await runAutosaveChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks document`
Expected: build error `cannot find 'ProjectDocument' in scope`.

- [ ] **Step 3: Implement**

In `Sources/SlateCore/ProjectFile.swift` replace the existing `public static func load(from url: URL) async throws -> Project { … }` (and its doc comment) with:

```swift
    /// Probe every clip whose file exists. A file that cannot be probed keeps `media == nil`
    /// (its card shows as missing or unreadable).
    public static func attachMedia(to project: Project) async -> Project {
        var project = project
        for i in project.clips.indices where FileManager.default.fileExists(atPath: project.clips[i].url.path) {
            project.clips[i].media = try? await ClipProbe.probe(url: project.clips[i].url)
        }
        return project
    }

    /// Read a `.slate` file, resolve the clip paths and probe every file that exists.
    public static func load(from url: URL) async throws -> Project {
        let file = try decode(try Data(contentsOf: url))
        let project = file.project(resolvingFrom: url, exists: { FileManager.default.fileExists(atPath: $0.path) })
        return await attachMedia(to: project)
    }
```

Create `Sources/SlateCore/ProjectDocument.swift`:

```swift
import Foundation

public enum ProjectDocumentError: Error, LocalizedError, Equatable {
    case noFile

    public var errorDescription: String? {
        "This project has no file yet. Use Save As…"
    }
}

/// Which file a project belongs to, whether it has unsaved changes, and where it is autosaved.
/// Pure logic (no UI); the view model calls it from the main actor.
public final class ProjectDocument {
    public private(set) var fileURL: URL?
    public private(set) var savedRevision: Int
    public let untitledStore: UntitledAutosaveStore

    public init(fileURL: URL? = nil, savedRevision: Int = 0,
                untitledStore: UntitledAutosaveStore = UntitledAutosaveStore(directory: UntitledAutosaveStore.defaultDirectory)) {
        self.fileURL = fileURL
        self.savedRevision = savedRevision
        self.untitledStore = untitledStore
    }

    public var isUntitled: Bool { fileURL == nil }

    public var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    public func hasUnsavedChanges(revision: Int) -> Bool { revision != savedRevision }

    /// A project was just opened from `url`.
    public func opened(from url: URL, revision: Int) {
        fileURL = url
        savedRevision = revision
    }

    /// A new, empty project replaced the old one.
    public func startedNew(revision: Int) {
        fileURL = nil
        savedRevision = revision
        untitledStore.discard()
    }

    /// The untitled autosave was restored: the project counts as unsaved until the user saves it.
    public func restoredUntitled() {
        fileURL = nil
        savedRevision = -1
    }

    public func save(_ project: Project, revision: Int) throws {
        guard let url = fileURL else { throw ProjectDocumentError.noFile }
        try ProjectFile(project: project, savedAt: url).write(to: url)
        savedRevision = revision
    }

    public func saveAs(_ project: Project, to url: URL, revision: Int) throws {
        try ProjectFile(project: project, savedAt: url).write(to: url)
        fileURL = url
        savedRevision = revision
        untitledStore.discard()
    }

    /// Called by the debounced autosaver. A titled project is written in place (and counts as saved);
    /// an untitled one goes to the autosave store, or the store is cleared when nothing is worth keeping.
    public func autosave(_ project: Project, revision: Int) throws {
        if fileURL != nil {
            try save(project, revision: revision)
            return
        }
        if project.clips.isEmpty {
            untitledStore.discard()
            return
        }
        try untitledStore.save(ProjectFile(project: project, savedAt: nil))
    }

    /// The untitled project autosaved by an earlier run, with its media probed, or nil.
    public func restorableProject() async -> Project? {
        guard let file = untitledStore.pending() else { return nil }
        let project = file.project(resolvingFrom: nil, exists: { FileManager.default.fileExists(atPath: $0.path) })
        return await ProjectFile.attachMedia(to: project)
    }

    public func discardUntitledAutosave() {
        untitledStore.discard()
    }
}
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `154 passed, 0 failed, 0 skipped` (147 + 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore Sources/SlateChecks
git commit -m "feat(core): ProjectDocument — file identity, dirty flag, save, autosave, restore"
```

---
### Task 4: `ProjectViewModel` — the app's model (players, visuals, files, export, autosave)

**Files:**
- Create: `Sources/Slate/ViewModels/ProjectViewModel.swift`

This task adds the new view model next to the old `EditorViewModel` (both compile; the old one is deleted in Task 7). It has no UI. It is verified by `swift build`; every rule it applies is tested in Tasks 1-3.

**Interfaces:**
- Consumes: `ProjectEditor`, `ClipPresentation`, `ProjectDocument`, `ProjectFile`, `ProjectExporter`, `ExportStage`, `ProjectExportError`, `CompositionBuilder`, `CompositionError`, `ProjectTimeMap`, `FrameRateChoice`, `ClipProbe` (SlateCore); `ThumbnailGenerator`, `Thumbnail`, `KeyframeScanner` (app, unchanged).
- Produces (used by Tasks 5-7):
  - Types: `ProjectViewModel.PlayerMode {clip, project}`, `.ClipVisuals {poster, thumbnails, keyframes, isScanning}`, `.ExportUI {idle, review, running(ExportStage?), done(URL), refused([String]), failed(String)}`, `extension UTType { static let slateProject }`.
  - State: `editor`, `plan`, `mode`, `player`, `clipTime`, `projectTime`, `timelinePlayhead`, `clipDuration`, `segments`, `inPoint`, `selectedSegmentID` (get/set), `selectedClip`, `selectedVisuals`, `visuals`, `previewNote`, `errorMessage`, `zoom`, `exportUI`, `isExporting`, `canExport`, `windowTitle`, `isConstant`, `followsHighest`, `targetFrameDuration`, `fpsChoices`, `isPlaying`.
  - Commands: `openPanel()`, `addClipsPanel()`, `open(urls:)`, `handleDrop(_:at:)`, `addFiles(_:at:)`, `newProject()`, `save() -> Bool`, `saveAs() -> Bool`, `confirmDiscardChanges() -> Bool`, `offerRestore() async`, `autosaveNowSync()`, `selectClip(_:)`, `selectNextClip()`, `selectPreviousClip()`, `moveClip(_:to:)`, `removeClip(_:)`, `duplicateClip(_:)`, `removeSelectedClip()`, `duplicateSelectedClip()`, `revealInFinder(_:)`, `relink(_:)`, `markIn()`, `markOut()`, `deleteSelectedSegment()`, `clearSelection()`, `timelineSeek(to:)`, `beginSegmentDrag()`, `dragEdge(id:edge:to:)`, `endSegmentDrag()`, `undo()`, `redo()`, `setMixed()`, `setConstant(_:)`, `setMode(_:)`, `toggleMode()`, transport (`togglePlayPause()`, `nudgeReverse()`, `nudgeForward()`, `pause()`, `stepFrame(by:)`), zoom (`setZoom(_:)`, `zoomIn()`, `zoomOut()`, `resetZoom()`), export (`beginExport()`, `startExport()`, `cancelExport()`, `dismissExport()`), `clearError()`.

- [ ] **Step 1: Create the file**

Create `Sources/Slate/ViewModels/ProjectViewModel.swift`:

```swift
import Foundation
import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers
import SlateCore

extension UTType {
    static let slateProject = UTType(exportedAs: "co.aceguardian.slate.project", conformingTo: .json)
}

@MainActor
@Observable
final class ProjectViewModel {
    enum PlayerMode { case clip, project }

    struct ClipVisuals {
        var poster: NSImage?
        var thumbnails: [Thumbnail] = []
        var keyframes = KeyframeIndex(times: [])
        var isScanning = false
    }

    enum ExportUI: Equatable {
        case idle
        case review
        case running(ExportStage?)
        case done(URL)
        case refused([String])
        case failed(String)
    }

    // MARK: State

    private(set) var editor = ProjectEditor()
    private(set) var plan: ExportPlan = ExportPlanner.plan(Project())
    private(set) var document = ProjectDocument()
    private(set) var documentVersion = 0
    private(set) var mode: PlayerMode = .clip
    private(set) var clipPlayer: AVPlayer?
    private(set) var projectPlayer: AVPlayer?
    /// Source time in the selected clip.
    private(set) var clipTime: CMTime = .zero
    /// Time in the assembled project.
    private(set) var projectTime: CMTime = .zero
    private(set) var previewNote: String?
    private(set) var visuals: [UUID: ClipVisuals] = [:]
    private(set) var errorMessage: String?
    private(set) var zoom: Double = 1.0
    private(set) var exportUI: ExportUI = .idle
    private(set) var isLoadingFiles = false

    @ObservationIgnored private var lastRevision = 0
    @ObservationIgnored private var clipLoadedID: UUID?
    @ObservationIgnored private var clipLoadedURL: URL?
    @ObservationIgnored private var clipObserver: (player: AVPlayer, token: Any)?
    @ObservationIgnored private var projectObserver: (player: AVPlayer, token: Any)?
    @ObservationIgnored private var projectStale = true
    @ObservationIgnored private var isBuildingPreview = false
    @ObservationIgnored private var autosaver: Autosaver?
    @ObservationIgnored private var exporter: ProjectExporter?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var didOfferRestore = false

    private let zoomMin = 1.0
    private let zoomMax = 64.0

    init() {
        autosaver = Autosaver(
            delay: .seconds(2),
            write: { [weak self] in try await self?.autosaveNow() },
            onError: { [weak self] error in
                Task { @MainActor in self?.errorMessage = "Autosave failed: \(error.localizedDescription)" }
            })
    }

    // MARK: Derived

    var project: Project { editor.project }
    var selectedClip: Clip? { editor.selectedClip }
    var segments: [Segment] { editor.selectedClip?.segments ?? [] }
    var inPoint: CMTime? { editor.inPoint }
    var clipDuration: CMTime { editor.clipEnd ?? .zero }
    var timeMap: ProjectTimeMap { ProjectTimeMap(grid: plan.grid) }
    var player: AVPlayer? { mode == .clip ? clipPlayer : projectPlayer }
    var selectedVisuals: ClipVisuals {
        guard let id = editor.selectedClipID else { return ClipVisuals() }
        return visuals[id] ?? ClipVisuals()
    }

    var selectedSegmentID: UUID? {
        get { editor.selectedSegmentID }
        set { editor.selectedSegmentID = newValue }
    }

    /// Source time of the playhead as the timeline shows it. In Project mode this is the mapped
    /// position inside the clip under the project playhead.
    var timelinePlayhead: CMTime {
        switch mode {
        case .clip:
            return clipTime
        case .project:
            guard projectTime.isNumeric, let loc = timeMap.locate(Rational(projectTime)),
                  loc.clipID == editor.selectedClipID else { return .zero }
            return loc.sourceTime.cmTime
        }
    }

    var isPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus == .playing && player.rate != 0
    }

    var isConstant: Bool {
        if case .constant = project.fpsMode { return true }
        return false
    }

    var targetFrameDuration: Rational? {
        if case .constant(let d) = project.fpsMode { return d }
        return nil
    }

    var followsHighest: Bool { editor.targetFollowsHighest }

    var fpsChoices: [Rational] {
        var list = FrameRateChoice.candidates(for: project.clips)
        if let current = targetFrameDuration, !list.contains(current) {
            list.append(current)
            list.sort()
        }
        return list
    }

    var isExporting: Bool { exportUI != .idle }
    var canExport: Bool { plan.canExport && !isExporting }

    var windowTitle: String {
        _ = documentVersion
        let dirty = document.hasUnsavedChanges(revision: editor.revision) && !project.clips.isEmpty
        return document.displayName + (dirty ? " — Edited" : "")
    }

    func clearError() { errorMessage = nil }

    // MARK: Edit plumbing

    private func edit(_ body: (inout ProjectEditor) -> Void) {
        body(&editor)
        afterEdit()
    }

    private func afterEdit() {
        if editor.revision != lastRevision {
            lastRevision = editor.revision
            plan = editor.plan
            projectStale = true
            documentVersion += 1
            autosaver?.noteChange()
        }
        if mode == .clip { syncClipPlayer() }
    }

    // MARK: Files in and out

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .slateProject]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await open(urls: urls) }
    }

    func addClipsPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addFiles(urls) }
    }

    /// Finder open, Dock drop, Cmd+O: a `.slate` file replaces the project, video files are added.
    func open(urls: [URL]) async {
        if let slate = urls.first(where: { $0.pathExtension.lowercased() == "slate" }) {
            await openProject(at: slate)
        } else {
            await addFiles(urls)
        }
    }

    func handleDrop(_ urls: [URL], at index: Int?) async {
        if urls.contains(where: { $0.pathExtension.lowercased() == "slate" }) {
            await open(urls: urls)
        } else {
            await addFiles(urls, at: index)
        }
    }

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Probe each file; a file that cannot be read is reported by name and does not stop the others.
    func addFiles(_ urls: [URL], at index: Int? = nil) async {
        let videos = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else {
            if !urls.isEmpty { errorMessage = "Slate opens mp4, m4v and mov video files and .slate projects." }
            return
        }
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        var clips: [Clip] = []
        var failures: [String] = []
        for url in videos {
            do {
                let media = try await ClipProbe.probe(url: url)
                clips.append(ProjectEditor.makeClip(url: url, media: media))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !clips.isEmpty {
            ensureClipMode()
            edit { $0.addClips(clips, at: index) }
            for clip in clips { ensurePoster(clip.id) }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func openProject(at url: URL) async {
        guard confirmDiscardChanges() else { return }
        do {
            let loaded = try await ProjectFile.load(from: url)
            replaceProject(loaded, url: url, followsHighest: false)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func newProject() {
        guard confirmDiscardChanges() else { return }
        document.discardUntitledAutosave()
        replaceProject(Project(), url: nil, followsHighest: true)
    }

    private func replaceProject(_ p: Project, url: URL?, followsHighest: Bool) {
        stopPlayers()
        visuals = [:]
        mode = .clip
        editor = ProjectEditor(project: p, targetFollowsHighest: followsHighest)
        lastRevision = editor.revision
        plan = editor.plan
        projectStale = true
        document = url.map { ProjectDocument(fileURL: $0, savedRevision: editor.revision) }
            ?? ProjectDocument(savedRevision: editor.revision)
        documentVersion += 1
        clipTime = .zero
        projectTime = .zero
        previewNote = nil
        syncClipPlayer()
        for clip in p.clips { ensurePoster(clip.id) }
    }

    /// Ask before an action that would drop unsaved changes. Returns false if the user cancels.
    func confirmDiscardChanges() -> Bool {
        guard document.hasUnsavedChanges(revision: editor.revision), !project.clips.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you do not save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func save() -> Bool {
        if document.isUntitled { return saveAs() }
        do {
            try document.save(project, revision: editor.revision)
            documentVersion += 1
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.slateProject]
        panel.nameFieldStringValue = "\(document.displayName).slate"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try document.saveAs(project, to: url, revision: editor.revision)
            documentVersion += 1
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// Called once at launch: offer the untitled project autosaved by an earlier run.
    func offerRestore() async {
        guard !didOfferRestore, project.clips.isEmpty else { return }
        didOfferRestore = true
        guard let restored = await document.restorableProject() else { return }
        let alert = NSAlert()
        alert.messageText = "Restore your unsaved project?"
        alert.informativeText = "Slate found a project that was autosaved in an earlier session."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            replaceProject(restored, url: nil, followsHighest: false)
            document.restoredUntitled()
            documentVersion += 1
        } else {
            document.discardUntitledAutosave()
        }
    }

    private func autosaveNow() throws {
        try document.autosave(project, revision: editor.revision)
        documentVersion += 1
    }

    /// For `applicationWillTerminate`: write the latest state before the process ends.
    func autosaveNowSync() {
        autosaver?.cancel()
        try? autosaveNow()
    }

    // MARK: Clips

    func selectClip(_ id: UUID) {
        editor.selectClip(id)
        if mode == .project {
            if let start = timeMap.firstOutputStart(of: id) { seekProject(start.cmTime) }
            ensureVisuals(id)
        } else {
            syncClipPlayer()
        }
    }

    func selectNextClip() {
        var e = editor
        e.selectNextClip()
        if let id = e.selectedClipID { selectClip(id) }
    }

    func selectPreviousClip() {
        var e = editor
        e.selectPreviousClip()
        if let id = e.selectedClipID { selectClip(id) }
    }

    func moveClip(_ id: UUID, to index: Int) {
        ensureClipMode()
        edit { $0.moveClip(id, to: index) }
    }

    func removeClip(_ id: UUID) {
        ensureClipMode()
        edit { $0.removeClip(id) }
    }

    func duplicateClip(_ id: UUID) {
        ensureClipMode()
        edit { $0.duplicateClip(id) }
        if let selected = editor.selectedClipID { ensurePoster(selected) }
    }

    func removeSelectedClip() { if let id = editor.selectedClipID { removeClip(id) } }
    func duplicateSelectedClip() { if let id = editor.selectedClipID { duplicateClip(id) } }

    func revealInFinder(_ id: UUID) {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    /// "Locate file…": pick a replacement file for a missing clip.
    func relink(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let media = try await ClipProbe.probe(url: url)
                ensureClipMode()
                visuals[id] = nil
                clipLoadedID = nil
                edit { $0.relinkClip(id, url: url, media: media) }
                ensurePoster(id)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Segments (source time)

    func markIn() {
        ensureClipMode()
        edit { $0.setInPoint(clipTime) }
    }

    func markOut() {
        ensureClipMode()
        edit { _ = $0.commitOut(at: clipTime) }
    }

    func deleteSelectedSegment() {
        ensureClipMode()
        edit { _ = $0.deleteSelectedSegment() }
    }

    /// Esc: drop the pending in-point and the segment selection.
    func clearSelection() {
        edit {
            $0.clearInPoint()
            $0.selectedSegmentID = nil
        }
    }

    func timelineSeek(to time: CMTime) {
        ensureClipMode()
        seekClip(time)
    }

    func beginSegmentDrag() {
        ensureClipMode()
        edit { $0.beginSegmentDrag() }
    }

    func dragEdge(id: UUID, edge: SegmentEdge, to time: CMTime) {
        edit { $0.dragEdge(id: id, edge: edge, to: time) }
    }

    func endSegmentDrag() {
        edit { $0.endSegmentDrag() }
    }

    func undo() {
        ensureClipMode()
        edit { $0.undo() }
    }

    func redo() {
        ensureClipMode()
        edit { $0.redo() }
    }

    // MARK: Frame rate

    func setMixed() { edit { $0.useMixed() } }
    func setConstant(_ d: Rational?) { edit { $0.useConstant(d) } }

    // MARK: Players

    /// Make sure the selected clip's own player is loaded (source-file playback for trimming).
    private func syncClipPlayer() {
        guard clipLoadedID != editor.selectedClipID || clipLoadedURL != editor.selectedClip?.url else { return }
        if let (p, token) = clipObserver { p.removeTimeObserver(token) }
        clipObserver = nil
        clipLoadedID = editor.selectedClipID
        clipLoadedURL = editor.selectedClip?.url
        clipTime = .zero
        guard let clip = editor.selectedClip, clip.media != nil else {
            clipPlayer = nil
            return
        }
        let p = AVPlayer(url: clip.url)
        p.actionAtItemEnd = .pause
        clipPlayer = p
        clipObserver = (p, makeObserver(for: p, isProject: false))
        ensureVisuals(clip.id)
    }

    private func makeObserver(for player: AVPlayer, isProject: Bool) -> Any {
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t, isProject: isProject) }
        }
    }

    private func tick(_ t: CMTime, isProject: Bool) {
        guard t.isNumeric else { return }
        if isProject {
            projectTime = t
            // In Project mode the selection follows the playhead.
            if mode == .project, let loc = timeMap.locate(Rational(t)), loc.clipID != editor.selectedClipID {
                editor.selectClip(loc.clipID)
                ensureVisuals(loc.clipID)
            }
        } else {
            clipTime = t
        }
    }

    private func stopPlayers() {
        clipPlayer?.pause()
        projectPlayer?.pause()
        if let (p, token) = clipObserver { p.removeTimeObserver(token) }
        if let (p, token) = projectObserver { p.removeTimeObserver(token) }
        clipObserver = nil
        projectObserver = nil
        clipPlayer = nil
        projectPlayer = nil
        clipLoadedID = nil
        clipLoadedURL = nil
    }

    func setMode(_ new: PlayerMode) {
        guard new != mode else { return }
        switch new {
        case .clip:
            ensureClipMode()
        case .project:
            clipPlayer?.pause()
            Task { await enterProjectMode() }
        }
    }

    func toggleMode() { setMode(mode == .clip ? .project : .clip) }

    private func enterProjectMode() async {
        await rebuildProjectPlayerIfNeeded()
        guard projectPlayer != nil else { return }
        var start = Rational.zero
        if let id = editor.selectedClipID {
            if clipTime.isNumeric, let t = timeMap.projectTime(clipID: id, sourceTime: Rational(clipTime)) {
                start = t
            } else if let first = timeMap.firstOutputStart(of: id) {
                start = first
            }
        }
        mode = .project
        seekProject(start.cmTime)
    }

    /// Leave Project mode: pause, select the clip under the project playhead, load it, and seek it to
    /// the mapped source time — so an edit command lands on the frame the user saw.
    func ensureClipMode() {
        guard mode == .project else { return }
        projectPlayer?.pause()
        let location = projectTime.isNumeric ? timeMap.locate(Rational(projectTime)) : nil
        mode = .clip
        if let location { editor.selectClip(location.clipID) }
        syncClipPlayer()
        if let location { seekClip(location.sourceTime.cmTime) }
    }

    /// The Project player plays the same grid segments as the export (each at its output start).
    /// A clip whose audio is more than one AAC packet short makes the composition throw; the preview
    /// then falls back to video only and says so.
    private func rebuildProjectPlayerIfNeeded() async {
        guard projectStale || projectPlayer == nil, !isBuildingPreview else { return }
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        previewNote = nil
        let plan = self.plan
        let project = self.project
        guard plan.canExport else {
            previewNote = "Preview unavailable: " + ClipPresentation.blockerTexts(plan, project: project).joined(separator: " ")
            dropProjectPlayer()
            return
        }
        var assets: [UUID: AVAsset] = [:]
        for clip in project.clips { assets[clip.id] = AVURLAsset(url: clip.url) }
        do {
            let inserts = try CompositionBuilder.inserts(for: plan.grid, assets: assets)
            let composition: AVMutableComposition
            do {
                composition = try await CompositionBuilder.build(inserts: inserts, includeAudio: plan.hasAudio,
                                                                 timescale: plan.outputTimescale)
            } catch CompositionError.audioTruncated(let clipID, _) {
                let number = project.clips.firstIndex { $0.id == clipID }.map { "clip \($0 + 1)" } ?? "a clip"
                previewNote = "Preview is silent: the audio of \(number) ends before its video. Export will refuse it."
                composition = try await CompositionBuilder.build(inserts: inserts, includeAudio: false,
                                                                 timescale: plan.outputTimescale)
            }
            dropProjectPlayer()
            let p = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            p.actionAtItemEnd = .pause
            projectPlayer = p
            projectObserver = (p, makeObserver(for: p, isProject: true))
            projectStale = false
        } catch {
            previewNote = "Preview unavailable: \(error.localizedDescription)"
            dropProjectPlayer()
        }
    }

    private func dropProjectPlayer() {
        projectPlayer?.pause()
        if let (p, token) = projectObserver { p.removeTimeObserver(token) }
        projectObserver = nil
        projectPlayer = nil
    }

    // MARK: Transport

    func togglePlayPause() {
        guard let player else { return }
        player.rate = player.rate == 0 ? 1.0 : 0
    }

    /// J: reverse, rates -1, -2, -4, -8.
    func nudgeReverse() {
        guard let player else { return }
        player.rate = player.rate >= 0 ? -1.0 : max(player.rate * 2, -8.0)
    }

    /// K: pause.
    func pause() { player?.rate = 0 }

    /// L: forward, rates 1, 2, 4, 8.
    func nudgeForward() {
        guard let player else { return }
        player.rate = player.rate <= 0 ? 1.0 : min(player.rate * 2, 8.0)
    }

    func stepFrame(by count: Int) {
        guard let item = player?.currentItem else { return }
        player?.rate = 0
        item.step(byCount: count)
    }

    private func clampClip(_ t: CMTime) -> CMTime {
        guard t.isNumeric else { return .zero }
        var r = t
        if CMTimeCompare(r, .zero) < 0 { r = .zero }
        if let end = editor.clipEnd, CMTimeCompare(r, end) > 0 { r = end }
        return r
    }

    private func seekClip(_ t: CMTime) {
        guard let p = clipPlayer else { return }
        let c = clampClip(t)
        p.seek(to: c, toleranceBefore: .zero, toleranceAfter: .zero)
        clipTime = c
    }

    private func seekProject(_ t: CMTime) {
        guard let p = projectPlayer else { return }
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        projectTime = t
    }

    // MARK: Zoom

    func setZoom(_ z: Double) { zoom = max(zoomMin, min(zoomMax, z)) }
    func zoomIn() { setZoom(zoom * 1.5) }
    func zoomOut() { setZoom(zoom / 1.5) }
    func resetZoom() { setZoom(1.0) }

    // MARK: Thumbnails and keyframes

    /// First-frame poster for a card. Cheap; done for every clip.
    private func ensurePoster(_ id: UUID) {
        guard let clip = project.clips.first(where: { $0.id == id }), clip.media != nil,
              visuals[id]?.poster == nil else { return }
        let url = clip.url
        Task { [weak self] in
            let thumbs = (try? await ThumbnailGenerator.generate(asset: AVURLAsset(url: url), count: 1, pointHeight: 56)) ?? []
            await MainActor.run {
                guard let self else { return }
                var v = self.visuals[id] ?? ClipVisuals()
                if v.poster == nil { v.poster = thumbs.first?.image }
                self.visuals[id] = v
            }
        }
    }

    /// Timeline thumbnails and keyframe ticks for the selected clip (generated once, in the background).
    private func ensureVisuals(_ id: UUID) {
        guard let clip = project.clips.first(where: { $0.id == id }), clip.media != nil else { return }
        var v = visuals[id] ?? ClipVisuals()
        if v.isScanning || !v.thumbnails.isEmpty { return }
        v.isScanning = true
        visuals[id] = v
        let url = clip.url
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let thumbs = (try? await ThumbnailGenerator.generate(asset: asset, count: 80, pointHeight: 56)) ?? []
            let keys = (try? await KeyframeScanner.scan(asset: asset)) ?? KeyframeIndex(times: [])
            await MainActor.run {
                guard let self else { return }
                var v = self.visuals[id] ?? ClipVisuals()
                v.thumbnails = thumbs
                v.keyframes = keys
                v.isScanning = false
                if v.poster == nil { v.poster = thumbs.first?.image }
                self.visuals[id] = v
            }
        }
    }

    // MARK: Export

    /// Cmd+E: show the plan. The user starts the export from the sheet.
    func beginExport() {
        guard !isExporting else { return }
        exportUI = .review
    }

    func startExport() {
        guard plan.canExport, case .review = exportUI else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = ClipPresentation.defaultOutputName(
            project: project, documentName: document.isUntitled ? nil : document.displayName)
        if let first = project.clips.first { panel.directoryURL = first.url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let exporter = ProjectExporter()
        self.exporter = exporter
        exportUI = .running(nil)
        let snapshot = project
        exportTask = Task { @MainActor in
            do {
                _ = try await exporter.export(
                    project: snapshot, outputURL: outURL, tempDirectory: FileManager.default.temporaryDirectory,
                    progress: { stage in
                        Task { @MainActor in
                            if case .running = self.exportUI { self.exportUI = .running(stage) }
                        }
                    })
                self.exportUI = .done(outURL)
            } catch ProjectExportError.validationFailed(let report) {
                self.exportUI = .refused(report.issues)
            } catch ProjectExportError.cancelled {
                self.exportUI = .failed("Cancelled.")
            } catch ReencodeError.clipAudioTruncated(let clipID, _) {
                self.exportUI = .failed(self.audioShortMessage(clipID))
            } catch CompositionError.audioTruncated(let clipID, _) {
                self.exportUI = .failed(self.audioShortMessage(clipID))
            } catch {
                self.exportUI = .failed(error.localizedDescription)
            }
        }
    }

    private func audioShortMessage(_ clipID: UUID?) -> String {
        let name = project.clips.firstIndex { $0.id == clipID }
            .map { "Clip \($0 + 1) (\(project.clips[$0].url.lastPathComponent))" } ?? "A clip"
        return "\(name): its audio ends more than one audio packet before its video. Trim the end of the clip or use a file with complete audio."
    }

    func cancelExport() { exporter?.cancel() }

    func dismissExport() {
        exportUI = .idle
        exporter = nil
        exportTask = nil
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -20` (sandbox disabled)
Expected: `Build complete!` If the compiler rejects something (typical candidates: `MainActor.assumeIsolated` closure capture, `@Observable` with tuple-typed ignored properties, `case CompositionError.audioTruncated(let clipID, _)` label binding, the `if let (p, token) = clipObserver` tuple destructuring), fix with the smallest change that keeps the behaviour and list the change in the report.

- [ ] **Step 3: Regression**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `154 passed, 0 failed, 0 skipped`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Slate/ViewModels/ProjectViewModel.swift
git commit -m "feat(app): ProjectViewModel — project state, players, visuals, files, autosave, export"
```

---
### Task 5: Clip strip — cards, AppKit mouse capture, reorder, Finder drops, context menu

**Files:**
- Create: `Sources/Slate/Views/DroppedFiles.swift`, `Sources/Slate/Views/ClipCardView.swift`, `Sources/Slate/Views/ClipStripMouseCapture.swift`, `Sources/Slate/Views/ClipStripView.swift`

Nothing references these views yet (Task 7 wires them in), so this task is verified by `swift build`.

**Interfaces:**
- Consumes: `ProjectViewModel` (Task 4), `ClipPresentation`, `ClipCardInfo`, `Clip`.
- Produces: `ClipStripView(vm:)` (fixed card layout: card 132 × 96 pt, gap 8, inset 8; fixed height `ClipStripLayout.stripHeight + 14`), `ClipCardView`, `ClipStripLayout`, `DroppedFiles.urls(from:) async -> [URL]`.

- [ ] **Step 1: `DroppedFiles.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

enum DroppedFiles {
    /// File URLs behind the providers of a Finder drop, in drop order. Providers that are not files are skipped.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await load(provider) { urls.append(url) }
        }
        return urls
    }

    private static func load(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
```

- [ ] **Step 2: `ClipCardView.swift`**

```swift
import SwiftUI
import AppKit
import SlateCore

enum ClipStripLayout {
    static let cardWidth: CGFloat = 132
    static let cardHeight: CGFloat = 96
    static let gap: CGFloat = 8
    static let inset: CGFloat = 8
    static let stripHeight: CGFloat = 96
}

struct ClipCardView: View {
    let info: ClipCardInfo
    let poster: NSImage?
    let selected: Bool
    let dimmed: Bool

    private typealias L = ClipStripLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .top) {
                Group {
                    if let poster {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(white: 0.2))
                    }
                }
                .frame(width: L.cardWidth - 8, height: 52)
                .clipped()
                HStack {
                    Text("\(info.index)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    if info.hasAudio {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .padding(3)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                    }
                }
                .padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(info.fileName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                Text(info.keptText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(info.fpsText)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeColor)
                    .foregroundStyle(badgeTextColor)
                    .clipShape(Capsule())
            }
        }
        .padding(4)
        .frame(width: L.cardWidth, height: L.cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(info.tone == .error ? Color.red.opacity(0.28) : Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .opacity(dimmed ? 0.35 : 1)
    }

    private var badgeColor: Color {
        switch info.tone {
        case .normal: return Color(white: 0.32)
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private var badgeTextColor: Color {
        info.tone == .warning ? .black : .white
    }
}
```

- [ ] **Step 3: `ClipStripMouseCapture.swift`**

```swift
import SwiftUI
import AppKit

struct StripMenuItem {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
}

/// Transparent NSView over the strip. AppKit mouse handling for the same reason as the timeline:
/// SwiftUI gestures were unreliable. Also owns the right-click menu and the tooltip.
struct ClipStripMouseCapture: NSViewRepresentable {
    var onMouseDown: (CGPoint) -> Void
    var onMouseDragged: (CGPoint) -> Void
    var onMouseUp: (CGPoint) -> Void
    var tooltipAt: (CGPoint) -> String?
    var menuItemsAt: (CGPoint) -> [StripMenuItem]

    func makeNSView(context: Context) -> ClipStripNSView {
        let view = ClipStripNSView()
        apply(view)
        return view
    }

    func updateNSView(_ view: ClipStripNSView, context: Context) {
        apply(view)
    }

    private func apply(_ view: ClipStripNSView) {
        view.onMouseDown = onMouseDown
        view.onMouseDragged = onMouseDragged
        view.onMouseUp = onMouseUp
        view.tooltipAt = tooltipAt
        view.menuItemsAt = menuItemsAt
    }
}

final class ClipStripNSView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var tooltipAt: ((CGPoint) -> String?)?
    var menuItemsAt: ((CGPoint) -> [StripMenuItem])?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) { onMouseDown?(point(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(point(event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(point(event)) }

    override func mouseMoved(with event: NSEvent) {
        toolTip = tooltipAt?(point(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItemsAt?(point(event)) ?? []
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = ClosureMenuItem(title: item.title, closure: item.action)
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { closure() }
}
```

- [ ] **Step 4: `ClipStripView.swift`**

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SlateCore

struct ClipStripView: View {
    let vm: ProjectViewModel

    @State private var pressIndex: Int?
    @State private var pressX: CGFloat = 0
    @State private var dragging = false
    @State private var reorderMarker: Int?
    @State private var dropMarker: Int?

    private typealias L = ClipStripLayout

    private var clips: [Clip] { vm.project.clips }
    private var step: CGFloat { L.cardWidth + L.gap }
    private var contentWidth: CGFloat { max(CGFloat(clips.count) * step + L.inset * 2, 240) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    cards
                    if let marker = reorderMarker ?? dropMarker {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: L.cardHeight)
                            .offset(x: markerX(marker), y: 7)
                            .allowsHitTesting(false)
                    }
                    ClipStripMouseCapture(
                        onMouseDown: { handleDown($0) },
                        onMouseDragged: { handleDragged($0) },
                        onMouseUp: { handleUp($0) },
                        tooltipAt: { tooltip(at: $0) },
                        menuItemsAt: { menuItems(at: $0) })
                        .frame(width: contentWidth, height: L.stripHeight + 14)
                }
                .frame(width: contentWidth, height: L.stripHeight + 14, alignment: .topLeading)
                .onDrop(of: [.fileURL], delegate: StripDropDelegate(
                    indexForX: { insertionIndex(forX: $0) },
                    marker: $dropMarker,
                    onDrop: { urls, index in Task { await vm.handleDrop(urls, at: index) } }))
            }
            Divider()
            Button {
                vm.addClipsPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: L.stripHeight)
            }
            .buttonStyle(.borderless)
            .help("Add clips (⌘O)")
        }
        .frame(height: L.stripHeight + 14)
        .background(Color(white: 0.09))
    }

    private var cards: some View {
        HStack(spacing: L.gap) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                ClipCardView(info: ClipPresentation.card(for: clip, index: i + 1, plan: vm.plan),
                             poster: vm.visuals[clip.id]?.poster,
                             selected: clip.id == vm.editor.selectedClipID,
                             dimmed: dragging && pressIndex == i)
            }
        }
        .padding(.horizontal, L.inset)
        .padding(.top, 7)
        .allowsHitTesting(false)
    }

    // MARK: Geometry

    /// The clip whose card is under x, or nil in a gap or past the last card.
    private func index(at x: CGFloat) -> Int? {
        let rel = x - L.inset
        guard rel >= 0 else { return nil }
        let i = Int(rel / step)
        guard i < clips.count, rel - CGFloat(i) * step <= L.cardWidth else { return nil }
        return i
    }

    /// Where a card dropped at x would be inserted (0...count).
    private func insertionIndex(forX x: CGFloat) -> Int {
        let i = Int(((x - L.inset + step / 2) / step).rounded(.down))
        return min(max(i, 0), clips.count)
    }

    private func markerX(_ i: Int) -> CGFloat {
        L.inset + CGFloat(i) * step - L.gap / 2 - 1.5
    }

    // MARK: Mouse

    private func handleDown(_ p: CGPoint) {
        pressIndex = index(at: p.x)
        pressX = p.x
        dragging = false
        if let i = pressIndex { vm.selectClip(clips[i].id) }
    }

    private func handleDragged(_ p: CGPoint) {
        guard pressIndex != nil else { return }
        if abs(p.x - pressX) > 4 { dragging = true }
        if dragging { reorderMarker = insertionIndex(forX: p.x) }
    }

    private func handleUp(_ p: CGPoint) {
        defer {
            pressIndex = nil
            dragging = false
            reorderMarker = nil
        }
        guard dragging, let from = pressIndex, let insert = reorderMarker else { return }
        let final = insert > from ? insert - 1 : insert
        if final != from { vm.moveClip(clips[from].id, to: final) }
    }

    private func tooltip(at p: CGPoint) -> String? {
        guard let i = index(at: p.x) else { return nil }
        let info = ClipPresentation.card(for: clips[i], index: i + 1, plan: vm.plan)
        return "\(info.fileName) — \(info.tooltip)"
    }

    private func menuItems(at p: CGPoint) -> [StripMenuItem] {
        guard let i = index(at: p.x) else { return [] }
        let clip = clips[i]
        vm.selectClip(clip.id)
        let exists = FileManager.default.fileExists(atPath: clip.url.path)
        return [
            StripMenuItem(title: "Duplicate", isEnabled: true, action: { vm.duplicateClip(clip.id) }),
            StripMenuItem(title: "Remove", isEnabled: true, action: { vm.removeClip(clip.id) }),
            StripMenuItem(title: "Show in Finder", isEnabled: exists, action: { vm.revealInFinder(clip.id) }),
            StripMenuItem(title: "Locate file…", isEnabled: true, action: { vm.relink(clip.id) }),
        ]
    }
}

/// Finder drop onto the strip: shows an insertion marker and adds the files at that position.
struct StripDropDelegate: DropDelegate {
    let indexForX: (CGFloat) -> Int
    @Binding var marker: Int?
    let onDrop: ([URL], Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        marker = indexForX(info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        marker = indexForX(info.location.x)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        marker = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = indexForX(info.location.x)
        marker = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            let urls = await DroppedFiles.urls(from: providers)
            await MainActor.run { onDrop(urls, index) }
        }
        return true
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -20` (sandbox disabled)
Expected: `Build complete!`. Likely compile fixes: `DropDelegate` methods are `@MainActor`-isolated in newer SDKs (mark `StripDropDelegate` `@MainActor` if the compiler asks), `Image(nsImage:)` inside `Group`, the `defer` block in `handleUp` reading `@State`. Fix minimally and list deviations.

- [ ] **Step 6: Commit**

```bash
git add Sources/Slate/Views
git commit -m "feat(app): clip strip — cards, mouse capture, reorder, Finder drops, context menu"
```

---

### Task 6: `ProjectExportSheet`

**Files:**
- Create: `Sources/Slate/Views/ProjectExportSheet.swift`

**Interfaces:**
- Consumes: `ProjectViewModel.exportUI`, `plan`, `project`, `isConstant`, `startExport()`, `cancelExport()`, `dismissExport()`; `ClipPresentation`.
- Produces: `ProjectExportSheet(vm:)`. Present it when `vm.exportUI != .idle` (Task 7). The old `ExportSheet` stays until Task 7.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import AppKit
import SlateCore

struct ProjectExportSheet: View {
    let vm: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            switch vm.exportUI {
            case .idle:
                EmptyView()
            case .review:
                review
            case .running(let stage):
                running(stage)
            case .done(let url):
                done(url)
            case .refused(let issues):
                refused(issues)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var title: String {
        switch vm.exportUI {
        case .idle: return ""
        case .review: return "Export"
        case .running: return "Exporting…"
        case .done: return "Export complete"
        case .refused: return "Export refused"
        case .failed: return "Export failed"
        }
    }

    // MARK: Review (the plan)

    private var review: some View {
        let plan = vm.plan
        let rows = ClipPresentation.rows(plan, project: vm.project)
        let blockers = ClipPresentation.blockerTexts(plan, project: vm.project)
        return VStack(alignment: .leading, spacing: 10) {
            Text(ClipPresentation.modeText(plan)).font(.subheadline)
            if !vm.isConstant {
                Text(ClipPresentation.mixedLabel).font(.caption).foregroundStyle(.orange)
            }
            if plan.canExport {
                Text(ClipPresentation.summary(plan)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.index) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(row.index)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(row.text).font(.caption).foregroundStyle(color(row.tone))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            ForEach(blockers, id: \.self) { text in
                Text(text).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { vm.dismissExport() }
                Button("Export…") { vm.startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canExport)
            }
        }
    }

    private func color(_ tone: ClipCardInfo.Tone) -> Color {
        switch tone {
        case .normal: return .secondary
        case .warning: return .yellow
        case .error: return .red
        }
    }

    // MARK: Running

    private func running(_ stage: ExportStage?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stageTitle(stage))
            if let fraction = fraction(stage) {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { vm.cancelExport() }
            }
        }
    }

    private func stageTitle(_ stage: ExportStage?) -> String {
        switch stage {
        case nil: return "Starting…"
        case .reencoding(let k, let n, _)?: return "Re-encoding \(k) of \(n)"
        case .assembling?: return "Assembling"
        case .validating?: return "Validating"
        }
    }

    private func fraction(_ stage: ExportStage?) -> Double? {
        switch stage {
        case .reencoding(_, _, let p)?: return p
        case .assembling(let p)?: return p
        default: return nil
        }
    }

    // MARK: Results

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refused(_ issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The exported file failed the timing check, so it was not saved. Any file that was already at the destination is unchanged.")
                .font(.callout)
            ForEach(Array(issues.prefix(8).enumerated()), id: \.offset) { _, issue in
                Text("• \(issue)").font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
            }
            if issues.count > 8 {
                Text("… and \(issues.count - 8) more").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.callout).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Close") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -20` (sandbox disabled)
Expected: `Build complete!`. (`case .reencoding(let k, let n, _)?` and `case .assembling?` optional-pattern forms are the usual trouble spot: if the compiler prefers, unwrap with `guard let stage` first.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Slate/Views/ProjectExportSheet.swift
git commit -m "feat(app): ProjectExportSheet — plan, stages, refused-export report"
```

---
### Task 7: The switch — timeline on the selected clip, new editor window, menu commands, `.slate` document type

**Files:**
- Rewrite: `Sources/Slate/Views/TimelineView.swift`, `Sources/Slate/Views/EditorView.swift`, `Sources/Slate/SlateApp.swift`
- Modify: `scripts/Info.plist`
- Delete: `Sources/Slate/ViewModels/EditorViewModel.swift`, `Sources/Slate/Services/Exporter.swift`, `Sources/Slate/Views/ExportSheet.swift`

After this task the app runs the multi-clip flow end to end. Old and new code never coexist in a commit that fails to build: do all steps, then build once.

**Interfaces:**
- Consumes: everything from Tasks 4-6. The core `SegmentEdge` replaces the old app-local enum (deleted with `EditorViewModel.swift`).
- Produces: the finished app: `sharedViewModel`, `AppDelegate`, `AppCommands`.

- [ ] **Step 1: Rewrite `TimelineView.swift`**

The timeline shows the selected clip in SOURCE time. Auto segments draw lighter with the label "whole clip". In Project mode it is dimmed and read-only (any click or edit switches to Clip mode first, inside the view model).

```swift
import SwiftUI
import AVFoundation
import AppKit
import CoreMedia
import SlateCore

struct TimelineView: View {
    let vm: ProjectViewModel

    private let stripHeight: CGFloat = 56
    private let rulerHeight: CGFloat = 18
    private let handleVisibleWidth: CGFloat = 6
    private let handleHitRadius: CGFloat = 10  // ±10pt around the actual edge

    private var totalHeight: CGFloat { stripHeight + rulerHeight }

    private enum DragKind: Equatable {
        case none
        case seek
        case edge(UUID, SegmentEdge)
    }

    @State private var dragKind: DragKind = .none
    @State private var lastMagnification: Double = 1.0
    @State private var hoverNearEdge: Bool = false

    /// Ticks per second used for times created from mouse positions (the clip's own track timescale).
    private var sourceTimescale: Int32 { vm.selectedClip?.media?.frames.timescale ?? 600 }

    var body: some View {
        GeometryReader { geo in
            let baseWidth = geo.size.width
            let contentWidth = max(baseWidth * CGFloat(vm.zoom), baseWidth)
            let total = max(vm.clipDuration.seconds, 0.0001)

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color(white: 0.10)
                        .frame(width: contentWidth, height: totalHeight)

                    thumbnailsLayer(width: contentWidth)
                        .frame(width: contentWidth, height: stripHeight)
                        .offset(y: rulerHeight)

                    keyframeTicks(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: rulerHeight)

                    segmentBodiesVisual(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: stripHeight)
                        .offset(y: rulerHeight)

                    edgeHandlesVisual(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    inPointMarker(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    playhead(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    if vm.selectedClip?.media == nil {
                        Text("File is missing — right-click the card and choose “Locate file…”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.top, rulerHeight + 20)
                            .allowsHitTesting(false)
                    }

                    // Topmost layer: AppKit mouse capture owns ALL mouse handling for the timeline.
                    TimelineMouseCapture(
                        onMouseDown: { p in handleMouseDown(p, contentWidth: contentWidth, total: total) },
                        onMouseDragged: { p in handleMouseDragged(p, contentWidth: contentWidth, total: total) },
                        onMouseUp: { p in handleMouseUp(p, contentWidth: contentWidth, total: total) },
                        onMouseMoved: { p in handleMouseMoved(p, contentWidth: contentWidth, total: total) },
                        onMouseExited: { handleMouseExited() }
                    )
                    .frame(width: contentWidth, height: totalHeight)
                }
                .gesture(magnifyGesture)
            }
        }
        .frame(height: totalHeight)
        .background(Color(white: 0.06))
        .opacity(vm.mode == .project ? 0.55 : 1)
    }

    // MARK: Mouse handlers

    private func handleMouseDown(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let kind = classify(at: p, contentWidth: contentWidth, total: total)
        dragKind = kind
        switch kind {
        case .none:
            break
        case .seek:
            // Click on a segment body selects it; a click in an empty area seeks.
            if let s = hitSegment(atX: p.x, contentWidth: contentWidth, total: total) {
                vm.selectedSegmentID = s.id
            } else {
                vm.selectedSegmentID = nil
                vm.timelineSeek(to: time(forX: p.x, contentWidth: contentWidth, total: total))
            }
        case .edge(let id, _):
            vm.selectedSegmentID = id
            vm.beginSegmentDrag()
        }
    }

    private func handleMouseDragged(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let t = time(forX: p.x, contentWidth: contentWidth, total: total)
        switch dragKind {
        case .none:
            break
        case .seek:
            // Keep seeking only if the press started in an empty area (no segment selected then).
            if vm.selectedSegmentID == nil { vm.timelineSeek(to: t) }
        case .edge(let id, let edge):
            vm.dragEdge(id: id, edge: edge, to: t)
        }
    }

    private func handleMouseUp(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        if case .edge(let id, let edge) = dragKind {
            vm.dragEdge(id: id, edge: edge, to: time(forX: p.x, contentWidth: contentWidth, total: total))
            vm.endSegmentDrag()
        }
        dragKind = .none
    }

    private func handleMouseMoved(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let near = isNearAnyEdge(x: p.x, contentWidth: contentWidth, total: total)
        if near != hoverNearEdge {
            hoverNearEdge = near
            if near { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
    }

    private func handleMouseExited() {
        if hoverNearEdge { NSCursor.arrow.set(); hoverNearEdge = false }
    }

    // MARK: Visual layers

    @ViewBuilder
    private func thumbnailsLayer(width: CGFloat) -> some View {
        let thumbs = vm.selectedVisuals.thumbnails
        if thumbs.isEmpty {
            Rectangle().fill(Color(white: 0.18))
        } else {
            Canvas { ctx, size in
                let cell = size.width / CGFloat(thumbs.count)
                for (i, thumb) in thumbs.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * cell, y: 0, width: cell + 0.5, height: size.height)
                    ctx.draw(Image(nsImage: thumb.image), in: rect)
                }
            }
        }
    }

    private func keyframeTicks(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            let tickColor = GraphicsContext.Shading.color(.white.opacity(0.55))
            for t in vm.selectedVisuals.keyframes.times {
                let x = CGFloat(t.seconds / total) * size.width
                let rect = CGRect(x: x, y: 4, width: 1, height: size.height - 6)
                ctx.fill(Path(rect), with: tickColor)
            }
        }
    }

    private func segmentBodiesVisual(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            for seg in vm.segments {
                let x = CGFloat(seg.start.seconds / total) * size.width
                let w = max(CGFloat(seg.duration.seconds / total) * size.width, 2)
                let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                let isSelected = vm.selectedSegmentID == seg.id
                if seg.isAuto {
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.08)))
                    ctx.stroke(Path(rect), with: .color(.white.opacity(isSelected ? 0.9 : 0.45)),
                               style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3]))
                    ctx.draw(Text("whole clip").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.8)),
                             at: CGPoint(x: rect.minX + 12, y: rect.midY), anchor: .leading)
                } else {
                    ctx.fill(Path(rect), with: .color(.yellow.opacity(isSelected ? 0.32 : 0.20)))
                    ctx.stroke(Path(rect), with: .color(.yellow.opacity(isSelected ? 1.0 : 0.7)),
                               lineWidth: isSelected ? 2 : 1)
                }
            }
        }
    }

    private func edgeHandlesVisual(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            for seg in vm.segments {
                let leftX = CGFloat(seg.start.seconds / total) * size.width
                let rightX = CGFloat(seg.end.seconds / total) * size.width
                let isSelected = vm.selectedSegmentID == seg.id
                let base: Color = seg.isAuto ? .white : .yellow
                let color = GraphicsContext.Shading.color(base.opacity(isSelected ? 1.0 : (seg.isAuto ? 0.6 : 0.85)))
                let leftBar = CGRect(x: leftX - handleVisibleWidth / 2, y: rulerHeight,
                                     width: handleVisibleWidth, height: stripHeight)
                let rightBar = CGRect(x: rightX - handleVisibleWidth / 2, y: rulerHeight,
                                      width: handleVisibleWidth, height: stripHeight)
                ctx.fill(Path(leftBar), with: color)
                ctx.fill(Path(rightBar), with: color)
            }
        }
    }

    // MARK: Hit-classification helpers

    private func classify(at point: CGPoint, contentWidth: CGFloat, total: Double) -> DragKind {
        // Edge takes priority: the nearest edge within the hit radius wins.
        var bestEdge: (UUID, SegmentEdge, CGFloat)? = nil
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            let dl = abs(point.x - leftX)
            let dr = abs(point.x - rightX)
            if dl <= handleHitRadius, bestEdge == nil || dl < bestEdge!.2 {
                bestEdge = (seg.id, .start, dl)
            }
            if dr <= handleHitRadius, bestEdge == nil || dr < bestEdge!.2 {
                bestEdge = (seg.id, .end, dr)
            }
        }
        if let e = bestEdge { return .edge(e.0, e.1) }
        return .seek
    }

    private func isNearAnyEdge(x: CGFloat, contentWidth: CGFloat, total: Double) -> Bool {
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            if abs(x - leftX) <= handleHitRadius { return true }
            if abs(x - rightX) <= handleHitRadius { return true }
        }
        return false
    }

    private func hitSegment(atX x: CGFloat, contentWidth: CGFloat, total: Double) -> Segment? {
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            if x >= leftX && x <= rightX { return seg }
        }
        return nil
    }

    private func time(forX x: CGFloat, contentWidth: CGFloat, total: Double) -> CMTime {
        let f = max(0, min(1, Double(x / max(contentWidth, 1))))
        return CMTime(seconds: f * total, preferredTimescale: sourceTimescale)
    }

    // MARK: Markers

    private func inPointMarker(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            if let inP = vm.inPoint {
                let x = CGFloat(inP.seconds / total) * size.width
                let rect = CGRect(x: x - 1, y: 0, width: 2, height: size.height)
                ctx.fill(Path(rect), with: .color(.green))
            }
        }
    }

    private func playhead(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            let x = CGFloat(vm.timelinePlayhead.seconds / total) * size.width
            let line = CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)
            ctx.fill(Path(line), with: .color(.white))
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: 8))
            tri.addLine(to: CGPoint(x: x - 5, y: 0))
            tri.addLine(to: CGPoint(x: x + 5, y: 0))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(.white))
        }
    }

    // MARK: Pinch zoom

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                vm.setZoom(vm.zoom * Double(scale) / lastMagnification)
                lastMagnification = Double(scale)
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }
}
```

- [ ] **Step 2: Rewrite `EditorView.swift`**

```swift
import SwiftUI
import AVFoundation
import AppKit
import CoreMedia
import SlateCore

@MainActor
struct EditorView: View {
    let vm: ProjectViewModel
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.black)
            notes
            content
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .navigationTitle(vm.windowTitle)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .task { await vm.offerRestore() }
        .onKeyPress(.space) { vm.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { vm.stepFrame(by: -1); return .handled }
        .onKeyPress(.rightArrow) { vm.stepFrame(by: 1); return .handled }
        .onKeyPress(keys: ["j", "k", "l", "i", "o", "[", "]"]) { press in
            switch press.characters.lowercased() {
            case "j": vm.nudgeReverse()
            case "k": vm.pause()
            case "l": vm.nudgeForward()
            case "i": vm.markIn()
            case "o": vm.markOut()
            case "[": vm.selectPreviousClip()
            case "]": vm.selectNextClip()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.delete) { vm.deleteSelectedSegment(); return .handled }
        .onKeyPress(.escape) { vm.clearSelection(); return .handled }
        .onKeyPress(keys: ["=", "+", "-", "0"]) { press in
            switch press.characters {
            case "=", "+": vm.zoomIn()
            case "-": vm.zoomOut()
            case "0": vm.resetZoom()
            default: return .ignored
            }
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                let urls = await DroppedFiles.urls(from: providers)
                await vm.handleDrop(urls, at: nil)
            }
            return true
        }
        .alert("Error", isPresented: errorBinding, presenting: vm.errorMessage) { _ in
            Button("OK") { vm.clearError() }
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: exportBinding) {
            ProjectExportSheet(vm: vm)
        }
    }

    // MARK: Bindings

    private var errorBinding: Binding<Bool> {
        Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.clearError() } })
    }

    /// The sheet cannot be dismissed (Esc) while an export runs; use Cancel.
    private var exportBinding: Binding<Bool> {
        Binding(get: { vm.isExporting }, set: { shown in
            if !shown {
                if case .running = vm.exportUI { return }
                vm.dismissExport()
            }
        })
    }

    private var modeBinding: Binding<ProjectViewModel.PlayerMode> {
        Binding(get: { vm.mode }, set: { vm.setMode($0) })
    }

    private var constantBinding: Binding<Bool> {
        Binding(get: { vm.isConstant }, set: { $0 ? vm.setConstant(nil) : vm.setMixed() })
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Slate")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if !vm.project.clips.isEmpty {
                Picker("Player", selection: modeBinding) {
                    Text("Clip").tag(ProjectViewModel.PlayerMode.clip)
                    Text("Project").tag(ProjectViewModel.PlayerMode.project)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("Clip plays the selected file for trimming; Project plays the assembled result (Tab)")

                Divider().frame(height: 18)

                Picker("Frame rate", selection: constantBinding) {
                    Text("Constant").tag(true)
                    Text("Mixed").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("Constant re-encodes every clip to one frame rate; Mixed copies clips as they are")

                if vm.isConstant { fpsMenu }

                Text(ClipPresentation.summary(vm.plan))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                vm.addClipsPanel()
            } label: {
                Label("Add Clips", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Add clips (⌘O)")
            Button {
                vm.beginExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(!vm.canExport)
            .help("Export the project (⌘E)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    private var fpsMenu: some View {
        Menu {
            ForEach(vm.fpsChoices, id: \.self) { d in
                Button(ClipPresentation.fpsText(d)) { vm.setConstant(d) }
            }
            Divider()
            Button("Highest present") { vm.setConstant(nil) }
        } label: {
            Text((vm.targetFrameDuration.map(ClipPresentation.fpsText) ?? "—") + (vm.followsHighest ? " (auto)" : ""))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Output frame rate")
    }

    @ViewBuilder
    private var notes: some View {
        if !vm.project.clips.isEmpty && (!vm.isConstant || vm.previewNote != nil) {
            VStack(alignment: .leading, spacing: 2) {
                if !vm.isConstant {
                    Text(ClipPresentation.mixedLabel).foregroundStyle(.orange)
                }
                if let note = vm.previewNote {
                    Text(note).foregroundStyle(.yellow)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.10))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if vm.project.clips.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                playerArea
                Divider().background(Color.black)
                ClipStripView(vm: vm)
                Divider().background(Color.black)
                TimelineView(vm: vm)
                statusBar
            }
        }
    }

    private var playerArea: some View {
        ZStack {
            Color.black
            if let player = vm.player {
                PlayerView(player: player)
            } else {
                Text(vm.selectedClip?.media == nil ? "This file is missing" : "No preview")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            markButtons
            Text(timestamp(vm.mode == .clip ? vm.clipTime : vm.projectTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("/")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(timestamp(vm.mode == .clip ? vm.clipDuration : vm.plan.totalDuration.cmTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(vm.mode == .clip ? "clip" : "project")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if vm.selectedVisuals.isScanning {
                ProgressView().controlSize(.small)
                Text("scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.selectedVisuals.keyframes.count > 0 {
                Text("\(vm.selectedVisuals.keyframes.count) keyframes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.08))
    }

    private var markButtons: some View {
        HStack(spacing: 6) {
            markButton("I", help: "Mark in-point at the playhead (I)") { vm.markIn() }
            markButton("O", help: "Mark out-point and commit the segment (O)") { vm.markOut() }
                .disabled(vm.inPoint == nil)
        }
    }

    private func markButton(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 1))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { vm.zoomOut() } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom out (−)")

            Text(String(format: "%.1f×", vm.zoom))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36)

            Button { vm.zoomIn() } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom in (+)")

            Button { vm.resetZoom() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10)).frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Reset zoom (0)")
            .disabled(vm.zoom <= 1.001)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop clips here")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("mp4, m4v or mov files — or a .slate project")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Add Clips…") { vm.addClipsPanel() }
                    .buttonStyle(.borderedProminent)
                Button("Open Project…") { vm.openPanel() }
            }
            .padding(.top, 8)
            if vm.isLoadingFiles { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Keys

    /// Backstop for keys SwiftUI `.onKeyPress` loses after clicks in NSView-backed children:
    /// Backspace/Fn+Delete delete the selected segment, Tab toggles Clip / Project.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = event.window?.firstResponder, responder is NSTextView { return event }
            if vm.isExporting { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 51 = Backspace, 117 = Fn+Delete, 48 = Tab.
            if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty {
                if vm.selectedSegmentID != nil {
                    vm.deleteSelectedSegment()
                    return nil
                }
            }
            if event.keyCode == 48 && mods.isEmpty && !vm.project.clips.isEmpty {
                vm.toggleMode()
                return nil
            }
            return event
        }
    }

    private func timestamp(_ t: CMTime) -> String {
        guard t.isValid, !t.isIndefinite else { return "—" }
        let s = t.seconds
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = s.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, sec) }
        return String(format: "%d:%05.2f", m, sec)
    }
}
```

- [ ] **Step 3: Rewrite `SlateApp.swift`**

```swift
import SwiftUI
import AppKit

/// One model for the one window; the app delegate and the menu commands use it too.
@MainActor let sharedViewModel = ProjectViewModel()

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder "Open With", Dock drop, double-click on a `.slate` file.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await sharedViewModel.open(urls: urls) }
    }

    /// Write the latest state before the process ends (untitled: autosave store; titled: the file).
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { sharedViewModel.autosaveNowSync() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SlateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("Slate", id: "main") {
            EditorView(vm: sharedViewModel)
                .frame(minWidth: 900, minHeight: 640)
        }
        .commands {
            AppCommands(vm: sharedViewModel)
        }
    }
}

struct AppCommands: Commands {
    let vm: ProjectViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { vm.newProject() }
                .keyboardShortcut("n")
            Button("Open…") { vm.openPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Save") { vm.save() }
                .keyboardShortcut("s")
            Button("Save As…") { vm.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export…") { vm.beginExport() }
                .keyboardShortcut("e")
                .disabled(!vm.canExport)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { vm.undo() }
                .keyboardShortcut("z")
            Button("Redo") { vm.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Clip") {
            Button("Previous Clip") { vm.selectPreviousClip() }
            Button("Next Clip") { vm.selectNextClip() }
            Divider()
            Button("Duplicate Clip") { vm.duplicateSelectedClip() }
                .keyboardShortcut("d")
            Button("Remove Clip") { vm.removeSelectedClip() }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Toggle Clip / Project Player") { vm.toggleMode() }
        }
    }
}
```

The plain keys `[`, `]` and Tab are handled in `EditorView`; the menu items for previous/next clip have no shortcut on purpose.

- [ ] **Step 4: Register the `.slate` document type in `scripts/Info.plist`**

Read the file, then: (a) inside the `CFBundleDocumentTypes` array add a second `<dict>` after the existing MPEG-4 one:

```xml
        <dict>
            <key>CFBundleTypeName</key>
            <string>Slate Project</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>co.aceguardian.slate.project</string>
            </array>
        </dict>
```

(b) before the final `</dict>` of the plist add:

```xml
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>co.aceguardian.slate.project</string>
            <key>UTTypeDescription</key>
            <string>Slate Project</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>slate</string>
                </array>
            </dict>
        </dict>
    </array>
```

Run `plutil -lint scripts/Info.plist`; expected `scripts/Info.plist: OK`.

- [ ] **Step 5: Delete the old single-clip code**

```bash
git rm Sources/Slate/ViewModels/EditorViewModel.swift Sources/Slate/Services/Exporter.swift Sources/Slate/Views/ExportSheet.swift
```

- [ ] **Step 6: Build, check, bundle**

Run: `swift build 2>&1 | tail -30` (sandbox disabled) → expected `Build complete!`. Fix compile errors with the smallest change that keeps the behaviour; likely spots: `Window` scene vs `WindowGroup` availability (macOS 13+ is fine), `@MainActor let` global in `SlateApp.swift`, `.commands { AppCommands(...) }` needing `@CommandsBuilder`, `Menu` label concatenation, `Picker` tag types, `.alert(... presenting:)` closure signatures.
Run: `swift run SlateChecks --strict 2>&1 | tail -3` → expected `154 passed, 0 failed, 0 skipped`.
Run: `scripts/build-app.sh debug 2>&1 | tail -5` → expected `✓ built …/build/Slate.app`.
Run: `codesign -v build/Slate.app && echo signed` → expected `signed`.
Run: `grep -rn "EditorViewModel\|Exporter()\|ExportSheet(" Sources/Slate | grep -v ProjectExportSheet` → expected no output.

- [ ] **Step 7: Commit**

```bash
git add -A Sources scripts/Info.plist
git commit -m "feat(app): multi-clip editor — timeline on the selected clip, clip strip, Project player, export sheet, .slate"
```

---

### Task 8: Verification hand-over — smoke-test list, docs, branch finish

**Files:**
- Create: `docs/superpowers/handoffs/2026-09-30-plan2b-smoke-test.md`
- Modify (disk only, gitignored): `MASTER_PLAN.md`

The GUI cannot be driven from the sandbox, so this task ends with a written manual test for the user and honest status.

- [ ] **Step 1: Full verification**

Run: `swift run SlateChecks --strict 2>&1 | tail -3` → `154 passed, 0 failed, 0 skipped`.
Run: `swift build 2>&1 | tail -2` → `Build complete!`.
Run: `scripts/build-app.sh debug 2>&1 | tail -3` → `✓ built …/build/Slate.app`.

- [ ] **Step 2: Write the smoke test**

Create `docs/superpowers/handoffs/2026-09-30-plan2b-smoke-test.md` with this content (fixtures are in `build/fixtures`; run `scripts/make-test-clips.sh` first if they are missing; start the app with `open build/Slate.app` in the user's own terminal):

```markdown
# Slate multi-clip — manual smoke test (about 15 minutes)

Tick each line. Write the first failing step and what you saw.

1. Launch: `open build/Slate.app`. The window shows "Drop clips here", Add Clips…, Open Project….
2. Drag `build/fixtures/c24.mp4` and `build/fixtures/c48.mp4` onto the window.
   - Two cards appear, numbered 1 and 2, with a poster, "5.0 / 5.0 s", the fps badge, no speaker icon.
   - Toolbar shows Constant, "48 fps (auto)". Card 2 (48 fps) is grey, card 1 (24 fps) has a yellow badge; its tooltip says it is re-encoded to 48 fps.
   - The timeline of the selected clip shows a light dashed segment labelled "whole clip".
3. Select card 1. Press Space (plays), Space (stops). Press `I` at about 1 s, `O` at about 2 s.
   - The "whole clip" segment is replaced by one yellow segment; the card says about "1.0 / 5.0 s".
4. Drag the right edge of the yellow segment. Release. Press ⌘Z once: the whole drag is undone in one step. ⇧⌘Z redoes it.
5. Press `]` then `[`: the selection moves between cards.
6. Right-click card 1: Duplicate, Remove, Show in Finder, Locate file…. Choose Duplicate: a third card appears after card 1 and is selected. ⌘Z removes it.
7. Drag card 2 to the left of card 1: an accent line shows where it goes; after release the numbers swap.
8. Press Tab: the toolbar switches to "Project"; the player plays the assembled result. While it plays the selection follows the clip under the playhead. Press `I` during playback: it switches back to Clip mode, and the in-point sits on the frame you saw.
9. Toolbar: click Mixed. An orange line shows "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant." No badge is yellow. Click Constant again.
10. ⌘E (or Export). The sheet lists each clip and what happens to it. Click Export…, choose a file. It shows "Re-encoding 1 of 2", "Re-encoding 2 of 2", "Assembling", "Validating", then "Export complete". Reveal in Finder. Open the file in QuickTime: it plays. Run `scripts/phase0-ffprobe.sh <the file>` if you want the fps and pts report.
11. ⌘S: choose a name, e.g. `test.slate`. The window title has no "— Edited". Make a change: the title shows "— Edited"; wait 3 s: the title clears (autosave wrote the file).
12. Quit (⌘Q). Launch again and double-click `test.slate` (or ⌘O and choose it): the clips, segments and Constant 48 fps come back. The cards show posters again.
13. Move the folder that holds a clip (or rename a clip), reopen the project: that card is red with "File is missing". Right-click → Locate file… and pick the file: the card recovers.
14. ⌘N (say Don't Save if asked): an empty project. Drop `c24.mp4` on the window, wait 3 s, then force-quit the app (Activity Monitor). Launch again: a dialog offers "Restore your unsaved project?". Restore: the clip is back and the title shows "— Edited".
15. Drop a text file (any `.txt`) on the window together with `c48.mp4`: `c48.mp4` is added; an error names the text file and says what Slate opens. The rest of the project is unchanged.
16. Add `build/fixtures/c24_trunc_a.mp4` (audio 0.5 s shorter than its video) to a project that also has `c24_a.mp4`. Tab to Project: a yellow note says the preview is silent. Export: the sheet says which clip's audio ends before its video and nothing is written.
17. Delete every segment of a clip (select the segment, Backspace): the card shows "0.0 / 5.0 s" and the plan row says "Skipped". Remove all clips: the window returns to "Drop clips here" and Export is disabled.
```

- [ ] **Step 3: Update `MASTER_PLAN.md` (on disk)**

- `Done`: add `Plan 2B implemented on branch feat/multi-clip-2b` with the check count, the list of new files and "manual smoke test pending: docs/superpowers/handoffs/2026-09-30-plan2b-smoke-test.md".
- `File Map`: add `ProjectEditor`, `ClipPresentation`, `ProjectDocument` to SlateCore; replace the old `Sources/Slate/...` entries (planned/scaffold text) with the real ones: `SlateApp.swift`, `ViewModels/ProjectViewModel.swift`, `Views/{EditorView,TimelineView,ClipStripView,ClipCardView,ClipStripMouseCapture,ProjectExportSheet,DroppedFiles,PlayerView,TimelineMouseCapture}.swift`, `Services/{KeyframeScanner,ThumbnailGenerator}.swift`.
- `In Progress`: "Plan 2B needs the user's manual smoke test".
- `Next`: item 0 = run the smoke test and report failures; then the older manual-validation items still apply. Remove nothing under Done / Architecture Decisions.
- `Architecture Decisions`: add "UI logic that can be tested lives in SlateCore (`ProjectEditor`, `ClipPresentation`, `ProjectDocument`); the app's `ProjectViewModel` only holds players, panels and the export task. Reason: no XCTest or SwiftUI previews here."

- [ ] **Step 4: Commit and finish**

```bash
git add docs/superpowers/handoffs/2026-09-30-plan2b-smoke-test.md
git commit -m "docs: Plan 2B smoke-test list"
```

Then use superpowers:finishing-a-development-branch. Do not merge or push: report that the app builds and the checks pass but that the GUI has not been run.

---

## Self-review notes

**Spec coverage.** Section 1 "Project file": Tasks 1 (auto segment rules, project-wide undo), 3 (save / autosave / restore / dirty), 7 (Info.plist type). Section 2 "UI": toolbar, clip strip (cards, badges, reorder, Finder drops, context menu, `[+]`), timeline on the selected clip (Task 7), Clip/Project player with `ProjectTimeMap` (Task 4), new hotkeys (`[` `]` Tab in `EditorView`; Cmd+Backspace, Cmd+D, Cmd+S, Cmd+Shift+S, Cmd+O, Cmd+E, Cmd+N in `AppCommands`), empty state (Task 7). Section 3 "Progress and result": export sheet with plan, stages Re-encoding k of n → Assembling → Validating, cancel, refused report, default file name (Tasks 2, 4, 6). Plan 2 decisions: Mixed label (Tasks 2, 7), Selective hidden (nothing in the UI mentions it), new-project default and sticky target (Task 1), user rulings on Cmd+O and Cmd+E (Tasks 4, 7).
**Deferred from the 2A hand-off, handled:** preview tolerant of short audio (Task 4 `rebuildProjectPlayerIfNeeded`), card message for unreadable files (`ClipProbe` failure → not added, named in the error), weak capture in the `Autosaver` closures and `flush` before discard (Task 4: `autosaveNowSync` cancels the timer then writes; `newProject` discards after `confirmDiscardChanges`), `ProjectFile.init` never sees invalid times because segments come only from `ProjectEditor` (clamped numeric times), audio-format rows (Task 2 `blockText`).
**Not in this plan (known gaps, by design):** duplicate clip ids on decode are not rejected (the planner blocks them; a hand-edited `.slate` can show odd list behaviour), the GUI is unverified until the user runs the smoke test, the window-close-with-unsaved-changes prompt (autosave covers it), NLE compatibility (Resolve) stays UNVERIFIED.
**Type consistency.** `ProjectEditor` API names (Task 1) are exactly those used in `ProjectViewModel` (Task 4); `ClipPresentation.card/rows/blockerTexts/summary/modeText/defaultOutputName/mixedLabel` (Task 2) are used verbatim in Tasks 5-7; `ProjectDocument` (Task 3) API is used in Task 4; `ProjectViewModel` members used by the views (Tasks 5-7) all appear in the Task 4 interface list.

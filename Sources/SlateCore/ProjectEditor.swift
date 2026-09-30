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
        public var targetFollowsHighest: Bool
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

    private var snapshot: Snapshot { Snapshot(clips: project.clips, fpsMode: project.fpsMode,
                                          targetFollowsHighest: targetFollowsHighest) }

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
        let chosen = d ?? FrameRateChoice.highest(for: project.clips) ?? Rational(1, 24)
        recordUndo()   // before the flag changes, so undo restores the old policy too
        targetFollowsHighest = (d == nil)
        project.fpsMode = .constant(frameDuration: chosen)
        changed()
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
        targetFollowsHighest = s.targetFollowsHighest
        inPoint = nil
        changed()
    }
}

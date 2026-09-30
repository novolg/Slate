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
    @ObservationIgnored private var restoreSettled = false
    @ObservationIgnored private var pendingProjectMode = false
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var exportToken: UUID?

    private let zoomMin = 1.0
    private let zoomMax = 64.0

    init() {
        autosaver = Autosaver(
            delay: .seconds(2),
            write: { [weak self] in try await self?.autosaveNow() },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in self?.errorMessage = "Autosave failed: \(error.localizedDescription)" }
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

    /// Timeline selection writes go through here: leave Project mode first, then select.
    func selectSegment(_ id: UUID?) {
        ensureClipMode()
        editor.selectedSegmentID = id
    }

    /// Source time of the playhead as the timeline shows it. In Project mode this is the mapped
    /// position inside the clip under the project playhead.
    var timelinePlayhead: CMTime {
        switch mode {
        case .clip:
            return clipTime
        case .project:
            guard projectTime.isNumeric, let loc = timeMap.locate(quantized(projectTime, timescale: plan.outputTimescale)),
                  loc.clipID == editor.selectedClipID else { return .zero }
            return cmTime(loc.sourceTime, timescale: sourceTimescale(of: loc.clipID))
        }
    }

    // MARK: Bounded time conversions

    /// Player times can carry any timescale; snap them to a fixed one before they meet grid rationals,
    /// so denominators stay bounded.
    private func quantized(_ t: CMTime, timescale: Int32) -> Rational {
        Rational(CMTimeConvertScale(t, timescale: timescale, method: .roundHalfAwayFromZero))
    }

    /// Never use `Rational.cmTime` on a derived value: its denominator can exceed Int32.
    private func cmTime(_ r: Rational, timescale: Int32) -> CMTime {
        CMTime(value: (r * Rational(Int64(timescale))).rounded(), timescale: timescale)
    }

    private func sourceTimescale(of clipID: UUID?) -> Int32 {
        project.clips.first { $0.id == clipID }?.media?.frames.timescale ?? 600
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
            if mode == .project {
                // Safety net: the plan changed under the Project player; go back to Clip mode unmapped.
                mode = .clip
                projectPlayer?.pause()
            }
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
        var failures: [String] = urls
            .filter { !Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { "\($0.lastPathComponent): not a video file Slate can open (mp4, m4v, mov)" }
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
        autosaver?.cancel()
        let wasUntitled = document.isUntitled
        do {
            let loaded = try await ProjectFile.load(from: url)
            replaceProject(loaded, url: url, followsHighest: false, discardUntitledAutosave: wasUntitled && restoreSettled)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func newProject() {
        guard confirmDiscardChanges() else { return }
        autosaver?.cancel()
        if restoreSettled { document.discardUntitledAutosave() }
        replaceProject(Project(), url: nil, followsHighest: true, discardUntitledAutosave: false)
    }

    private func replaceProject(_ p: Project, url: URL?, followsHighest: Bool, discardUntitledAutosave: Bool) {
        autosaver?.cancel()
        if discardUntitledAutosave { document.discardUntitledAutosave() }
        pendingProjectMode = false
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
        guard !didOfferRestore else { return }
        didOfferRestore = true
        defer {
            restoreSettled = true
            if !project.clips.isEmpty { autosaver?.noteChange() }
        }
        guard let restored = await document.restorableProject() else { return }
        // The user may have added files while the earlier project was probed.
        let hasClips = !project.clips.isEmpty
        let alert = NSAlert()
        alert.messageText = "Restore your unsaved project?"
        alert.informativeText = "Slate found a project that was autosaved in an earlier session."
            + (hasClips ? " Restoring replaces the project that is open now." : "")
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            if hasClips { guard confirmDiscardChanges() else { return } }
            replaceProject(restored, url: nil, followsHighest: false, discardUntitledAutosave: false)
            document.restoredUntitled()
            documentVersion += 1
            autosaver?.noteChange()
        } else {
            document.discardUntitledAutosave()
        }
    }

    private func autosaveNow() throws {
        // Until the launch restore offer is settled, an untitled autosave would overwrite the earlier session's.
        if document.isUntitled && !restoreSettled { return }
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
            if let start = timeMap.firstOutputStart(of: id) { seekProject(cmTime(start, timescale: plan.outputTimescale)) }
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

    /// If the clip player is running, stop it on the frame it shows and refresh `clipTime` from it.
    private func freezeClipTime() {
        guard let p = clipPlayer, p.rate != 0 else { return }
        p.pause()
        let now = p.currentTime()
        if now.isNumeric {
            clipTime = clampClip(CMTimeConvertScale(now, timescale: sourceTimescale(of: editor.selectedClipID),
                                                    method: .roundHalfAwayFromZero))
        }
    }

    func markIn() {
        ensureClipMode()
        freezeClipTime()
        edit { $0.setInPoint(clipTime) }
    }

    func markOut() {
        ensureClipMode()
        freezeClipTime()
        edit { _ = $0.commitOut(at: clipTime) }
    }

    func deleteSelectedSegment() {
        ensureClipMode()
        edit { _ = $0.deleteSelectedSegment() }
    }

    /// Esc: drop the pending in-point and the segment selection.
    func clearSelection() {
        ensureClipMode()
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

    func dragEdge(id: UUID, edge: SlateCore.SegmentEdge, to time: CMTime) {
        ensureClipMode()
        edit { $0.dragEdge(id: id, edge: edge, to: time) }
    }

    func endSegmentDrag() {
        ensureClipMode()
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

    func setMixed() {
        ensureClipMode()
        edit { $0.useMixed() }
    }

    func setConstant(_ d: Rational?) {
        ensureClipMode()
        edit { $0.useConstant(d) }
    }

    // MARK: Players

    /// Make sure the selected clip's own player is loaded (source-file playback for trimming).
    private func syncClipPlayer() {
        guard clipLoadedID != editor.selectedClipID || clipLoadedURL != editor.selectedClip?.url else { return }
        clipPlayer?.pause()
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
            if mode == .project, let loc = timeMap.locate(quantized(t, timescale: plan.outputTimescale)), loc.clipID != editor.selectedClipID {
                editor.selectClip(loc.clipID)
                ensureVisuals(loc.clipID)
            }
        } else {
            clipTime = t
        }
    }

    private func stopPlayers() {
        projectGeneration += 1
        projectStale = true
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
        if new == .clip { pendingProjectMode = false }
        guard new != mode else { return }
        switch new {
        case .clip:
            ensureClipMode()
        case .project:
            guard !pendingProjectMode else { return }
            pendingProjectMode = true
            clipPlayer?.pause()
            Task { await enterProjectMode() }
        }
    }

    func toggleMode() { setMode(mode == .clip ? .project : .clip) }

    private enum PreviewBuild { case ready, stale, failed }

    private func enterProjectMode() async {
        defer { pendingProjectMode = false }
        var result = PreviewBuild.stale
        for _ in 0..<2 {
            guard pendingProjectMode else { return }
            result = await rebuildProjectPlayerIfNeeded()
            if result != .stale { break }
        }
        guard pendingProjectMode else { return }
        if result == .stale {
            previewNote = "Preview unavailable: the project changed while the preview was being built."
            return
        }
        guard result == .ready, projectPlayer != nil else { return }
        var start = Rational.zero
        if let id = editor.selectedClipID {
            let ts = sourceTimescale(of: id)
            if clipTime.isNumeric, let t = timeMap.projectTime(clipID: id, sourceTime: quantized(clipTime, timescale: ts)) {
                start = t
            } else if let first = timeMap.firstOutputStart(of: id) {
                start = first
            }
        }
        mode = .project
        seekProject(cmTime(start, timescale: plan.outputTimescale))
    }

    /// Leave Project mode: pause, select the clip under the project playhead, load it, and seek it to
    /// the mapped source time — so an edit command lands on the frame the user saw.
    func ensureClipMode() {
        guard mode == .project else { return }
        projectPlayer?.pause()
        // The periodic observer can be 100 ms stale; ask the paused player for the exact frame.
        if let now = projectPlayer?.currentTime(), now.isNumeric { projectTime = now }
        let location = projectTime.isNumeric
            ? timeMap.locate(quantized(projectTime, timescale: plan.outputTimescale)) : nil
        mode = .clip
        if let location { editor.selectClip(location.clipID) }
        syncClipPlayer()
        if let location { seekClip(cmTime(location.sourceTime, timescale: sourceTimescale(of: location.clipID))) }
    }

    /// The Project player plays the same grid segments as the export (each at its output start).
    /// A clip whose audio is more than one AAC packet short makes the composition throw; the preview
    /// then falls back to video only and says so.
    private func rebuildProjectPlayerIfNeeded() async -> PreviewBuild {
        guard projectStale || projectPlayer == nil else { return .ready }
        guard !isBuildingPreview else { return .failed }
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        previewNote = nil
        let plan = self.plan
        let project = self.project
        let revision = editor.revision
        let generation = projectGeneration
        func isCurrent() -> Bool { editor.revision == revision && projectGeneration == generation }
        guard plan.canExport else {
            previewNote = "Preview unavailable: " + ClipPresentation.blockerTexts(plan, project: project).joined(separator: " ")
            dropProjectPlayer()
            return .failed
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
            guard isCurrent() else { return .stale }
            dropProjectPlayer()
            let p = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            p.actionAtItemEnd = .pause
            projectPlayer = p
            projectObserver = (p, makeObserver(for: p, isProject: true))
            projectStale = false
            return .ready
        } catch {
            guard isCurrent() else { return .stale }
            previewNote = "Preview unavailable: \(error.localizedDescription)"
            dropProjectPlayer()
            return .failed
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
        let token = UUID()
        exportToken = token
        exportUI = .running(nil)
        let snapshot = project
        exportTask = Task { @MainActor in
            @MainActor func finish(_ ui: ExportUI) {
                guard self.exportToken == token else { return }
                self.exportUI = ui
            }
            do {
                _ = try await exporter.export(
                    project: snapshot, outputURL: outURL, tempDirectory: FileManager.default.temporaryDirectory,
                    progress: { stage in
                        Task { @MainActor in
                            guard self.exportToken == token else { return }
                            if case .running = self.exportUI { self.exportUI = .running(stage) }
                        }
                    })
                finish(.done(outURL))
            } catch ProjectExportError.validationFailed(let report) {
                finish(.refused(report.issues))
            } catch ProjectExportError.cancelled {
                finish(.failed("Cancelled."))
            } catch ReencodeError.clipAudioTruncated(let clipID, _) {
                finish(.failed(self.audioShortMessage(clipID)))
            } catch CompositionError.audioTruncated(let clipID, _) {
                finish(.failed(self.audioShortMessage(clipID)))
            } catch {
                finish(.failed(error.localizedDescription))
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
        if case .running = exportUI { exporter?.cancel() }
        exportToken = nil
        exportUI = .idle
        exporter = nil
        exportTask = nil
    }
}

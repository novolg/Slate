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

    func dragEdge(id: UUID, edge: SlateCore.SegmentEdge, to time: CMTime) {
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

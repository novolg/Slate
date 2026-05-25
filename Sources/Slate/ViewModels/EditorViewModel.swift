import Foundation
import AVFoundation
import Observation
import AppKit
import UniformTypeIdentifiers

@Observable
final class EditorViewModel {
    private(set) var assetURL: URL?
    private(set) var player: AVPlayer?
    private(set) var duration: CMTime = .zero
    private(set) var nominalFrameRate: Float = 30.0
    private(set) var keyframes: KeyframeIndex = KeyframeIndex(times: [])
    private(set) var isScanningKeyframes: Bool = false
    private(set) var thumbnails: [Thumbnail] = []
    private(set) var currentTime: CMTime = .zero
    private(set) var errorMessage: String?

    // Segment editing
    private(set) var segments: [Segment] = []
    private(set) var inPoint: CMTime?
    var selectedSegmentID: UUID?

    // Zoom
    private(set) var zoom: Double = 1.0
    private let zoomMin: Double = 1.0
    private let zoomMax: Double = 64.0

    func setZoom(_ z: Double) {
        zoom = max(zoomMin, min(zoomMax, z))
    }

    func zoomIn()  { setZoom(zoom * 1.5) }
    func zoomOut() { setZoom(zoom / 1.5) }
    func resetZoom() { setZoom(1.0) }

    // Export
    enum ExportState: Equatable {
        case idle
        case inProgress(Float)
        case done(URL)
        case failed(String)
    }
    private(set) var exportState: ExportState = .idle
    var isExporting: Bool {
        if case .idle = exportState { return false }
        return true
    }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var undoStack: [[Segment]] = []
    @ObservationIgnored private var redoStack: [[Segment]] = []
    @ObservationIgnored private var exporter: Exporter?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    var isPlaying: Bool {
        guard let player else { return false }
        return player.timeControlStatus == .playing && player.rate != 0
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    @MainActor
    func load(url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let (duration, tracks) = try await asset.load(.duration, .tracks)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                errorMessage = "No video track in \(url.lastPathComponent)"
                return
            }
            let rate = try await videoTrack.load(.nominalFrameRate)

            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            p.actionAtItemEnd = .pause

            // Tear down any previous time observer.
            if let token = self.timeObserver, let prev = self.player {
                prev.removeTimeObserver(token)
            }
            self.timeObserver = nil

            self.assetURL = url
            self.duration = duration
            self.nominalFrameRate = rate > 0 ? rate : 30.0
            self.player = p
            self.keyframes = KeyframeIndex(times: [])
            self.thumbnails = []
            self.currentTime = .zero
            self.segments = []
            self.inPoint = nil
            self.selectedSegmentID = nil
            self.undoStack = []
            self.redoStack = []
            self.errorMessage = nil

            // Periodic playhead observer (10 Hz — adequate for UI; player frame still seeks at full rate).
            let interval = CMTime(value: 1, timescale: 10)
            self.timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
                self?.currentTime = t
            }

            // Generate thumbnail strip in the background.
            Task { [weak self] in
                let thumbs = (try? await ThumbnailGenerator.generate(asset: asset, count: 80, pointHeight: 56)) ?? []
                await MainActor.run {
                    self?.thumbnails = thumbs
                }
            }

            // Scan keyframes in the background; UI updates when complete.
            self.isScanningKeyframes = true
            Task { [weak self] in
                do {
                    let index = try await KeyframeScanner.scan(asset: asset)
                    await MainActor.run {
                        guard let self else { return }
                        self.keyframes = index
                        self.isScanningKeyframes = false
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.isScanningKeyframes = false
                        self.errorMessage = "Keyframe scan failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            errorMessage = "Failed to open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        guard let player else { return }
        if player.rate == 0 {
            player.rate = 1.0
        } else {
            player.rate = 0
        }
    }

    /// J — reverse / accelerate reverse. Rates: -1, -2, -4, -8.
    func nudgeReverse() {
        guard let player else { return }
        if player.rate >= 0 {
            player.rate = -1.0
        } else {
            player.rate = max(player.rate * 2, -8.0)
        }
    }

    /// K — pause.
    func pause() {
        player?.rate = 0
    }

    /// L — forward / accelerate. Rates: 1, 2, 4, 8.
    func nudgeForward() {
        guard let player else { return }
        if player.rate <= 0 {
            player.rate = 1.0
        } else {
            player.rate = min(player.rate * 2, 8.0)
        }
    }

    func stepFrame(by count: Int) {
        guard let item = player?.currentItem else { return }
        player?.rate = 0
        item.step(byCount: count)
    }

    func seek(to time: CMTime) {
        guard let player else { return }
        let clamped = clamp(time)
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func seek(toFraction fraction: Double) {
        guard duration.isValid, duration.seconds > 0 else { return }
        let f = max(0.0, min(1.0, fraction))
        let t = CMTime(seconds: f * duration.seconds, preferredTimescale: duration.timescale)
        seek(to: t)
    }

    private func clamp(_ t: CMTime) -> CMTime {
        if !t.isValid || t.isIndefinite { return .zero }
        if CMTimeCompare(t, .zero) < 0 { return .zero }
        if duration.isValid && CMTimeCompare(t, duration) > 0 { return duration }
        return t
    }

    // MARK: Segment editing

    enum Snap { case none, nearest, floor, ceil }

    func snap(_ t: CMTime, mode: Snap) -> CMTime {
        guard !keyframes.isEmpty, mode != .none else { return t }
        let snapped: CMTime?
        switch mode {
        case .none: snapped = t
        case .nearest: snapped = keyframes.nearest(to: t)
        case .floor: snapped = keyframes.floor(t) ?? keyframes.first
        case .ceil: snapped = keyframes.ceil(t) ?? keyframes.last
        }
        return snapped ?? t
    }

    /// I — set the in-point at the current playhead (no keyframe snap).
    func setInPointAtPlayhead() {
        inPoint = currentTime
    }

    /// O — commit a segment from the in-point to the current playhead (no keyframe snap).
    func commitOutPointAtPlayhead() {
        guard let inP = inPoint else { return }
        let outP = currentTime
        guard CMTimeCompare(outP, inP) > 0 else { return }
        let range = CMTimeRangeFromTimeToTime(start: inP, end: outP)
        pushUndo()
        segments = SegmentOps.insert(range, into: segments)
        inPoint = nil
    }

    func deleteSelected() {
        guard let id = selectedSegmentID else { return }
        pushUndo()
        segments = SegmentOps.remove(id: id, from: segments)
        selectedSegmentID = nil
    }

    func clearInPoint() {
        inPoint = nil
    }

    /// Update segment edge during drag. `edge` is .start or .end. Snap mode controls keyframe alignment.
    func updateSegmentEdge(id: UUID, edge: SegmentEdge, to time: CMTime, snap snapMode: Snap, commit: Bool) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        let snapped = snap(time, mode: snapMode)
        let oldRange = segments[idx].range
        let newRange: CMTimeRange
        switch edge {
        case .start:
            let s = clamp(snapped)
            guard CMTimeCompare(s, oldRange.end) < 0 else { return }
            newRange = CMTimeRangeFromTimeToTime(start: s, end: oldRange.end)
        case .end:
            let e = clamp(snapped)
            guard CMTimeCompare(e, oldRange.start) > 0 else { return }
            newRange = CMTimeRangeFromTimeToTime(start: oldRange.start, end: e)
        }
        if commit { pushUndo() }
        segments = SegmentOps.updateRange(of: id, to: newRange, in: segments)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(segments)
        segments = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(segments)
        segments = next
    }

    private func pushUndo() {
        undoStack.append(segments)
        redoStack.removeAll()
    }

    // MARK: Export

    @MainActor
    func startExportFlow() {
        guard let assetURL else { return }
        guard !segments.isEmpty else {
            errorMessage = "Mark at least one keep-segment with I/O before exporting."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let base = assetURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) — trimmed.mp4"
        panel.directoryURL = assetURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        let asset = AVURLAsset(url: assetURL)
        let segs = segments
        let exporter = Exporter()
        self.exporter = exporter
        self.exportState = .inProgress(0)

        exportTask = Task { @MainActor in
            do {
                try await exporter.export(
                    asset: asset,
                    segments: segs,
                    outputURL: outURL,
                    progress: { p in
                        Task { @MainActor in
                            if case .inProgress = self.exportState {
                                self.exportState = .inProgress(p)
                            }
                        }
                    }
                )
                self.exportState = .done(outURL)
            } catch ExporterError.cancelled {
                self.exportState = .failed("Cancelled.")
            } catch {
                self.exportState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExport() {
        Task { await exporter?.cancel() }
    }

    func dismissExport() {
        exportState = .idle
        exporter = nil
        exportTask = nil
    }
}

enum SegmentEdge { case start, end }

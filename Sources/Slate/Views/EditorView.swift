import SwiftUI
import AVFoundation
import AppKit
import CoreMedia

@MainActor
struct EditorView: View {
    @State private var vm = EditorViewModel()
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.black)
            content
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .onKeyPress(.space) {
            vm.togglePlayPause(); return .handled
        }
        .onKeyPress(.leftArrow) {
            vm.stepFrame(by: -1); return .handled
        }
        .onKeyPress(.rightArrow) {
            vm.stepFrame(by: 1); return .handled
        }
        .onKeyPress(keys: ["j", "k", "l", "i", "o"]) { press in
            switch press.characters.lowercased() {
            case "j": vm.nudgeReverse()
            case "k": vm.pause()
            case "l": vm.nudgeForward()
            case "i": vm.setInPointAtPlayhead()
            case "o": vm.commitOutPointAtPlayhead()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.delete) {
            vm.deleteSelected(); return .handled
        }
        .onKeyPress(.escape) {
            vm.clearInPoint(); vm.selectedSegmentID = nil; return .handled
        }
        .onKeyPress(keys: ["=", "+", "-", "0"]) { press in
            switch press.characters {
            case "=", "+": vm.zoomIn()
            case "-":      vm.zoomOut()
            case "0":      vm.resetZoom()
            default:       return .ignored
            }
            return .handled
        }
        .onKeyPress(keys: ["z"]) { press in
            // Undo / redo via Cmd+Z / Shift+Cmd+Z. SwiftUI .onKeyPress doesn't expose modifiers directly,
            // so we read them from NSEvent.
            let mods = NSEvent.modifierFlags
            guard mods.contains(.command) else { return .ignored }
            if mods.contains(.shift) { vm.redo() } else { vm.undo() }
            return .handled
        }
        .alert("Error",
               isPresented: Binding(
                   get: { vm.errorMessage != nil },
                   set: { if !$0 { /* dismiss handled below */ } }
               ),
               presenting: vm.errorMessage) { _ in
            Button("OK") { /* alert auto-dismisses */ }
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: Binding(
            get: { vm.isExporting },
            set: { if !$0 { vm.dismissExport() } }
        )) {
            ExportSheet(vm: vm)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Slate")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("v1.0")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                vm.openFile()
            } label: {
                Label("Open Source Video", systemImage: "film")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open mp4 (⌘O)")
            Button {
                vm.startExportFlow()
            } label: {
                Label("Export Trimmed", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(vm.player == nil || vm.segments.isEmpty || vm.isExporting)
            .help("Export keep-segments without re-encoding (⌘E)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    @ViewBuilder
    private var content: some View {
        if let player = vm.player {
            VStack(spacing: 0) {
                PlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().background(Color.black)
                TimelineView(vm: vm)
                statusBar
            }
        } else {
            emptyState
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            markButtons
            Text(timestamp(vm.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("/")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(timestamp(vm.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if vm.isScanningKeyframes {
                ProgressView().controlSize(.small)
                Text("scanning keyframes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.keyframes.count > 0 {
                Text("\(vm.keyframes.count) keyframes")
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
            Button {
                vm.setInPointAtPlayhead()
            } label: {
                Text("I")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 22, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.secondary, lineWidth: 1)
                    )
            }
            .buttonStyle(.borderless)
            .help("Mark in-point at playhead (I)")

            Button {
                vm.commitOutPointAtPlayhead()
            } label: {
                Text("O")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 22, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.secondary, lineWidth: 1)
                    )
            }
            .buttonStyle(.borderless)
            .disabled(vm.inPoint == nil)
            .help("Mark out-point and commit segment (O)")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                vm.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom out (−)")

            Text(String(format: "%.1f×", vm.zoom))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 36)

            Button {
                vm.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom in (+)")

            Button {
                vm.resetZoom()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .regular))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Reset zoom (0)")
            .disabled(vm.zoom <= 1.001)
        }
    }

    /// Backstop for keyboard input — SwiftUI .onKeyPress can lose focus after clicks
    /// in NSView-backed children. NSEvent local monitor catches keys reliably.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Bail out if a text field has focus (so we never eat Backspace from a real input).
            if let resp = event.window?.firstResponder, resp is NSTextView { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // delete (51) = Backspace on Mac;  forwardDelete (117) = Fn+Delete.
            if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty {
                if vm.selectedSegmentID != nil && !vm.isExporting {
                    vm.deleteSelected()
                    return nil
                }
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
        if h > 0 {
            return String(format: "%d:%02d:%05.2f", h, m, sec)
        }
        return String(format: "%d:%05.2f", m, sec)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Slate")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open an mp4 to begin")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Open…") { vm.openFile() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

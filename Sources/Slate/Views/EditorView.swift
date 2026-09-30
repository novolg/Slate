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
        Binding(get: { vm.isConstant }, set: { $0 ? vm.resumeConstant() : vm.setMixed() })
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

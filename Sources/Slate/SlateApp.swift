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

@MainActor
struct AppCommands: Commands {
    let vm: ProjectViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { vm.newProject() }
                .keyboardShortcut("n")
                .disabled(vm.isExporting)
            Button("Open…") { vm.openPanel() }
                .keyboardShortcut("o")
                .disabled(vm.isExporting)
            Divider()
            Button("Save") { vm.save() }
                .keyboardShortcut("s")
                .disabled(vm.isExporting)
            Button("Save As…") { vm.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(vm.isExporting)
            Divider()
            Button("Export…") { vm.beginExport() }
                .keyboardShortcut("e")
                .disabled(!vm.canExport)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { vm.undo() }
                .keyboardShortcut("z")
                .disabled(vm.isExporting)
            Button("Redo") { vm.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(vm.isExporting)
        }
        CommandMenu("Clip") {
            Button("Previous Clip") { vm.selectPreviousClip() }
                .disabled(vm.isExporting)
            Button("Next Clip") { vm.selectNextClip() }
                .disabled(vm.isExporting)
            Divider()
            Button("Duplicate Clip") { vm.duplicateSelectedClip() }
                .keyboardShortcut("d")
                .disabled(vm.isExporting)
            Button("Remove Clip") { vm.removeSelectedClip() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(vm.isExporting)
            Divider()
            Button("Toggle Clip / Project Player") { vm.toggleMode() }
                .disabled(vm.isExporting)
        }
    }
}

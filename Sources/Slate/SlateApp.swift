import SwiftUI
import AppKit

@main
struct SlateApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Slate") {
            EditorView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

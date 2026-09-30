import SwiftUI
import AppKit

struct StripMenuItem {
    let title: String
    let isEnabled: Bool
    let action: @MainActor () -> Void
}

/// Transparent NSView over the strip. AppKit mouse handling for the same reason as the timeline:
/// SwiftUI gestures were unreliable. Also owns the right-click menu and the tooltip.
@MainActor
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

@MainActor
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

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let closure: @MainActor () -> Void

    init(title: String, closure: @escaping @MainActor () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { closure() }
}

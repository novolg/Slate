import SwiftUI
import AppKit

/// A transparent NSView overlay that captures mouse events for the timeline.
/// We use AppKit directly because SwiftUI gesture composition (DragGesture +
/// ScrollView + MagnificationGesture + per-handle gestures) is too unreliable
/// for sub-pixel edge dragging.
struct TimelineMouseCapture: NSViewRepresentable {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    func makeNSView(context: Context) -> _MouseCaptureNSView {
        let v = _MouseCaptureNSView()
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onMouseMoved = onMouseMoved
        v.onMouseExited = onMouseExited
        return v
    }

    func updateNSView(_ v: _MouseCaptureNSView, context: Context) {
        v.onMouseDown = onMouseDown
        v.onMouseDragged = onMouseDragged
        v.onMouseUp = onMouseUp
        v.onMouseMoved = onMouseMoved
        v.onMouseExited = onMouseExited
    }
}

final class _MouseCaptureNSView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Match SwiftUI's top-down coordinate convention.
    override var isFlipped: Bool { true }

    /// Don't steal keyboard focus from SwiftUI — that would break .onKeyPress.
    override var acceptsFirstResponder: Bool { false }

    /// Receive a click that activates the window — needed for clicks in newly-focused window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let opts: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        let t = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(point(event))
    }
    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(point(event))
    }
    override func mouseUp(with event: NSEvent) {
        onMouseUp?(point(event))
    }
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(point(event))
    }
    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

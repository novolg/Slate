import SwiftUI
import AVFoundation
import AppKit
import CoreMedia

struct TimelineView: View {
    let vm: EditorViewModel

    private let stripHeight: CGFloat = 56
    private let rulerHeight: CGFloat = 18
    private let handleVisibleWidth: CGFloat = 6
    private let handleHitRadius: CGFloat = 10  // ±10pt around the actual edge

    private var totalHeight: CGFloat { stripHeight + rulerHeight }

    private enum DragKind: Equatable {
        case none
        case seek
        case edge(UUID, SegmentEdge)
    }

    @State private var dragKind: DragKind = .none
    @State private var lastMagnification: Double = 1.0
    @State private var hoverNearEdge: Bool = false

    var body: some View {
        GeometryReader { geo in
            let baseWidth = geo.size.width
            let contentWidth = max(baseWidth * CGFloat(vm.zoom), baseWidth)
            let total = max(vm.duration.seconds, 0.0001)

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color(white: 0.10)
                        .frame(width: contentWidth, height: totalHeight)

                    thumbnailsLayer(width: contentWidth)
                        .frame(width: contentWidth, height: stripHeight)
                        .offset(y: rulerHeight)

                    keyframeTicks(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: rulerHeight)

                    segmentBodiesVisual(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: stripHeight)
                        .offset(y: rulerHeight)

                    edgeHandlesVisual(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    inPointMarker(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    playhead(width: contentWidth, total: total)
                        .frame(width: contentWidth, height: totalHeight)

                    // Topmost layer: NSView-based mouse capture. Owns ALL mouse handling
                    // for the timeline (drag classification, seek, edge resize, hover cursor).
                    TimelineMouseCapture(
                        onMouseDown: { p in handleMouseDown(p, contentWidth: contentWidth, total: total) },
                        onMouseDragged: { p in handleMouseDragged(p, contentWidth: contentWidth, total: total) },
                        onMouseUp: { p in handleMouseUp(p, contentWidth: contentWidth, total: total) },
                        onMouseMoved: { p in handleMouseMoved(p, contentWidth: contentWidth, total: total) },
                        onMouseExited: { handleMouseExited() }
                    )
                    .frame(width: contentWidth, height: totalHeight)
                }
                // Pinch zoom (trackpad) — magnify gesture is fine here, no conflict with mouse.
                .gesture(magnifyGesture)
            }
        }
        .frame(height: totalHeight)
        .background(Color(white: 0.06))
    }

    // MARK: Mouse handlers (replaces SwiftUI DragGesture)

    private func handleMouseDown(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let kind = classify(at: p, contentWidth: contentWidth, total: total)
        dragKind = kind
        switch kind {
        case .none:
            break
        case .seek:
            // Click on segment body → select; click in empty area → seek.
            if let s = hitSegment(atX: p.x, contentWidth: contentWidth, total: total) {
                vm.selectedSegmentID = s.id
            } else {
                vm.selectedSegmentID = nil
                vm.seek(to: time(forX: p.x, contentWidth: contentWidth, total: total))
            }
        case .edge(let id, _):
            vm.selectedSegmentID = id
        }
    }

    private func handleMouseDragged(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let t = time(forX: p.x, contentWidth: contentWidth, total: total)
        switch dragKind {
        case .none:
            break
        case .seek:
            // Only continue seeking if start was in empty area (we set selectedSegmentID
            // to nil in that case, so use that as the marker).
            if vm.selectedSegmentID == nil {
                vm.seek(to: t)
            }
        case .edge(let id, let edge):
            vm.updateSegmentEdge(id: id, edge: edge, to: t, snap: .none, commit: false)
        }
    }

    private func handleMouseUp(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        if case .edge(let id, let edge) = dragKind {
            let t = time(forX: p.x, contentWidth: contentWidth, total: total)
            vm.updateSegmentEdge(id: id, edge: edge, to: t, snap: .none, commit: true)
        }
        dragKind = .none
    }

    private func handleMouseMoved(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let near = isNearAnyEdge(x: p.x, contentWidth: contentWidth, total: total)
        if near != hoverNearEdge {
            hoverNearEdge = near
            if near { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
    }

    private func handleMouseExited() {
        if hoverNearEdge { NSCursor.arrow.set(); hoverNearEdge = false }
    }

    // MARK: Visual layers

    @ViewBuilder
    private func thumbnailsLayer(width: CGFloat) -> some View {
        let thumbs = vm.thumbnails
        if thumbs.isEmpty {
            Rectangle().fill(Color(white: 0.18))
        } else {
            Canvas { ctx, size in
                let cell = size.width / CGFloat(thumbs.count)
                for (i, thumb) in thumbs.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * cell, y: 0, width: cell + 0.5, height: size.height)
                    ctx.draw(Image(nsImage: thumb.image), in: rect)
                }
            }
        }
    }

    private func keyframeTicks(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            let tickColor = GraphicsContext.Shading.color(.white.opacity(0.55))
            for t in vm.keyframes.times {
                let x = CGFloat(t.seconds / total) * size.width
                let rect = CGRect(x: x, y: 4, width: 1, height: size.height - 6)
                ctx.fill(Path(rect), with: tickColor)
            }
        }
    }

    private func segmentBodiesVisual(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            for seg in vm.segments {
                let x = CGFloat(seg.start.seconds / total) * size.width
                let w = max(CGFloat(seg.duration.seconds / total) * size.width, 2)
                let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                let isSelected = vm.selectedSegmentID == seg.id
                ctx.fill(Path(rect), with: .color(.yellow.opacity(isSelected ? 0.32 : 0.20)))
                ctx.stroke(Path(rect), with: .color(.yellow.opacity(isSelected ? 1.0 : 0.7)),
                           lineWidth: isSelected ? 2 : 1)
            }
        }
    }

    private func edgeHandlesVisual(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            for seg in vm.segments {
                let leftX = CGFloat(seg.start.seconds / total) * size.width
                let rightX = CGFloat(seg.end.seconds / total) * size.width
                let isSelected = vm.selectedSegmentID == seg.id
                let color = GraphicsContext.Shading.color(.yellow.opacity(isSelected ? 1.0 : 0.85))
                let leftBar = CGRect(x: leftX - handleVisibleWidth / 2, y: rulerHeight,
                                     width: handleVisibleWidth, height: stripHeight)
                let rightBar = CGRect(x: rightX - handleVisibleWidth / 2, y: rulerHeight,
                                      width: handleVisibleWidth, height: stripHeight)
                ctx.fill(Path(leftBar), with: color)
                ctx.fill(Path(rightBar), with: color)
            }
        }
    }

    // MARK: Hit-classification helpers

    private func classify(at point: CGPoint, contentWidth: CGFloat, total: Double) -> DragKind {
        // Edge takes priority — search all segments for an edge within hit radius.
        var bestEdge: (UUID, SegmentEdge, CGFloat)? = nil
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            let dl = abs(point.x - leftX)
            let dr = abs(point.x - rightX)
            if dl <= handleHitRadius {
                if bestEdge == nil || dl < bestEdge!.2 {
                    bestEdge = (seg.id, .start, dl)
                }
            }
            if dr <= handleHitRadius {
                if bestEdge == nil || dr < bestEdge!.2 {
                    bestEdge = (seg.id, .end, dr)
                }
            }
        }
        if let e = bestEdge {
            return .edge(e.0, e.1)
        }
        return .seek
    }

    private func isNearAnyEdge(x: CGFloat, contentWidth: CGFloat, total: Double) -> Bool {
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            if abs(x - leftX) <= handleHitRadius { return true }
            if abs(x - rightX) <= handleHitRadius { return true }
        }
        return false
    }

    private func hitSegment(atX x: CGFloat, contentWidth: CGFloat, total: Double) -> Segment? {
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            if x >= leftX && x <= rightX { return seg }
        }
        return nil
    }

    private func time(forX x: CGFloat, contentWidth: CGFloat, total: Double) -> CMTime {
        let f = max(0, min(1, Double(x / max(contentWidth, 1))))
        return CMTime(seconds: f * total, preferredTimescale: vm.duration.timescale)
    }

    // MARK: Markers

    private func inPointMarker(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            if let inP = vm.inPoint {
                let x = CGFloat(inP.seconds / total) * size.width
                let rect = CGRect(x: x - 1, y: 0, width: 2, height: size.height)
                ctx.fill(Path(rect), with: .color(.green))
            }
        }
    }

    private func playhead(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            let x = CGFloat(vm.currentTime.seconds / total) * size.width
            let line = CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)
            ctx.fill(Path(line), with: .color(.white))
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: 8))
            tri.addLine(to: CGPoint(x: x - 5, y: 0))
            tri.addLine(to: CGPoint(x: x + 5, y: 0))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(.white))
        }
    }

    // MARK: Pinch zoom

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                vm.setZoom(vm.zoom * Double(scale) / lastMagnification)
                lastMagnification = Double(scale)
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }
}

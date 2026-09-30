import SwiftUI
import AVFoundation
import AppKit
import CoreMedia
import SlateCore

@MainActor
struct TimelineView: View {
    let vm: ProjectViewModel

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
    @State private var didBeginDrag = false
    @State private var dragStartX: CGFloat = 0
    @State private var edgeOffset: CGFloat = 0

    /// Ticks per second used for times created from mouse positions (the clip's own track timescale).
    private var sourceTimescale: Int32 { vm.selectedClip?.media?.frames.timescale ?? 600 }

    var body: some View {
        GeometryReader { geo in
            let baseWidth = geo.size.width
            let contentWidth = max(baseWidth * CGFloat(vm.zoom), baseWidth)
            let total = max(vm.clipDuration.seconds, 0.0001)

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

                    if vm.selectedClip?.media == nil {
                        Text("File is missing — right-click the card and choose “Locate file…”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.top, rulerHeight + 20)
                            .allowsHitTesting(false)
                    }

                    // Topmost layer: AppKit mouse capture owns ALL mouse handling for the timeline.
                    TimelineMouseCapture(
                        onMouseDown: { p in handleMouseDown(p, contentWidth: contentWidth, total: total) },
                        onMouseDragged: { p in handleMouseDragged(p, contentWidth: contentWidth, total: total) },
                        onMouseUp: { p in handleMouseUp(p, contentWidth: contentWidth, total: total) },
                        onMouseMoved: { p in handleMouseMoved(p, contentWidth: contentWidth, total: total) },
                        onMouseExited: { handleMouseExited() }
                    )
                    .frame(width: contentWidth, height: totalHeight)
                }
                .gesture(magnifyGesture)
            }
        }
        .frame(height: totalHeight)
        .background(Color(white: 0.06))
        .opacity(vm.mode == .project ? 0.55 : 1)
    }

    // MARK: Mouse handlers

    private func handleMouseDown(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        let kind = classify(at: p, contentWidth: contentWidth, total: total)
        dragKind = kind
        didBeginDrag = false
        dragStartX = p.x
        edgeOffset = 0
        switch kind {
        case .none:
            break
        case .seek:
            // A click on a segment body selects it and seeks; empty space clears the selection and seeks.
            let hit = hitSegment(atX: p.x, contentWidth: contentWidth, total: total)
            vm.selectSegment(hit?.id)
            vm.timelineSeek(to: time(forX: p.x, contentWidth: contentWidth, total: total))
        case .edge(let id, let edge):
            // Only select; the model is not touched until the pointer really moves.
            vm.selectSegment(id)
            if let seg = vm.segments.first(where: { $0.id == id }) {
                let edgeSeconds = (edge == .start ? seg.start : seg.end).seconds
                edgeOffset = CGFloat(edgeSeconds / total) * contentWidth - p.x
            }
        }
    }

    private func handleMouseDragged(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        switch dragKind {
        case .none:
            break
        case .seek:
            vm.timelineSeek(to: time(forX: p.x, contentWidth: contentWidth, total: total))
        case .edge(let id, let edge):
            if !didBeginDrag {
                guard abs(p.x - dragStartX) >= 3 else { return }
                didBeginDrag = true
                vm.beginSegmentDrag()
            }
            vm.dragEdge(id: id, edge: edge, to: time(forX: p.x + edgeOffset, contentWidth: contentWidth, total: total))
        }
    }

    private func handleMouseUp(_ p: CGPoint, contentWidth: CGFloat, total: Double) {
        if case .edge(let id, let edge) = dragKind, didBeginDrag {
            vm.dragEdge(id: id, edge: edge, to: time(forX: p.x + edgeOffset, contentWidth: contentWidth, total: total))
            vm.endSegmentDrag()
        }
        dragKind = .none
        didBeginDrag = false
        edgeOffset = 0
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
        let thumbs = vm.selectedVisuals.thumbnails
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
            for t in vm.selectedVisuals.keyframes.times {
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
                if seg.isAuto {
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.08)))
                    ctx.stroke(Path(rect), with: .color(.white.opacity(isSelected ? 0.9 : 0.45)),
                               style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3]))
                    ctx.draw(Text("whole clip").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.8)),
                             at: CGPoint(x: rect.minX + 12, y: rect.midY), anchor: .leading)
                } else {
                    ctx.fill(Path(rect), with: .color(.yellow.opacity(isSelected ? 0.32 : 0.20)))
                    ctx.stroke(Path(rect), with: .color(.yellow.opacity(isSelected ? 1.0 : 0.7)),
                               lineWidth: isSelected ? 2 : 1)
                }
            }
        }
    }

    private func edgeHandlesVisual(width: CGFloat, total: Double) -> some View {
        Canvas { ctx, size in
            for seg in vm.segments {
                let leftX = CGFloat(seg.start.seconds / total) * size.width
                let rightX = CGFloat(seg.end.seconds / total) * size.width
                let isSelected = vm.selectedSegmentID == seg.id
                let base: Color = seg.isAuto ? .white : .yellow
                let color = GraphicsContext.Shading.color(base.opacity(isSelected ? 1.0 : (seg.isAuto ? 0.6 : 0.85)))
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
        // Edge takes priority: the nearest edge within the hit radius wins.
        var bestEdge: (UUID, SegmentEdge, CGFloat)? = nil
        for seg in vm.segments {
            let leftX = CGFloat(seg.start.seconds / total) * contentWidth
            let rightX = CGFloat(seg.end.seconds / total) * contentWidth
            let dl = abs(point.x - leftX)
            let dr = abs(point.x - rightX)
            if dl <= handleHitRadius, bestEdge == nil || dl < bestEdge!.2 {
                bestEdge = (seg.id, .start, dl)
            }
            if dr <= handleHitRadius, bestEdge == nil || dr < bestEdge!.2 {
                bestEdge = (seg.id, .end, dr)
            }
        }
        if let e = bestEdge { return .edge(e.0, e.1) }
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
        return CMTime(seconds: f * total, preferredTimescale: sourceTimescale)
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
            let x = CGFloat(vm.timelinePlayhead.seconds / total) * size.width
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

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SlateCore

@MainActor
struct ClipStripView: View {
    let vm: ProjectViewModel

    @State private var pressIndex: Int?
    @State private var pressX: CGFloat = 0
    @State private var dragging = false
    @State private var reorderMarker: Int?
    @State private var dropMarker: Int?

    private typealias L = ClipStripLayout

    private var clips: [Clip] { vm.project.clips }
    private var step: CGFloat { L.cardWidth + L.gap }
    private var contentWidth: CGFloat { max(CGFloat(clips.count) * step + L.inset * 2, 240) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    cards
                    if let marker = reorderMarker ?? dropMarker {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: L.cardHeight)
                            .offset(x: markerX(marker), y: 7)
                            .allowsHitTesting(false)
                    }
                    if let ph = vm.stripPlayhead, let i = clips.firstIndex(where: { $0.id == ph.clipID }) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: L.cardHeight)
                            .offset(x: L.inset + CGFloat(i) * step + 4 + CGFloat(ph.fraction) * (L.cardWidth - 8), y: 7)
                            .allowsHitTesting(false)
                    }
                    ClipStripMouseCapture(
                        onMouseDown: { handleDown($0) },
                        onMouseDragged: { handleDragged($0) },
                        onMouseUp: { handleUp($0) },
                        tooltipAt: { tooltip(at: $0) },
                        menuItemsAt: { menuItems(at: $0) })
                        .frame(width: contentWidth, height: L.stripHeight + 14)
                }
                .frame(width: contentWidth, height: L.stripHeight + 14, alignment: .topLeading)
                .onDrop(of: [.fileURL], delegate: StripDropDelegate(
                    indexForX: { insertionIndex(forX: $0) },
                    marker: $dropMarker,
                    onDrop: { urls, index in Task { await vm.handleDrop(urls, at: index) } }))
            }
            Divider()
            Button {
                vm.addClipsPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: L.stripHeight)
            }
            .buttonStyle(.borderless)
            .help("Add clips (⌘O)")
        }
        .frame(height: L.stripHeight + 14)
        .background(Color(white: 0.09))
    }

    private var cards: some View {
        HStack(spacing: L.gap) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                ClipCardView(info: ClipPresentation.card(for: clip, index: i + 1, plan: vm.plan),
                             poster: vm.visuals[clip.id]?.poster,
                             selected: clip.id == vm.editor.selectedClipID,
                             dimmed: dragging && pressIndex == i)
            }
        }
        .padding(.horizontal, L.inset)
        .padding(.top, 7)
        .allowsHitTesting(false)
    }

    // MARK: Geometry

    /// The clip whose card is under x, or nil in a gap or past the last card.
    private func index(at x: CGFloat) -> Int? {
        let rel = x - L.inset
        guard rel >= 0 else { return nil }
        let i = Int(rel / step)
        guard i < clips.count, rel - CGFloat(i) * step <= L.cardWidth else { return nil }
        return i
    }

    /// Where a card dropped at x would be inserted (0...count).
    private func insertionIndex(forX x: CGFloat) -> Int {
        let i = Int(((x - L.inset + step / 2) / step).rounded(.down))
        return min(max(i, 0), clips.count)
    }

    private func markerX(_ i: Int) -> CGFloat {
        L.inset + CGFloat(i) * step - L.gap / 2 - 1.5
    }

    // MARK: Mouse

    private func handleDown(_ p: CGPoint) {
        pressIndex = index(at: p.x)
        pressX = p.x
        dragging = false
        if let i = pressIndex { vm.selectClip(clips[i].id) }
    }

    private func handleDragged(_ p: CGPoint) {
        guard pressIndex != nil else { return }
        if abs(p.x - pressX) > 4 { dragging = true }
        if dragging { reorderMarker = insertionIndex(forX: p.x) }
    }

    private func handleUp(_ p: CGPoint) {
        defer {
            pressIndex = nil
            dragging = false
            reorderMarker = nil
        }
        guard dragging, let from = pressIndex, let insert = reorderMarker else { return }
        guard clips.indices.contains(from) else { return }
        let final = insert > from ? insert - 1 : insert
        if final != from { vm.moveClip(clips[from].id, to: final) }
    }

    private func tooltip(at p: CGPoint) -> String? {
        guard let i = index(at: p.x) else { return nil }
        let info = ClipPresentation.card(for: clips[i], index: i + 1, plan: vm.plan)
        return "\(info.fileName) — \(info.tooltip)"
    }

    private func menuItems(at p: CGPoint) -> [StripMenuItem] {
        guard let i = index(at: p.x) else { return [] }
        let clip = clips[i]
        vm.selectClip(clip.id)
        let exists = FileManager.default.fileExists(atPath: clip.url.path)
        return [
            StripMenuItem(title: "Duplicate", isEnabled: true, action: { vm.duplicateClip(clip.id) }),
            StripMenuItem(title: "Remove", isEnabled: true, action: { vm.removeClip(clip.id) }),
            StripMenuItem(title: "Show in Finder", isEnabled: exists, action: { vm.revealInFinder(clip.id) }),
            StripMenuItem(title: "Locate file…", isEnabled: true, action: { vm.relink(clip.id) }),
        ]
    }
}

/// Finder drop onto the strip: shows an insertion marker and adds the files at that position.
@MainActor
struct StripDropDelegate: DropDelegate {
    let indexForX: (CGFloat) -> Int
    @Binding var marker: Int?
    let onDrop: ([URL], Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        marker = indexForX(info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        marker = indexForX(info.location.x)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        marker = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = indexForX(info.location.x)
        marker = nil
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            let urls = await DroppedFiles.urls(from: providers)
            await MainActor.run { onDrop(urls, index) }
        }
        return true
    }
}

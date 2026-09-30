import SwiftUI
import AppKit
import SlateCore

enum ClipStripLayout {
    static let cardWidth: CGFloat = 132
    static let cardHeight: CGFloat = 96
    static let gap: CGFloat = 8
    static let inset: CGFloat = 8
    static let stripHeight: CGFloat = 96
}

struct ClipCardView: View {
    let info: ClipCardInfo
    let poster: NSImage?
    let selected: Bool
    let dimmed: Bool

    private typealias L = ClipStripLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .top) {
                Group {
                    if let poster {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(white: 0.2))
                    }
                }
                .frame(width: L.cardWidth - 8, height: 52)
                .clipped()
                HStack {
                    Text("\(info.index)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    if info.hasAudio {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .padding(3)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                    }
                }
                .padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(info.fileName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                Text(info.keptText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(info.fpsText)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badgeColor)
                    .foregroundStyle(badgeTextColor)
                    .clipShape(Capsule())
            }
        }
        .padding(4)
        .frame(width: L.cardWidth, height: L.cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(info.tone == .error ? Color.red.opacity(0.28) : Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .opacity(dimmed ? 0.35 : 1)
    }

    private var badgeColor: Color {
        switch info.tone {
        case .normal: return Color(white: 0.32)
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private var badgeTextColor: Color {
        info.tone == .warning ? .black : .white
    }
}

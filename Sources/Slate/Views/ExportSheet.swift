import SwiftUI
import AppKit

struct ExportSheet: View {
    let vm: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            switch vm.exportState {
            case .idle:
                EmptyView()

            case .inProgress(let p):
                ProgressView(value: Double(p))
                    .progressViewStyle(.linear)
                Text("\(Int(p * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        vm.cancelExport()
                    }
                }

            case .done(let url):
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Done") {
                        vm.dismissExport()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .failed(let msg):
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                HStack {
                    Spacer()
                    Button("Close") {
                        vm.dismissExport()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var title: String {
        switch vm.exportState {
        case .idle: return ""
        case .inProgress: return "Exporting…"
        case .done: return "Export complete"
        case .failed: return "Export failed"
        }
    }
}

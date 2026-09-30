import SwiftUI
import AppKit
import SlateCore

@MainActor
struct ProjectExportSheet: View {
    let vm: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            switch vm.exportUI {
            case .idle:
                EmptyView()
            case .review:
                review
            case .running(let stage):
                running(stage)
            case .done(let url):
                done(url)
            case .refused(let issues):
                refused(issues)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var title: String {
        switch vm.exportUI {
        case .idle: return ""
        case .review: return "Export"
        case .running: return "Exporting…"
        case .done: return "Export complete"
        case .refused: return "Export refused"
        case .failed: return "Export failed"
        }
    }

    // MARK: Review (the plan)

    private var review: some View {
        let plan = vm.plan
        let rows = ClipPresentation.rows(plan, project: vm.project)
        let blockers = ClipPresentation.blockerTexts(plan, project: vm.project)
        return VStack(alignment: .leading, spacing: 10) {
            Text(ClipPresentation.modeText(plan)).font(.subheadline)
            if !vm.isConstant {
                Text(ClipPresentation.mixedLabel).font(.caption).foregroundStyle(.orange)
            }
            if plan.canExport {
                Text(ClipPresentation.summary(plan)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.index) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(row.index)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(row.text).font(.caption).foregroundStyle(color(row.tone))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            ForEach(blockers, id: \.self) { text in
                Text(text).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { vm.dismissExport() }
                Button("Export…") { vm.startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canExport)
            }
        }
    }

    private func color(_ tone: ClipCardInfo.Tone) -> Color {
        switch tone {
        case .normal: return .secondary
        case .warning: return .yellow
        case .error: return .red
        }
    }

    // MARK: Running

    private func running(_ stage: ExportStage?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stageTitle(stage))
            if let fraction = fraction(stage) {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { vm.cancelExport() }
            }
        }
    }

    private func stageTitle(_ stage: ExportStage?) -> String {
        switch stage {
        case nil: return "Starting…"
        case .reencoding(let k, let n, _)?: return "Re-encoding \(k) of \(n)"
        case .assembling?: return "Assembling"
        case .validating?: return "Validating"
        }
    }

    private func fraction(_ stage: ExportStage?) -> Double? {
        switch stage {
        case .reencoding(_, _, let p)?: return p
        case .assembling(let p)?: return p
        default: return nil
        }
    }

    // MARK: Results

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func refused(_ issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The exported file failed the timing check, so it was not saved. Any file that was already at the destination is unchanged.")
                .font(.callout)
            ForEach(Array(issues.prefix(8).enumerated()), id: \.offset) { _, issue in
                Text("• \(issue)").font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
            }
            if issues.count > 8 {
                Text("… and \(issues.count - 8) more").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.callout).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Close") { vm.dismissExport() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

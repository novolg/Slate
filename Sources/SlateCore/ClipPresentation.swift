import Foundation

public struct ClipCardInfo: Equatable {
    public enum Tone: Equatable { case normal, warning, error }

    public let index: Int
    public let fileName: String
    public let keptText: String
    public let fpsText: String
    public let hasAudio: Bool
    public let tone: Tone
    public let tooltip: String
}

public struct PlanRow: Equatable {
    public let index: Int
    public let fileName: String
    public let text: String
    public let tone: ClipCardInfo.Tone
}

/// Text and badge decisions for the clip strip and the export sheet. Pure, so the rules are checked.
public enum ClipPresentation {
    public static let mixedLabel =
        "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."

    /// "24 fps", "23.976 fps", "29.97 fps".
    public static func fpsText(_ d: Rational) -> String {
        var s = String(format: "%.3f", 1 / d.seconds)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " fps"
    }

    /// One decimal, no unit: "2.5".
    public static func seconds(_ r: Rational) -> String { String(format: "%.1f", r.seconds) }

    public static func blockText(_ reason: BlockReason) -> String {
        switch reason {
        case .missingFile: return "File is missing or unreadable."
        case .frameSizeMismatch: return "Frame size differs from the first clip."
        case .codecMismatch: return "Codec differs from the first clip."
        case .unsupportedCodec: return "Codec is not supported (H.264 or HEVC only)."
        case .audioMismatch: return "Some clips have audio and some do not."
        case .audioFormatMismatch: return "Audio sample rate or channels differ (allowed only in Constant mode)."
        }
    }

    public static func actionText(_ action: ClipAction, plan: ExportPlan) -> String {
        switch action {
        case .copy:
            return "Copied without re-encoding"
        case .reencode(let reason):
            let target = plan.frameDuration.map { " to \(fpsText($0))" } ?? ""
            switch reason {
            case .fpsDiffers: return "Re-encoded\(target): fps differs"
            case .timingNotExact: return "Re-encoded\(target): frame timing is not exact"
            case .reencodeAll: return "Re-encoded\(target)"
            }
        case .skipped:
            return "Skipped: nothing is kept"
        case .blocked(let reason):
            return blockText(reason)
        }
    }

    public static func card(for clip: Clip, index: Int, plan: ExportPlan) -> ClipCardInfo {
        let name = clip.url.lastPathComponent
        guard let media = clip.media else {
            return ClipCardInfo(index: index, fileName: name, keptText: "— / — s", fpsText: "—",
                                hasAudio: false, tone: .error, tooltip: blockText(.missingFile))
        }
        let clipPlan = plan.plan(for: clip.id)
        let kept = clipPlan?.segments.reduce(Rational.zero) { $0 + $1.outputDuration } ?? .zero
        let exact = media.frames.exactFrameDuration
        let shown: Rational? = exact ?? (media.nominalFPS.isFinite && media.nominalFPS > 0
            ? Rational.frameDuration(fps: media.nominalFPS) : nil)
        let fps = shown.map(fpsText) ?? "—"

        var tone = ClipCardInfo.Tone.normal
        var tip = "Copied as is."
        if case .blocked(let reason)? = clipPlan?.action {
            tone = .error
            tip = blockText(reason)
        } else if case .skipped? = clipPlan?.action {
            tip = "Nothing is kept: this clip is skipped."
        } else if case .constant(let target) = plan.mode {
            if exact == nil {
                tone = .warning
                tip = "Frame timing is not exact, so this clip is re-encoded to \(fpsText(target))."
            } else if exact != target {
                tone = .warning
                tip = "This clip is \(fps); it is re-encoded to \(fpsText(target))."
            } else {
                tip = "Matches the output frame rate."
            }
        }
        return ClipCardInfo(index: index, fileName: name,
                            keptText: "\(seconds(kept)) / \(seconds(media.frames.clipEnd)) s",
                            fpsText: fps, hasAudio: media.hasAudio, tone: tone, tooltip: tip)
    }

    public static func rows(_ plan: ExportPlan, project: Project) -> [PlanRow] {
        project.clips.enumerated().map { i, clip in
            let card = card(for: clip, index: i + 1, plan: plan)
            var text = plan.plan(for: clip.id).map { actionText($0.action, plan: plan) } ?? ""
            let dropped = plan.plan(for: clip.id)?.droppedSegmentIDs.count ?? 0
            if dropped > 0 { text += " · \(dropped) selection(s) shorter than one frame skipped" }
            return PlanRow(index: i + 1, fileName: clip.url.lastPathComponent, text: text, tone: card.tone)
        }
    }

    public static func blockerTexts(_ plan: ExportPlan, project: Project) -> [String] {
        func name(_ id: UUID) -> String {
            project.clips.first { $0.id == id }?.url.lastPathComponent ?? "A clip"
        }
        return plan.blockers.map { b in
            switch b {
            case .noClips: return "Add at least one clip."
            case .noFrames: return "All selections are shorter than one frame."
            case .clip(let id, let reason): return "\(name(id)): \(blockText(reason))"
            case .duplicateClipID(let id): return "\(name(id)): the same clip id appears twice."
            case .timescaleOverflow: return "Clip timescales cannot share one exact timeline."
            }
        }
    }

    /// "12.3 s · 296 frames".
    public static func summary(_ plan: ExportPlan) -> String {
        "\(seconds(plan.totalDuration)) s · \(plan.totalFrames) frames"
    }

    public static func modeText(_ plan: ExportPlan) -> String {
        switch plan.mode {
        case .mixed: return "Mixed frame rates · copied without re-encoding"
        case .constant(let d): return "Constant \(fpsText(d)) · every clip is re-encoded"
        }
    }

    public static func defaultOutputName(project: Project, documentName: String?) -> String {
        if let documentName { return "\(documentName).mp4" }
        if project.clips.count == 1, let only = project.clips.first {
            return "\(only.url.deletingPathExtension().lastPathComponent) — trimmed.mp4"
        }
        return "Slate export.mp4"
    }
}

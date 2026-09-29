import Foundation

public enum ReencodeReason: Equatable {
    case fpsDiffers
    case timingNotExact
    case reencodeAll
}

public enum BlockReason: Equatable {
    case missingFile
    case frameSizeMismatch
    case codecMismatch
    case audioMismatch
}

public enum ClipAction: Equatable {
    case copy
    case reencode(ReencodeReason)
    /// No output frames (no segments, or all shorter than one frame). Not an error.
    case skipped
    case blocked(BlockReason)
}

public struct ClipPlan: Equatable {
    public let clipID: UUID
    public let action: ClipAction
    public let segments: [GridSegment]
    public let droppedSegmentIDs: [UUID]

    public var frameCount: Int { segments.reduce(0) { $0 + $1.frameCount } }
}

public enum PlanBlocker: Equatable {
    case noClips
    case noFrames
    case clip(UUID, BlockReason)
    case timescaleOverflow
}

public struct ExportPlan: Equatable {
    public let mode: FPSMode
    public let strategy: ConstantStrategy
    public let clips: [ClipPlan]
    /// All grid segments in output order. Feeds export, preview and ProjectTimeMap.
    public let grid: [GridSegment]
    public let totalDuration: Rational
    public let totalFrames: Int
    /// T_out: d and every COPIED clip's timescale divide it. Re-encoded and skipped clips
    /// are optional; if a timescale overflows, it is silently omitted from the fold.
    public let outputTimescale: Int32
    /// The first readable clip. Every other clip must match its size, codec and audio.
    public let reference: ClipMedia?
    public let blockers: [PlanBlocker]

    public var canExport: Bool { blockers.isEmpty }
    public var hasAudio: Bool { reference?.hasAudio ?? false }
    public var audio: AudioFormat? { reference?.audio }

    public var frameDuration: Rational? {
        if case .constant(let d) = mode { return d }
        return nil
    }

    public func plan(for clipID: UUID) -> ClipPlan? {
        clips.first { $0.clipID == clipID }
    }
}

public enum ExportPlanner {
    public static func plan(_ project: Project) -> ExportPlan {
        let reference = project.clips.first { $0.media != nil }?.media

        var blocked: [UUID: BlockReason] = [:]
        for clip in project.clips {
            guard let m = clip.media, let ref = reference else {
                blocked[clip.id] = .missingFile
                continue
            }
            if m.width != ref.width || m.height != ref.height {
                blocked[clip.id] = .frameSizeMismatch
            } else if m.codec != ref.codec {
                blocked[clip.id] = .codecMismatch
            } else if m.hasAudio != ref.hasAudio {
                blocked[clip.id] = .audioMismatch
            }
        }

        let inputs: [FrameGrid.ClipInput] = project.clips.compactMap { clip in
            guard blocked[clip.id] == nil, let m = clip.media else { return nil }
            return FrameGrid.ClipInput(clipID: clip.id, frames: m.frames, segments: clip.segments)
        }
        let grid = FrameGrid.build(inputs, mode: project.fpsMode)
        let droppedSet = Set(grid.dropped)

        var clipPlans: [ClipPlan] = []
        for clip in project.clips {
            let segs = grid.segments.filter { $0.clipID == clip.id }
            let dropped = clip.segments.map(\.id).filter { droppedSet.contains($0) }
            let action: ClipAction
            if let reason = blocked[clip.id] {
                action = .blocked(reason)
            } else if segs.isEmpty {
                action = .skipped
            } else {
                action = decide(clip.media!, mode: project.fpsMode, strategy: project.constantStrategy)
            }
            clipPlans.append(ClipPlan(clipID: clip.id, action: action, segments: segs, droppedSegmentIDs: dropped))
        }

        var blockers: [PlanBlocker] = []
        if project.clips.isEmpty { blockers.append(.noClips) }
        for clip in project.clips {
            if let reason = blocked[clip.id] { blockers.append(.clip(clip.id, reason)) }
        }
        if !project.clips.isEmpty && grid.totalFrames == 0 { blockers.append(.noFrames) }

        // Separate timescales by action: required (copied) vs optional (re-encoded/skipped)
        var requiredTimescales: [Int32] = []
        var optionalTimescales: [Int32] = []
        for plan in clipPlans {
            if case .copy = plan.action, let ts = project.clips.first(where: { $0.id == plan.clipID })?.media?.frames.timescale {
                requiredTimescales.append(ts)
            } else if case .reencode = plan.action, let ts = project.clips.first(where: { $0.id == plan.clipID })?.media?.frames.timescale {
                optionalTimescales.append(ts)
            } else if case .skipped = plan.action, let ts = project.clips.first(where: { $0.id == plan.clipID })?.media?.frames.timescale {
                optionalTimescales.append(ts)
            }
        }

        let timescale = outputTimescale(mode: project.fpsMode, required: requiredTimescales, optional: optionalTimescales)
        if timescale == nil { blockers.append(.timescaleOverflow) }

        return ExportPlan(mode: project.fpsMode, strategy: project.constantStrategy, clips: clipPlans,
                          grid: grid.segments, totalDuration: grid.totalDuration, totalFrames: grid.totalFrames,
                          outputTimescale: timescale ?? 600, reference: reference, blockers: blockers)
    }

    static func decide(_ media: ClipMedia, mode: FPSMode, strategy: ConstantStrategy) -> ClipAction {
        guard case .constant(let d) = mode else { return .copy }
        if strategy == .reencodeAll { return .reencode(.reencodeAll) }
        guard let src = media.frames.exactFrameDuration else { return .reencode(.timingNotExact) }
        return src == d ? .copy : .reencode(.fpsDiffers)
    }

    /// Compute T_out: the lcm of d (in Constant mode) and every REQUIRED (copied) clip's timescale.
    /// Then optionally fold in each OPTIONAL timescale (re-encoded/skipped clips) one by one,
    /// keeping the fold only if the lcm exists and ≤ Int32.max; otherwise skip that timescale.
    /// In Constant mode: overflow on required → return nil (blocker). In Mixed mode: overflow on
    /// required → return largest required timescale (or 600 if none). Optional overflows never block.
    static func outputTimescale(mode: FPSMode, required: [Int32], optional: [Int32]) -> Int32? {
        var t: Int64 = 1
        if case .constant(let d) = mode { t = d.den }

        // Required timescales: any overflow or overflow causes blocker
        for ts in required {
            if let l = Rational.lcm(t, Int64(ts)) {
                if l > Int64(Int32.max) {
                    if case .mixed = mode { return required.max().map { Int32($0) } ?? 600 }
                    return nil
                }
                t = l
            } else {
                if case .mixed = mode { return required.max().map { Int32($0) } ?? 600 }
                return nil
            }
        }

        // Optional timescales: silently skip if overflow
        for ts in optional {
            if let l = Rational.lcm(t, Int64(ts)), l <= Int64(Int32.max) {
                t = l
            }
            // If lcm fails or exceeds limit, silently skip this optional timescale
        }

        return t == 1 ? 600 : Int32(t)
    }
}

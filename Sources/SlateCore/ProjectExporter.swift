import Foundation
import AVFoundation
import CoreMedia

public enum ExportStage: Equatable {
    case reencoding(clip: Int, of: Int, progress: Double)
    case assembling(Double)
    case validating
}

public enum ProjectExportError: Error, LocalizedError {
    case blocked([PlanBlocker])
    case outputIsSource
    case validationFailed(CadenceReport)
    case cannotCreateSession
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .blocked: return "The project cannot be exported. See the plan for details."
        case .outputIsSource: return "The output file is one of the source clips. Choose another name."
        case .validationFailed(let r): return "The exported file failed validation: \(r.issues.joined(separator: "; "))"
        case .cannotCreateSession: return "Could not create the export session."
        case .exportFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

/// Exports one project to one output file.
///
/// An instance is single-use. Once it is cancelled — via `cancel()`, or because the
/// enclosing Swift `Task` running `export(...)` was cancelled — it stays cancelled
/// forever: a later `export(...)` call on the same instance throws
/// `ProjectExportError.cancelled` immediately, without touching disk. There is no API
/// to reset it; create a fresh `ProjectExporter` for the next export.
public final class ProjectExporter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var session: AVAssetExportSession?
    private var reencoder: ClipReencoder?

    /// Checks the staged file. Replaceable in checks to simulate a failed validation.
    public var validator: (URL, ExportPlan) async throws -> CadenceReport = { url, plan in
        try await CadenceValidator.validate(url: url, frameDuration: plan.frameDuration,
                                            expectedFrames: plan.totalFrames,
                                            expectedDuration: plan.totalDuration,
                                            audioSampleRate: plan.audio?.sampleRate)
    }

    /// If set, a file that fails validation is saved here for inspection (Phase 0).
    /// The real destination is never touched in that case.
    public var keepInvalidAt: URL?

    public init() {}

    public func cancel() {
        lock.withLock {
            cancelled = true
            session?.cancelExport()
            reencoder?.cancel()
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func export(project: Project, outputURL: URL, tempDirectory: URL,
                       progress: @escaping @Sendable (ExportStage) -> Void) async throws -> CadenceReport {
        // Bridges cooperative cancellation of the enclosing Task onto this instance:
        // cancelling the Task running this call behaves exactly like calling `cancel()`.
        try await withTaskCancellationHandler {
            let plan = ExportPlanner.plan(project)
            guard plan.canExport else { throw ProjectExportError.blocked(plan.blockers) }
            let sources = project.clips.map(\.url)
            if Self.outputCollides(outputURL, with: sources) {
                throw ProjectExportError.outputIsSource
            }
            // The diagnostic path must not alias a source or the real destination either.
            if let keepInvalidAt, Self.outputCollides(keepInvalidAt, with: sources + [outputURL]) {
                throw ProjectExportError.outputIsSource
            }

            let work = tempDirectory.appendingPathComponent("slate-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            // Render and validate a staged file. The destination is touched only after
            // success, so a failed or cancelled export keeps any existing file there.
            let staged = work.appendingPathComponent("render.mp4")
            do {
                try await render(plan: plan, project: project, output: staged, work: work, progress: progress)
                if isCancelled { throw ProjectExportError.cancelled }
                progress(.validating)
                let report = try await validator(staged, plan)
                if isCancelled { throw ProjectExportError.cancelled }
                guard report.ok else {
                    // Never replace the destination with a file that failed validation.
                    if let keepInvalidAt { try? Self.install(staged, at: keepInvalidAt) }
                    throw ProjectExportError.validationFailed(report)
                }
                try Self.install(staged, at: outputURL)
                return report
            } catch {
                if isCancelled || error is CancellationError { throw ProjectExportError.cancelled }
                if case ReencodeError.cancelled = error { throw ProjectExportError.cancelled }
                throw error
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// True if `output` is (or would overwrite) one of the sources: same resolved path
    /// after following symlinks, or the same file identity (case aliases, hard links).
    static func outputCollides(_ output: URL, with sources: [URL]) -> Bool {
        let out = output.resolvingSymlinksInPath().standardizedFileURL
        let outID = try? out.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        for source in sources {
            let src = source.resolvingSymlinksInPath().standardizedFileURL
            if src.path == out.path { return true }
            if let outID,
               let srcID = try? src.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               outID.isEqual(srcID) {
                return true
            }
        }
        return false
    }

    /// Move the staged file next to the destination (same volume), then swap it in.
    static func install(_ staged: URL, at destination: URL) throws {
        let fm = FileManager.default
        let sibling = destination.deletingLastPathComponent()
            .appendingPathComponent(".slate-\(UUID().uuidString).mp4")
        do {
            try fm.moveItem(at: staged, to: sibling)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: sibling)
            } else {
                try fm.moveItem(at: sibling, to: destination)
            }
        } catch {
            try? fm.removeItem(at: sibling)
            throw error
        }
    }

    private func render(plan: ExportPlan, project: Project, output: URL, work: URL,
                        progress: @escaping @Sendable (ExportStage) -> Void) async throws {
        let clips = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        var assets: [UUID: AVURLAsset] = [:]
        for cp in plan.clips where !cp.segments.isEmpty {
            assets[cp.clipID] = AVURLAsset(url: clips[cp.clipID]!.url)
        }
        let reference = plan.reference!

        if let d = plan.frameDuration, plan.strategy == .reencodeAll {
            var jobs: [ReencodeJob] = []
            for cp in plan.clips where !cp.segments.isEmpty {
                jobs.append(try await ReencodeJob.load(asset: assets[cp.clipID]!,
                                                       frames: clips[cp.clipID]!.media!.frames,
                                                       segments: cp.segments))
            }
            try await reencode(jobs, d: d, plan: plan, reference: reference, to: output) { p in
                progress(.reencoding(clip: 1, of: 1, progress: p))
            }
            return
        }

        let reencodeCount = plan.clips.filter {
            if case .reencode = $0.action { return true }
            return false
        }.count
        var reencoded = 0
        var inserts: [CompositionInsert] = []
        for cp in plan.clips where !cp.segments.isEmpty {
            if isCancelled { throw ProjectExportError.cancelled }
            let asset = assets[cp.clipID]!
            switch cp.action {
            case .copy:
                inserts += try CompositionBuilder.inserts(for: cp.segments, assets: [cp.clipID: asset])
            case .reencode:
                guard let d = plan.frameDuration else { continue }
                reencoded += 1
                let index = reencoded
                let job = try await ReencodeJob.load(asset: asset, frames: clips[cp.clipID]!.media!.frames,
                                                     segments: cp.segments)
                let tmp = work.appendingPathComponent("\(cp.clipID.uuidString).mp4")
                try await reencode([job], d: d, plan: plan, reference: reference, to: tmp) { p in
                    progress(.reencoding(clip: index, of: reencodeCount, progress: p))
                }
                let total = cp.segments.reduce(Rational.zero) { $0 + $1.outputDuration }
                inserts.append(CompositionInsert(asset: AVURLAsset(url: tmp), sourceStart: .zero,
                                                 duration: total, outputStart: cp.segments[0].outputStart))
            case .skipped, .blocked:
                continue
            }
        }

        if isCancelled { throw ProjectExportError.cancelled }
        progress(.assembling(0))
        let comp = try await CompositionBuilder.build(inserts: inserts, includeAudio: plan.hasAudio,
                                                      timescale: plan.outputTimescale)
        try await passthrough(comp, to: output) { progress(.assembling($0)) }
    }

    private func reencode(_ jobs: [ReencodeJob], d: Rational, plan: ExportPlan, reference: ClipMedia,
                          to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let encoder = ClipReencoder()
        lock.withLock { reencoder = encoder }
        if isCancelled { encoder.cancel() }
        defer { lock.withLock { reencoder = nil } }
        try await encoder.encode(jobs: jobs, frameDuration: d, timescale: plan.outputTimescale,
                                 video: .matching(reference), audio: plan.audio,
                                 outputURL: url, progress: progress)
    }

    private func passthrough(_ comp: AVMutableComposition, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ProjectExportError.cannotCreateSession
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        lock.withLock { self.session = session }
        if isCancelled { session.cancelExport() }
        defer { lock.withLock { self.session = nil } }

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await session.export()
        poll.cancel()

        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw ProjectExportError.cancelled
        default: throw ProjectExportError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
    }
}

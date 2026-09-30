import Foundation

/// Debounced autosave. Call `noteChange()` after every edit; the write runs once, `delay` after the last change.
///
/// Writes never overlap: each one first awaits the previously started write, so the last
/// write to reach the disk is the last one started. `flush()` is therefore always final.
public final class Autosaver: @unchecked Sendable {
    /// Shared state. The timer task captures this (never `self`), so a dropped Autosaver
    /// can deinit and cancel its pending timer.
    private final class State: @unchecked Sendable {
        let write: @Sendable () async throws -> Void
        let onError: @Sendable (Error) -> Void
        let lock = NSLock()
        var pending: Task<Void, Never>?
        var inFlight: Task<Void, Never>?

        init(write: @escaping @Sendable () async throws -> Void, onError: @escaping @Sendable (Error) -> Void) {
            self.write = write
            self.onError = onError
        }

        /// Start a write after the previous one. Caller holds `lock`.
        func startWriteLocked(swallowCancellation: Bool) -> Task<Void, Never> {
            let previous = inFlight
            let task = Task { [write, onError] in
                await previous?.value
                do {
                    try await write()
                } catch is CancellationError where swallowCancellation {
                    // replaced by a newer change or a flush
                } catch {
                    onError(error)
                }
            }
            inFlight = task
            return task
        }

        func cancelPending() {
            lock.withLock {
                pending?.cancel()
                pending = nil
            }
        }
    }

    private let delay: Duration
    private let state: State

    public init(delay: Duration, write: @escaping @Sendable () async throws -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.delay = delay
        self.state = State(write: write, onError: onError)
    }

    deinit {
        state.cancelPending()
    }

    public func noteChange() {
        let state = self.state
        let task = Task { [delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // a newer change or flush/cancel replaced this write
            }
            // Decide and register under the lock, so a concurrent flush() either cancels us
            // first (we skip) or sees our write in flight (and waits for it).
            let write: Task<Void, Never>? = state.lock.withLock {
                Task.isCancelled ? nil : state.startWriteLocked(swallowCancellation: true)
            }
            await write?.value
        }
        state.lock.withLock {
            state.pending?.cancel()
            state.pending = task
        }
    }

    /// Write now (for example on quit or before Save As) and drop the pending timer.
    /// Waits for a write that is already running; this write lands after it.
    public func flush() async {
        let task: Task<Void, Never> = state.lock.withLock {
            state.pending?.cancel()
            state.pending = nil
            return state.startWriteLocked(swallowCancellation: false)
        }
        await task.value
    }

    public func cancel() {
        state.cancelPending()
    }
}

/// Where an untitled project is autosaved. On launch the app offers to restore it.
public struct UntitledAutosaveStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slate", isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent("untitled.slate") }

    public func save(_ file: ProjectFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try file.write(to: fileURL)
    }

    /// The autosaved project, or nil when there is none or it cannot be read.
    public func pending() -> ProjectFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? ProjectFile.decode(data)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

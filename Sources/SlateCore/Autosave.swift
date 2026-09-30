import Foundation

/// Debounced autosave. Call `noteChange()` after every edit; the write runs once, `delay` after the last change.
public final class Autosaver: @unchecked Sendable {
    private let delay: Duration
    private let write: @Sendable () async throws -> Void
    private let onError: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    public init(delay: Duration, write: @escaping @Sendable () async throws -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.delay = delay
        self.write = write
        self.onError = onError
    }

    public func noteChange() {
        let task = Task { [delay, write, onError] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                try await write()
            } catch is CancellationError {
                // a newer change or flush/cancel replaced this write
            } catch {
                onError(error)
            }
        }
        lock.withLock {
            pending?.cancel()
            pending = task
        }
    }

    /// Write now (for example on quit or before Save As) and drop the pending timer.
    public func flush() async {
        cancel()
        do { try await write() } catch { onError(error) }
    }

    public func cancel() {
        lock.withLock {
            pending?.cancel()
            pending = nil
        }
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

import Foundation

public enum ProjectDocumentError: Error, LocalizedError, Equatable {
    case noFile

    public var errorDescription: String? {
        "This project has no file yet. Use Save As…"
    }
}

/// Which file a project belongs to, whether it has unsaved changes, and where it is autosaved.
/// Pure logic (no UI); the view model calls it from the main actor.
public final class ProjectDocument {
    public private(set) var fileURL: URL?
    public private(set) var savedRevision: Int
    public let untitledStore: UntitledAutosaveStore

    public init(fileURL: URL? = nil, savedRevision: Int = 0,
                untitledStore: UntitledAutosaveStore = UntitledAutosaveStore(directory: UntitledAutosaveStore.defaultDirectory)) {
        self.fileURL = fileURL
        self.savedRevision = savedRevision
        self.untitledStore = untitledStore
    }

    public var isUntitled: Bool { fileURL == nil }

    public var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    public func hasUnsavedChanges(revision: Int) -> Bool { revision != savedRevision }

    /// A project was just opened from `url`.
    public func opened(from url: URL, revision: Int) {
        fileURL = url
        savedRevision = revision
    }

    /// A new, empty project replaced the old one.
    public func startedNew(revision: Int) {
        fileURL = nil
        savedRevision = revision
        untitledStore.discard()
    }

    /// The untitled autosave was restored: the project counts as unsaved until the user saves it.
    public func restoredUntitled() {
        fileURL = nil
        savedRevision = -1
    }

    public func save(_ project: Project, revision: Int) throws {
        guard let url = fileURL else { throw ProjectDocumentError.noFile }
        try ProjectFile(project: project, savedAt: url).write(to: url)
        savedRevision = revision
    }

    public func saveAs(_ project: Project, to url: URL, revision: Int) throws {
        try ProjectFile(project: project, savedAt: url).write(to: url)
        fileURL = url
        savedRevision = revision
        untitledStore.discard()
    }

    /// Called by the debounced autosaver. A titled project is written in place (and counts as saved);
    /// an untitled one goes to the autosave store, or the store is cleared when nothing is worth keeping.
    public func autosave(_ project: Project, revision: Int) throws {
        if fileURL != nil {
            try save(project, revision: revision)
            return
        }
        if project.clips.isEmpty {
            untitledStore.discard()
            return
        }
        try untitledStore.save(ProjectFile(project: project, savedAt: nil))
    }

    /// The untitled project autosaved by an earlier run, with its media probed, or nil.
    public func restorableProject() async -> Project? {
        guard let file = untitledStore.pending() else { return nil }
        let project = file.project(resolvingFrom: nil, exists: { FileManager.default.fileExists(atPath: $0.path) })
        return await ProjectFile.attachMedia(to: project)
    }

    public func discardUntitledAutosave() {
        untitledStore.discard()
    }
}

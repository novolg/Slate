import Foundation
import CoreMedia
import SlateCore

func runProjectDocumentChecks() async {
    func freshDirectory(_ name: String) throws -> URL {
        let dir = try checksOutputDirectory().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func project(in dir: URL) -> Project {
        let seg = Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)))
        return Project(clips: [Clip(url: dir.appendingPathComponent("a.mp4"), segments: [seg], media: nil)])
    }

    await checkAsync("document: save as, dirty flag, save") {
        let dir = try freshDirectory("doc-save")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        expect(doc.isUntitled)
        expectEqual(doc.displayName, "Untitled")
        let p = project(in: dir)
        do {
            try doc.save(p, revision: 1)
            expect(false, "an untitled document cannot Save")
        } catch ProjectDocumentError.noFile {
            // expected
        }
        let url = dir.appendingPathComponent("Trailer.slate")
        try doc.saveAs(p, to: url, revision: 3)
        expect(!doc.isUntitled)
        expectEqual(doc.displayName, "Trailer")
        expect(!doc.hasUnsavedChanges(revision: 3))
        expect(doc.hasUnsavedChanges(revision: 4))
        try doc.save(p, revision: 4)
        expect(!doc.hasUnsavedChanges(revision: 4))
        let loaded = try await ProjectFile.load(from: url)
        expectEqual(loaded.clips.map(\.id), p.clips.map(\.id))
    }

    await checkAsync("document: autosave of a titled project writes in place and counts as saved") {
        let dir = try freshDirectory("doc-titled")
        let doc = ProjectDocument(untitledStore: UntitledAutosaveStore(directory: dir.appendingPathComponent("auto")))
        let url = dir.appendingPathComponent("p.slate")
        var p = project(in: dir)
        try doc.saveAs(p, to: url, revision: 1)
        p.clips.append(Clip(url: dir.appendingPathComponent("b.mp4"), segments: [], media: nil))
        try doc.autosave(p, revision: 2)
        expect(!doc.hasUnsavedChanges(revision: 2))
        let loaded = try await ProjectFile.load(from: url)
        expectEqual(loaded.clips.count, 2)
    }

    await checkAsync("document: an untitled project autosaves to the store, is offered back, and Save As discards it") {
        let dir = try freshDirectory("doc-untitled")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        let p = project(in: dir)
        try doc.autosave(p, revision: 1)
        expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        let restored = await doc.restorableProject()
        expectEqual(restored?.clips.map(\.id), p.clips.map(\.id))
        try doc.saveAs(p, to: dir.appendingPathComponent("kept.slate"), revision: 1)
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "Save As discards the untitled autosave")
        let none = await doc.restorableProject()
        expect(none == nil)
    }

    await checkAsync("document: an empty untitled project writes nothing and clears an old autosave") {
        let dir = try freshDirectory("doc-empty")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        let doc = ProjectDocument(untitledStore: store)
        try doc.autosave(project(in: dir), revision: 1)
        expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        try doc.autosave(Project(), revision: 2)
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    await checkAsync("document: a corrupt untitled autosave is not offered") {
        let dir = try freshDirectory("doc-corrupt")
        let store = UntitledAutosaveStore(directory: dir.appendingPathComponent("auto"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL)
        let doc = ProjectDocument(untitledStore: store)
        let none = await doc.restorableProject()
        expect(none == nil)
    }

    await checkAsync("document: a restored untitled project is dirty until it is saved; New and Open reset the flag") {
        let dir = try freshDirectory("doc-flags")
        let doc = ProjectDocument(untitledStore: UntitledAutosaveStore(directory: dir.appendingPathComponent("auto")))
        doc.restoredUntitled()
        expect(doc.isUntitled)
        expect(doc.hasUnsavedChanges(revision: 0))
        doc.opened(from: dir.appendingPathComponent("x.slate"), revision: 0)
        expect(!doc.isUntitled)
        expect(!doc.hasUnsavedChanges(revision: 0))
        doc.startedNew(revision: 0)
        expect(doc.isUntitled)
        expect(!doc.hasUnsavedChanges(revision: 0))
    }

    await checkAsync("project file: attachMedia probes existing files and leaves missing ones without media") {
        let dir = try freshDirectory("doc-attach")
        let real = dir.appendingPathComponent("c24.mp4")
        try FileManager.default.copyItem(at: try fixture("c24.mp4"), to: real)
        let p = Project(clips: [
            Clip(url: real, segments: [], media: nil),
            Clip(url: dir.appendingPathComponent("gone.mp4"), segments: [], media: nil),
        ])
        let out = await ProjectFile.attachMedia(to: p)
        expect(out.clips[0].media != nil)
        expect(out.clips[1].media == nil)
    }
}

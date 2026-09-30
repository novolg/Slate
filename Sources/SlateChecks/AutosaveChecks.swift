import Foundation
import CoreMedia
import SlateCore

final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var events: [String] { lock.withLock { items } }
}

func runAutosaveChecks() async {
    await checkAsync("autosave: many quick changes write once, after the delay") {
        let counter = WriteCounter()
        let saver = Autosaver(delay: .milliseconds(150), write: { counter.hit() })
        for _ in 0..<5 {
            saver.noteChange()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        expectEqual(counter.count, 0, "must not write while changes keep coming")
        try await Task.sleep(nanoseconds: 500_000_000)
        expectEqual(counter.count, 1)
    }

    await checkAsync("autosave: flush writes at once and cancels the pending write") {
        let counter = WriteCounter()
        let saver = Autosaver(delay: .milliseconds(150), write: { counter.hit() })
        saver.noteChange()
        await saver.flush()
        expectEqual(counter.count, 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        expectEqual(counter.count, 1, "the cancelled timer must not write again")
    }

    await checkAsync("autosave: cancel drops the pending write") {
        let counter = WriteCounter()
        let saver = Autosaver(delay: .milliseconds(100), write: { counter.hit() })
        saver.noteChange()
        saver.cancel()
        try await Task.sleep(nanoseconds: 350_000_000)
        expectEqual(counter.count, 0)
    }

    await checkAsync("autosave: a failing write is reported, not thrown") {
        struct Boom: Error {}
        let errors = WriteCounter()
        let saver = Autosaver(delay: .milliseconds(50), write: { throw Boom() }, onError: { _ in errors.hit() })
        saver.noteChange()
        try await Task.sleep(nanoseconds: 300_000_000)
        expectEqual(errors.count, 1)
    }

    await checkAsync("autosave: flush waits for a running timer write and its write lands last") {
        let log = EventLog()
        let calls = WriteCounter()
        let saver = Autosaver(delay: .milliseconds(30), write: {
            calls.hit()
            let n = calls.count
            log.add("start\(n)")
            if n == 1 { try await Task.sleep(nanoseconds: 200_000_000) }
            log.add("end\(n)")
        })
        saver.noteChange()
        try await Task.sleep(nanoseconds: 80_000_000)
        await saver.flush()
        expectEqual(log.events, ["start1", "end1", "start2", "end2"])
        expectEqual(calls.count, 2)
    }

    await checkAsync("autosave: a dropped Autosaver writes nothing") {
        let counter = WriteCounter()
        do {
            let saver = Autosaver(delay: .milliseconds(100), write: { counter.hit() })
            saver.noteChange()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        expectEqual(counter.count, 0)
    }

    check("autosave: untitled store saves, restores and discards; a corrupt file is ignored") {
        let dir = try checksOutputDirectory().appendingPathComponent("untitled-autosave", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let store = UntitledAutosaveStore(directory: dir)
        expect(store.pending() == nil, "nothing saved yet")
        let clip = Clip(url: URL(fileURLWithPath: "/tmp/x.mp4"),
                        segments: [Segment.wholeClip(duration: CMTime(value: 5, timescale: 1))], media: nil)
        let file = ProjectFile(project: Project(clips: [clip]), savedAt: nil)
        try store.save(file)
        expectEqual(store.pending(), file)
        try Data("garbage".utf8).write(to: store.fileURL)
        expect(store.pending() == nil, "a corrupt autosave must not crash the restore offer")
        store.discard()
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    check("autosave: the default folder is under Application Support/Slate/Autosave") {
        expect(UntitledAutosaveStore.defaultDirectory.path.hasSuffix("Application Support/Slate/Autosave"),
               UntitledAutosaveStore.defaultDirectory.path)
    }
}

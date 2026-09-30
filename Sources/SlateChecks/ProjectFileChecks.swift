import Foundation
import CoreMedia
import SlateCore

func runProjectFileChecks() async {
    // macOS resolves /tmp to /private/tmp, and ProjectFile stores resolved paths. Build every test
    // path from the resolved root so string comparisons are stable.
    let root = URL(fileURLWithPath: "/tmp/slate-pf", isDirectory: true).resolvingSymlinksInPath()
    let base = root.appendingPathComponent("project", isDirectory: true)
    let file = base.appendingPathComponent("cut.slate")
    let movedFolder = root.deletingLastPathComponent().appendingPathComponent("slate-moved", isDirectory: true)

    func sampleProject() -> Project {
        let seg = Segment(range: CMTimeRange(start: CMTime(value: 420, timescale: 600), end: CMTime(value: 1500, timescale: 600)))
        let auto = Segment.wholeClip(duration: CMTime(value: 5, timescale: 1))
        let a = Clip(url: base.appendingPathComponent("a.mp4"), segments: [seg], media: nil)
        let b = Clip(url: root.appendingPathComponent("other/b.mp4"), segments: [auto], media: nil)
        return Project(clips: [a, b], fpsMode: .constant(frameDuration: Rational(1001, 24000)))
    }

    check("project file: paths relative to the project folder") {
        expectEqual(PathRelinking.relativePath(of: base.appendingPathComponent("a.mp4"), from: base), "a.mp4")
        expectEqual(PathRelinking.relativePath(of: base.appendingPathComponent("sub/a.mp4"), from: base), "sub/a.mp4")
        expectEqual(PathRelinking.relativePath(of: root.appendingPathComponent("other/b.mp4"), from: base), "../other/b.mp4")
        expectEqual(PathRelinking.resolve(relative: "../other/b.mp4", from: base).path,
                    root.appendingPathComponent("other/b.mp4").path)
    }

    check("project file: round trip keeps ids, order, segments (incl. auto flag) and the fps mode") {
        let p = sampleProject()
        let data = try ProjectFile(project: p, savedAt: file).encoded()
        let back = try ProjectFile.decode(data).project(resolvingFrom: file, exists: { _ in true })
        expectEqual(back.clips.map(\.id), p.clips.map(\.id))
        expectEqual(back.clips.map(\.segments), p.clips.map(\.segments))
        expectEqual(back.clips.map(\.url.path), p.clips.map { $0.url.resolvingSymlinksInPath().path })
        expectEqual(back.fpsMode, p.fpsMode)
        expect(back.clips.allSatisfy { $0.media == nil })
    }

    check("project file: constantStrategy is not stored and loads as Re-encode all") {
        let p = Project(clips: sampleProject().clips, fpsMode: .mixed, constantStrategy: .selective)
        let json = String(decoding: try ProjectFile(project: p, savedAt: file).encoded(), as: UTF8.self)
        expect(!json.contains("constantStrategy") && !json.contains("selective"), json)
        let back = try ProjectFile.decode(Data(json.utf8)).project(resolvingFrom: file, exists: { _ in true })
        expectEqual(back.constantStrategy, ConstantStrategy.reencodeAll)
        expectEqual(back.fpsMode, FPSMode.mixed)
    }

    check("project file: a newer version is refused, unknown fields are ignored, junk is not a project") {
        var json = String(decoding: try ProjectFile(project: sampleProject(), savedAt: file).encoded(), as: UTF8.self)
        let newer = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        do {
            _ = try ProjectFile.decode(Data(newer.utf8))
            expect(false, "expected unsupportedVersion")
        } catch ProjectFileError.unsupportedVersion(let v) {
            expectEqual(v, 2)
        }
        json = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 1, \"futureField\" : {\"x\": 1}")
        _ = try ProjectFile.decode(Data(json.utf8))
        do {
            _ = try ProjectFile.decode(Data("not json".utf8))
            expect(false, "expected notAProject")
        } catch ProjectFileError.notAProject {
            // expected
        }
    }

    check("project file: relink tries the relative path, then the absolute path, then keeps the absolute path") {
        let p = sampleProject()
        let f = try ProjectFile(project: p, savedAt: file)
        let moved = movedFolder.appendingPathComponent("cut.slate")
        let movedClip = movedFolder.appendingPathComponent("a.mp4").path
        let oldClip = base.appendingPathComponent("a.mp4").path
        // Whole folder moved: relative path is found next to the new project file.
        let viaRelative = f.project(resolvingFrom: moved, exists: { $0.path == movedClip })
        expectEqual(viaRelative.clips[0].url.path, movedClip)
        // Project file moved alone: absolute path still exists.
        let viaAbsolute = f.project(resolvingFrom: moved, exists: { $0.path == oldClip })
        expectEqual(viaAbsolute.clips[0].url.path, oldClip)
        // Nothing exists: keep the absolute path so the card can say "Locate file…".
        let nowhere = f.project(resolvingFrom: moved, exists: { _ in false })
        expectEqual(nowhere.clips[0].url.path, oldClip)
    }

    check("project file: an untitled project stores no relative paths") {
        let f = try ProjectFile(project: sampleProject(), savedAt: nil)
        expect(f.clips.allSatisfy { $0.relativePath == nil })
    }

    await checkAsync("project file: load probes files that exist and leaves missing ones without media") {
        let dir = try checksOutputDirectory().appendingPathComponent("pf-load", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("c24.mp4")
        try FileManager.default.copyItem(at: try fixture("c24.mp4"), to: real)
        let clipA = Clip(url: real, segments: [Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))], media: nil)
        let clipB = Clip(url: dir.appendingPathComponent("gone.mp4"), segments: [], media: nil)
        let projectURL = dir.appendingPathComponent("p.slate")
        try ProjectFile(project: Project(clips: [clipA, clipB]), savedAt: projectURL).write(to: projectURL)
        let loaded = try await ProjectFile.load(from: projectURL)
        expect(loaded.clips[0].media != nil, "existing file must be probed")
        expect(loaded.clips[1].media == nil, "missing file has no media")
        expectEqual(loaded.clips.map(\.id), [clipA.id, clipB.id])
    }
}

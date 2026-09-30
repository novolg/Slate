import Foundation
import CoreMedia

public enum ProjectFileError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case notAProject

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "This project was saved by a newer version of Slate (file version \(v))."
        case .notAProject: return "This file is not a Slate project."
        }
    }
}

/// Relative-path helpers for `.slate` files.
public enum PathRelinking {
    /// `file` relative to `directory` ("a.mp4", "sub/a.mp4", "../other/b.mp4").
    public static func relativePath(of file: URL, from directory: URL) -> String {
        let f = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let d = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < f.count, common < d.count, f[common] == d[common] { common += 1 }
        let ups = Array(repeating: "..", count: d.count - common)
        return (ups + f[common...]).joined(separator: "/")
    }

    public static func resolve(relative: String, from directory: URL) -> URL {
        URL(fileURLWithPath: relative, relativeTo: directory).standardizedFileURL
    }
}

/// The `.slate` project file, version 1. JSON, no media, no `constantStrategy`.
public struct ProjectFile: Codable, Equatable {
    public static let currentVersion = 1

    public struct RationalRecord: Codable, Equatable {
        public var num: Int64
        public var den: Int64
    }

    public struct FPSModeRecord: Codable, Equatable {
        /// "mixed" or "constant".
        public var kind: String
        public var frameDuration: RationalRecord?
    }

    public struct SegmentRecord: Codable, Equatable {
        public var id: UUID
        public var start: RationalRecord
        public var end: RationalRecord
        public var isAuto: Bool
    }

    public struct ClipRecord: Codable, Equatable {
        public var id: UUID
        public var relativePath: String?
        public var absolutePath: String
        public var segments: [SegmentRecord]
    }

    public var version: Int
    public var fpsMode: FPSModeRecord
    public var clips: [ClipRecord]

    /// `fileURL` is where the project file lives; nil for an untitled project (no relative paths).
    public init(project: Project, savedAt fileURL: URL?) {
        version = Self.currentVersion
        switch project.fpsMode {
        case .mixed:
            fpsMode = FPSModeRecord(kind: "mixed", frameDuration: nil)
        case .constant(let d):
            fpsMode = FPSModeRecord(kind: "constant", frameDuration: RationalRecord(num: d.num, den: d.den))
        }
        let folder = fileURL?.deletingLastPathComponent()
        clips = project.clips.map { clip in
            ClipRecord(
                id: clip.id,
                relativePath: folder.map { PathRelinking.relativePath(of: clip.url, from: $0) },
                absolutePath: clip.url.resolvingSymlinksInPath().path,
                segments: clip.segments.map { s in
                    let a = Rational(s.start), b = Rational(s.end)
                    return SegmentRecord(id: s.id, start: RationalRecord(num: a.num, den: a.den),
                                         end: RationalRecord(num: b.num, den: b.den), isAuto: s.isAuto)
                })
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProjectFile {
        struct VersionOnly: Decodable { let version: Int }
        guard let v = try? JSONDecoder().decode(VersionOnly.self, from: data) else {
            throw ProjectFileError.notAProject
        }
        guard v.version >= 1 else { throw ProjectFileError.notAProject }
        guard v.version <= currentVersion else { throw ProjectFileError.unsupportedVersion(v.version) }
        let file: ProjectFile
        do {
            file = try JSONDecoder().decode(ProjectFile.self, from: data)
        } catch {
            throw ProjectFileError.notAProject
        }
        try file.validate()
        return file
    }

    /// Reject values that would trap later in `Rational` / `CMTime` construction.
    private func validate() throws {
        func sane(_ r: RationalRecord) -> Bool {
            r.den > 0 && r.den <= Int64(Int32.max) && r.num != Int64.min
        }
        switch fpsMode.kind {
        case "mixed":
            break
        case "constant":
            guard let d = fpsMode.frameDuration, sane(d), d.num > 0 else { throw ProjectFileError.notAProject }
        default:
            throw ProjectFileError.notAProject
        }
        for clip in clips {
            for s in clip.segments {
                guard sane(s.start), sane(s.end) else { throw ProjectFileError.notAProject }
                // start > end via full-width cross products (cannot overflow).
                let l = s.start.num.multipliedFullWidth(by: s.end.den)
                let r = s.end.num.multipliedFullWidth(by: s.start.den)
                if l.high > r.high || (l.high == r.high && l.low > r.low) { throw ProjectFileError.notAProject }
            }
        }
    }

    /// Build the project. Media is not loaded here. Each clip's URL is the relative path next to
    /// `fileURL` if that file exists, else the absolute path (even if missing, so the card can
    /// offer "Locate file…").
    public func project(resolvingFrom fileURL: URL?, exists: (URL) -> Bool) -> Project {
        let folder = fileURL?.deletingLastPathComponent()
        let mode: FPSMode
        if fpsMode.kind == "constant", let d = fpsMode.frameDuration, d.num > 0, d.den > 0 {
            mode = .constant(frameDuration: Rational(d.num, d.den))
        } else {
            mode = .mixed
        }
        let loaded = clips.map { record -> Clip in
            let absolute = URL(fileURLWithPath: record.absolutePath)
            var url = absolute
            if let folder, let relative = record.relativePath {
                let candidate = PathRelinking.resolve(relative: relative, from: folder)
                if exists(candidate) { url = candidate } else if exists(absolute) { url = absolute }
            }
            let segments = record.segments.map { s in
                Segment(range: CMTimeRangeFromTimeToTime(
                            start: Rational(s.start.num, s.start.den).cmTime,
                            end: Rational(s.end.num, s.end.den).cmTime),
                        id: s.id, isAuto: s.isAuto)
            }
            return Clip(id: record.id, url: url, segments: segments, media: nil)
        }
        return Project(clips: loaded, fpsMode: mode)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    /// Read a `.slate` file, resolve the clip paths and probe every file that exists.
    /// A file that cannot be probed keeps `media == nil` (its card shows as missing).
    public static func load(from url: URL) async throws -> Project {
        let file = try decode(try Data(contentsOf: url))
        var project = file.project(resolvingFrom: url, exists: { FileManager.default.fileExists(atPath: $0.path) })
        for i in project.clips.indices where FileManager.default.fileExists(atPath: project.clips[i].url.path) {
            project.clips[i].media = try? await ClipProbe.probe(url: project.clips[i].url)
        }
        return project
    }
}

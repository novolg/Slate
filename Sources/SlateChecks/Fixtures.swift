import Foundation

/// URL of a generated fixture. Skips the check when fixtures were not generated.
func fixture(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/fixtures/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SkipCheck(reason: "missing \(name) — run scripts/make-test-clips.sh")
    }
    return url
}

/// Fresh directory for files written by checks.
func checksOutputDirectory() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/checks-out", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

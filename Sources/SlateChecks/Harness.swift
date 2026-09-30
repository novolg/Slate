import Foundation

/// Minimal assertion harness. XCTest is not available with Command Line Tools.
enum Harness {
    static var passed = 0
    static var failed = 0
    static var skipped = 0
    static var filter: String?
    static var strict = false
    static var currentFailed = false

    static func shouldRun(_ name: String) -> Bool {
        guard let filter else { return true }
        return name.hasPrefix(filter)
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        let strictFailure = strict && skipped > 0
        if strictFailure { print("--strict: \(skipped) skipped check(s) count as a failure") }
        exit(failed == 0 && !strictFailure ? 0 : 1)
    }
}

/// Throw from a check to skip it (for example, when fixtures are missing).
struct SkipCheck: Error {
    let reason: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        Harness.currentFailed = true
        print("    ✗ \(file):\(line) \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        Harness.currentFailed = true
        print("    ✗ \(file):\(line) expected \(expected), got \(actual) \(message())")
    }
}

private func record(_ name: String, error: Error?) {
    if let skip = error as? SkipCheck {
        Harness.skipped += 1
        print("  – \(name) (skipped: \(skip.reason))")
        return
    }
    if let error {
        Harness.currentFailed = true
        print("    ✗ threw: \(error)")
    }
    if Harness.currentFailed {
        Harness.failed += 1
        print("  ✗ \(name)")
    } else {
        Harness.passed += 1
        print("  ✓ \(name)")
    }
}

func check(_ name: String, _ body: () throws -> Void) {
    guard Harness.shouldRun(name) else { return }
    Harness.currentFailed = false
    do { try body(); record(name, error: nil) } catch { record(name, error: error) }
}

func checkAsync(_ name: String, _ body: () async throws -> Void) async {
    guard Harness.shouldRun(name) else { return }
    Harness.currentFailed = false
    do { try await body(); record(name, error: nil) } catch { record(name, error: error) }
}

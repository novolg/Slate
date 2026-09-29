# Multi-clip Core + Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure timing core (exact rationals, frame grid, planner, retimer, time map), the AVFoundation media services (probe, composition, re-encoder, exporter, validator), and the Phase 0 feasibility command. The result is a command-line proof that multi-clip export works in Mixed, Selective and Re-encode-all modes.

**Architecture:** A new SPM library target `SlateCore` holds all logic. The app target `Slate` and a new executable `SlateChecks` depend on it. `SlateChecks` is a tiny assertion harness (XCTest is unavailable without Xcode) and also hosts the `phase0` subcommand. The app UI is NOT changed in this plan, except for moving `Segment` and `KeyframeIndex` into `SlateCore`. UI, project file and autosave are Plan 2, written after the Phase 0 decision.

**Tech Stack:** Swift 5.10 compiler, swift-tools 5.9, SPM, AVFoundation, CoreMedia, CoreVideo. ffmpeg/ffprobe from Homebrew for dev-only test fixtures.

**Spec:** `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md`

## Global Constraints

- macOS 14+ (`platforms: [.macOS(.v14)]`), swift-tools-version 5.9, no Xcode project, no external Swift packages.
- No bundled ffmpeg. ffmpeg/ffprobe (`/opt/homebrew/bin`) are used only by `scripts/make-test-clips.sh` and `scripts/phase0-ffprobe.sh`.
- XCTest is unavailable. All tests run with `swift run SlateChecks [prefix]`. A non-zero exit code means failure.
- In the Claude Code sandbox, `swift build` / `swift run` fail with `xcode-select: error: unable to read data link at '/var/select/developer_dir'`. Run every swift command with the sandbox disabled.
- All timing math uses the exact `Rational` type. No `Double` comparisons for timing. The only tolerance in the design is the retimer `τ` (`FrameTable.pickTolerance`).
- Output container is `.mp4`.
- `SegmentOps` id preservation (`preferredID` in `merge`) is load-bearing. Do not regress it.
- The user's private clips never enter the repo. Fixtures live in `build/fixtures/` (`build/` is gitignored).
- `MASTER_PLAN.md` is gitignored. Update it on disk at the end of the plan. Do not `git add` it.

## Review Focus

1. **Two selections in one clip less than a frame apart** — they must never share a source frame, also after 24→48 retiming and for VFR sources. The start is pushed to the next source boundary. Tests are in Task 4 and Task 6.
2. **Audio track a few ms shorter than video** (ffmpeg `-shortest`) — building the composition must not throw. Re-encoding tolerates a shortfall of at most one AAC packet and throws beyond that. Tests are in Task 10 and Task 11.
3. **A source that fails to decode midway** — the export must fail, never freeze on the last good frame, and remove its partial file. The test is in Task 11.
4. **Cancel or failure with an existing file at the output path** — the old file must stay unchanged, and no temp or staging files may remain. The test is in Task 12.
5. **Output path that is a source reached another way** (symlinked parent, case alias, hard link) — the export must refuse to run and never touch the source. Tests are in Task 12.

---

### Task 1: SlateCore target, check harness, auto segment

**Files:**
- Modify: `Package.swift`
- Move: `Sources/Slate/Models/Segment.swift` → `Sources/SlateCore/Segment.swift`
- Move: `Sources/Slate/Models/KeyframeIndex.swift` → `Sources/SlateCore/KeyframeIndex.swift`
- Modify: `Sources/Slate/ViewModels/EditorViewModel.swift`, `Sources/Slate/Views/TimelineView.swift`, `Sources/Slate/Views/EditorView.swift`, `Sources/Slate/Services/Exporter.swift`, `Sources/Slate/Services/KeyframeScanner.swift` (add `import SlateCore`)
- Modify: `scripts/build-app.sh` (build only the app product)
- Create: `Sources/SlateChecks/Harness.swift`, `Sources/SlateChecks/main.swift`, `Sources/SlateChecks/SegmentChecks.swift`

**Interfaces:**
- Produces: `public struct Segment { id, range, isAuto; init(range:id:isAuto:); static func wholeClip(duration:) }`
- Produces: `public enum SegmentOps { merge, insert, updateRange, remove, isValid, commitMarked(_:into:) }`
- Produces (checks): `check(_:_:)`, `checkAsync(_:_:)`, `expect(_:_:)`, `expectEqual(_:_:_:)`, `SkipCheck`, `Harness.finish()`

- [ ] **Step 1: Split the package**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SlateCore",
            path: "Sources/SlateCore"
        ),
        .executableTarget(
            name: "Slate",
            dependencies: ["SlateCore"],
            path: "Sources/Slate"
        ),
        .executableTarget(
            name: "SlateChecks",
            dependencies: ["SlateCore"],
            path: "Sources/SlateChecks"
        ),
    ]
)
```

Move the two model files:

```bash
mkdir -p Sources/SlateCore Sources/SlateChecks
git mv Sources/Slate/Models/Segment.swift Sources/SlateCore/Segment.swift
git mv Sources/Slate/Models/KeyframeIndex.swift Sources/SlateCore/KeyframeIndex.swift
```

In `scripts/build-app.sh`, change the two build lines so only the app is built:

```bash
echo "→ swift build -c $CONFIG --product $APP_NAME"
swift build -c "$CONFIG" --product "$APP_NAME"
```

- [ ] **Step 2: Write the harness**

Create `Sources/SlateChecks/Harness.swift`:

```swift
import Foundation

/// Minimal assertion harness. XCTest is not available with Command Line Tools.
enum Harness {
    static var passed = 0
    static var failed = 0
    static var skipped = 0
    static var filter: String?
    static var currentFailed = false

    static func shouldRun(_ name: String) -> Bool {
        guard let filter else { return true }
        return name.hasPrefix(filter)
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        exit(failed == 0 ? 0 : 1)
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
```

Create `Sources/SlateChecks/main.swift`:

```swift
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
Harness.filter = arguments.first

runSegmentChecks()

Harness.finish()
```

- [ ] **Step 3: Write the failing segment checks**

Create `Sources/SlateChecks/SegmentChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

private func r(_ a: Double, _ b: Double) -> CMTimeRange {
    CMTimeRangeFromTimeToTime(start: CMTime(seconds: a, preferredTimescale: 600),
                              end: CMTime(seconds: b, preferredTimescale: 600))
}

func runSegmentChecks() {
    check("segments: drag keeps the dragged id through merges") {
        let a = Segment(range: r(0, 1))
        let b = Segment(range: r(2, 3))
        var segs = [a, b]
        // Drag b's start left across a's end in several steps.
        for start in [1.8, 1.4, 1.0, 0.6] {
            segs = SegmentOps.updateRange(of: b.id, to: r(start, 3), in: segs)
            expect(segs.contains { $0.id == b.id }, "dragged id lost at start \(start)")
        }
        expectEqual(segs.count, 1)
    }

    check("segments: first O replaces the auto whole-clip segment") {
        let auto = Segment.wholeClip(duration: CMTime(seconds: 5, preferredTimescale: 600))
        expect(auto.isAuto)
        let out = SegmentOps.commitMarked(r(1, 2), into: [auto])
        expectEqual(out.count, 1)
        expectEqual(out[0].range, r(1, 2))
        expect(!out[0].isAuto)
    }

    check("segments: O without an auto segment inserts and merges") {
        let s = Segment(range: r(0, 1))
        let out = SegmentOps.commitMarked(r(0.5, 2), into: [s])
        expectEqual(out.count, 1)
        expectEqual(out[0].range, r(0, 2))
        let out2 = SegmentOps.commitMarked(r(3, 4), into: out)
        expectEqual(out2.count, 2)
    }

    check("segments: dragging an auto segment edge makes it normal") {
        let auto = Segment.wholeClip(duration: CMTime(seconds: 5, preferredTimescale: 600))
        let out = SegmentOps.updateRange(of: auto.id, to: r(0.5, 5), in: [auto])
        expectEqual(out.count, 1)
        expectEqual(out[0].id, auto.id)
        expect(!out[0].isAuto)
    }

    check("segments: removing the last segment leaves none") {
        let s = Segment(range: r(0, 1))
        expect(SegmentOps.remove(id: s.id, from: [s]).isEmpty)
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `swift run SlateChecks segments`
Expected: build FAILS with errors such as `cannot find 'Segment' in scope` / `type 'Segment' has no member 'wholeClip'`.

- [ ] **Step 5: Make the moved models public and add the auto segment**

Replace `Sources/SlateCore/Segment.swift` with:

```swift
import Foundation
import CoreMedia

public struct Segment: Identifiable, Equatable {
    public let id: UUID
    public var range: CMTimeRange
    /// True only for the automatic "whole clip" segment a new clip starts with.
    public var isAuto: Bool

    public init(range: CMTimeRange, id: UUID = UUID(), isAuto: Bool = false) {
        self.id = id
        self.range = range
        self.isAuto = isAuto
    }

    public var start: CMTime { range.start }
    public var end: CMTime { range.end }
    public var duration: CMTime { range.duration }

    /// The segment a newly added clip gets: the whole clip, marked auto.
    public static func wholeClip(duration: CMTime) -> Segment {
        Segment(range: CMTimeRange(start: .zero, duration: duration), isAuto: true)
    }
}

public enum SegmentOps {
    /// Sort + merge any overlapping/adjacent segments. When merging, the survivor's id is
    /// `preferredID` if either input had it, otherwise the earlier (lower-start) segment's id
    /// is preserved. This is critical for live-drag stability — without preferring the dragged
    /// segment's id, every drag step would replace the segment with a new UUID and the next
    /// mouseDragged call would find nothing to update. A merged segment is never auto.
    public static func merge(_ segments: [Segment], preferredID: UUID? = nil) -> [Segment] {
        let sorted = segments.sorted { CMTimeCompare($0.start, $1.start) < 0 }
        var result: [Segment] = []
        for s in sorted {
            if let last = result.last, CMTimeCompare(s.start, last.end) <= 0 {
                let endCandidate = CMTimeCompare(s.end, last.end) > 0 ? s.end : last.end
                let newRange = CMTimeRangeFromTimeToTime(start: last.start, end: endCandidate)
                let survivorID: UUID
                if let p = preferredID, last.id == p || s.id == p {
                    survivorID = p
                } else {
                    survivorID = last.id
                }
                result[result.count - 1] = Segment(range: newRange, id: survivorID)
            } else {
                result.append(s)
            }
        }
        return result
    }

    /// Insert a new segment, merging with overlapping neighbours.
    public static func insert(_ range: CMTimeRange, into segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else { return segments }
        return merge(segments + [Segment(range: range)])
    }

    /// `O` commit. While the clip holds only its auto whole-clip segment, the marked
    /// range replaces it. Otherwise the range is inserted and merged as before.
    public static func commitMarked(_ range: CMTimeRange, into segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else { return segments }
        if segments.count == 1, segments[0].isAuto {
            return [Segment(range: range)]
        }
        return insert(range, into: segments)
    }

    /// Update the range of segment `id` and re-merge with `id` as the preferred survivor.
    /// The updated segment stops being auto.
    public static func updateRange(of id: UUID, to range: CMTimeRange, in segments: [Segment]) -> [Segment] {
        guard range.duration.seconds > 0 else {
            return segments.filter { $0.id != id }
        }
        let updated = segments.map { seg -> Segment in
            seg.id == id ? Segment(range: range, id: id, isAuto: false) : seg
        }
        return merge(updated, preferredID: id)
    }

    public static func remove(id: UUID, from segments: [Segment]) -> [Segment] {
        segments.filter { $0.id != id }
    }

    public static func isValid(_ segments: [Segment]) -> Bool {
        for i in segments.indices {
            if CMTimeCompare(segments[i].start, segments[i].end) >= 0 { return false }
            if i + 1 < segments.count {
                if CMTimeCompare(segments[i].end, segments[i + 1].start) > 0 { return false }
            }
        }
        return true
    }
}
```

In `Sources/SlateCore/KeyframeIndex.swift`, make the API public: change `struct KeyframeIndex: Equatable {` to `public struct KeyframeIndex: Equatable {`, and add `public` to `let times`, `isEmpty`, `count`, `first`, `last`, `nearest(to:)`, `floor(_:)`, `ceil(_:)`. Add this initializer below `let times`:

```swift
    public init(times: [CMTime]) {
        self.times = times
    }
```

Add `import SlateCore` below the existing imports in each of these app files: `Sources/Slate/ViewModels/EditorViewModel.swift`, `Sources/Slate/Views/TimelineView.swift`, `Sources/Slate/Views/EditorView.swift`, `Sources/Slate/Services/Exporter.swift`, `Sources/Slate/Services/KeyframeScanner.swift`.

- [ ] **Step 6: Run the checks and build the app**

Run: `swift run SlateChecks segments`
Expected: `5 passed, 0 failed, 0 skipped`, exit code 0.

Run: `scripts/build-app.sh debug`
Expected: `✓ built .../build/Slate.app`. The app behaves exactly as before.

- [ ] **Step 7: Commit**

```bash
git add Package.swift scripts/build-app.sh Sources/SlateCore Sources/SlateChecks Sources/Slate
git commit -m "refactor: add SlateCore and SlateChecks targets, auto whole-clip segment"
```

---

### Task 2: Exact `Rational`

**Files:**
- Create: `Sources/SlateCore/Rational.swift`
- Create: `Sources/SlateChecks/RationalChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Produces: `public struct Rational: Hashable, Comparable` with `num`, `den`, `init(_:_:)`, `init(_ time: CMTime)`, `static let zero`, `+ - * /`, `* Int`, `floor()`, `rounded()`, `seconds`, `magnitude`, `cmTime`, `cmTime(timescale:) -> CMTime?`, `static gcd`, `static lcm -> Int64?`, `static frameDuration(fps:)`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/RationalChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

func runRationalChecks() {
    check("rational: normalizes sign and gcd") {
        expectEqual(Rational(2, 4), Rational(1, 2))
        expectEqual(Rational(-1, -2), Rational(1, 2))
        expectEqual(Rational(1, -2), Rational(-1, 2))
        expectEqual(Rational(0, 7), Rational.zero)
    }

    check("rational: arithmetic is exact") {
        expectEqual(Rational(1, 24) + Rational(1, 48), Rational(1, 16))
        expectEqual(Rational(1, 24) - Rational(1, 48), Rational(1, 48))
        expectEqual(Rational(1001, 24000) * 240, Rational(1001, 100))
        expectEqual(Rational(5, 24) / Rational(1, 48), Rational(10))
        expect(Rational(1, 3) < Rational(1, 2))
        expect(Rational(-1, 2) < Rational.zero)
    }

    check("rational: floor and round-half-up") {
        expectEqual(Rational(-1, 2).floor(), -1)
        expectEqual(Rational(7, 2).floor(), 3)
        expectEqual(Rational(5, 2).rounded(), 3)
        expectEqual(Rational(1, 2).rounded(), 1)
        expectEqual(Rational(-1, 2).rounded(), 0)
        expectEqual(Rational(149, 100).rounded(), 1)
    }

    check("rational: CMTime conversion") {
        expectEqual(Rational(CMTime(value: 1001, timescale: 24000)), Rational(1001, 24000))
        expectEqual(Rational(1, 24).cmTime(timescale: 12288), CMTime(value: 512, timescale: 12288))
        expect(Rational(1, 7).cmTime(timescale: 12288) == nil)
        expectEqual(Rational(3, 2).cmTime, CMTime(value: 3, timescale: 2))
    }

    check("rational: frame duration from fps") {
        expectEqual(Rational.frameDuration(fps: 23.976), Rational(1001, 24000))
        expectEqual(Rational.frameDuration(fps: 29.97), Rational(1001, 30000))
        expectEqual(Rational.frameDuration(fps: 24), Rational(1, 24))
        expectEqual(Rational.frameDuration(fps: 48.0), Rational(1, 48))
    }

    check("rational: gcd and lcm") {
        expectEqual(Rational.gcd(12288, 24), 24)
        expectEqual(Rational.lcm(12288, 24), 12288)
        expectEqual(Rational.lcm(24000, 90000), 360000)
        expect(Rational.lcm(Int64.max / 2, Int64.max / 3) == nil)
    }
}
```

In `Sources/SlateChecks/main.swift`, add `runRationalChecks()` on the line after `runSegmentChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks rational`
Expected: build FAILS with `cannot find 'Rational' in scope`.

- [ ] **Step 3: Implement `Rational`**

Create `Sources/SlateCore/Rational.swift`:

```swift
import Foundation
import CoreMedia

/// Exact rational number for all timing math. Always reduced, denominator > 0.
/// Overflow is a programming error (values here are small: seconds × timescales).
public struct Rational: Hashable, Comparable, CustomStringConvertible {
    public let num: Int64
    public let den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) {
        precondition(den != 0, "Rational: zero denominator")
        let sign: Int64 = den < 0 ? -1 : 1
        let g = Rational.gcd(Swift.abs(num), Swift.abs(den))
        let divisor = g == 0 ? 1 : g
        self.num = sign * (num / divisor)
        self.den = sign * (den / divisor)
    }

    public init(_ time: CMTime) {
        precondition(time.isNumeric, "Rational: non-numeric CMTime \(time)")
        self.init(time.value, Int64(time.timescale))
    }

    public static let zero = Rational(0)

    public static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = Swift.abs(a)
        var y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Least common multiple, or nil on overflow.
    public static func lcm(_ a: Int64, _ b: Int64) -> Int64? {
        if a == 0 || b == 0 { return 0 }
        let (r, overflow) = (Swift.abs(a) / gcd(a, b)).multipliedReportingOverflow(by: Swift.abs(b))
        return overflow ? nil : r
    }

    private static func mul(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        precondition(!o, "Rational overflow")
        return r
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        precondition(!o, "Rational overflow")
        return r
    }

    public static func + (l: Rational, r: Rational) -> Rational {
        let g = gcd(l.den, r.den)
        let lScale = r.den / g
        let rScale = l.den / g
        return Rational(add(mul(l.num, lScale), mul(r.num, rScale)), mul(l.den, lScale))
    }

    public static prefix func - (x: Rational) -> Rational { Rational(-x.num, x.den) }

    public static func - (l: Rational, r: Rational) -> Rational { l + (-r) }

    public static func * (l: Rational, r: Rational) -> Rational {
        let g1 = gcd(l.num, r.den)
        let g2 = gcd(r.num, l.den)
        let a = g1 == 0 ? 1 : g1
        let b = g2 == 0 ? 1 : g2
        return Rational(mul(l.num / a, r.num / b), mul(l.den / b, r.den / a))
    }

    public static func * (l: Rational, n: Int) -> Rational { l * Rational(Int64(n)) }

    public static func / (l: Rational, r: Rational) -> Rational {
        precondition(r.num != 0, "Rational: division by zero")
        return l * Rational(r.den, r.num)
    }

    public static func < (l: Rational, r: Rational) -> Bool { (l - r).num < 0 }

    /// Largest integer ≤ self.
    public func floor() -> Int64 {
        let q = num / den
        return (num % den != 0 && num < 0) ? q - 1 : q
    }

    /// Round half up: floor(self + 1/2).
    public func rounded() -> Int64 { (self + Rational(1, 2)).floor() }

    public var magnitude: Rational { Rational(Swift.abs(num), den) }

    public var seconds: Double { Double(num) / Double(den) }

    /// CMTime with the reduced denominator as timescale.
    public var cmTime: CMTime {
        precondition(den <= Int64(Int32.max), "Rational: denominator too large for CMTime")
        return CMTime(value: num, timescale: Int32(den))
    }

    /// CMTime in `timescale`, or nil if self is not a whole number of ticks.
    public func cmTime(timescale: Int32) -> CMTime? {
        let scaled = self * Rational(Int64(timescale))
        guard scaled.den == 1 else { return nil }
        return CMTime(value: scaled.num, timescale: timescale)
    }

    /// Exact frame duration for a nominal fps (handles NTSC rates).
    public static func frameDuration(fps: Double) -> Rational {
        let ntsc: [(Int64, Int64)] = [(24000, 1001), (30000, 1001), (48000, 1001), (60000, 1001), (120000, 1001)]
        for (n, d) in ntsc where Swift.abs(fps - Double(n) / Double(d)) < 0.001 {
            return Rational(d, n)
        }
        let whole = fps.rounded()
        if whole > 0, Swift.abs(fps - whole) < 0.001 {
            return Rational(1, Int64(whole))
        }
        return Rational(1000, Int64((fps * 1000).rounded()))
    }

    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks rational`
Expected: `6 passed, 0 failed, 0 skipped`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/Rational.swift Sources/SlateChecks/RationalChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): exact Rational for timing math"
```

---

### Task 3: `FrameTable` — boundaries, exact CFR, pick tolerance

**Files:**
- Create: `Sources/SlateCore/FrameTable.swift`
- Create: `Sources/SlateChecks/TestData.swift`
- Create: `Sources/SlateChecks/FrameTableChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `Rational` (Task 2).
- Produces: `public struct FrameTable: Equatable { pts, durations, timescale, init(pts:durations:timescale:), static uniform(count:frameDuration:timescale:start:), count, clipEnd, boundaries, exactFrameDuration: Rational?, pickTolerance: Rational, nearestBoundaryIndex(to:) -> Int, lastFrameIndex(atOrBefore:) -> Int?, firstBoundaryIndex(atOrAfter:) -> Int }`
- Produces (checks): `TestData.jittered23976(count:)`, `TestData.drift(first:second:count:)`.

- [ ] **Step 1: Write the test data helpers**

Create `Sources/SlateChecks/TestData.swift`:

```swift
import Foundation
import SlateCore

enum TestData {
    /// 23.976 fps stored at timescale 90000: ticks_k = round(k · 3753.75), so
    /// durations alternate 3753/3754. Not exact CFR.
    static func jittered23976(count: Int) -> FrameTable {
        let step = Rational(15015, 4) // 90000 · 1001 / 24000 = 3753.75 ticks
        let ticks = (0...count).map { (Rational(Int64($0)) * step).rounded() }
        let pts = (0..<count).map { Rational(ticks[$0], 90000) }
        let durations = (0..<count).map { Rational(ticks[$0 + 1] - ticks[$0], 90000) }
        return FrameTable(pts: pts, durations: durations, timescale: 90000)
    }

    /// Ideal rational 23.976 source (exact CFR at 1001/24000).
    static func ideal23976(count: Int) -> FrameTable {
        FrameTable.uniform(count: count, frameDuration: Rational(1001, 24000), timescale: 24000)
    }

    /// `count` frames of `first` ticks then `count` frames of `second` ticks (timescale 90000).
    static func drift(first: Int64, second: Int64, count: Int) -> FrameTable {
        var pts: [Rational] = []
        var durations: [Rational] = []
        var t: Int64 = 0
        for i in 0..<(2 * count) {
            let d = i < count ? first : second
            pts.append(Rational(t, 90000))
            durations.append(Rational(d, 90000))
            t += d
        }
        return FrameTable(pts: pts, durations: durations, timescale: 90000)
    }
}
```

- [ ] **Step 2: Write the failing checks**

Create `Sources/SlateChecks/FrameTableChecks.swift`:

```swift
import Foundation
import SlateCore

func runFrameTableChecks() {
    let five24 = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)

    check("frametable: boundaries include clip end") {
        expectEqual(five24.clipEnd, Rational(5, 24))
        expectEqual(five24.boundaries.count, 6)
        expectEqual(five24.boundaries.last, Rational(5, 24))
    }

    check("frametable: exact CFR detection") {
        expectEqual(five24.exactFrameDuration, Rational(1, 24))
        expectEqual(TestData.ideal23976(count: 240).exactFrameDuration, Rational(1001, 24000))
        expect(TestData.jittered23976(count: 240).exactFrameDuration == nil, "jittered 23.976 must not be exact")
        expect(TestData.drift(first: 3754, second: 3753, count: 100).exactFrameDuration == nil)
        // Equal durations but a hole in the pts sequence is not CFR either.
        let holed = FrameTable(pts: [Rational(0), Rational(1, 24), Rational(3, 24)],
                               durations: Array(repeating: Rational(1, 24), count: 3), timescale: 24)
        expect(holed.exactFrameDuration == nil)
    }

    check("frametable: pick tolerance is one tick only when a tick is ≤ 1% of a frame") {
        expectEqual(five24.pickTolerance, Rational.zero)
        expectEqual(TestData.jittered23976(count: 10).pickTolerance, Rational(1, 90000))
        expectEqual(FrameTable.uniform(count: 3, frameDuration: Rational(1, 24), timescale: 12288).pickTolerance,
                    Rational(1, 12288))
    }

    check("frametable: nearest boundary, ties go earlier") {
        expectEqual(five24.nearestBoundaryIndex(to: Rational(5, 24)), 5)
        expectEqual(five24.nearestBoundaryIndex(to: Rational(1, 5)), 5)     // 0.2 is nearer 5/24 than 4/24
        expectEqual(five24.nearestBoundaryIndex(to: Rational(1, 48)), 0)    // exact tie → earlier
        expectEqual(five24.nearestBoundaryIndex(to: Rational(-1)), 0)
        expectEqual(five24.nearestBoundaryIndex(to: Rational(10)), 5)
    }

    check("frametable: last frame at or before") {
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(1, 48)), 0)
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(1, 24)), 1)
        expect(five24.lastFrameIndex(atOrBefore: Rational(-1, 100)) == nil)
        expectEqual(five24.lastFrameIndex(atOrBefore: Rational(99)), 4)
    }

    check("frametable: first boundary at or after") {
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(1, 16)), 2)   // 1/16 is between 1/24 and 2/24
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(1, 24)), 1)   // exact boundary
        expectEqual(five24.firstBoundaryIndex(atOrAfter: .zero), 0)
        expectEqual(five24.firstBoundaryIndex(atOrAfter: Rational(9)), 5)      // clamps to clip end
    }
}
```

In `main.swift`, add `runFrameTableChecks()` after `runRationalChecks()`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run SlateChecks frametable`
Expected: build FAILS with `cannot find 'FrameTable' in scope`.

- [ ] **Step 4: Implement `FrameTable`**

Create `Sources/SlateCore/FrameTable.swift`:

```swift
import Foundation

/// Actual video sample timing of one clip, in presentation order.
public struct FrameTable: Equatable {
    public let pts: [Rational]
    public let durations: [Rational]
    /// Track timescale (ticks per second) the times came from.
    public let timescale: Int32

    public init(pts: [Rational], durations: [Rational], timescale: Int32) {
        precondition(!pts.isEmpty && pts.count == durations.count, "FrameTable: bad input")
        self.pts = pts
        self.durations = durations
        self.timescale = timescale
    }

    public static func uniform(count: Int, frameDuration: Rational, timescale: Int32,
                               start: Rational = .zero) -> FrameTable {
        FrameTable(pts: (0..<count).map { start + frameDuration * $0 },
                   durations: Array(repeating: frameDuration, count: count),
                   timescale: timescale)
    }

    public var count: Int { pts.count }

    public var clipEnd: Rational { pts[pts.count - 1] + durations[durations.count - 1] }

    /// Valid cut points: every frame start plus the clip end.
    public var boundaries: [Rational] { pts + [clipEnd] }

    /// The frame duration when every duration and every pts gap are exactly equal. No tolerance.
    public var exactFrameDuration: Rational? {
        let d = durations[0]
        guard d > .zero else { return nil }
        for i in 0..<count {
            if durations[i] != d { return nil }
            if i + 1 < count, pts[i + 1] - pts[i] != d { return nil }
        }
        return d
    }

    /// Retimer tolerance τ: one tick when a tick is at most 1% of the shortest frame, else 0.
    public var pickTolerance: Rational {
        let tick = Rational(1, Int64(timescale))
        guard let shortest = durations.min() else { return .zero }
        return tick * 100 <= shortest ? tick : .zero
    }

    /// Index into `boundaries` (0...count) nearest to `t`. Ties go to the earlier boundary.
    public func nearestBoundaryIndex(to t: Rational) -> Int {
        let b = boundaries
        var lo = 0
        var hi = b.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if b[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == b.count { return b.count - 1 }
        return (t - b[lo - 1]) <= (b[lo] - t) ? lo - 1 : lo
    }

    /// Largest frame index whose pts ≤ `t`, or nil if `t` is before the first frame.
    public func lastFrameIndex(atOrBefore t: Rational) -> Int? {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Smallest index into `boundaries` whose value is ≥ `t` (count when `t` > clipEnd is clamped to count).
    public func firstBoundaryIndex(atOrAfter t: Rational) -> Int {
        let b = boundaries
        var lo = 0
        var hi = b.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if b[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, b.count - 1)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run SlateChecks frametable`
Expected: `6 passed, 0 failed, 0 skipped`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/FrameTable.swift Sources/SlateChecks/TestData.swift Sources/SlateChecks/FrameTableChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): FrameTable with exact CFR check and boundary snapping"
```

---

### Task 4: Project models and `FrameGrid` (one quantization policy)

**Files:**
- Create: `Sources/SlateCore/ProjectModel.swift`
- Create: `Sources/SlateCore/FrameGrid.swift`
- Create: `Sources/SlateChecks/FrameGridChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `Rational`, `FrameTable`, `Segment`.
- Produces: `public enum FPSMode { case mixed; case constant(frameDuration: Rational) }`, `public enum ConstantStrategy { case selective, reencodeAll }`, `public struct AudioFormat { sampleRate: Double; channels: Int }`, `public struct ClipMedia { frames, width, height, codec: FourCharCode, nominalFPS, estimatedDataRate: Float, audio: AudioFormat?, hasAudio }`, `public struct Clip { id, url, segments, media: ClipMedia? }`, `public struct Project { clips, fpsMode, constantStrategy }`, `public func fourCC(_:) -> FourCharCode`.
- Produces: `public struct GridSegment { clipID, segmentID, sourceStart, frameCount, outputStart, outputDuration, sourceEnd, outputEnd }`, `public struct QuantizedRange`, `public enum FrameGrid { quantize(start:end:frames:unit:notBefore:) -> QuantizedRange?; struct ClipInput; struct Result { segments, dropped, totalDuration, totalFrames }; build(_:mode:) -> Result }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/FrameGridChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

private func seg(_ a: Rational, _ b: Rational) -> Segment {
    Segment(range: CMTimeRange(start: a.cmTime, end: b.cmTime))
}

private func input(_ frames: FrameTable, _ segs: [Segment]) -> FrameGrid.ClipInput {
    FrameGrid.ClipInput(clipID: UUID(), frames: frames, segments: segs)
}

/// Deterministic pseudo-random generator for property checks.
struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

func runFrameGridChecks() {
    let c24 = FrameTable.uniform(count: 120, frameDuration: Rational(1, 24), timescale: 12288)
    let c48 = FrameTable.uniform(count: 240, frameDuration: Rational(1, 48), timescale: 12288)
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
    let d48 = FPSMode.constant(frameDuration: Rational(1, 48))

    check("framegrid: constant full clip keeps every frame") {
        let r = FrameGrid.build([input(c24, [seg(.zero, Rational(5))])], mode: d24)
        expectEqual(r.segments.count, 1)
        expectEqual(r.segments[0].frameCount, 120)
        expectEqual(r.totalDuration, Rational(5))
        let r48 = FrameGrid.build([input(c24, [seg(.zero, Rational(5))])], mode: d48)
        expectEqual(r48.segments[0].frameCount, 240)
    }

    check("framegrid: mixed full 5-frame clip keeps all 5 frames") {
        let five = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)
        let r = FrameGrid.build([input(five, [seg(.zero, five.clipEnd)])], mode: .mixed)
        expectEqual(r.totalFrames, 5)
        let jit = TestData.jittered23976(count: 50)
        let rj = FrameGrid.build([input(jit, [seg(.zero, jit.clipEnd)])], mode: .mixed)
        expectEqual(rj.totalFrames, 50)
        expectEqual(rj.totalDuration, jit.clipEnd)
    }

    check("framegrid: selection shorter than one frame is dropped") {
        let s = seg(.zero, Rational(1, 100))
        let r = FrameGrid.build([input(c24, [s])], mode: d24)
        expect(r.segments.isEmpty)
        expectEqual(r.dropped, [s.id])
        expectEqual(r.totalFrames, 0)
    }

    check("framegrid: clamps at clip end") {
        let r = FrameGrid.build([input(c24, [seg(Rational(49, 10), Rational(53, 10))])], mode: d24)
        expectEqual(r.segments.count, 1)
        expectEqual(r.segments[0].sourceStart, Rational(118, 24))
        expectEqual(r.segments[0].frameCount, 2)
        expect(r.segments[0].sourceEnd <= c24.clipEnd)
    }

    check("framegrid: gaps between kept ranges are skipped") {
        let six = FrameTable.uniform(count: 144, frameDuration: Rational(1, 24), timescale: 12288)
        let r = FrameGrid.build([input(six, [seg(Rational(2), Rational(3)), seg(Rational(4), Rational(5))])], mode: d48)
        expectEqual(r.segments.map(\.outputStart), [Rational(0), Rational(1)])
        expectEqual(r.segments.map(\.sourceStart), [Rational(2), Rational(4)])
        expectEqual(r.segments.map(\.frameCount), [48, 48])
    }

    check("framegrid: adjacent selections never share a frame") {
        // s1 snaps up to 1/24 and rounds to 2 frames → ends at 3/24.
        // s2 starts at 0.085, whose nearest boundary 2/24 is inside s1's output.
        let s1 = seg(Rational(21, 1000), Rational(84, 1000))
        let s2 = seg(Rational(85, 1000), Rational(1))
        let r = FrameGrid.build([input(c24, [s1, s2])], mode: d24)
        expectEqual(r.segments.count, 2)
        expect(r.segments[1].sourceStart >= r.segments[0].sourceEnd,
               "second starts at \(r.segments[1].sourceStart), first ends at \(r.segments[0].sourceEnd)")
    }

    check("framegrid: a pushed start lands on a source boundary") {
        let s1 = seg(Rational(21, 1000), Rational(51, 1000))
        let s2 = seg(Rational(52, 1000), Rational(100, 1000))
        let r = FrameGrid.build([input(c24, [s1, s2])], mode: d48)
        expectEqual(r.segments.count, 2)
        expectEqual(r.segments[1].sourceStart, Rational(2, 24))
        expectEqual(r.segments[1].frameCount, 2, "pushing the start keeps N")
    }

    check("framegrid: constant offsets are multiples of d (random projects)") {
        var rng = LCG(state: 42)
        for _ in 0..<200 {
            var clips: [FrameGrid.ClipInput] = []
            for _ in 0..<(1 + rng.next(4)) {
                let frames = rng.next(2) == 0 ? c24 : c48
                var segs: [Segment] = []
                var t = Rational(Int64(rng.next(50)), 100)
                while t < Rational(5) {
                    let len = Rational(Int64(1 + rng.next(150)), 100)
                    segs.append(seg(t, min(t + len, Rational(5))))
                    t = t + len + Rational(Int64(1 + rng.next(80)), 100)
                }
                clips.append(input(frames, segs))
            }
            let r = FrameGrid.build(clips, mode: d24)
            for g in r.segments {
                expectEqual((g.outputStart / Rational(1, 24)).den, 1)
                expectEqual(g.outputDuration, Rational(1, 24) * g.frameCount)
            }
        }
    }

    check("framegrid: 23.976 rational math") {
        let ideal = TestData.ideal23976(count: 240)
        let r = FrameGrid.build([input(ideal, [seg(.zero, ideal.clipEnd)])],
                                mode: .constant(frameDuration: Rational(1001, 24000)))
        expectEqual(r.totalFrames, 240)
        expectEqual(r.totalDuration, Rational(1001, 100))
    }
}
```

In `main.swift`, add `runFrameGridChecks()` after `runFrameTableChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks framegrid`
Expected: build FAILS with `cannot find 'FrameGrid' in scope` and `cannot find 'FPSMode' in scope`.

- [ ] **Step 3: Implement the models**

Create `Sources/SlateCore/ProjectModel.swift`:

```swift
import Foundation
import CoreMedia

public enum FPSMode: Equatable {
    case mixed
    /// Constant output cadence with this exact frame duration (1/24, 1001/24000, …).
    case constant(frameDuration: Rational)
}

public enum ConstantStrategy: Equatable {
    case selective
    case reencodeAll
}

public struct AudioFormat: Equatable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Probed facts about one clip file.
public struct ClipMedia: Equatable {
    public var frames: FrameTable
    public var width: Int
    public var height: Int
    public var codec: FourCharCode
    public var nominalFPS: Double
    /// Bits per second, as reported by the track.
    public var estimatedDataRate: Float
    public var audio: AudioFormat?

    public init(frames: FrameTable, width: Int, height: Int, codec: FourCharCode,
                nominalFPS: Double, estimatedDataRate: Float, audio: AudioFormat?) {
        self.frames = frames
        self.width = width
        self.height = height
        self.codec = codec
        self.nominalFPS = nominalFPS
        self.estimatedDataRate = estimatedDataRate
        self.audio = audio
    }

    public var hasAudio: Bool { audio != nil }
}

public struct Clip: Identifiable, Equatable {
    public let id: UUID
    public var url: URL
    public var segments: [Segment]
    /// nil when the file is missing or unreadable.
    public var media: ClipMedia?

    public init(id: UUID = UUID(), url: URL, segments: [Segment], media: ClipMedia?) {
        self.id = id
        self.url = url
        self.segments = segments
        self.media = media
    }
}

public struct Project: Equatable {
    public var clips: [Clip]
    public var fpsMode: FPSMode
    public var constantStrategy: ConstantStrategy

    public init(clips: [Clip] = [], fpsMode: FPSMode = .mixed, constantStrategy: ConstantStrategy = .selective) {
        self.clips = clips
        self.fpsMode = fpsMode
        self.constantStrategy = constantStrategy
    }
}

/// "avc1" → FourCharCode.
public func fourCC(_ s: String) -> FourCharCode {
    precondition(s.utf8.count == 4, "fourCC needs 4 ASCII characters")
    return s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
```

- [ ] **Step 4: Implement `FrameGrid`**

Create `Sources/SlateCore/FrameGrid.swift`:

```swift
import Foundation
import CoreMedia

/// One kept range after quantization, placed on the output timeline.
public struct GridSegment: Equatable {
    public let clipID: UUID
    public let segmentID: UUID
    /// s' — where reading starts in the source clip.
    public let sourceStart: Rational
    /// N — output frames for this range.
    public let frameCount: Int
    /// O_k — where this range starts in the output.
    public let outputStart: Rational
    /// N · d (Constant), N · srcD (Mixed exact CFR), or e' − s' (Mixed non-exact).
    public let outputDuration: Rational

    public init(clipID: UUID, segmentID: UUID, sourceStart: Rational, frameCount: Int,
                outputStart: Rational, outputDuration: Rational) {
        self.clipID = clipID
        self.segmentID = segmentID
        self.sourceStart = sourceStart
        self.frameCount = frameCount
        self.outputStart = outputStart
        self.outputDuration = outputDuration
    }

    /// Source and output ranges always have the same length.
    public var sourceEnd: Rational { sourceStart + outputDuration }
    public var outputEnd: Rational { outputStart + outputDuration }
}

public struct QuantizedRange: Equatable {
    public let sourceStart: Rational
    public let frameCount: Int
    public let duration: Rational
}

/// The single quantization policy. It runs before any copy/re-encode decision,
/// so the export strategy can never change the edit.
public enum FrameGrid {
    /// Quantize one kept range `[s, e)`.
    /// - unit: d in Constant mode, the clip's exact srcD in Mixed mode, nil for a
    ///   non-exact-CFR clip in Mixed mode.
    /// - notBefore: end of the previous quantized range of the same clip. The start
    ///   is pushed to the first source-frame boundary at or after it, so two
    ///   selections never share a source frame (also at 24→48 and for VFR).
    ///   Pushing the start keeps the wanted frame count N (the output length the user
    ///   selected); only the clip-end clamp can shorten it.
    public static func quantize(start s: Rational, end e: Rational, frames: FrameTable,
                                unit: Rational?, notBefore: Rational = .zero) -> QuantizedRange? {
        let b = frames.boundaries
        let floorIndex = frames.firstBoundaryIndex(atOrAfter: notBefore)
        let a = max(frames.nearestBoundaryIndex(to: s), floorIndex)
        if let unit {
            let sp = b[a]
            let wanted = ((e - s) / unit).rounded()
            let fits = ((frames.clipEnd - sp) / unit).floor()
            let n = min(wanted, fits)
            guard n > 0 else { return nil }
            return QuantizedRange(sourceStart: sp, frameCount: Int(n), duration: unit * Int(n))
        }
        let z = frames.nearestBoundaryIndex(to: e)
        guard z > a else { return nil }
        return QuantizedRange(sourceStart: b[a], frameCount: z - a, duration: b[z] - b[a])
    }

    public struct ClipInput {
        public let clipID: UUID
        public let frames: FrameTable
        public let segments: [Segment]

        public init(clipID: UUID, frames: FrameTable, segments: [Segment]) {
            self.clipID = clipID
            self.frames = frames
            self.segments = segments
        }
    }

    public struct Result: Equatable {
        public let segments: [GridSegment]
        /// Ids of kept segments that quantized to zero frames.
        public let dropped: [UUID]
        public let totalDuration: Rational

        public var totalFrames: Int { segments.reduce(0) { $0 + $1.frameCount } }
    }

    public static func build(_ clips: [ClipInput], mode: FPSMode) -> Result {
        var out: [GridSegment] = []
        var dropped: [UUID] = []
        var cursor = Rational.zero
        for clip in clips {
            let unit: Rational?
            switch mode {
            case .constant(let d): unit = d
            case .mixed: unit = clip.frames.exactFrameDuration
            }
            var notBefore = Rational.zero
            let sorted = clip.segments.sorted { CMTimeCompare($0.start, $1.start) < 0 }
            for seg in sorted {
                guard let q = quantize(start: Rational(seg.start), end: Rational(seg.end),
                                       frames: clip.frames, unit: unit, notBefore: notBefore) else {
                    dropped.append(seg.id)
                    continue
                }
                out.append(GridSegment(clipID: clip.clipID, segmentID: seg.id, sourceStart: q.sourceStart,
                                       frameCount: q.frameCount, outputStart: cursor, outputDuration: q.duration))
                cursor = cursor + q.duration
                notBefore = q.sourceStart + q.duration
            }
        }
        return Result(segments: out, dropped: dropped, totalDuration: cursor)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run SlateChecks framegrid`
Expected: `9 passed, 0 failed, 0 skipped`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/ProjectModel.swift Sources/SlateCore/FrameGrid.swift Sources/SlateChecks/FrameGridChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): project models and FrameGrid quantization"
```

---

### Task 5: `ExportPlanner`

**Files:**
- Create: `Sources/SlateCore/ExportPlanner.swift`
- Create: `Sources/SlateChecks/PlannerChecks.swift`
- Modify: `Sources/SlateChecks/TestData.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: models, `FrameGrid` (Task 4).
- Produces: `public enum ReencodeReason { fpsDiffers, timingNotExact, reencodeAll }`, `public enum BlockReason { missingFile, frameSizeMismatch, codecMismatch, audioMismatch }`, `public enum ClipAction { copy, reencode(ReencodeReason), skipped, blocked(BlockReason) }`, `public struct ClipPlan { clipID, action, segments: [GridSegment], droppedSegmentIDs: [UUID], frameCount }`, `public enum PlanBlocker { noClips, noFrames, clip(UUID, BlockReason), timescaleOverflow }`, `public struct ExportPlan { mode, strategy, clips, grid, totalDuration, totalFrames, outputTimescale: Int32, hasAudio, audio: AudioFormat?, reference: ClipMedia?, blockers, canExport, frameDuration: Rational?, plan(for:) }`, `public enum ExportPlanner { static func plan(_ project: Project) -> ExportPlan }`.

- [ ] **Step 1: Add media test helpers**

Add `import CoreMedia` to the import lines at the top of `Sources/SlateChecks/TestData.swift`. Then append:

```swift
extension TestData {
    static func media(_ frames: FrameTable, width: Int = 640, height: Int = 360,
                      codec: String = "avc1", audio: Bool = false) -> ClipMedia {
        ClipMedia(frames: frames, width: width, height: height, codec: fourCC(codec),
                  nominalFPS: 1 / frames.durations[0].seconds, estimatedDataRate: 2_000_000,
                  audio: audio ? AudioFormat(sampleRate: 44100, channels: 1) : nil)
    }

    static func clip(_ media: ClipMedia?, keep ranges: [(Rational, Rational)]) -> Clip {
        Clip(url: URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).mp4"),
             segments: ranges.map { Segment(range: CMTimeRange(start: $0.0.cmTime, end: $0.1.cmTime)) },
             media: media)
    }

    static let c24 = FrameTable.uniform(count: 120, frameDuration: Rational(1, 24), timescale: 12288)
    static let c48 = FrameTable.uniform(count: 240, frameDuration: Rational(1, 48), timescale: 12288)
}
```

- [ ] **Step 2: Write the failing checks**

Create `Sources/SlateChecks/PlannerChecks.swift`:

```swift
import Foundation
import SlateCore

func runPlannerChecks() {
    let whole = [(Rational.zero, Rational(5))]
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))

    check("planner: constant 24 copies exact 24 and re-encodes 48") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: d24))
        expect(plan.canExport, "\(plan.blockers)")
        expectEqual(plan.plan(for: a.id)?.action, .copy)
        expectEqual(plan.plan(for: b.id)?.action, .reencode(.fpsDiffers))
        expectEqual(plan.outputTimescale, 12288)
        expectEqual(plan.totalFrames, 240)
    }

    check("planner: jittered 23.976 re-encodes in constant, copies in mixed") {
        let jit = TestData.jittered23976(count: 240)
        let c = TestData.clip(TestData.media(jit), keep: [(.zero, jit.clipEnd)])
        let constant = ExportPlanner.plan(Project(clips: [c], fpsMode: .constant(frameDuration: Rational(1001, 24000))))
        expectEqual(constant.plan(for: c.id)?.action, .reencode(.timingNotExact))
        expectEqual(constant.outputTimescale, 360000)
        let mixed = ExportPlanner.plan(Project(clips: [c], fpsMode: .mixed))
        expectEqual(mixed.plan(for: c.id)?.action, .copy)
    }

    check("planner: drift clip (3754 then 3753 ticks) re-encodes in constant") {
        let drift = TestData.drift(first: 3754, second: 3753, count: 100)
        let c = TestData.clip(TestData.media(drift), keep: [(.zero, drift.clipEnd)])
        let plan = ExportPlanner.plan(Project(clips: [c], fpsMode: .constant(frameDuration: Rational(1001, 24000))))
        expectEqual(plan.plan(for: c.id)?.action, .reencode(.timingNotExact))
    }

    check("planner: re-encode all gives the same grid as selective (random projects)") {
        var rng = LCG(state: 7)
        for _ in 0..<100 {
            var clips: [Clip] = []
            for _ in 0..<(1 + rng.next(4)) {
                let frames = rng.next(2) == 0 ? TestData.c24 : TestData.c48
                let s = Rational(Int64(rng.next(300)), 100)
                let e = s + Rational(Int64(rng.next(250)), 100)
                clips.append(TestData.clip(TestData.media(frames), keep: [(s, min(e, Rational(5)))]))
            }
            let sel = ExportPlanner.plan(Project(clips: clips, fpsMode: d24, constantStrategy: .selective))
            let all = ExportPlanner.plan(Project(clips: clips, fpsMode: d24, constantStrategy: .reencodeAll))
            expectEqual(sel.grid, all.grid)
            for cp in all.clips where !cp.segments.isEmpty {
                expectEqual(cp.action, .reencode(.reencodeAll))
            }
        }
    }

    check("planner: blocks missing file, size, codec and audio mismatch") {
        let ref = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let missing = TestData.clip(nil, keep: whole)
        let small = TestData.clip(TestData.media(TestData.c24, width: 320, height: 180), keep: whole)
        let hevc = TestData.clip(TestData.media(TestData.c24, codec: "hvc1"), keep: whole)
        let loud = TestData.clip(TestData.media(TestData.c24, audio: true), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [missing, ref, small, hevc, loud], fpsMode: .mixed))
        expect(!plan.canExport)
        expectEqual(plan.plan(for: missing.id)?.action, .blocked(.missingFile))
        expectEqual(plan.plan(for: ref.id)?.action, .copy)
        expectEqual(plan.plan(for: small.id)?.action, .blocked(.frameSizeMismatch))
        expectEqual(plan.plan(for: hevc.id)?.action, .blocked(.codecMismatch))
        expectEqual(plan.plan(for: loud.id)?.action, .blocked(.audioMismatch))
        expect(plan.blockers.contains(.clip(missing.id, .missingFile)))
    }

    check("planner: clip with no segments is skipped, not blocked") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
        let plan = ExportPlanner.plan(Project(clips: [a, empty], fpsMode: d24))
        expect(plan.canExport)
        expectEqual(plan.plan(for: empty.id)?.action, .skipped)
    }

    check("planner: only a sub-frame selection blocks with noFrames in every strategy") {
        let c = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1, 100))])
        for strategy in [ConstantStrategy.selective, .reencodeAll] {
            let plan = ExportPlanner.plan(Project(clips: [c], fpsMode: d24, constantStrategy: strategy))
            expect(plan.blockers.contains(.noFrames), "\(strategy)")
            expectEqual(plan.plan(for: c.id)?.droppedSegmentIDs, c.segments.map(\.id))
        }
        expect(ExportPlanner.plan(Project()).blockers.contains(.noClips))
    }
}
```

In `main.swift`, add `runPlannerChecks()` after `runFrameGridChecks()`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run SlateChecks planner`
Expected: build FAILS with `cannot find 'ExportPlanner' in scope`.

- [ ] **Step 4: Implement the planner**

Create `Sources/SlateCore/ExportPlanner.swift`:

```swift
import Foundation

public enum ReencodeReason: Equatable {
    case fpsDiffers
    case timingNotExact
    case reencodeAll
}

public enum BlockReason: Equatable {
    case missingFile
    case frameSizeMismatch
    case codecMismatch
    case audioMismatch
}

public enum ClipAction: Equatable {
    case copy
    case reencode(ReencodeReason)
    /// No output frames (no segments, or all shorter than one frame). Not an error.
    case skipped
    case blocked(BlockReason)
}

public struct ClipPlan: Equatable {
    public let clipID: UUID
    public let action: ClipAction
    public let segments: [GridSegment]
    public let droppedSegmentIDs: [UUID]

    public var frameCount: Int { segments.reduce(0) { $0 + $1.frameCount } }
}

public enum PlanBlocker: Equatable {
    case noClips
    case noFrames
    case clip(UUID, BlockReason)
    case timescaleOverflow
}

public struct ExportPlan: Equatable {
    public let mode: FPSMode
    public let strategy: ConstantStrategy
    public let clips: [ClipPlan]
    /// All grid segments in output order. Feeds export, preview and ProjectTimeMap.
    public let grid: [GridSegment]
    public let totalDuration: Rational
    public let totalFrames: Int
    /// T_out: d and every copied clip's timescale divide it.
    public let outputTimescale: Int32
    /// The first readable clip. Every other clip must match its size, codec and audio.
    public let reference: ClipMedia?
    public let blockers: [PlanBlocker]

    public var canExport: Bool { blockers.isEmpty }
    public var hasAudio: Bool { reference?.hasAudio ?? false }
    public var audio: AudioFormat? { reference?.audio }

    public var frameDuration: Rational? {
        if case .constant(let d) = mode { return d }
        return nil
    }

    public func plan(for clipID: UUID) -> ClipPlan? {
        clips.first { $0.clipID == clipID }
    }
}

public enum ExportPlanner {
    public static func plan(_ project: Project) -> ExportPlan {
        let reference = project.clips.first { $0.media != nil }?.media

        var blocked: [UUID: BlockReason] = [:]
        for clip in project.clips {
            guard let m = clip.media, let ref = reference else {
                blocked[clip.id] = .missingFile
                continue
            }
            if m.width != ref.width || m.height != ref.height {
                blocked[clip.id] = .frameSizeMismatch
            } else if m.codec != ref.codec {
                blocked[clip.id] = .codecMismatch
            } else if m.hasAudio != ref.hasAudio {
                blocked[clip.id] = .audioMismatch
            }
        }

        let inputs: [FrameGrid.ClipInput] = project.clips.compactMap { clip in
            guard blocked[clip.id] == nil, let m = clip.media else { return nil }
            return FrameGrid.ClipInput(clipID: clip.id, frames: m.frames, segments: clip.segments)
        }
        let grid = FrameGrid.build(inputs, mode: project.fpsMode)
        let droppedSet = Set(grid.dropped)

        var clipPlans: [ClipPlan] = []
        for clip in project.clips {
            let segs = grid.segments.filter { $0.clipID == clip.id }
            let dropped = clip.segments.map(\.id).filter { droppedSet.contains($0) }
            let action: ClipAction
            if let reason = blocked[clip.id] {
                action = .blocked(reason)
            } else if segs.isEmpty {
                action = .skipped
            } else {
                action = decide(clip.media!, mode: project.fpsMode, strategy: project.constantStrategy)
            }
            clipPlans.append(ClipPlan(clipID: clip.id, action: action, segments: segs, droppedSegmentIDs: dropped))
        }

        var blockers: [PlanBlocker] = []
        if project.clips.isEmpty { blockers.append(.noClips) }
        for clip in project.clips {
            if let reason = blocked[clip.id] { blockers.append(.clip(clip.id, reason)) }
        }
        if !project.clips.isEmpty && grid.totalFrames == 0 { blockers.append(.noFrames) }

        let timescales = project.clips.compactMap { clip -> Int32? in
            guard blocked[clip.id] == nil else { return nil }
            return clip.media?.frames.timescale
        }
        let timescale = outputTimescale(mode: project.fpsMode, clipTimescales: timescales)
        if timescale == nil { blockers.append(.timescaleOverflow) }

        return ExportPlan(mode: project.fpsMode, strategy: project.constantStrategy, clips: clipPlans,
                          grid: grid.segments, totalDuration: grid.totalDuration, totalFrames: grid.totalFrames,
                          outputTimescale: timescale ?? 600, reference: reference, blockers: blockers)
    }

    static func decide(_ media: ClipMedia, mode: FPSMode, strategy: ConstantStrategy) -> ClipAction {
        guard case .constant(let d) = mode else { return .copy }
        if strategy == .reencodeAll { return .reencode(.reencodeAll) }
        guard let src = media.frames.exactFrameDuration else { return .reencode(.timingNotExact) }
        return src == d ? .copy : .reencode(.fpsDiffers)
    }

    /// lcm of d's denominator and every usable clip's timescale. In Mixed mode an
    /// overflow falls back to the largest clip timescale (no cadence promise there).
    static func outputTimescale(mode: FPSMode, clipTimescales: [Int32]) -> Int32? {
        var t: Int64 = 1
        if case .constant(let d) = mode { t = d.den }
        var overflow = false
        for ts in clipTimescales {
            if let l = Rational.lcm(t, Int64(ts)) { t = l } else { overflow = true; break }
        }
        if overflow || t > Int64(Int32.max) {
            if case .mixed = mode { return clipTimescales.max() ?? 600 }
            return nil
        }
        return t == 1 ? 600 : Int32(t)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run SlateChecks planner`
Expected: `7 passed, 0 failed, 0 skipped`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/ExportPlanner.swift Sources/SlateChecks/PlannerChecks.swift Sources/SlateChecks/TestData.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ExportPlanner with copy/re-encode/blocked decisions"
```

---

### Task 6: `FrameRetimer`

**Files:**
- Create: `Sources/SlateCore/FrameRetimer.swift`
- Create: `Sources/SlateChecks/RetimerChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `FrameTable`, `Rational`, `FrameGrid`.
- Produces: `public enum FrameRetimer { static func sourceFrameIndices(frames:sourceStart:frameDuration:count:tolerance:) -> [Int] }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/RetimerChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

func runRetimerChecks() {
    check("retimer: 24→48 doubles each frame, even at timescale 24") {
        let five = FrameTable.uniform(count: 5, frameDuration: Rational(1, 24), timescale: 24)
        let picks = FrameRetimer.sourceFrameIndices(frames: five, sourceStart: .zero,
                                                    frameDuration: Rational(1, 48), count: 10)
        expectEqual(picks, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    check("retimer: 48→24 keeps every second frame") {
        let ten = FrameTable.uniform(count: 10, frameDuration: Rational(1, 48), timescale: 12288)
        let picks = FrameRetimer.sourceFrameIndices(frames: ten, sourceStart: .zero,
                                                    frameDuration: Rational(1, 24), count: 5)
        expectEqual(picks, [0, 2, 4, 6, 8])
    }

    check("retimer: same rate is identity") {
        let c = FrameTable.uniform(count: 30, frameDuration: Rational(1, 30), timescale: 30000)
        let picks = FrameRetimer.sourceFrameIndices(frames: c, sourceStart: .zero,
                                                    frameDuration: Rational(1, 30), count: 30)
        expectEqual(picks, Array(0..<30))
    }

    check("retimer: VFR input with a hole holds the previous frame") {
        let vfr = FrameTable(pts: [Rational(0), Rational(1, 24), Rational(3, 24), Rational(4, 24)],
                             durations: [Rational(1, 24), Rational(2, 24), Rational(1, 24), Rational(1, 24)],
                             timescale: 24)
        let picks = FrameRetimer.sourceFrameIndices(frames: vfr, sourceStart: .zero,
                                                    frameDuration: Rational(1, 24), count: 5)
        expectEqual(picks, [0, 1, 1, 2, 3])
    }

    check("retimer: kept ranges with a gap map each segment on its own") {
        let six = FrameTable.uniform(count: 144, frameDuration: Rational(1, 24), timescale: 12288)
        let grid = FrameGrid.build([FrameGrid.ClipInput(clipID: UUID(), frames: six, segments: [
            Segment(range: CMTimeRange(start: Rational(2).cmTime, end: Rational(3).cmTime)),
            Segment(range: CMTimeRange(start: Rational(4).cmTime, end: Rational(5).cmTime)),
        ])], mode: .constant(frameDuration: Rational(1, 48)))
        let first = FrameRetimer.sourceFrameIndices(frames: six, sourceStart: grid.segments[0].sourceStart,
                                                    frameDuration: Rational(1, 48), count: grid.segments[0].frameCount)
        let second = FrameRetimer.sourceFrameIndices(frames: six, sourceStart: grid.segments[1].sourceStart,
                                                     frameDuration: Rational(1, 48), count: grid.segments[1].frameCount)
        expectEqual(Array(first.prefix(4)), [48, 48, 49, 49])
        expectEqual(first.last, 71)
        expectEqual(Array(second.prefix(2)), [96, 96])
        expectEqual(second.last, 119)
    }

    check("retimer: adjacent selections share no source frame (24→48 and VFR)") {
        let vfr = FrameTable(pts: [0, 1, 3, 4, 5, 6].map { Rational(Int64($0), 24) },
                             durations: [1, 2, 1, 1, 1, 1].map { Rational(Int64($0), 24) }, timescale: 24)
        let d = Rational(1, 48)
        for frames in [TestData.c24, vfr] {
            // Review case: without boundary pushing, starts are 1/24 and 1/16 and both show frame 1.
            let s1 = Segment(range: CMTimeRange(start: Rational(21, 1000).cmTime, end: Rational(51, 1000).cmTime))
            let s2 = Segment(range: CMTimeRange(start: Rational(52, 1000).cmTime, end: Rational(100, 1000).cmTime))
            let r = FrameGrid.build([FrameGrid.ClipInput(clipID: UUID(), frames: frames, segments: [s1, s2])],
                                    mode: .constant(frameDuration: d))
            expectEqual(r.segments.count, 2)
            let picks = r.segments.map {
                Set(FrameRetimer.sourceFrameIndices(frames: frames, sourceStart: $0.sourceStart,
                                                    frameDuration: d, count: $0.frameCount))
            }
            expect(picks[0].isDisjoint(with: picks[1]), "shared: \(picks[0].intersection(picks[1]))")
            expect(frames.boundaries.contains(r.segments[1].sourceStart), "start must be a source boundary")
        }
    }

    check("retimer: jittered 23.976 with τ matches exact picks on the ideal source") {
        let jit = TestData.jittered23976(count: 2400)
        let ideal = TestData.ideal23976(count: 2400)
        for d in [Rational(1, 24), Rational(1, 30), Rational(1, 48)] {
            let n = Int(((ideal.pts.last!) / d).floor())
            let exact = FrameRetimer.sourceFrameIndices(frames: ideal, sourceStart: .zero,
                                                        frameDuration: d, count: n, tolerance: .zero)
            let withTau = FrameRetimer.sourceFrameIndices(frames: jit, sourceStart: .zero,
                                                          frameDuration: d, count: n)
            expectEqual(withTau, exact, "d = \(d)")
        }
    }
}
```

In `main.swift`, add `runRetimerChecks()` after `runPlannerChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks retimer`
Expected: build FAILS with `cannot find 'FrameRetimer' in scope`.

- [ ] **Step 3: Implement the retimer**

Create `Sources/SlateCore/FrameRetimer.swift`:

```swift
import Foundation

public enum FrameRetimer {
    /// For output frames 0..<count of one grid segment, the source frame index to show.
    /// Output frame i shows the source frame with the largest pts ≤ s' + i·d + τ.
    /// τ defaults to `frames.pickTolerance` (0 when a tick is coarse, so it never
    /// moves the choice to a later frame).
    public static func sourceFrameIndices(frames: FrameTable, sourceStart: Rational,
                                          frameDuration d: Rational, count: Int,
                                          tolerance: Rational? = nil) -> [Int] {
        let tau = tolerance ?? frames.pickTolerance
        return (0..<count).map { i in
            frames.lastFrameIndex(atOrBefore: sourceStart + d * i + tau) ?? 0
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks retimer`
Expected: `7 passed, 0 failed, 0 skipped`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/FrameRetimer.swift Sources/SlateChecks/RetimerChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): FrameRetimer with bounded pick tolerance"
```

---

### Task 7: `ProjectTimeMap`

**Files:**
- Create: `Sources/SlateCore/ProjectTimeMap.swift`
- Create: `Sources/SlateChecks/TimeMapChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `GridSegment`, `ExportPlanner`.
- Produces: `public struct ProjectTimeMap { struct Location { clipID, segmentID, gridIndex, sourceTime }; init(grid:); totalDuration; locate(_:) -> Location?; projectTime(clipID:sourceTime:) -> Rational?; firstOutputStart(of:) -> Rational? }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/TimeMapChecks.swift`:

```swift
import Foundation
import SlateCore

func runTimeMapChecks() {
    let a = TestData.clip(TestData.media(TestData.c24), keep: [(Rational(2), Rational(3)), (Rational(4), Rational(5))])
    let b = TestData.clip(TestData.media(TestData.c48), keep: [(Rational(1), Rational(2))])
    let empty = TestData.clip(TestData.media(TestData.c24), keep: [])
    let plan = ExportPlanner.plan(Project(clips: [a, empty, b], fpsMode: .constant(frameDuration: Rational(1, 24))))
    let map = ProjectTimeMap(grid: plan.grid)

    check("timemap: total equals the plan") {
        expectEqual(map.totalDuration, plan.totalDuration)
        expectEqual(map.totalDuration, Rational(3))
    }

    check("timemap: segment edges map to the right clip") {
        expectEqual(map.locate(.zero)?.sourceTime, Rational(2))
        expectEqual(map.locate(Rational(1))?.sourceTime, Rational(4))
        expectEqual(map.locate(Rational(1))?.clipID, a.id)
        expectEqual(map.locate(Rational(2))?.clipID, b.id)
        expectEqual(map.locate(Rational(2))?.sourceTime, Rational(1))
        expectEqual(map.locate(Rational(3))?.sourceTime, Rational(2), "end maps to the last source end")
        expectEqual(map.locate(Rational(-1))?.sourceTime, Rational(2))
    }

    check("timemap: round trip for every output frame") {
        for (i, g) in plan.grid.enumerated() {
            for f in 0..<g.frameCount {
                let t = g.outputStart + Rational(1, 24) * f
                guard let loc = map.locate(t) else { expect(false, "no location at \(t)"); continue }
                expectEqual(loc.gridIndex, i)
                expectEqual(map.projectTime(clipID: loc.clipID, sourceTime: loc.sourceTime), t)
            }
        }
    }

    check("timemap: clip with no kept frames has no output time") {
        expect(map.firstOutputStart(of: empty.id) == nil)
        expect(map.projectTime(clipID: empty.id, sourceTime: .zero) == nil)
        expectEqual(map.firstOutputStart(of: b.id), Rational(2))
        expect(map.projectTime(clipID: a.id, sourceTime: Rational(7, 2)) == nil, "removed interval")
        expect(ProjectTimeMap(grid: []).locate(.zero) == nil)
    }
}
```

In `main.swift`, add `runTimeMapChecks()` after `runRetimerChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks timemap`
Expected: build FAILS with `cannot find 'ProjectTimeMap' in scope`.

- [ ] **Step 3: Implement the map**

Create `Sources/SlateCore/ProjectTimeMap.swift`:

```swift
import Foundation

/// Converts between project time (assembled output) and source time (one clip file).
/// Built from the planner's grid, so it matches the export exactly.
public struct ProjectTimeMap: Equatable {
    public struct Location: Equatable {
        public let clipID: UUID
        public let segmentID: UUID
        public let gridIndex: Int
        public let sourceTime: Rational
    }

    public let grid: [GridSegment]

    public init(grid: [GridSegment]) {
        self.grid = grid
    }

    public var totalDuration: Rational { grid.last?.outputEnd ?? .zero }

    /// Project time → clip and source time. Times before 0 clamp to the start;
    /// times at or past the end map to the end of the last segment.
    public func locate(_ t: Rational) -> Location? {
        guard !grid.isEmpty else { return nil }
        var lo = 0
        var hi = grid.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if grid[mid].outputStart <= t { lo = mid + 1 } else { hi = mid }
        }
        let k = max(lo - 1, 0)
        let g = grid[k]
        let source: Rational
        if t <= g.outputStart {
            source = g.sourceStart
        } else if t >= g.outputEnd {
            source = g.sourceEnd
        } else {
            source = g.sourceStart + (t - g.outputStart)
        }
        return Location(clipID: g.clipID, segmentID: g.segmentID, gridIndex: k, sourceTime: source)
    }

    /// Source time in a clip → project time, or nil if that source time is not kept.
    public func projectTime(clipID: UUID, sourceTime st: Rational) -> Rational? {
        for g in grid where g.clipID == clipID && g.sourceStart <= st && st < g.sourceEnd {
            return g.outputStart + (st - g.sourceStart)
        }
        return nil
    }

    public func firstOutputStart(of clipID: UUID) -> Rational? {
        grid.first { $0.clipID == clipID }?.outputStart
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks timemap`
Expected: `4 passed, 0 failed, 0 skipped`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ProjectTimeMap.swift Sources/SlateChecks/TimeMapChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ProjectTimeMap from planner grid"
```

---

### Task 8: Test fixtures and `ClipProbe`

**Files:**
- Create: `scripts/make-test-clips.sh`
- Create: `Sources/SlateCore/ClipProbe.swift`
- Create: `Sources/SlateChecks/Fixtures.swift`
- Create: `Sources/SlateChecks/ProbeChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `FrameTable`, `ClipMedia`, `AudioFormat`.
- Produces: `public enum ClipProbe { static func probe(url:) async throws -> ClipMedia; static func readFrameTable(asset:track:) async throws -> FrameTable }`, `public enum ClipProbeError`.
- Produces (checks): `func fixture(_ name: String) throws -> URL`, `func checksOutputDirectory() throws -> URL`.

- [ ] **Step 1: Write the fixture script**

Create `scripts/make-test-clips.sh`:

```bash
#!/usr/bin/env bash
# Dev-only: write ComfyUI-like test clips into build/fixtures (needs Homebrew ffmpeg).
# ComfyUI Video Helper Suite writes through ffmpeg/libx264, so these match its output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/fixtures"
mkdir -p "$OUT"

FF=(ffmpeg -loglevel error -y)
X264=(-c:v libx264 -pix_fmt yuv420p -crf 19)

# 24 fps, 5 s, with AAC audio (default GOP: one keyframe at the start).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=5 \
    "${X264[@]}" -c:a aac -b:a 128k -shortest "$OUT/c24_a.mp4"

# 48 fps stand-in for RIFE: motion-interpolated from the 24 fps clip.
"${FF[@]}" -i "$OUT/c24_a.mp4" -vf minterpolate=fps=48 "${X264[@]}" -c:a copy "$OUT/c48_a.mp4"

# Video-only versions.
"${FF[@]}" -i "$OUT/c24_a.mp4" -an -c:v copy "$OUT/c24.mp4"
"${FF[@]}" -i "$OUT/c48_a.mp4" -an -c:v copy "$OUT/c48.mp4"

# 23.976 fps at timescale 90000 (rounded tick durations).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24000/1001:duration=5 \
    "${X264[@]}" -video_track_timescale 90000 "$OUT/j23976.mp4"

# Different frame size (must be blocked when mixed with the others).
"${FF[@]}" -f lavfi -i testsrc2=size=320x180:rate=24:duration=2 "${X264[@]}" "$OUT/small24.mp4"

# Decoder-failure fixture: moov first, then cut the media data at 60 %.
"${FF[@]}" -i "$OUT/c48.mp4" -c copy -movflags +faststart "$OUT/c48_fs.mp4"
SIZE=$(stat -f%z "$OUT/c48_fs.mp4")
head -c $((SIZE * 6 / 10)) "$OUT/c48_fs.mp4" > "$OUT/c48_trunc.mp4"

echo "✓ fixtures in $OUT"
```

Run it and confirm the timing:

```bash
chmod +x scripts/make-test-clips.sh
scripts/make-test-clips.sh
for f in c24 c48 j23976; do
  ffprobe -v error -select_streams v:0 -show_entries stream=time_base,r_frame_rate,nb_frames -of compact build/fixtures/$f.mp4
  ffprobe -v error -select_streams v:0 -show_entries packet=duration -of csv=p=0 build/fixtures/$f.mp4 | sort | uniq -c
done
```

Expected: `c24` shows `time_base=1/12288`, 120 frames, all durations `512`. `c48` shows `1/12288` and all durations `256`. `j23976` shows `1/90000`. Write down the `j23976` duration histogram in the commit message (3753/3754 or a single value). Either is fine for later checks.

- [ ] **Step 2: Write the fixture helpers and failing checks**

Create `Sources/SlateChecks/Fixtures.swift`:

```swift
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
```

Create `Sources/SlateChecks/ProbeChecks.swift`:

```swift
import Foundation
import SlateCore

func runProbeChecks() async {
    await checkAsync("probe: 24 fps fixture has exact frame timing") {
        let m = try await ClipProbe.probe(url: try fixture("c24.mp4"))
        expectEqual(m.frames.count, 120)
        expectEqual(m.frames.pts.first, Rational.zero)
        expectEqual(m.frames.exactFrameDuration, Rational(1, 24))
        expectEqual(m.frames.clipEnd, Rational(5))
        expectEqual(m.frames.timescale, 12288)
        expectEqual(m.width, 640)
        expectEqual(m.height, 360)
        expectEqual(m.codec, fourCC("avc1"))
        expect(m.audio == nil)
    }

    await checkAsync("probe: 48 fps fixture is exact 1/48") {
        let m = try await ClipProbe.probe(url: try fixture("c48.mp4"))
        expectEqual(m.frames.exactFrameDuration, Rational(1, 48))
        expect(m.frames.count > 200, "count \(m.frames.count)")
    }

    await checkAsync("probe: audio format is read") {
        let m = try await ClipProbe.probe(url: try fixture("c24_a.mp4"))
        expectEqual(m.audio, AudioFormat(sampleRate: 44100, channels: 1))
    }

    await checkAsync("probe: 23.976 at timescale 90000 is not copyable at 1001/24000") {
        let m = try await ClipProbe.probe(url: try fixture("j23976.mp4"))
        expectEqual(m.frames.timescale, 90000)
        expect(m.frames.exactFrameDuration != Rational(1001, 24000),
               "90000 cannot hold 1001/24000 exactly")
    }
}
```

In `main.swift`, add `await runProbeChecks()` after `runTimeMapChecks()`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run SlateChecks probe`
Expected: build FAILS with `cannot find 'ClipProbe' in scope`.

- [ ] **Step 4: Implement `ClipProbe`**

Create `Sources/SlateCore/ClipProbe.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia

public enum ClipProbeError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .readerFailed(let m): return "Could not read the file: \(m)"
        case .noFrames: return "The video track has no frames."
        }
    }
}

public enum ClipProbe {
    public static func probe(url: URL) async throws -> ClipMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let (size, fps, rate, formats) = try await track.load(
            .naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let frames = try await readFrameTable(asset: asset, track: track)

        var audio: AudioFormat?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            if let f = audioFormats.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                audio = AudioFormat(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
            }
        }

        return ClipMedia(frames: frames, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                         codec: codec, nominalFPS: Double(fps), estimatedDataRate: rate, audio: audio)
    }

    /// Every video sample's presentation time and duration, sorted by pts.
    /// Only samples inside the track's time range (after edit lists) are kept.
    public static func readFrameTable(asset: AVAsset, track: AVAssetTrack) async throws -> FrameTable {
        let (timescale, trackRange) = try await track.load(.naturalTimeScale, .timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipProbeError.readerFailed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        let rangeStart = Rational(trackRange.start)
        let rangeEnd = Rational(trackRange.end)
        var entries: [(pts: Rational, duration: Rational)] = []
        while let buffer = output.copyNextSampleBuffer() {
            var needed: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
            guard needed > 0 else { continue }
            var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: needed)
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: needed, arrayToFill: &infos, entriesNeededOut: &needed)
            let samples = CMSampleBufferGetNumSamples(buffer)
            if infos.count == 1 && samples > 1 {
                // One timing entry shared by several samples.
                let info = infos[0]
                guard info.presentationTimeStamp.isNumeric, info.duration.isNumeric else { continue }
                let d = Rational(info.duration)
                for k in 0..<samples {
                    entries.append((Rational(info.presentationTimeStamp) + d * k, d))
                }
            } else {
                for info in infos where info.presentationTimeStamp.isNumeric && info.duration.isNumeric {
                    entries.append((Rational(info.presentationTimeStamp), Rational(info.duration)))
                }
            }
        }
        if reader.status == .failed {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        entries = entries.filter { $0.pts >= rangeStart && $0.pts < rangeEnd }
        guard !entries.isEmpty else { throw ClipProbeError.noFrames }
        entries.sort { $0.pts < $1.pts }
        return FrameTable(pts: entries.map(\.pts), durations: entries.map(\.duration), timescale: timescale)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run SlateChecks probe`
Expected: `4 passed, 0 failed, 0 skipped`.

If "24 fps fixture" fails on `pts.first` (for example the first pts is `1024/12288`), print `trackRange` and the first five entries. Then compare them with `ffprobe -show_packets`. The frame table must live in the same timeline that `AVMutableCompositionTrack.insertTimeRange` uses, which is the track's time range. Fix the filter, not the check.

- [ ] **Step 6: Commit**

```bash
git add scripts/make-test-clips.sh Sources/SlateCore/ClipProbe.swift Sources/SlateChecks/Fixtures.swift Sources/SlateChecks/ProbeChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ClipProbe reads exact frame timing; dev fixture script"
```

---

### Task 9: `CadenceValidator`

**Files:**
- Create: `Sources/SlateCore/CadenceValidator.swift`
- Create: `Sources/SlateChecks/ValidatorChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `Rational`, `ClipProbeError`.
- Produces: `public struct CadenceReport { frameCount, videoDuration, issues, ok }`, `public enum CadenceValidator { cadenceIssues(pts:durations:videoEnd:frameDuration:expectedFrames:) -> [String]; mixedIssues(frameCount:expectedFrames:duration:expectedDuration:) -> [String]; audioIssues(firstAudioPTS:audioEnd:videoEnd:sampleRate:) -> [String]; validate(url:frameDuration:expectedFrames:expectedDuration:audioSampleRate:) async throws -> CadenceReport }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ValidatorChecks.swift`:

```swift
import Foundation
import SlateCore

func runValidatorChecks() async {
    let d = Rational(1, 24)
    let perfect = (0..<48).map { d * $0 }
    let perfectDur = Array(repeating: d, count: 48)

    func issues(_ pts: [Rational], _ durs: [Rational], end: Rational = Rational(2)) -> [String] {
        CadenceValidator.cadenceIssues(pts: pts, durations: durs, videoEnd: end, frameDuration: d, expectedFrames: 48)
    }

    check("validator: a perfect grid has no issues") {
        expect(issues(perfect, perfectDur).isEmpty)
    }

    check("validator: shifted, missing frames and a short track end are reported") {
        var shifted = perfect
        shifted[10] = shifted[10] + Rational(1, 12288)
        expect(!issues(shifted, perfectDur).isEmpty)
        expect(!issues(Array(perfect.dropLast()), Array(perfectDur.dropLast())).isEmpty)
        expect(!issues(perfect, perfectDur, end: Rational(2) - Rational(1, 100)).isEmpty)
    }

    check("validator: a wrong middle or final sample duration is reported with perfect pts and track end") {
        var middle = perfectDur
        middle[20] = Rational(1, 48)
        expect(!issues(perfect, middle).isEmpty, "middle duration")
        var final = perfectDur
        final[47] = Rational(1, 48)
        expect(!issues(perfect, final).isEmpty, "final duration")
        var zero = perfectDur
        zero[5] = .zero
        expect(!issues(perfect, zero).isEmpty, "missing duration")
    }

    check("validator: audio start and end within one AAC packet") {
        let ok = CadenceValidator.audioIssues(firstAudioPTS: .zero, audioEnd: Rational(2) + Rational(1, 100),
                                              videoEnd: Rational(2), sampleRate: 44100)
        expect(ok.isEmpty, "\(ok)")
        let late = CadenceValidator.audioIssues(firstAudioPTS: Rational(1, 10), audioEnd: Rational(2),
                                                videoEnd: Rational(2), sampleRate: 44100)
        expect(!late.isEmpty)
        expect(!CadenceValidator.audioIssues(firstAudioPTS: nil, audioEnd: nil, videoEnd: Rational(2), sampleRate: 44100).isEmpty)
    }

    check("validator: mixed checks count and duration") {
        expect(CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(1), expectedDuration: Rational(1)).isEmpty)
        expect(!CadenceValidator.mixedIssues(frameCount: 9, expectedFrames: 10, duration: Rational(1), expectedDuration: Rational(1)).isEmpty)
        expect(!CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(11, 10), expectedDuration: Rational(1)).isEmpty)
    }

    await checkAsync("validator: the 24 fps fixture itself passes a Constant-24 check") {
        let report = try await CadenceValidator.validate(url: try fixture("c24_a.mp4"), frameDuration: d,
                                                         expectedFrames: 120, expectedDuration: Rational(5),
                                                         audioSampleRate: 44100)
        expect(report.ok, "\(report.issues)")
        expectEqual(report.frameCount, 120)
    }
}
```

In `main.swift`, add `await runValidatorChecks()` after `await runProbeChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks validator`
Expected: build FAILS with `cannot find 'CadenceValidator' in scope`.

- [ ] **Step 3: Implement the validator**

Create `Sources/SlateCore/CadenceValidator.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia

public struct CadenceReport: Equatable {
    public let frameCount: Int
    public let videoDuration: Rational
    public let issues: [String]

    public var ok: Bool { issues.isEmpty }
}

public enum CadenceValidator {
    /// Constant mode: frame n at exactly n·d, every sample duration exactly d
    /// (including the last), count as planned, and the track ends at the last frame's end.
    /// `durations[i]` is the reported duration of the frame at `pts[i]`.
    public static func cadenceIssues(pts: [Rational], durations: [Rational], videoEnd: Rational,
                                     frameDuration d: Rational, expectedFrames: Int) -> [String] {
        var issues: [String] = []
        if pts.count != expectedFrames {
            issues.append("frame count \(pts.count), expected \(expectedFrames)")
        }
        if durations.count != pts.count {
            issues.append("\(durations.count) durations for \(pts.count) frames")
        }
        var bad = 0
        for (n, p) in pts.enumerated() where p != d * n {
            if bad < 5 { issues.append("frame \(n) at \(p), expected \(d * n)") }
            bad += 1
        }
        if bad > 5 { issues.append("\(bad - 5) more frames off the grid") }
        var badDur = 0
        for (n, dur) in durations.enumerated() where dur != d {
            if badDur < 5 { issues.append("frame \(n) lasts \(dur), expected \(d)") }
            badDur += 1
        }
        if badDur > 5 { issues.append("\(badDur - 5) more frames with a wrong duration") }
        if let last = pts.last, videoEnd - last != d {
            issues.append("track ends \(videoEnd - last) after the last frame, expected \(d)")
        }
        return issues
    }

    /// Mixed mode: only frame count and total duration (within 1 ms).
    public static func mixedIssues(frameCount: Int, expectedFrames: Int, duration: Rational,
                                   expectedDuration: Rational) -> [String] {
        var issues: [String] = []
        if frameCount != expectedFrames {
            issues.append("frame count \(frameCount), expected \(expectedFrames)")
        }
        if (duration - expectedDuration).magnitude > Rational(1, 1000) {
            issues.append("duration \(duration.seconds) s, expected \(expectedDuration.seconds) s")
        }
        return issues
    }

    /// Audio must start at 0 and end with the video, each within one AAC packet (1024 samples).
    public static func audioIssues(firstAudioPTS: Rational?, audioEnd: Rational?, videoEnd: Rational,
                                   sampleRate: Double) -> [String] {
        guard let first = firstAudioPTS, let end = audioEnd else { return ["no decodable audio"] }
        let packet = Rational(1024, Int64(sampleRate.rounded()))
        var issues: [String] = []
        if first.magnitude > packet {
            issues.append("audio starts at \(first.seconds) s (priming not compensated?)")
        }
        if (end - videoEnd).magnitude > packet {
            issues.append("audio ends at \(end.seconds) s, video at \(videoEnd.seconds) s")
        }
        return issues
    }

    /// Decode the file (edit lists applied) and check it.
    /// `frameDuration` nil means Mixed mode.
    public static func validate(url: URL, frameDuration: Rational?, expectedFrames: Int,
                                expectedDuration: Rational, audioSampleRate: Double?) async throws -> CadenceReport {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let video = try decodedTimes(asset: asset, track: videoTrack, settings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let videoEnd = Rational(videoRange.end)
        let pts = video.map(\.pts)

        var issues: [String] = []
        if let d = frameDuration {
            issues += cadenceIssues(pts: pts, durations: try await frameDurations(asset: asset, track: videoTrack, decoded: video),
                                    videoEnd: videoEnd, frameDuration: d, expectedFrames: expectedFrames)
        } else {
            issues += mixedIssues(frameCount: pts.count, expectedFrames: expectedFrames,
                                  duration: videoEnd - (pts.first ?? .zero), expectedDuration: expectedDuration)
        }

        if let sampleRate = audioSampleRate {
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                let audio = try decodedTimes(asset: asset, track: audioTrack, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                ])
                issues += audioIssues(firstAudioPTS: audio.first?.pts,
                                      audioEnd: audio.last.map { $0.pts + $0.duration },
                                      videoEnd: videoEnd, sampleRate: sampleRate)
            } else {
                issues.append("no audio track")
            }
        }
        return CadenceReport(frameCount: pts.count, videoDuration: videoEnd, issues: issues)
    }

    /// Duration of each decoded frame. Uses the decoder's durations when every one is
    /// reported. Otherwise uses the sample table (an independent source), matched by pts.
    /// A frame with no duration in either source gets 0, which the check reports.
    static func frameDurations(asset: AVAsset, track: AVAssetTrack,
                               decoded: [(pts: Rational, duration: Rational)]) async throws -> [Rational] {
        if decoded.allSatisfy({ $0.duration > .zero }) {
            return decoded.map(\.duration)
        }
        let table = try await ClipProbe.readFrameTable(asset: asset, track: track)
        var byPTS: [Rational: Rational] = [:]
        for (p, d) in zip(table.pts, table.durations) { byPTS[p] = d }
        return decoded.map { byPTS[$0.pts] ?? .zero }
    }

    static func decodedTimes(asset: AVAsset, track: AVAssetTrack,
                             settings: [String: Any]) throws -> [(pts: Rational, duration: Rational)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipProbeError.readerFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        var out: [(pts: Rational, duration: Rational)] = []
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isNumeric else { continue }
            let dur = CMSampleBufferGetDuration(buffer)
            out.append((Rational(pts), dur.isNumeric ? Rational(dur) : .zero))
        }
        if reader.status == .failed {
            throw ClipProbeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        return out.sorted { $0.pts < $1.pts }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks validator`
Expected: `6 passed, 0 failed, 0 skipped`.

If the fixture check fails only on the audio end (ffmpeg `-shortest` can cut audio by more than one packet), print the issue. Then regenerate `c24_a.mp4` without `-shortest` and with `-t 5` on the sine input. Do not loosen the tolerance.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/CadenceValidator.swift Sources/SlateChecks/ValidatorChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): CadenceValidator for exact output cadence and audio sync"
```

---

### Task 10: `CompositionBuilder`

**Files:**
- Create: `Sources/SlateCore/CompositionBuilder.swift`
- Create: `Sources/SlateChecks/CompositionChecks.swift`
- Modify: `Sources/SlateChecks/Fixtures.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `GridSegment`, `ExportPlan`, `ClipProbe`.
- Produces: `public struct CompositionInsert { asset: AVAsset; sourceStart; duration; outputStart }`, `public enum CompositionError`, `public enum CompositionBuilder { static func inserts(for:assets:) -> [CompositionInsert]; static func build(inserts:includeAudio:timescale:) async throws -> AVMutableComposition }`.
- Produces (checks): `func loadClip(_ name: String, keep: [(Double, Double)]) async throws -> Clip`.

- [ ] **Step 1: Add the clip loader**

Add `import CoreMedia` and `import SlateCore` to the import lines at the top of `Sources/SlateChecks/Fixtures.swift`. Then append:

```swift
/// Probe a fixture and keep the given second ranges.
func loadClip(_ name: String, keep: [(Double, Double)]) async throws -> Clip {
    let url = try fixture(name)
    let media = try await ClipProbe.probe(url: url)
    let segments = keep.map { r in
        Segment(range: CMTimeRangeFromTimeToTime(start: CMTime(seconds: r.0, preferredTimescale: 600),
                                                 end: CMTime(seconds: r.1, preferredTimescale: 600)))
    }
    return Clip(url: url, segments: segments, media: media)
}
```

- [ ] **Step 2: Write the failing checks**

Create `Sources/SlateChecks/CompositionChecks.swift`:

```swift
import Foundation
import AVFoundation
import SlateCore

func runCompositionChecks() async {
    await checkAsync("composition: duration equals the plan exactly (mixed 24 + 48)") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        expect(plan.canExport, "\(plan.blockers)")
        let assets: [UUID: AVAsset] = [a.id: AVURLAsset(url: a.url), b.id: AVURLAsset(url: b.url)]
        let comp = try await CompositionBuilder.build(
            inserts: CompositionBuilder.inserts(for: plan.grid, assets: assets),
            includeAudio: false, timescale: plan.outputTimescale)
        expectEqual(Rational(comp.duration), plan.totalDuration)
    }

    await checkAsync("composition: audio a few ms shorter than video does not throw") {
        let a = try await loadClip("c24_a.mp4", keep: [(0, 5)])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        let comp = try await CompositionBuilder.build(
            inserts: CompositionBuilder.inserts(for: plan.grid, assets: [a.id: AVURLAsset(url: a.url)]),
            includeAudio: true, timescale: plan.outputTimescale)
        expectEqual(comp.tracks(withMediaType: .audio).count, 1)
        expectEqual(Rational(comp.duration), Rational(5))
    }
}
```

In `main.swift`, add `await runCompositionChecks()` after `await runValidatorChecks()`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run SlateChecks composition`
Expected: build FAILS with `cannot find 'CompositionBuilder' in scope`.

- [ ] **Step 4: Implement the builder**

Create `Sources/SlateCore/CompositionBuilder.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia

/// One source range placed at an output time.
public struct CompositionInsert {
    public let asset: AVAsset
    public let sourceStart: Rational
    public let duration: Rational
    public let outputStart: Rational

    public init(asset: AVAsset, sourceStart: Rational, duration: Rational, outputStart: Rational) {
        self.asset = asset
        self.sourceStart = sourceStart
        self.duration = duration
        self.outputStart = outputStart
    }
}

public enum CompositionError: Error, LocalizedError {
    case cannotAddTrack
    case noVideoTrack
    case missingAsset(UUID)

    public var errorDescription: String? {
        switch self {
        case .cannotAddTrack: return "Could not create a composition track."
        case .noVideoTrack: return "A clip has no video track."
        case .missingAsset(let id): return "No asset for clip \(id)."
        }
    }
}

public enum CompositionBuilder {
    /// One insert per grid segment, reading from the clip's own file.
    /// Used for Project preview, Mixed export and copied clips.
    public static func inserts(for grid: [GridSegment], assets: [UUID: AVAsset]) -> [CompositionInsert] {
        grid.compactMap { g in
            guard let asset = assets[g.clipID] else { return nil }
            return CompositionInsert(asset: asset, sourceStart: g.sourceStart,
                                     duration: g.outputDuration, outputStart: g.outputStart)
        }
    }

    public static func build(inserts: [CompositionInsert], includeAudio: Bool,
                             timescale: Int32) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.cannotAddTrack
        }
        video.naturalTimeScale = timescale
        var audio: AVMutableCompositionTrack?
        if includeAudio {
            audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            if audio == nil { throw CompositionError.cannotAddTrack }
        }

        for ins in inserts {
            guard let srcVideo = try await ins.asset.loadTracks(withMediaType: .video).first else {
                throw CompositionError.noVideoTrack
            }
            let range = CMTimeRange(start: ins.sourceStart.cmTime, duration: ins.duration.cmTime)
            let at = ins.outputStart.cmTime(timescale: timescale) ?? ins.outputStart.cmTime
            try video.insertTimeRange(range, of: srcVideo, at: at)

            if let audio, let srcAudio = try await ins.asset.loadTracks(withMediaType: .audio).first {
                // Audio may end a few ms before video. Insert only the overlapping part.
                let audioRange = try await srcAudio.load(.timeRange)
                let clipped = range.intersection(audioRange)
                if clipped.duration > .zero {
                    let offset = CMTimeSubtract(clipped.start, range.start)
                    try audio.insertTimeRange(clipped, of: srcAudio, at: CMTimeAdd(at, offset))
                }
            }
        }
        return comp
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run SlateChecks composition`
Expected: `2 passed, 0 failed, 0 skipped`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/CompositionBuilder.swift Sources/SlateChecks/CompositionChecks.swift Sources/SlateChecks/Fixtures.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): CompositionBuilder places grid segments at exact offsets"
```

---

### Task 11: `ClipReencoder`

**Files:**
- Create: `Sources/SlateCore/ClipReencoder.swift`
- Create: `Sources/SlateChecks/ReencoderChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: `FrameTable`, `GridSegment`, `FrameRetimer`, `AudioFormat`, `ClipMedia`, `fourCC`.
- Produces: `public struct ReencodeJob { asset, videoTrack, audioTrack, frames, segments; static func load(asset:frames:segments:) async throws -> ReencodeJob }`, `public struct VideoEncodeSettings { codec, width, height, bitsPerSecond; static func matching(_:) }`, `public enum ReencodeError`, `public final class ClipReencoder { init(); cancel(); encode(jobs:frameDuration:timescale:video:audio:outputURL:progress:) async throws }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ReencoderChecks.swift`:

```swift
import Foundation
import AVFoundation
import SlateCore

private func reencode(_ clip: Clip, to d: Rational, name: String) async throws -> (URL, ExportPlan) {
    let plan = ExportPlanner.plan(Project(clips: [clip], fpsMode: .constant(frameDuration: d)))
    let media = clip.media!
    let job = try await ReencodeJob.load(asset: AVURLAsset(url: clip.url), frames: media.frames,
                                         segments: plan.grid)
    let out = try checksOutputDirectory().appendingPathComponent(name)
    try await ClipReencoder().encode(jobs: [job], frameDuration: d, timescale: plan.outputTimescale,
                                     video: .matching(media), audio: media.audio,
                                     outputURL: out, progress: { _ in })
    return (out, plan)
}

func runReencoderChecks() async {
    await checkAsync("reencoder: 48→24 output has exact cadence") {
        let clip = try await loadClip("c48.mp4", keep: [(0.3, 2.9)])
        let (url, plan) = try await reencode(clip, to: Rational(1, 24), name: "re-48to24.mp4")
        let report = try await CadenceValidator.validate(url: url, frameDuration: Rational(1, 24),
                                                         expectedFrames: plan.totalFrames,
                                                         expectedDuration: plan.totalDuration, audioSampleRate: nil)
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("reencoder: 24→48 with two kept ranges and audio") {
        let clip = try await loadClip("c24_a.mp4", keep: [(0.5, 1.5), (2.5, 4.0)])
        let (url, plan) = try await reencode(clip, to: Rational(1, 48), name: "re-24to48-a.mp4")
        let report = try await CadenceValidator.validate(url: url, frameDuration: Rational(1, 48),
                                                         expectedFrames: plan.totalFrames,
                                                         expectedDuration: plan.totalDuration, audioSampleRate: 44100)
        expect(report.ok, "\(report.issues)")
        expectEqual(report.frameCount, 120)
    }

    await checkAsync("reencoder: a truncated source fails instead of freezing, and leaves no output") {
        // Frame table from the intact file; media data from the cut copy.
        let good = try await loadClip("c48_fs.mp4", keep: [(0, 4.9)])
        let d = Rational(1, 24)
        let plan = ExportPlanner.plan(Project(clips: [good], fpsMode: .constant(frameDuration: d)))
        let job = try await ReencodeJob.load(asset: AVURLAsset(url: try fixture("c48_trunc.mp4")),
                                             frames: good.media!.frames, segments: plan.grid)
        let out = try checksOutputDirectory().appendingPathComponent("re-trunc.mp4")
        do {
            try await ClipReencoder().encode(jobs: [job], frameDuration: d, timescale: plan.outputTimescale,
                                             video: .matching(good.media!), audio: nil,
                                             outputURL: out, progress: { _ in })
            expect(false, "expected a decode error, got a successful (frozen) export")
        } catch ReencodeError.missingFrame {
            // expected
        } catch ReencodeError.readerFailed {
            // expected
        } catch ReencodeError.cannotStartReader {
            // expected
        }
        expect(!FileManager.default.fileExists(atPath: out.path), "partial output must be removed")
    }

    await checkAsync("reencoder: cancel throws cancelled") {
        let clip = try await loadClip("c48.mp4", keep: [(0, 4.9)])
        let plan = ExportPlanner.plan(Project(clips: [clip], fpsMode: .constant(frameDuration: Rational(1, 24))))
        let job = try await ReencodeJob.load(asset: AVURLAsset(url: clip.url), frames: clip.media!.frames, segments: plan.grid)
        let encoder = ClipReencoder()
        encoder.cancel()
        do {
            try await encoder.encode(jobs: [job], frameDuration: Rational(1, 24), timescale: plan.outputTimescale,
                                     video: .matching(clip.media!), audio: nil,
                                     outputURL: try checksOutputDirectory().appendingPathComponent("re-cancel.mp4"),
                                     progress: { _ in })
            expect(false, "expected cancellation")
        } catch ReencodeError.cancelled {
            // expected
        }
    }
}
```

In `main.swift`, add `await runReencoderChecks()` after `await runCompositionChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks reencoder`
Expected: build FAILS with `cannot find 'ReencodeJob' in scope`.

- [ ] **Step 3: Implement the re-encoder**

Create `Sources/SlateCore/ClipReencoder.swift`:

```swift
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public enum ReencodeError: Error, LocalizedError {
    case cannotStartWriter(String)
    case cannotStartReader(String)
    case writerFailed(String)
    case readerFailed(String)
    case audioFailed(OSStatus)
    case audioTruncated(samples: Int64)
    case missingFrame
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotStartWriter(let m): return "Could not start the encoder: \(m)"
        case .cannotStartReader(let m): return "Could not read a clip: \(m)"
        case .readerFailed(let m): return "Reading a clip failed: \(m)"
        case .audioTruncated(let n): return "A clip's audio ends \(n) samples early."
        case .writerFailed(let m): return "Encoding failed: \(m)"
        case .audioFailed(let s): return "Audio processing failed (\(s))."
        case .missingFrame: return "A source frame could not be decoded."
        case .cancelled: return "Cancelled."
        }
    }
}

/// One clip's grid segments to re-encode, with its tracks already loaded.
public struct ReencodeJob {
    public let asset: AVAsset
    public let videoTrack: AVAssetTrack
    public let audioTrack: AVAssetTrack?
    public let frames: FrameTable
    public let segments: [GridSegment]

    public static func load(asset: AVAsset, frames: FrameTable, segments: [GridSegment]) async throws -> ReencodeJob {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipProbeError.noVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return ReencodeJob(asset: asset, videoTrack: video, audioTrack: audio, frames: frames, segments: segments)
    }
}

public struct VideoEncodeSettings: Equatable {
    public var codec: AVVideoCodecType
    public var width: Int
    public var height: Int
    public var bitsPerSecond: Int

    /// Same codec and size as the project. Bitrate ≈ 2× source, floor 20 Mbit/s at 1080p (scaled by pixels).
    public static func matching(_ media: ClipMedia) -> VideoEncodeSettings {
        let isHEVC = media.codec == fourCC("hvc1") || media.codec == fourCC("hev1")
        let floor = 20_000_000.0 * Double(media.width * media.height) / Double(1920 * 1080)
        let bitrate = max(2.0 * Double(media.estimatedDataRate), floor)
        return VideoEncodeSettings(codec: isHEVC ? .hevc : .h264, width: media.width, height: media.height,
                                   bitsPerSecond: Int(bitrate))
    }
}

/// Decodes kept ranges, retimes them onto the d grid, and encodes into one file.
/// Several jobs go back to back into the same file ("Re-encode all").
public final class ClipReencoder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func encode(jobs: [ReencodeJob], frameDuration d: Rational, timescale: Int32,
                       video: VideoEncodeSettings, audio: AudioFormat?, outputURL: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        if isCancelled { throw ReencodeError.cancelled }
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.movieTimeScale = timescale
        let fps = Int((Rational(1) / d).seconds.rounded())
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: video.codec,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: video.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: fps,
                // No B-frames: presentation order = decode order, no composition offsets.
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ReencodeError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = jobs.flatMap(\.segments).reduce(0) { $0 + $1.frameCount }
        let videoSource = VideoFrameSource(jobs: jobs, frameDuration: d, timescale: timescale)
        let audioSource = audio.map { AudioSampleSource(jobs: jobs, format: $0) }

        do {
            try await Task.detached(priority: .userInitiated) { [self] in
                var videoDone = false
                var audioDone = audioInput == nil
                while !(videoDone && audioDone) {
                    if self.isCancelled { throw ReencodeError.cancelled }
                    if writer.status == .failed {
                        throw ReencodeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                    }
                    var didWork = false
                    if !videoDone, videoInput.isReadyForMoreMediaData {
                        didWork = true
                        if try videoSource.appendNext(to: adaptor) {
                            progress(Double(videoSource.written) / Double(max(totalFrames, 1)))
                        } else {
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                    }
                    if !audioDone, let audioInput, let audioSource, audioInput.isReadyForMoreMediaData {
                        didWork = true
                        if try !audioSource.appendNext(to: audioInput) {
                            audioInput.markAsFinished()
                            audioDone = true
                        }
                    }
                    // Both inputs wait for interleaving; poll instead of blocking.
                    if !didWork { Thread.sleep(forTimeInterval: 0.002) }
                }
            }.value
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ReencodeError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}

/// Streams decoded source frames and appends retimed output frames.
final class VideoFrameSource {
    private let jobs: [ReencodeJob]
    private let d: Rational
    private let timescale: Int32
    private var jobIndex = 0
    private var segIndex = 0
    private var frameInSeg = 0
    private var indices: [Int] = []
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CVPixelBuffer?
    private var currentIndex = -1
    private var nextOutputPTS = Rational.zero
    private(set) var written = 0

    init(jobs: [ReencodeJob], frameDuration: Rational, timescale: Int32) {
        self.jobs = jobs
        self.d = frameDuration
        self.timescale = timescale
    }

    /// Appends one output frame. Returns false when every frame is written.
    func appendNext(to adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> Bool {
        if output == nil {
            guard try openNextSegment() else { return false }
        }
        let job = jobs[jobIndex]
        let seg = job.segments[segIndex]
        try advance(to: indices[frameInSeg], frames: job.frames)
        guard let buffer = current else { throw ReencodeError.missingFrame }
        let pts = nextOutputPTS.cmTime(timescale: timescale) ?? nextOutputPTS.cmTime
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw ReencodeError.writerFailed("video append failed at \(nextOutputPTS)")
        }
        nextOutputPTS = nextOutputPTS + d
        frameInSeg += 1
        written += 1
        if frameInSeg == seg.frameCount {
            reader?.cancelReading()
            reader = nil
            output = nil
            segIndex += 1
        }
        return true
    }

    private func openNextSegment() throws -> Bool {
        while jobIndex < jobs.count {
            let job = jobs[jobIndex]
            guard segIndex < job.segments.count else {
                jobIndex += 1
                segIndex = 0
                continue
            }
            let seg = job.segments[segIndex]
            indices = FrameRetimer.sourceFrameIndices(frames: job.frames, sourceStart: seg.sourceStart,
                                                      frameDuration: d, count: seg.frameCount)
            let f = job.frames
            let first = indices[0]
            let last = indices[indices.count - 1]
            let reader = try AVAssetReader(asset: job.asset)
            reader.timeRange = CMTimeRange(start: f.pts[first].cmTime, end: (f.pts[last] + f.durations[last]).cmTime)
            let out = AVAssetReaderTrackOutput(track: job.videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw ReencodeError.cannotStartReader("cannot add video output") }
            reader.add(out)
            guard reader.startReading() else {
                throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
            }
            self.reader = reader
            self.output = out
            current = nil
            currentIndex = -1
            frameInSeg = 0
            return true
        }
        return false
    }

    /// Read forward until the decoded frame is exactly the wanted source frame.
    /// A frame is shown again only when the retimer picks the same index again.
    /// A failed, cancelled or early-ending reader, or a skipped frame, is an error.
    private func advance(to want: Int, frames: FrameTable) throws {
        while currentIndex < want {
            guard let buffer = output?.copyNextSampleBuffer() else {
                try throwIfReaderFailed(reader)
                throw ReencodeError.missingFrame
            }
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let pts = Rational(CMSampleBufferGetPresentationTimeStamp(buffer))
            current = image
            currentIndex = frames.lastFrameIndex(atOrBefore: pts) ?? -1
        }
        if currentIndex != want { throw ReencodeError.missingFrame }
    }
}

/// Turns a reader that stopped for a bad reason into an error. Normal completion returns.
func throwIfReaderFailed(_ reader: AVAssetReader?) throws {
    guard let reader else { return }
    switch reader.status {
    case .failed: throw ReencodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    case .cancelled: throw ReencodeError.cancelled
    default: return
    }
}

/// Streams decoded PCM for each grid segment, trimmed to exact sample ranges and
/// retimed onto the output clock. The AAC encoder in AVAssetWriter adds priming.
final class AudioSampleSource {
    private struct Piece {
        let job: Int
        let sourceStartSample: Int64
        let outStartSample: Int64
        let count: Int64
    }

    private let jobs: [ReencodeJob]
    private let format: AudioFormat
    private let rate: Int64
    private var pieces: [Piece] = []
    private var pieceIndex = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var emitted: Int64 = 0

    init(jobs: [ReencodeJob], format: AudioFormat) {
        self.jobs = jobs
        self.format = format
        self.rate = Int64(format.sampleRate.rounded())
        let r = Rational(rate)
        var localOut = Rational.zero
        for (j, job) in jobs.enumerated() {
            for seg in job.segments {
                let outStart = (localOut * r).rounded()
                let outEnd = ((localOut + seg.outputDuration) * r).rounded()
                pieces.append(Piece(job: j, sourceStartSample: (seg.sourceStart * r).rounded(),
                                    outStartSample: outStart, count: outEnd - outStart))
                localOut = localOut + seg.outputDuration
            }
        }
    }

    /// Appends one trimmed buffer. Returns false when all audio is written.
    func appendNext(to input: AVAssetWriterInput) throws -> Bool {
        while pieceIndex < pieces.count {
            let piece = pieces[pieceIndex]
            if output == nil { try open(piece) }
            if emitted >= piece.count {
                closePiece()
                continue
            }
            guard let buffer = output?.copyNextSampleBuffer() else {
                try throwIfReaderFailed(reader)
                // Normal end of the source audio. Allow it to be short by at most one
                // AAC packet (ffmpeg `-shortest` files); anything more is truncation.
                let shortfall = piece.count - emitted
                if shortfall > 1024 { throw ReencodeError.audioTruncated(samples: shortfall) }
                closePiece()
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let n = Int64(CMSampleBufferGetNumSamples(buffer))
            guard pts.isNumeric, n > 0 else { continue }
            let first = (Rational(pts) * Rational(rate)).rounded()
            let wantFrom = piece.sourceStartSample + emitted
            let wantTo = piece.sourceStartSample + piece.count
            let lo = max(first, wantFrom)
            let hi = min(first + n, wantTo)
            guard hi > lo else {
                if first >= wantTo { closePiece() }
                continue
            }
            var sub: CMSampleBuffer?
            let status = CMSampleBufferCopySampleBufferForRange(
                allocator: nil, sampleBuffer: buffer,
                sampleRange: CFRange(location: CFIndex(lo - first), length: CFIndex(hi - lo)),
                sampleBufferOut: &sub)
            guard status == noErr, let sub else { throw ReencodeError.audioFailed(status) }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: Int32(rate)),
                presentationTimeStamp: CMTime(value: piece.outStartSample + (lo - piece.sourceStartSample),
                                              timescale: Int32(rate)),
                decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            let status2 = CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: sub, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &retimed)
            guard status2 == noErr, let retimed else { throw ReencodeError.audioFailed(status2) }
            guard input.append(retimed) else { throw ReencodeError.writerFailed("audio append failed") }
            emitted = hi - piece.sourceStartSample
            return true
        }
        return false
    }

    private func open(_ piece: Piece) throws {
        let job = jobs[piece.job]
        guard let track = job.audioTrack else { throw ReencodeError.cannotStartReader("clip has no audio track") }
        let reader = try AVAssetReader(asset: job.asset)
        // A little slack at the end; exact trimming happens per buffer.
        reader.timeRange = CMTimeRange(start: CMTime(value: piece.sourceStartSample, timescale: Int32(rate)),
                                       duration: CMTime(value: piece.count + rate / 10, timescale: Int32(rate)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
        ])
        guard reader.canAdd(out) else { throw ReencodeError.cannotStartReader("cannot add audio output") }
        reader.add(out)
        guard reader.startReading() else {
            throw ReencodeError.cannotStartReader(reader.error?.localizedDescription ?? "startReading failed")
        }
        self.reader = reader
        self.output = out
        emitted = 0
    }

    private func closePiece() {
        reader?.cancelReading()
        reader = nil
        output = nil
        emitted = 0
        pieceIndex += 1
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks reencoder`
Expected: `4 passed, 0 failed, 0 skipped`.

If a cadence check fails with frames off the grid, print the first 5 decoded pts and the output track's `timeRange`. Check that `writer.movieTimeScale` and `videoInput.mediaTimeScale` equal the plan's timescale. Do not add a tolerance to the validator.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ClipReencoder.swift Sources/SlateChecks/ReencoderChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ClipReencoder retimes kept ranges onto the output grid"
```

---

### Task 12: `ProjectExporter`

**Files:**
- Create: `Sources/SlateCore/ProjectExporter.swift`
- Create: `Sources/SlateChecks/ExporterChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `public enum ExportStage { reencoding(clip: Int, of: Int, progress: Double); assembling(Double); validating }`, `public enum ProjectExportError { blocked([PlanBlocker]); outputIsSource; cannotCreateSession; exportFailed(String); cancelled }`, `public final class ProjectExporter { init(); cancel(); export(project:outputURL:tempDirectory:progress:) async throws -> CadenceReport }`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ExporterChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

private func exportProject(_ project: Project, name: String) async throws -> (CadenceReport, ExportPlan) {
    let out = try checksOutputDirectory().appendingPathComponent(name)
    let temp = try checksOutputDirectory().appendingPathComponent("tmp", isDirectory: true)
    let report = try await ProjectExporter().export(project: project, outputURL: out, tempDirectory: temp,
                                                    progress: { _ in })
    return (report, ExportPlanner.plan(project))
}

func runExporterChecks() async {
    let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
    let d48 = FPSMode.constant(frameDuration: Rational(1, 48))

    await checkAsync("exporter: mixed 24 + 48 copies everything") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let (report, _) = try await exportProject(Project(clips: [a, b], fpsMode: .mixed), name: "ex-mixed.mp4")
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("exporter: constant 24 selective and re-encode all agree") {
        let a = try await loadClip("c24.mp4", keep: [(0.7, 2.3), (3.1, 4.4)])
        let b = try await loadClip("c48.mp4", keep: [(1.05, 3.6)])
        let (sel, _) = try await exportProject(Project(clips: [a, b], fpsMode: d24, constantStrategy: .selective),
                                               name: "ex-c24-selective.mp4")
        expect(sel.ok, "selective: \(sel.issues)")
        let (all, _) = try await exportProject(Project(clips: [a, b], fpsMode: d24, constantStrategy: .reencodeAll),
                                               name: "ex-c24-all.mp4")
        expect(all.ok, "re-encode all: \(all.issues)")
        expectEqual(sel.frameCount, all.frameCount)
    }

    await checkAsync("exporter: constant 48 selective with audio") {
        let a = try await loadClip("c24_a.mp4", keep: [(0.7, 2.3)])
        let b = try await loadClip("c48_a.mp4", keep: [(1.05, 3.6)])
        let (report, _) = try await exportProject(Project(clips: [a, b], fpsMode: d48), name: "ex-c48-a.mp4")
        expect(report.ok, "\(report.issues)")
    }

    await checkAsync("exporter: the same file twice as two clips") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let b = try await loadClip("c24.mp4", keep: [(3.0, 4.0)])
        let (report, plan) = try await exportProject(Project(clips: [a, b], fpsMode: d24), name: "ex-dup.mp4")
        expect(report.ok, "\(report.issues)")
        expectEqual(plan.totalFrames, 48)
    }

    await checkAsync("exporter: blocked project throws and writes nothing") {
        let a = try await loadClip("c24.mp4", keep: [(0, 1)])
        let small = try await loadClip("small24.mp4", keep: [(0, 1)])
        let out = try checksOutputDirectory().appendingPathComponent("ex-blocked.mp4")
        try? FileManager.default.removeItem(at: out)
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [a, small]), outputURL: out,
                                                   tempDirectory: try checksOutputDirectory(), progress: { _ in })
            expect(false, "expected blocked")
        } catch ProjectExportError.blocked(let blockers) {
            expect(blockers.contains(.clip(small.id, .frameSizeMismatch)))
        }
        expect(!FileManager.default.fileExists(atPath: out.path))
    }

    await checkAsync("exporter: output path equal to a source is refused") {
        let a = try await loadClip("c24.mp4", keep: [(0, 1)])
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [a]), outputURL: a.url,
                                                   tempDirectory: try checksOutputDirectory(), progress: { _ in })
            expect(false, "expected outputIsSource")
        } catch ProjectExportError.outputIsSource {
            // expected
        }
        expect(FileManager.default.fileExists(atPath: a.url.path), "source must survive")
    }

    await checkAsync("exporter: a symlinked parent or a case alias of a source is refused") {
        let fm = FileManager.default
        let base = try checksOutputDirectory().appendingPathComponent("alias-test", isDirectory: true)
        try? fm.removeItem(at: base)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let realClip = real.appendingPathComponent("clip.mp4")
        try fm.copyItem(at: try fixture("c24.mp4"), to: realClip)
        let alias = base.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let media = try await ClipProbe.probe(url: realClip)
        let whole = [Segment(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))]

        // Input through the symlink, output through the real path.
        let viaAlias = Clip(url: alias.appendingPathComponent("clip.mp4"), segments: whole, media: media)
        do {
            _ = try await ProjectExporter().export(project: Project(clips: [viaAlias]), outputURL: realClip,
                                                   tempDirectory: base, progress: { _ in })
            expect(false, "symlink parent not detected")
        } catch ProjectExportError.outputIsSource {
            // expected
        }
        expect(fm.fileExists(atPath: realClip.path), "source must survive (symlink case)")

        // Case alias, only meaningful on a case-insensitive volume.
        let caseSensitive = (try? real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        if !caseSensitive {
            let direct = Clip(url: realClip, segments: whole, media: media)
            do {
                _ = try await ProjectExporter().export(project: Project(clips: [direct]),
                                                       outputURL: real.appendingPathComponent("CLIP.MP4"),
                                                       tempDirectory: base, progress: { _ in })
                expect(false, "case alias not detected")
            } catch ProjectExportError.outputIsSource {
                // expected
            }
            expect(fm.fileExists(atPath: realClip.path), "source must survive (case alias)")
        }
    }

    await checkAsync("exporter: cancel during re-encode leaves no temp files and keeps an existing export") {
        let a = try await loadClip("c48.mp4", keep: [(0, 4.9)])
        let temp = try checksOutputDirectory().appendingPathComponent("tmp-cancel", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let out = try checksOutputDirectory().appendingPathComponent("ex-cancel.mp4")
        try Data("previous export".utf8).write(to: out)
        let exporter = ProjectExporter()
        let task = Task {
            try await exporter.export(project: Project(clips: [a], fpsMode: d24), outputURL: out,
                                      tempDirectory: temp, progress: { stage in
                if case .reencoding(_, _, let p) = stage, p > 0.1 { exporter.cancel() }
            })
        }
        do {
            _ = try await task.value
            expect(false, "expected cancellation")
        } catch ProjectExportError.cancelled {
            // expected
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        expect(leftovers.isEmpty, "leftovers: \(leftovers)")
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
        expect(!siblings.contains { $0.hasPrefix(".slate-") }, "staging file left next to the output")
    }
}
```

In `main.swift`, add `await runExporterChecks()` after `await runReencoderChecks()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift run SlateChecks exporter`
Expected: build FAILS with `cannot find 'ProjectExporter' in scope`.

- [ ] **Step 3: Implement the exporter**

Create `Sources/SlateCore/ProjectExporter.swift`:

```swift
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
    case cannotCreateSession
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .blocked: return "The project cannot be exported. See the plan for details."
        case .outputIsSource: return "The output file is one of the source clips. Choose another name."
        case .cannotCreateSession: return "Could not create the export session."
        case .exportFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

public final class ProjectExporter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var session: AVAssetExportSession?
    private var reencoder: ClipReencoder?

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
        let plan = ExportPlanner.plan(project)
        guard plan.canExport else { throw ProjectExportError.blocked(plan.blockers) }
        if Self.outputCollides(outputURL, with: project.clips.map(\.url)) {
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
            let report = try await CadenceValidator.validate(url: staged, frameDuration: plan.frameDuration,
                                                             expectedFrames: plan.totalFrames,
                                                             expectedDuration: plan.totalDuration,
                                                             audioSampleRate: plan.audio?.sampleRate)
            if isCancelled { throw ProjectExportError.cancelled }
            try Self.install(staged, at: outputURL)
            return report
        } catch {
            if isCancelled || error is CancellationError { throw ProjectExportError.cancelled }
            if case ReencodeError.cancelled = error { throw ProjectExportError.cancelled }
            throw error
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
        try fm.moveItem(at: staged, to: sibling)
        do {
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
                inserts += CompositionBuilder.inserts(for: cp.segments, assets: [cp.clipID: asset])
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run SlateChecks exporter`
Expected: `8 passed, 0 failed, 0 skipped`.

A failure in "constant 24 selective" while "re-encode all" passes is a real Phase 0 finding. It is NOT a bug to hide. Record the issues text and continue to Task 13. The spec's decision rule decides what happens next.

- [ ] **Step 5: Run the whole suite**

Run: `swift run SlateChecks`
Expected: every check passes, `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/ProjectExporter.swift Sources/SlateChecks/ExporterChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): ProjectExporter for mixed, selective and re-encode-all"
```

---

### Task 13: Phase 0 command and gate decision

**Files:**
- Create: `Sources/SlateChecks/Phase0.swift`
- Create: `scripts/phase0-ffprobe.sh`
- Modify: `Sources/SlateChecks/main.swift`
- Modify (on disk only, gitignored): `MASTER_PLAN.md`

**Interfaces:**
- Consumes: `ProjectExporter`, `loadClip`, `ExportPlanner`.
- Produces: `enum Phase0 { static func run(arguments:) async -> Int32 }` and the subcommand `swift run SlateChecks phase0 [--clip24 <path> --clip48 <path>]`.

- [ ] **Step 1: Write the Phase 0 command**

Create `Sources/SlateChecks/Phase0.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

/// Writes the Phase 0 files into build/phase0 and prints an automatic report.
enum Phase0 {
    struct Case {
        let file: String
        let mode: FPSMode
        let strategy: ConstantStrategy
        let audio: Bool
    }

    /// Arguments: optional `--clip24 <path> --clip48 <path>` to run the video-only cases
    /// on the user's own clips, locally. Paths are never copied into the repo.
    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let real24 = value("--clip24")
        let real48 = value("--clip48")
        if (real24 == nil) != (real48 == nil) {
            print("Pass both --clip24 and --clip48, or neither.")
            return 2
        }
        let usingRealClips = real24 != nil

        func load(_ generated: String, real: String?, keep: [(Double, Double)]) async throws -> Clip {
            guard let real else { return try await loadClip(generated, keep: keep) }
            let url = URL(fileURLWithPath: (real as NSString).expandingTildeInPath)
            let media = try await ClipProbe.probe(url: url)
            let segments = keep.map { r in
                Segment(range: CMTimeRangeFromTimeToTime(start: CMTime(seconds: r.0, preferredTimescale: 600),
                                                         end: CMTime(seconds: r.1, preferredTimescale: 600)))
            }
            return Clip(url: url, segments: segments, media: media)
        }

        let d24 = FPSMode.constant(frameDuration: Rational(1, 24))
        let d48 = FPSMode.constant(frameDuration: Rational(1, 48))
        let cases = [
            Case(file: "phase0-mixed.mp4", mode: .mixed, strategy: .selective, audio: false),
            Case(file: "phase0-selective-24.mp4", mode: d24, strategy: .selective, audio: false),
            Case(file: "phase0-all-24.mp4", mode: d24, strategy: .reencodeAll, audio: false),
            Case(file: "phase0-selective-48.mp4", mode: d48, strategy: .selective, audio: false),
            Case(file: "phase0-all-48.mp4", mode: d48, strategy: .reencodeAll, audio: false),
            Case(file: "phase0-selective-24-audio.mp4", mode: d24, strategy: .selective, audio: true),
            Case(file: "phase0-all-24-audio.mp4", mode: d24, strategy: .reencodeAll, audio: true),
        ]
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outDir = root.appendingPathComponent("build/phase0", isDirectory: true)
        let tmpDir = outDir.appendingPathComponent("tmp", isDirectory: true)
        var failures = 0
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            print("Phase 0 → \(outDir.path)  (video-only cases: \(usingRealClips ? "user clips" : "generated fixtures"))\n")
            for c in cases {
                // Both clips are cut mid-GOP (the fixtures have one keyframe at 0).
                // Audio cases always use the generated fixtures (supplemental AAC coverage).
                let a = try await load(c.audio ? "c24_a.mp4" : "c24.mp4", real: c.audio ? nil : real24,
                                       keep: [(0.7, 2.3), (3.1, 4.4)])
                let b = try await load(c.audio ? "c48_a.mp4" : "c48.mp4", real: c.audio ? nil : real48,
                                       keep: [(1.05, 3.6)])
                let project = Project(clips: [a, b], fpsMode: c.mode, constantStrategy: c.strategy)
                let plan = ExportPlanner.plan(project)
                let actions = plan.clips.map { "\($0.action)" }.joined(separator: ", ")
                do {
                    let report = try await ProjectExporter().export(
                        project: project, outputURL: outDir.appendingPathComponent(c.file),
                        tempDirectory: tmpDir, progress: { _ in })
                    let status = report.ok ? "PASS" : "FAIL"
                    if !report.ok { failures += 1 }
                    print("\(status)  \(c.file)  frames=\(report.frameCount)  duration=\(report.videoDuration.seconds)s  [\(actions)]")
                    for issue in report.issues { print("      - \(issue)") }
                } catch {
                    failures += 1
                    print("FAIL  \(c.file)  error: \(error.localizedDescription)  [\(actions)]")
                }
            }
        } catch {
            print("Phase 0 could not start: \(error)")
            return 2
        }
        print("\n\(failures == 0 ? "All automatic checks passed." : "\(failures) case(s) failed.")")
        print("Next: scripts/phase0-ffprobe.sh, then (optional) import build/phase0/*.mp4 into DaVinci Resolve.")
        return failures == 0 ? 0 : 1
    }
}
```

At the top of `main.swift`, right after `let arguments = …`, add:

```swift
if arguments.first == "phase0" {
    exit(await Phase0.run(arguments: Array(arguments.dropFirst())))
}
```

- [ ] **Step 2: Write the ffprobe report script**

Create `scripts/phase0-ffprobe.sh`:

```bash
#!/usr/bin/env bash
# Dev-only: independent frame-timing report for the Phase 0 files (needs Homebrew ffprobe).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$ROOT"/build/phase0/*.mp4; do
    echo "== $(basename "$f")"
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,r_frame_rate,avg_frame_rate,time_base,nb_frames \
        -of compact=p=0 "$f"
    echo "   frame durations (count × ticks):"
    ffprobe -v error -select_streams v:0 -show_entries frame=duration -of csv=p=0 "$f" \
        | sort | uniq -c | sed 's/^/     /'
    echo "   stream start / edit-list info:"
    ffprobe -v error -show_entries stream=index,codec_type,start_time,duration -of compact=p=0 "$f" \
        | sed 's/^/     /'
done
```

- [ ] **Step 3: Run Phase 0**

```bash
chmod +x scripts/phase0-ffprobe.sh
swift run SlateChecks phase0
scripts/phase0-ffprobe.sh
```

Expected: 7 lines, each `PASS` or `FAIL`. For `*-24*` files, ffprobe shows `r_frame_rate=24/1` and ONE frame-duration value. For `*-48*` files, ffprobe shows `48/1` and one value. For `phase0-mixed.mp4`, ffprobe shows two duration values (VFR), which is expected.

- [ ] **Step 4: Offer the user's own checks (both optional, both local)**

The user decided on 2026-09-29 that their clips are private and that the Resolve check is optional. Respect that. Do not ask for the files. Ask the user (in their language, short):

1. "If you want, run Phase 0 on two of your own clips on your machine: `swift run SlateChecks phase0 --clip24 <path> --clip48 <path>`. The files stay on your machine."
2. "If you have 2 minutes: import `build/phase0/*.mp4` into DaVinci Resolve. Check the fps, the joins (no extra, missing, black or frozen frames), and audio sync on the `-audio` files."

Wait for the answer. Either can be skipped.

- [ ] **Step 5: Record the decision**

Apply the spec's rule to what was actually run:
- Selective passes → Selective is the Constant-mode default.
- Selective fails, Re-encode all passes → Re-encode all is the default, and Selective stays as an option.
- Both fail → STOP. Report to the user and revisit the design before Plan 2.

Record the evidence level honestly. Never write "NLE gate passed" unless the user reported a Resolve result:
- Resolve checked by the user → "NLE compatibility: verified in DaVinci Resolve (<date>)".
- Resolve skipped → "NLE compatibility: UNVERIFIED (user skipped the Resolve check). Default chosen from automatic checks only." Plan 2 may start, because the user chose this. The export sheet in Plan 2 then must show "Re-encode everything — max compatibility" prominently in Constant mode.
- Real clips run by the user → name them only as "user clips (local)". Otherwise write "generated fixtures only".

Add a dated entry under `## Done` in `MASTER_PLAN.md` (on disk only; the file is gitignored). Include the 7 result lines, the ffprobe summary, the evidence level above, and the chosen default. Update the File Map with the new `Sources/SlateCore/`, `Sources/SlateChecks/`, and `scripts/` files. Under `## Next`, add: "Write Plan 2 (UI: clip strip, per-clip timeline, Clip/Project player, `.slate` file, autosave, export sheet) from the spec."

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateChecks/Phase0.swift Sources/SlateChecks/main.swift scripts/phase0-ffprobe.sh
git commit -m "feat(checks): Phase 0 feasibility command and ffprobe report"
```

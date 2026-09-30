# Multi-clip Plan 2A — Core fixes, exact Mixed check, `.slate` file, autosave

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `SlateCore` ready for the UI: new-project defaults, stricter planner, exact Mixed validation (with an acceptance gate), the Plan 1 carry-over fixes, the `.slate` project file and the autosave engine.

**Architecture:** All work is in `Sources/SlateCore` (pure logic, no UI) and is covered by `Sources/SlateChecks` (`swift run SlateChecks`). Nothing in `Sources/Slate` (the app) changes in this plan. Plan 2B (UI: clip strip, project view model, Project player, export sheet, file open/save, Dock/Info.plist) is written after 2A is merged, against the real APIs produced here.

**Tech Stack:** Swift 5.9, SPM, AVFoundation, CoreMedia. No XCTest: checks use `check(...)` / `checkAsync(...)` / `expect(...)` / `expectEqual(...)` from `Sources/SlateChecks/Harness.swift`.

**Spec:** `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md` — read the section "Plan 2 decisions" first; it wins over older text. Reviews: `docs/superpowers/handoffs/plan1-records/final-review-fable.md`, `docs/superpowers/handoffs/plan2-records/spec-review-fable.md`.

## Global Constraints

- macOS 14+, Swift 5.9, no external dependencies, no XCTest (Command Line Tools only).
- `swift build` / `swift run` fail inside the Claude sandbox (`xcode-select: unable to read data link`). Run every `swift` command with the sandbox disabled. Shell heredocs fail in the sandbox: create files with the Write/Edit tools.
- Run `scripts/make-test-clips.sh` once in a fresh checkout. Without fixtures media checks SKIP.
- Fixtures keep libx264 B-frames + edit lists on purpose. Never "fix" a failure with `-bf 0`.
- All timing math uses exact `Rational` on actual frame timestamps. No Double tolerances for timing.
- New project default: Constant 1/24 + `.reencodeAll`. `.slate` v1 does not store `constantStrategy`.
- Mixed label text (used by 2B): "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."
- Validation failure = export refused, in every mode. There is no "warning" path.
- Codecs allowed: `avc1`, `hvc1`, `hev1`. AAC packet = 1024 samples (the audio shortfall bound everywhere).
- The user's clips are private: never ask for them, never copy them into the repo. NLE (Resolve) compatibility stays UNVERIFIED.
- `MASTER_PLAN.md` is gitignored: update it on disk only. Commit messages: short, imperative, `type(scope): text`.
- Work on a branch `feat/multi-clip-2a` (use superpowers:using-git-worktrees or a plain branch). Baseline before Task 1: `swift run SlateChecks` prints `84 passed, 0 failed, 0 skipped`.

## Review Focus

Inputs and conditions the spec implies but no obvious task exercises, most likely first. Each has a test in the task named in brackets.

1. Mixed project whose clip timescales cannot share one exact timeline (lcm overflow) must be blocked, never exported with rounded offsets. [Task 4]
2. A ProRes `.mov` (or any codec outside avc1/hvc1/hev1) as the FIRST clip must block only itself, not turn every other clip into "codec mismatch". [Task 3]
3. Clips with different audio sample rate or channel count must be blocked before export starts. [Task 3]
4. Cancel pressed while the exported file is being validated must end as `.cancelled` fast and leave an existing destination file untouched. [Task 7]
5. A stereo clip whose audio is a few samples short must export in Re-encode all without shifting later audio. [Task 9]
6. A `.slate` file written by a newer version, or with unknown extra fields, or whose media moved: must give a clear error / be ignored / relink by relative then absolute path. [Task 11]
7. Untitled autosave file that is corrupt must not crash the restore offer. [Task 12]

## File Structure

Create:
- `Sources/SlateCore/ExpectedPTS.swift` — pure: expected decoded pts of a Mixed export.
- `Sources/SlateCore/ReencodeProgress.swift` — pure: which clip "k of n" a progress fraction belongs to.
- `Sources/SlateCore/ProjectFile.swift` — `.slate` v1 DTO, encode/decode, path relink, loader.
- `Sources/SlateCore/Autosave.swift` — `Autosaver` (debounce) and `UntitledAutosaveStore`.
- `Sources/SlateChecks/ModelChecks.swift`, `PlannerBlockerChecks.swift`, `ExpectedPTSChecks.swift`, `ValidationCancelChecks.swift`, `ProjectFileChecks.swift`, `AutosaveChecks.swift`.

Modify: `Package.swift` (no), `Sources/SlateCore/{ProjectModel,ExportPlanner,CadenceValidator,CompositionBuilder,ProjectExporter,ClipReencoder,ClipProbe}.swift`, `Sources/SlateChecks/{main,Harness,Phase0,ReencoderChecks,ExporterChecks}.swift`, `scripts/make-test-clips.sh`.

Run one check group with `swift run SlateChecks "<prefix>"` (prefix match on the check name).

---

### Task 1: Evidence hygiene — `--strict`, stale INVALID files, loud guard

**Files:**
- Modify: `Sources/SlateChecks/Harness.swift`, `Sources/SlateChecks/main.swift`, `Sources/SlateChecks/Phase0.swift`, `Sources/SlateCore/ProjectExporter.swift:184`

**Interfaces:**
- Produces: `Harness.strict: Bool`; CLI flag `swift run SlateChecks --strict [prefix]` (a skipped check makes exit code 1).

- [ ] **Step 1: Add the flag to the harness**

In `Sources/SlateChecks/Harness.swift` replace `static var filter: String?` with:

```swift
    static var filter: String?
    static var strict = false
```

and replace `finish()` with:

```swift
    static func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        let strictFailure = strict && skipped > 0
        if strictFailure { print("--strict: \(skipped) skipped check(s) count as a failure") }
        exit(failed == 0 && !strictFailure ? 0 : 1)
    }
```

- [ ] **Step 2: Parse the flag in `main.swift`**

Replace the first 7 lines of `Sources/SlateChecks/main.swift` (through `Harness.filter = arguments.first`) with:

```swift
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "phase0" {
    exit(await Phase0.run(arguments: Array(arguments.dropFirst())))
}
if let i = arguments.firstIndex(of: "--strict") {
    Harness.strict = true
    arguments.remove(at: i)
}
Harness.filter = arguments.first
```

- [ ] **Step 3: Remove a stale `-INVALID` file before each Phase 0 case**

In `Sources/SlateChecks/Phase0.swift`, replace

```swift
                let exporter = ProjectExporter()
                exporter.keepInvalidAt = outDir.appendingPathComponent(
                    c.file.replacingOccurrences(of: ".mp4", with: "-INVALID.mp4"))
```

with

```swift
                let exporter = ProjectExporter()
                let invalidURL = outDir.appendingPathComponent(
                    c.file.replacingOccurrences(of: ".mp4", with: "-INVALID.mp4"))
                try? FileManager.default.removeItem(at: invalidURL)
                exporter.keepInvalidAt = invalidURL
```

- [ ] **Step 4: Make the unreachable guard loud**

In `Sources/SlateCore/ProjectExporter.swift` replace `guard let d = plan.frameDuration else { continue }` with:

```swift
                guard let d = plan.frameDuration else {
                    preconditionFailure("the planner never returns .reencode in Mixed mode")
                }
```

- [ ] **Step 5: Verify (sandbox off)**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `84 passed, 0 failed, 0 skipped`, exit 0.

Run: `mv build/fixtures build/fixtures.bak && swift run SlateChecks --strict probe; echo "exit=$?"; mv build/fixtures.bak build/fixtures`
Expected: output contains `--strict: … skipped check(s) count as a failure` and `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateChecks/Harness.swift Sources/SlateChecks/main.swift Sources/SlateChecks/Phase0.swift Sources/SlateCore/ProjectExporter.swift
git commit -m "test: --strict fails on skips; drop stale INVALID files; loud Mixed guard"
```

---

### Task 2: New-project defaults and the fps picker list

**Files:**
- Modify: `Sources/SlateCore/ProjectModel.swift:65-75`
- Create: `Sources/SlateChecks/ModelChecks.swift`
- Modify: `Sources/SlateChecks/main.swift` (register)

**Interfaces:**
- Produces: `Project.init(clips:fpsMode:constantStrategy:)` defaults `.constant(frameDuration: Rational(1, 24))` and `.reencodeAll`; `FrameRateChoice.candidates(for: [Clip]) -> [Rational]` (unique, ascending `d`, so fastest first); `FrameRateChoice.highest(for: [Clip]) -> Rational?`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ModelChecks.swift`:

```swift
import Foundation
import SlateCore

func runModelChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("model: a new project starts in Constant 24 + Re-encode all") {
        let p = Project()
        expectEqual(p.fpsMode, FPSMode.constant(frameDuration: Rational(1, 24)))
        expectEqual(p.constantStrategy, ConstantStrategy.reencodeAll)
    }

    check("model: a default project re-encodes every clip (hidden Selective is never used)") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [a, b]))
        expect(plan.canExport, "\(plan.blockers)")
        for cp in plan.clips { expectEqual(cp.action, ClipAction.reencode(.reencodeAll)) }
    }

    check("model: picker lists exact frame durations, fastest first, no duplicates") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let b = TestData.clip(TestData.media(TestData.c48), keep: whole)
        let c = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let gone = TestData.clip(nil, keep: whole)
        expectEqual(FrameRateChoice.candidates(for: [a, gone, b, c]), [Rational(1, 48), Rational(1, 24)])
        expectEqual(FrameRateChoice.highest(for: [a, b]), Rational(1, 48))
        expectEqual(FrameRateChoice.highest(for: [gone]), nil)
        expectEqual(FrameRateChoice.highest(for: []), nil)
    }

    check("model: picker falls back to the nominal fps when no clip is exact CFR") {
        var m = TestData.media(TestData.jittered23976(count: 240))
        m.nominalFPS = 24000.0 / 1001.0
        let jit = TestData.clip(m, keep: [(.zero, Rational(5))])
        expectEqual(FrameRateChoice.candidates(for: [jit]), [Rational(1001, 24000)])
    }

    check("model: exact clips win over the nominal fallback of jittered clips") {
        var m = TestData.media(TestData.jittered23976(count: 240))
        m.nominalFPS = 24000.0 / 1001.0
        let jit = TestData.clip(m, keep: [(.zero, Rational(5))])
        let a = TestData.clip(TestData.media(TestData.c24), keep: whole)
        expectEqual(FrameRateChoice.candidates(for: [jit, a]), [Rational(1, 24)])
    }
}
```

In `Sources/SlateChecks/main.swift` add `runModelChecks()` on the line after `runSegmentChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks model`
Expected: build error `cannot find 'FrameRateChoice'` (and the first check would fail on `.mixed`).

- [ ] **Step 3: Implement**

In `Sources/SlateCore/ProjectModel.swift` replace the `Project` init line:

```swift
    public init(clips: [Clip] = [],
                fpsMode: FPSMode = .constant(frameDuration: Rational(1, 24)),
                constantStrategy: ConstantStrategy = .reencodeAll) {
```

Append to the end of the same file:

```swift
/// The frame durations the fps picker offers.
public enum FrameRateChoice {
    /// Unique frame durations, ascending (so the fastest fps comes first). Exact-CFR clips
    /// give their exact `d`. Only if no clip is exact CFR, each clip falls back to
    /// `Rational.frameDuration(fps: nominalFPS)`. Clips without media are ignored.
    public static func candidates(for clips: [Clip]) -> [Rational] {
        let medias = clips.compactMap(\.media)
        var exact = medias.compactMap { $0.frames.exactFrameDuration }
        if exact.isEmpty {
            exact = medias.map { Rational.frameDuration(fps: $0.nominalFPS) }
        }
        return Array(Set(exact)).sorted()
    }

    /// The default Constant target: the highest fps present.
    public static func highest(for clips: [Clip]) -> Rational? {
        candidates(for: clips).first
    }
}
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `89 passed, 0 failed, 0 skipped` (84 + 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ProjectModel.swift Sources/SlateChecks/ModelChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): new-project defaults Constant 24 + Re-encode all; fps picker list"
```

---

### Task 3: Planner blocks unsupported codecs and audio format mismatch

**Files:**
- Modify: `Sources/SlateCore/ExportPlanner.swift:9-14` and `:74-90`
- Create: `Sources/SlateChecks/PlannerBlockerChecks.swift`
- Modify: `Sources/SlateChecks/main.swift` (register)

**Interfaces:**
- Produces: `BlockReason.unsupportedCodec`, `BlockReason.audioFormatMismatch`; `ExportPlanner.supportedCodecs: Set<FourCharCode>`; the plan `reference` is the first readable clip with a supported codec.
- Consumes: `AudioFormat: Equatable`, `ClipMedia.audio`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/PlannerBlockerChecks.swift`:

```swift
import Foundation
import SlateCore

func runPlannerBlockerChecks() {
    let whole = [(Rational.zero, Rational(5))]

    check("planner: an unsupported codec blocks only that clip, even when it is first") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let good = TestData.clip(TestData.media(TestData.c24), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores, good]))
        expectEqual(plan.plan(for: prores.id)?.action, ClipAction.blocked(.unsupportedCodec))
        expect(plan.plan(for: good.id)?.action != ClipAction.blocked(.codecMismatch), "good clip must not be a mismatch")
        expect(plan.blockers.contains(.clip(prores.id, .unsupportedCodec)))
        expectEqual(plan.reference?.codec, fourCC("avc1"))
    }

    check("planner: unsupported codec is blocked in Mixed mode too, and hvc1/hev1 are allowed") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores], fpsMode: .mixed))
        expectEqual(plan.plan(for: prores.id)?.action, ClipAction.blocked(.unsupportedCodec))
        expect(!plan.canExport)
        for codec in ["avc1", "hvc1", "hev1"] {
            let c = TestData.clip(TestData.media(TestData.c24, codec: codec), keep: whole)
            expect(ExportPlanner.plan(Project(clips: [c], fpsMode: .mixed)).canExport, codec)
        }
    }

    check("planner: only unsupported clips gives no reference and no crash") {
        let prores = TestData.clip(TestData.media(TestData.c24, codec: "apcn"), keep: whole)
        let plan = ExportPlanner.plan(Project(clips: [prores]))
        expect(plan.reference == nil)
        expect(!plan.canExport)
    }

    check("planner: different audio sample rate or channel count is blocked") {
        var stereo = TestData.media(TestData.c24, audio: true)
        stereo.audio = AudioFormat(sampleRate: 44100, channels: 2)
        var rate48 = TestData.media(TestData.c24, audio: true)
        rate48.audio = AudioFormat(sampleRate: 48000, channels: 1)
        let ref = TestData.clip(TestData.media(TestData.c24, audio: true), keep: whole)
        let st = TestData.clip(stereo, keep: whole)
        let hi = TestData.clip(rate48, keep: whole)
        for mode in [FPSMode.mixed, .constant(frameDuration: Rational(1, 24))] {
            let plan = ExportPlanner.plan(Project(clips: [ref, st, hi], fpsMode: mode))
            expectEqual(plan.plan(for: st.id)?.action, ClipAction.blocked(.audioFormatMismatch), "\(mode)")
            expectEqual(plan.plan(for: hi.id)?.action, ClipAction.blocked(.audioFormatMismatch), "\(mode)")
            expect(plan.plan(for: ref.id)?.action != ClipAction.blocked(.audioFormatMismatch))
        }
    }
}
```

Register `runPlannerBlockerChecks()` in `main.swift` after `runPlannerChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks planner`
Expected: build error `type 'BlockReason' has no member 'unsupportedCodec'`.

- [ ] **Step 3: Implement**

In `Sources/SlateCore/ExportPlanner.swift` extend the enum:

```swift
public enum BlockReason: Equatable {
    case missingFile
    case frameSizeMismatch
    case codecMismatch
    case unsupportedCodec
    case audioMismatch
    case audioFormatMismatch
}
```

Replace the start of `ExportPlanner.plan` (from `public static func plan` through the end of the first `for clip in project.clips { … }` loop, i.e. lines 74-90) with:

```swift
    /// Codecs Slate can copy and re-encode into an `.mp4`. Anything else (e.g. ProRes) is blocked
    /// in every mode, because `VideoEncodeSettings.matching` would turn it into H.264.
    public static let supportedCodecs: Set<FourCharCode> = [fourCC("avc1"), fourCC("hvc1"), fourCC("hev1")]

    public static func plan(_ project: Project) -> ExportPlan {
        // The first readable clip with a supported codec is the reference for all others.
        let reference = project.clips.first {
            $0.media.map { supportedCodecs.contains($0.codec) } ?? false
        }?.media

        var blocked: [UUID: BlockReason] = [:]
        for clip in project.clips {
            guard let m = clip.media else {
                blocked[clip.id] = .missingFile
                continue
            }
            guard supportedCodecs.contains(m.codec) else {
                blocked[clip.id] = .unsupportedCodec
                continue
            }
            guard let ref = reference else { continue } // unreachable: m itself is a candidate
            if m.width != ref.width || m.height != ref.height {
                blocked[clip.id] = .frameSizeMismatch
            } else if m.codec != ref.codec {
                blocked[clip.id] = .codecMismatch
            } else if m.hasAudio != ref.hasAudio {
                blocked[clip.id] = .audioMismatch
            } else if m.audio != ref.audio {
                blocked[clip.id] = .audioFormatMismatch
            }
        }
```

(Keep the rest of `plan` unchanged, starting at `let inputs: [FrameGrid.ClipInput] = …`.)

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `93 passed, 0 failed, 0 skipped`. The old check "planner: blocks missing file, size, codec and audio mismatch" must still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ExportPlanner.swift Sources/SlateChecks/PlannerBlockerChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(planner): block unsupported codecs and audio format mismatch"
```

---

### Task 4: Mixed timescale overflow blocks (no silent rounding)

**Files:**
- Modify: `Sources/SlateCore/ExportPlanner.swift` (`outputTimescale`), `Sources/SlateCore/CompositionBuilder.swift:20-32` and `:67`
- Modify: `Sources/SlateChecks/PlannerBlockerChecks.swift`, `Sources/SlateChecks/CompositionChecks.swift`

**Interfaces:**
- Produces: in Mixed mode `outputTimescale` returns nil (→ `PlanBlocker.timescaleOverflow`) when the copied clips' timescales have no common multiple ≤ `Int32.max`; `CompositionError.offGrid(Rational)`.

- [ ] **Step 1: Write the failing checks**

Append inside `runPlannerBlockerChecks()` (before its closing brace):

```swift
    check("planner: Mixed clips whose timescales cannot share one timeline are blocked") {
        let odd = FrameTable.uniform(count: 50, frameDuration: Rational(1, 25), timescale: 2_147_483_629) // large prime
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        let b = TestData.clip(TestData.media(odd), keep: [(.zero, Rational(1))])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        expect(plan.blockers.contains(.timescaleOverflow), "\(plan.blockers)")
        expect(!plan.canExport)
    }
```

Append inside `runCompositionChecks()` (before its closing brace):

```swift
    await checkAsync("composition: an insert that is not a whole number of ticks throws instead of rounding") {
        let asset = AVURLAsset(url: try fixture("c24.mp4"))
        let ins = CompositionInsert(asset: asset, sourceStart: .zero, duration: Rational(1), outputStart: Rational(1, 7))
        do {
            _ = try await CompositionBuilder.build(inserts: [ins], includeAudio: false, timescale: 600)
            expect(false, "expected offGrid")
        } catch CompositionError.offGrid(let at) {
            expectEqual(at, Rational(1, 7))
        }
    }
```

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks planner`
Expected: build error `type 'CompositionError' has no member 'offGrid'`.

- [ ] **Step 3: Implement**

In `ExportPlanner.outputTimescale` replace the whole "Required timescales" loop with:

```swift
        // Required (copied) timescales: no common multiple that fits Int32 → blocker, in every mode.
        for ts in required {
            guard let l = Rational.lcm(t, Int64(ts)), l <= Int64(Int32.max) else { return nil }
            t = l
        }
```

and change the doc comment above `outputTimescale` to: `In every mode an overflow on a required (copied) timescale returns nil (blocker); optional overflows never block.` Also delete the two sentences in the doc that mention Mixed falling back to the largest timescale.

In `Sources/SlateCore/CompositionBuilder.swift` add the error case and text:

```swift
public enum CompositionError: Error, LocalizedError {
    case cannotAddTrack
    case noVideoTrack
    case missingAsset(UUID)
    case offGrid(Rational)

    public var errorDescription: String? {
        switch self {
        case .cannotAddTrack: return "Could not create a composition track."
        case .noVideoTrack: return "A clip has no video track."
        case .missingAsset(let id): return "No asset for clip \(id)."
        case .offGrid(let t): return "A clip cannot be placed exactly at \(t) s on the output timeline."
        }
    }
}
```

and replace `let at = ins.outputStart.cmTime(timescale: timescale) ?? ins.outputStart.cmTime` with:

```swift
            guard let at = ins.outputStart.cmTime(timescale: timescale) else {
                throw CompositionError.offGrid(ins.outputStart)
            }
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `95 passed, 0 failed, 0 skipped`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ExportPlanner.swift Sources/SlateCore/CompositionBuilder.swift Sources/SlateChecks/PlannerBlockerChecks.swift Sources/SlateChecks/CompositionChecks.swift
git commit -m "fix(planner): block Mixed timescale overflow; composition throws off-grid"
```

---

### Task 5: Exact expected-pts validation for Mixed

**Files:**
- Create: `Sources/SlateCore/ExpectedPTS.swift`, `Sources/SlateChecks/ExpectedPTSChecks.swift`
- Modify: `Sources/SlateCore/ExportPlanner.swift` (`ExportPlan` field + planner), `Sources/SlateCore/CadenceValidator.swift:50-61` and `:80-100`, `Sources/SlateCore/ProjectExporter.swift:45-50`, `Sources/SlateChecks/main.swift`

**Interfaces:**
- Produces: `ExpectedPTS.mixed(grid: [GridSegment], tables: [UUID: FrameTable]) -> [Rational]`; `ExportPlan.expectedPTS: [Rational]?` (non-nil only for a Mixed plan that can export); `CadenceValidator.mixedIssues(frameCount:expectedFrames:duration:expectedDuration:pts:expectedPTS:)` (last two default `nil`, and the 1 ms tolerance is gone: duration must match exactly); `CadenceValidator.validate(url:frameDuration:expectedFrames:expectedDuration:audioSampleRate:expectedPTS:)` (last param default `nil`).
- Consumes: `GridSegment` (`sourceStart`, `outputStart`, `outputDuration`, `sourceEnd`), `FrameTable.pts`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ExpectedPTSChecks.swift`:

```swift
import Foundation
import SlateCore

func runExpectedPTSChecks() {
    check("expected pts: Mixed 24 then 48 gives the source frames moved onto the output timeline") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        let b = TestData.clip(TestData.media(TestData.c48), keep: [(.zero, Rational(1))])
        let plan = ExportPlanner.plan(Project(clips: [a, b], fpsMode: .mixed))
        let expected = plan.expectedPTS ?? []
        expectEqual(expected.count, 72)
        expectEqual(expected.count, plan.totalFrames)
        expectEqual(Array(expected[0..<24]), (0..<24).map { Rational(Int64($0), 24) })
        expectEqual(Array(expected[24...]), (0..<48).map { Rational(1) + Rational(Int64($0), 48) })
    }

    check("expected pts: a mid-clip selection starts at its snapped source frame, shifted to the output start") {
        // keep [1.0, 1.5) of the 24 fps clip → frames 24…35 land at 0…11/24.
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(Rational(1), Rational(3, 2))])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        expectEqual(plan.expectedPTS ?? [], (0..<12).map { Rational(Int64($0), 24) })
    }

    check("expected pts: only Mixed plans that can export carry the list") {
        let a = TestData.clip(TestData.media(TestData.c24), keep: [(.zero, Rational(1))])
        expect(ExportPlanner.plan(Project(clips: [a])).expectedPTS == nil, "Constant plan")
        let blocked = TestData.clip(nil, keep: [(.zero, Rational(1))])
        expect(ExportPlanner.plan(Project(clips: [a, blocked], fpsMode: .mixed)).expectedPTS == nil, "blocked plan")
    }

    check("validator: Mixed exact check reports a shifted frame and stays quiet on a perfect list") {
        let expected = (0..<10).map { Rational(Int64($0), 24) }
        let ok = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(10, 24),
                                              expectedDuration: Rational(10, 24), pts: expected, expectedPTS: expected)
        expect(ok.isEmpty, "\(ok)")
        var shifted = expected
        for i in 5..<10 { shifted[i] = shifted[i] - Rational(1, 16) }
        let bad = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10, duration: Rational(10, 24),
                                               expectedDuration: Rational(10, 24), pts: shifted, expectedPTS: expected)
        expect(bad.count >= 1 && bad[0].contains("frame 5"), "\(bad)")
    }

    check("validator: Mixed duration must match exactly (no 1 ms tolerance)") {
        let issues = CadenceValidator.mixedIssues(frameCount: 10, expectedFrames: 10,
                                                  duration: Rational(1) + Rational(1, 2000), expectedDuration: Rational(1))
        expect(!issues.isEmpty)
    }
}
```

Register `runExpectedPTSChecks()` in `main.swift` after `runTimeMapChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks "expected pts"`
Expected: build error `value of type 'ExportPlan' has no member 'expectedPTS'`.

- [ ] **Step 3: Implement `ExpectedPTS`**

Create `Sources/SlateCore/ExpectedPTS.swift`:

```swift
import Foundation

/// The exact decoded presentation times a passthrough (Mixed) export must have.
/// Mixed copies frames, so the list is known before export: for every grid segment,
/// the source frames with pts in [sourceStart, sourceEnd), moved by outputStart − sourceStart.
public enum ExpectedPTS {
    public static func mixed(grid: [GridSegment], tables: [UUID: FrameTable]) -> [Rational] {
        var out: [Rational] = []
        for g in grid {
            guard let table = tables[g.clipID] else { continue }
            let shift = g.outputStart - g.sourceStart
            let end = g.sourceEnd
            for p in table.pts where p >= g.sourceStart && p < end {
                out.append(p + shift)
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Put the list on `ExportPlan`**

In `Sources/SlateCore/ExportPlanner.swift` add to `ExportPlan` after `public let blockers: [PlanBlocker]`:

```swift
    /// Mixed mode only, and only when the plan can export: the exact pts the output must decode to.
    public let expectedPTS: [Rational]?
```

In `plan(_:)` replace the final `return ExportPlan(...)` statement with:

```swift
        var expected: [Rational]?
        if case .mixed = project.fpsMode, blockers.isEmpty {
            var tables: [UUID: FrameTable] = [:]
            for c in project.clips { if let m = c.media { tables[c.id] = m.frames } }
            expected = ExpectedPTS.mixed(grid: grid.segments, tables: tables)
        }

        return ExportPlan(mode: project.fpsMode, strategy: project.constantStrategy, clips: clipPlans,
                          grid: grid.segments, totalDuration: grid.totalDuration, totalFrames: grid.totalFrames,
                          outputTimescale: timescale ?? 600, reference: reference, blockers: blockers,
                          expectedPTS: expected)
```

- [ ] **Step 5: Make the validator exact**

In `Sources/SlateCore/CadenceValidator.swift` replace `mixedIssues` with:

```swift
    /// Mixed mode: frame count, exact total duration and (when given) the exact pts list.
    public static func mixedIssues(frameCount: Int, expectedFrames: Int, duration: Rational,
                                   expectedDuration: Rational, pts: [Rational]? = nil,
                                   expectedPTS: [Rational]? = nil) -> [String] {
        var issues: [String] = []
        if frameCount != expectedFrames {
            issues.append("frame count \(frameCount), expected \(expectedFrames)")
        }
        if duration != expectedDuration {
            issues.append("duration \(duration.seconds) s, expected \(expectedDuration.seconds) s")
        }
        if let pts, let expectedPTS {
            var bad = 0
            for (n, pair) in zip(pts, expectedPTS).enumerated() where pair.0 != pair.1 {
                if bad < 5 { issues.append("frame \(n) at \(pair.0), expected \(pair.1)") }
                bad += 1
            }
            if bad > 5 { issues.append("\(bad - 5) more frames off the expected time") }
        }
        return issues
    }
```

Change the `validate` signature and the Mixed branch:

```swift
    public static func validate(url: URL, frameDuration: Rational?, expectedFrames: Int,
                                expectedDuration: Rational, audioSampleRate: Double?,
                                expectedPTS: [Rational]? = nil) async throws -> CadenceReport {
```

```swift
            issues += mixedIssues(frameCount: pts.count, expectedFrames: expectedFrames,
                                  duration: videoEnd - (pts.first ?? .zero), expectedDuration: expectedDuration,
                                  pts: pts, expectedPTS: expectedPTS)
```

In `Sources/SlateCore/ProjectExporter.swift` default validator add `expectedPTS: plan.expectedPTS` as the last argument of `CadenceValidator.validate(...)`.

- [ ] **Step 6: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `100 passed, 0 failed, 0 skipped` — **unless** the two Mixed exporter checks (`exporter: mixed 24 + 48 copies everything`, `… with audio`) now fail. That is the acceptance question of Task 6, not a bug to hide: if they fail, do NOT edit them and do NOT loosen the validator. Note the failure text and go to Task 6 (commit first).

- [ ] **Step 7: Commit**

```bash
git add Sources/SlateCore/ExpectedPTS.swift Sources/SlateCore/ExportPlanner.swift Sources/SlateCore/CadenceValidator.swift Sources/SlateCore/ProjectExporter.swift Sources/SlateChecks/ExpectedPTSChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(validator): exact expected-pts check for Mixed exports"
```

---

### Task 6: ACCEPTANCE GATE — does AVFoundation put Mixed on the exact grid?

This task decides whether ruling 1 ("Mixed stays, labelled Apple-only") is alive. No UI work exists in this plan, but Plan 2B must not start before this result is recorded.

**Files:** none in `Sources/`. Update `MASTER_PLAN.md` (on disk).

- [ ] **Step 1: Run the Mixed exporter checks**

Run: `swift run SlateChecks "exporter: mixed" 2>&1 | tail -8`
Expected on PASS: both lines `✓ exporter: mixed 24 + 48 copies everything` and `✓ exporter: mixed 24 + 48 with audio`, `2 passed, 0 failed`.

- [ ] **Step 2: Run the Phase 0 command**

Run: `swift run SlateChecks phase0 2>&1 | tail -20`
Expected on PASS: `PASS  phase0-mixed.mp4` and `PASS  phase0-mixed-audio.mp4` (the Selective rows may still FAIL — that is the known Phase 0 finding and is fine).

- [ ] **Step 3: Record the result**

Add a dated line at the top of the `## Done` list in `MASTER_PLAN.md`:

- PASS: `- [YYYY-MM-DD] Plan 2A acceptance: exact expected-pts check passes on phase0-mixed(-audio) and ex-mixed. Ruling 1 (Mixed stays, "Apple players only") holds.`
- FAIL: `- [YYYY-MM-DD] Plan 2A acceptance: exact expected-pts check FAILS on <files>: <first 3 issues>. Ruling 1 reopened.`

Also change the `Known Issues` bullet "Mixed-mode joins misplace frames in ffmpeg …" to say it is now ruled: Mixed is opt-in and labelled Apple-only.

- [ ] **Step 4: Decide**

- PASS → continue with Task 7.
- FAIL → **STOP.** Do not continue to Task 7. Report to the user in plain words: which files, the issues, and the two options from the spec (gate Mixed copy on identical format descriptions, or re-encode at joins). Wait for the user's ruling. Do not weaken `mixedIssues` to make it pass.

---

### Task 7: Exporter — "Re-encoding k of n", max bitrate, cancel during validation

**Files:**
- Create: `Sources/SlateCore/ReencodeProgress.swift`, `Sources/SlateChecks/ValidationCancelChecks.swift`
- Modify: `Sources/SlateCore/ClipReencoder.swift:52-61`, `Sources/SlateCore/ProjectExporter.swift`, `Sources/SlateCore/CadenceValidator.swift`, `Sources/SlateChecks/main.swift`, `Sources/SlateChecks/ReencoderChecks.swift`

**Interfaces:**
- Produces: `ReencodeProgress.clipIndex(fraction: Double, frameCounts: [Int]) -> Int` (1-based); `VideoEncodeSettings.matching(_ medias: [ClipMedia])` (codec/size of the first, bitrate from the largest `estimatedDataRate`); `ProjectExporter.cancel()` now also cancels a running validation; `.reencoding(clip:of:progress:)` reports the real index in Re-encode all.

- [ ] **Step 1: Write the failing checks**

Append inside `runReencoderChecks()` before its closing brace (use Edit on the unique text `        try await assertNoFrameReordering(out)\n    }\n}`, replacing it with the same text plus these checks before the final `}`):

```swift

    check("progress: the clip index follows the written frames") {
        let counts = [24, 48]
        expectEqual(ReencodeProgress.clipIndex(fraction: 0, frameCounts: counts), 1)
        expectEqual(ReencodeProgress.clipIndex(fraction: 23.0 / 72.0, frameCounts: counts), 1)
        expectEqual(ReencodeProgress.clipIndex(fraction: 24.0 / 72.0, frameCounts: counts), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 1, frameCounts: counts), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 0, frameCounts: [0, 10]), 2)
        expectEqual(ReencodeProgress.clipIndex(fraction: 0.5, frameCounts: []), 1)
    }

    check("encoder settings: bitrate comes from the fastest clip, not the first") {
        let lo = TestData.media(TestData.c24)
        var hi = TestData.media(TestData.c24)
        hi.estimatedDataRate = 30_000_000
        let mixed = VideoEncodeSettings.matching([lo, hi])
        expectEqual(mixed.bitsPerSecond, VideoEncodeSettings.matching(hi).bitsPerSecond)
        expect(mixed.bitsPerSecond > VideoEncodeSettings.matching(lo).bitsPerSecond)
        expectEqual(mixed.codec, VideoEncodeSettings.matching(lo).codec)
    }

    await checkAsync("exporter: Re-encode all reports the real clip index") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let b = try await loadClip("c48.mp4", keep: [(0.5, 1.5)])
        let out = try checksOutputDirectory().appendingPathComponent("ex-progress-index.mp4")
        let seen = SeenClips()
        _ = try await ProjectExporter().export(project: Project(clips: [a, b]), outputURL: out,
                                               tempDirectory: try checksOutputDirectory(), progress: { stage in
            if case .reencoding(let k, let n, _) = stage { seen.add(k, of: n) }
        })
        expectEqual(seen.of, 2)
        expect(seen.indices.contains(1) && seen.indices.contains(2), "saw \(seen.indices)")
    }
```

Add this helper at the end of `Sources/SlateChecks/ReencoderChecks.swift` (outside the function):

```swift
final class SeenClips: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<Int>()
    private var total = 0
    func add(_ k: Int, of n: Int) { lock.withLock { set.insert(k); total = n } }
    var indices: Set<Int> { lock.withLock { set } }
    var of: Int { lock.withLock { total } }
}
```

Create `Sources/SlateChecks/ValidationCancelChecks.swift`:

```swift
import Foundation
import SlateCore

func runValidationCancelChecks() async {
    await checkAsync("exporter: cancel during validation ends as cancelled and keeps an existing export") {
        let a = try await loadClip("c24.mp4", keep: [(0.5, 1.5)])
        let dir = try checksOutputDirectory()
        let out = dir.appendingPathComponent("ex-cancel-validate.mp4")
        try Data("previous export".utf8).write(to: out)
        let exporter = ProjectExporter()
        exporter.validator = { _, _ in
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return CadenceReport(frameCount: 0, videoDuration: .zero, issues: [])
        }
        let started = Date()
        do {
            _ = try await exporter.export(project: Project(clips: [a]), outputURL: out, tempDirectory: dir,
                                          progress: { stage in
                if stage == .validating {
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        exporter.cancel()
                    }
                }
            })
            expect(false, "expected cancelled")
        } catch ProjectExportError.cancelled {
            // expected
        }
        expect(Date().timeIntervalSince(started) < 15, "cancel did not interrupt the validation")
        expectEqual(try String(contentsOf: out, encoding: .utf8), "previous export")
    }
}
```

Register `await runValidationCancelChecks()` in `main.swift` after `await runExporterChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks progress`
Expected: build error `cannot find 'ReencodeProgress'`.

- [ ] **Step 3: Implement the pure helper and the bitrate**

Create `Sources/SlateCore/ReencodeProgress.swift`:

```swift
import Foundation

public enum ReencodeProgress {
    /// The 1-based clip the encoder is working on when `fraction` of all frames are written.
    /// `frameCounts` has one entry per re-encode job, in order.
    public static func clipIndex(fraction: Double, frameCounts: [Int]) -> Int {
        guard !frameCounts.isEmpty else { return 1 }
        let total = frameCounts.reduce(0, +)
        guard total > 0 else { return 1 }
        let written = Int((fraction * Double(total)).rounded(.down))
        var upTo = 0
        for (i, n) in frameCounts.enumerated() {
            upTo += n
            if written < upTo { return i + 1 }
        }
        return frameCounts.count
    }
}
```

In `Sources/SlateCore/ClipReencoder.swift`, inside `VideoEncodeSettings` after `matching(_ media:)` add:

```swift
    /// Codec and size of the first clip; bitrate from the clip with the highest data rate.
    public static func matching(_ medias: [ClipMedia]) -> VideoEncodeSettings {
        precondition(!medias.isEmpty, "matching needs at least one clip")
        var reference = medias[0]
        reference.estimatedDataRate = medias.map(\.estimatedDataRate).max() ?? reference.estimatedDataRate
        return matching(reference)
    }
```

- [ ] **Step 4: Wire the exporter**

In `Sources/SlateCore/ProjectExporter.swift`:

(a) Add a property next to `reencoder`: `private var validationTask: Task<CadenceReport, Error>?`

(b) In `cancel()` add `validationTask?.cancel()` inside the lock block.

(c) Replace `let report = try await validator(staged, plan)` with `let report = try await runValidation(staged, plan)` and add the method:

```swift
    private func runValidation(_ url: URL, _ plan: ExportPlan) async throws -> CadenceReport {
        let task = Task { try await validator(url, plan) }
        lock.withLock { validationTask = task }
        defer { lock.withLock { validationTask = nil } }
        if isCancelled { task.cancel() }
        return try await task.value
    }
```

(d) In `render(...)`: delete the line `let reference = plan.reference!`, and after `let clips = …` / `assets` setup add:

```swift
        let encodeMedias = plan.clips.filter { !$0.segments.isEmpty }.compactMap { clips[$0.clipID]?.media }
```

(e) Replace the Re-encode-all call

```swift
            try await reencode(jobs, d: d, plan: plan, reference: reference, to: output) { p in
                progress(.reencoding(clip: 1, of: 1, progress: p))
            }
```

with

```swift
            let counts = jobs.map { $0.segments.reduce(0) { $0 + $1.frameCount } }
            try await reencode(jobs, d: d, plan: plan, medias: encodeMedias, to: output) { p in
                progress(.reencoding(clip: ReencodeProgress.clipIndex(fraction: p, frameCounts: counts),
                                     of: jobs.count, progress: p))
            }
```

(f) In the selective branch change `try await reencode([job], d: d, plan: plan, reference: reference, to: tmp)` to `try await reencode([job], d: d, plan: plan, medias: encodeMedias, to: tmp)`.

(g) Change the `reencode` helper signature and body: `private func reencode(_ jobs: [ReencodeJob], d: Rational, plan: ExportPlan, medias: [ClipMedia], to url: URL, progress: …)` and `video: .matching(medias)` instead of `.matching(reference)`.

- [ ] **Step 5: Make the validator interruptible**

In `Sources/SlateCore/CadenceValidator.swift`: in `validate(...)` add `try Task.checkCancellation()` right after the video `decodedTimes` call (before `let videoEnd`) and again before the audio pass (`if let sampleRate = audioSampleRate {`). In `decodedTimes`, inside the `while let buffer` loop add a counter and check:

```swift
        var seen = 0
        while let buffer = output.copyNextSampleBuffer() {
            seen += 1
            if seen % 64 == 0 { try Task.checkCancellation() }
```

(keep the rest of the loop body as it is).

- [ ] **Step 6: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `104 passed, 0 failed, 0 skipped` (100 + 4 new; the cancel check and the index check both count).

- [ ] **Step 7: Commit**

```bash
git add Sources/SlateCore Sources/SlateChecks
git commit -m "feat(export): real clip index, max bitrate over clips, cancel during validation"
```

---

### Task 8: Audio-shortfall bound in the composition; name the clip

**Files:**
- Modify: `Sources/SlateCore/CompositionBuilder.swift`, `Sources/SlateCore/ClipReencoder.swift` (`AudioSampleSource`, `ReencodeError`), `Sources/SlateCore/ProjectExporter.swift` (insert creation), `scripts/make-test-clips.sh`, `Sources/SlateChecks/CompositionChecks.swift`

**Interfaces:**
- Produces: `CompositionInsert.clipID: UUID?` (new init param `clipID: UUID? = nil`, last); `CompositionError.audioTruncated(clip: UUID?, seconds: Double)` thrown when an insert's audio is more than 1024 samples shorter than its video range; `ReencodeError.clipAudioTruncated(clip: UUID?, samples: Int64)` thrown by the re-encoder instead of the unnamed `audioTruncated` (the unnamed case stays for `AudioCoverage`).

- [ ] **Step 1: Add a fixture with clearly short audio**

In `scripts/make-test-clips.sh`, after the `c24_short_a.mp4` block, add:

```bash
# Audio 0.5 s shorter than the video: far beyond one AAC packet, must be refused.
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=4.5 \
    "${X264[@]}" -c:a aac -b:a 128k "$OUT/c24_trunc_a.mp4"
```

Run: `scripts/make-test-clips.sh` (needs Homebrew ffmpeg). Expected last line `✓ fixtures in …/build/fixtures`.

- [ ] **Step 2: Write the failing check**

Append inside `runCompositionChecks()`:

```swift
    await checkAsync("composition: audio more than one AAC packet short throws and names the clip") {
        let a = try await loadClip("c24_trunc_a.mp4", keep: [(0, 5)])
        let plan = ExportPlanner.plan(Project(clips: [a], fpsMode: .mixed))
        do {
            _ = try await CompositionBuilder.build(
                inserts: CompositionBuilder.inserts(for: plan.grid, assets: [a.id: AVURLAsset(url: a.url)]),
                includeAudio: true, timescale: plan.outputTimescale)
            expect(false, "expected audioTruncated")
        } catch CompositionError.audioTruncated(let clip, let seconds) {
            expectEqual(clip, a.id)
            expect(seconds > 0.4 && seconds < 0.6, "seconds \(seconds)")
        }
    }
```

- [ ] **Step 3: Run to see it fail**

Run: `swift run SlateChecks composition`
Expected: build error `type 'CompositionError' has no member 'audioTruncated'`.

- [ ] **Step 4: Implement the composition bound**

In `Sources/SlateCore/CompositionBuilder.swift`:

(a) `CompositionInsert`: add `public let clipID: UUID?` and change the init to

```swift
    public init(asset: AVAsset, sourceStart: Rational, duration: Rational, outputStart: Rational,
                clipID: UUID? = nil) {
        self.asset = asset
        self.sourceStart = sourceStart
        self.duration = duration
        self.outputStart = outputStart
        self.clipID = clipID
    }
```

(b) In `inserts(for:assets:)` pass `clipID: g.clipID` to `CompositionInsert(...)`.

(c) Add to `CompositionError`: `case audioTruncated(clip: UUID?, seconds: Double)` with description

```swift
        case .audioTruncated(let clip, let s):
            return "The audio of clip \(clip.map { $0.uuidString } ?? "?") ends \(String(format: "%.2f", s)) s before its video."
```

(d) Replace the audio block inside the `for ins in inserts` loop with:

```swift
            if let audio, let srcAudio = try await ins.asset.loadTracks(withMediaType: .audio).first {
                // Audio may end a few ms before video. Insert only the overlapping part,
                // but never more than one AAC packet (1024 samples) short.
                let audioRange = try await srcAudio.load(.timeRange)
                let clipped = range.intersection(audioRange)
                let covered = clipped.duration > .zero ? Rational(clipped.duration) : Rational.zero
                let missing = Rational(range.duration) - covered
                let rate = try await Self.sampleRate(of: srcAudio)
                if missing > Rational(1024, Int64(rate.rounded())) {
                    throw CompositionError.audioTruncated(clip: ins.clipID, seconds: missing.seconds)
                }
                if clipped.duration > .zero {
                    let offset = CMTimeSubtract(clipped.start, range.start)
                    try audio.insertTimeRange(clipped, of: srcAudio, at: CMTimeAdd(at, offset))
                }
            }
```

(e) Add inside `CompositionBuilder`:

```swift
    private static func sampleRate(of track: AVAssetTrack) async throws -> Double {
        let formats = try await track.load(.formatDescriptions)
        if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee,
           asbd.mSampleRate > 0 {
            return asbd.mSampleRate
        }
        return 44100
    }
```

(f) In `ProjectExporter.render` the re-encoded insert becomes `CompositionInsert(asset: AVURLAsset(url: tmp), sourceStart: .zero, duration: total, outputStart: cp.segments[0].outputStart, clipID: cp.clipID)`.

- [ ] **Step 5: Name the clip in the re-encoder**

In `ClipReencoder.swift` add to `ReencodeError`: `case clipAudioTruncated(clip: UUID?, samples: Int64)` with description `"The audio of clip \(clip.map { $0.uuidString } ?? "?") ends \(n) samples early."`.

In `AudioSampleSource` add the helper and use it at the three coverage call sites (`try coverage!.finish()` twice, `try coverage!.accept(first:count:)` once):

```swift
    private func naming<T>(_ piece: Piece, _ body: () throws -> T) throws -> T {
        do { return try body() } catch ReencodeError.audioTruncated(let samples) {
            throw ReencodeError.clipAudioTruncated(clip: jobs[piece.job].segments.first?.clipID, samples: samples)
        }
    }
```

e.g. `let gapCount = try naming(piece) { try coverage!.finish() }` and `let accepted = try naming(piece) { try coverage!.accept(first: first, count: n) }`.

- [ ] **Step 6: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `105 passed, 0 failed, 0 skipped`. The existing "audio a few ms shorter than video does not throw" and the short-audio Re-encode-all check must still pass (their shortfall is under 1024 samples).

- [ ] **Step 7: Commit**

```bash
git add Sources/SlateCore Sources/SlateChecks scripts/make-test-clips.sh
git commit -m "feat(composition): bound audio shortfall to one AAC packet and name the clip"
```

---

### Task 9: Silence buffers keep the reader's format (stereo)

**Files:**
- Modify: `scripts/make-test-clips.sh`, `Sources/SlateCore/ClipReencoder.swift` (`AudioSampleSource`), `Sources/SlateChecks/ReencoderChecks.swift`

**Interfaces:**
- Produces: `AudioSampleSource.appendSilence` builds its buffer with the format description of the last decoded audio buffer when one exists; otherwise with an explicit mono/stereo channel layout.

- [ ] **Step 1: Add a stereo short-audio fixture**

In `scripts/make-test-clips.sh` after the `c24_trunc_a.mp4` block:

```bash
# Stereo audio a few hundred samples short (same idea as c24_short_a, two channels).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=4.99 \
    "${X264[@]}" -c:a aac -ac 2 -b:a 128k "$OUT/c24_st_short_a.mp4"
```

Run `scripts/make-test-clips.sh`. Then check: `ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 build/fixtures/c24_st_short_a.mp4` prints `2`.

- [ ] **Step 2: Write the check**

Append inside `runReencoderChecks()` (same Edit trick as Task 7, before the final `}`):

```swift

    await checkAsync("reencoder: stereo short audio is padded and the export still ends with the video") {
        let a = try await loadClip("c24_st_short_a.mp4", keep: [(0, 5.0)])
        let b = try await loadClip("c24_st_short_a.mp4", keep: [(0, 5.0)])
        expectEqual(a.media?.audio?.channels, 2)
        let project = Project(clips: [a, b])
        let plan = ExportPlanner.plan(project)
        expect(plan.canExport, "\(plan.blockers)")
        let out = try checksOutputDirectory().appendingPathComponent("re-stereo-short-audio.mp4")
        let report = try await ProjectExporter().export(project: project, outputURL: out,
                                                        tempDirectory: try checksOutputDirectory(), progress: { _ in })
        expect(report.ok, "\(report.issues)")
        let rate = Int64((plan.audio?.sampleRate ?? 44100).rounded())
        let (first, end) = try await preciseAudioRange(out)
        expect(first.magnitude <= Rational(1024, rate), "first audio sample at \(first.seconds) s")
        expect((end - plan.totalDuration).magnitude <= Rational(1, rate),
               "audio ends at \(end.seconds) s, video at \(plan.totalDuration.seconds) s")
    }
```

- [ ] **Step 3: Run the check**

Run: `swift run SlateChecks "reencoder: stereo"`
Expected: it may pass or fail today. Note the result, then apply Step 4 either way (the spec requires the change) and re-run.

- [ ] **Step 4: Implement**

In `AudioSampleSource` add a stored property `private var readerFormat: CMFormatDescription?`. In `appendNext`, right after `let pts = CMSampleBufferGetPresentationTimeStamp(buffer)` add `if let f = CMSampleBufferGetFormatDescription(buffer) { readerFormat = f }`.

In `appendSilence` replace the block that builds `asbd` and `formatDescription` (from `var asbd = …` through the `guard fdStatus == noErr …` line) with:

```swift
        let formatDescription: CMFormatDescription
        if let readerFormat {
            formatDescription = readerFormat
        } else {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: format.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(bytesPerFrame),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(bytesPerFrame),
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono
                : channels == 2 ? kAudioChannelLayoutTag_Stereo
                : kAudioChannelLayoutTag_DiscreteInOrder | channels
            var made: CMFormatDescription?
            let fdStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &made)
            guard fdStatus == noErr, let made else { throw ReencodeError.audioFailed(fdStatus) }
            formatDescription = made
        }
```

- [ ] **Step 5: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `106 passed, 0 failed, 0 skipped`. If the stereo check fails on the export (not on the fixture), stop and report the exact message; do not loosen the check.

- [ ] **Step 6: Commit**

```bash
git add Sources/SlateCore/ClipReencoder.swift Sources/SlateChecks/ReencoderChecks.swift scripts/make-test-clips.sh
git commit -m "fix(reencoder): silence buffers use the reader's audio format (stereo verified)"
```

---

### Task 10: `ClipProbe` throws on an unreadable format

**Files:**
- Modify: `Sources/SlateCore/ClipProbe.swift:5-17` and `:25-37`

**Interfaces:**
- Produces: `ClipProbeError.unreadableFormat(String)`.

- [ ] **Step 1: Implement**

Add to `ClipProbeError`: `case unreadableFormat(String)` with description `"Could not read the \(kind) format of the file."` (`case .unreadableFormat(let kind): return "Could not read the \(kind) format of the file."`).

Replace `let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0` with:

```swift
        guard let videoFormat = formats.first else { throw ClipProbeError.unreadableFormat("video") }
        let codec = CMFormatDescriptionGetMediaSubType(videoFormat)
```

Replace the audio block with:

```swift
        var audio: AudioFormat?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            guard let f = audioFormats.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee else {
                throw ClipProbeError.unreadableFormat("audio")
            }
            audio = AudioFormat(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
        }
```

- [ ] **Step 2: Run all checks (regression only; no fixture can trigger the throw)**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `106 passed, 0 failed, 0 skipped`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SlateCore/ClipProbe.swift
git commit -m "fix(probe): unreadable video or audio format throws instead of looking like a mismatch"
```

---

### Task 11: `.slate` project file (v1) and relink

**Files:**
- Create: `Sources/SlateCore/ProjectFile.swift`, `Sources/SlateChecks/ProjectFileChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Produces:
  - `ProjectFile` (`Codable, Equatable`): `version: Int`, `fpsMode: FPSModeRecord`, `clips: [ClipRecord]`; nested records `RationalRecord{num,den}`, `FPSModeRecord{kind,frameDuration?}`, `SegmentRecord{id,start,end,isAuto}`, `ClipRecord{id,relativePath?,absolutePath,segments}`.
  - `ProjectFile.currentVersion = 1`.
  - `ProjectFile.init(project: Project, savedAt fileURL: URL?)` — `fileURL` nil = untitled (no relative paths).
  - `func encoded() throws -> Data`, `static func decode(_ data: Data) throws -> ProjectFile` (throws `ProjectFileError`).
  - `func project(resolvingFrom fileURL: URL?, exists: (URL) -> Bool) -> Project` — media is always nil; `constantStrategy` is `.reencodeAll`.
  - `func write(to url: URL) throws` (atomic), `static func load(from url: URL) async throws -> Project` (decode, resolve, probe each existing file; a probe failure leaves `media == nil`).
  - `ProjectFileError.unsupportedVersion(Int)`, `.notAProject`.
  - `PathRelinking.relativePath(of: URL, from directory: URL) -> String`, `PathRelinking.resolve(relative: String, from directory: URL) -> URL`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/ProjectFileChecks.swift`:

```swift
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
```

Register `await runProjectFileChecks()` in `main.swift` after `await runProbeChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks "project file"`
Expected: build error `cannot find 'PathRelinking'`.

- [ ] **Step 3: Implement**

Create `Sources/SlateCore/ProjectFile.swift`:

```swift
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
        guard v.version <= currentVersion else { throw ProjectFileError.unsupportedVersion(v.version) }
        do {
            return try JSONDecoder().decode(ProjectFile.self, from: data)
        } catch {
            throw ProjectFileError.notAProject
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
```

Note for the implementer: the round-trip check compares `url.path` against `resolvingSymlinksInPath().path` because the file stores the resolved absolute path (`/tmp` becomes `/private/tmp` on macOS). Do not "fix" that by dropping the resolve: the relative path is computed from resolved paths on both sides.

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `113 passed, 0 failed, 0 skipped` (106 + 7). If the JSON string replacements in the "newer version" check do not match (pretty-printer spacing), print `json` and adjust the two `replacingOccurrences` needles to the printed form; the intent is: version 2 is refused, an extra field is ignored.

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/ProjectFile.swift Sources/SlateChecks/ProjectFileChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): .slate project file v1 with relative/absolute relink"
```

---

### Task 12: Autosave engine

**Files:**
- Create: `Sources/SlateCore/Autosave.swift`, `Sources/SlateChecks/AutosaveChecks.swift`
- Modify: `Sources/SlateChecks/main.swift`

**Interfaces:**
- Produces:
  - `Autosaver(delay: Duration, write: @escaping @Sendable () async throws -> Void, onError: @escaping @Sendable (Error) -> Void = { _ in })` with `noteChange()` (restarts the timer), `flush() async` (cancel the timer, write now), `cancel()`.
  - `UntitledAutosaveStore(directory: URL)` with `static var defaultDirectory: URL` (`~/Library/Application Support/Slate/Autosave`), `save(_ file: ProjectFile) throws`, `pending() -> ProjectFile?` (nil when absent or unreadable), `discard()`.
- Consumes: `ProjectFile.encoded()`, `ProjectFile.decode(_:)`.
- 2B wiring (not in this plan): saved project → `Autosaver(delay: .seconds(2))` writing `ProjectFile.write(to:)`; untitled → same debounce writing `UntitledAutosaveStore.save`.

- [ ] **Step 1: Write the failing checks**

Create `Sources/SlateChecks/AutosaveChecks.swift`:

```swift
import Foundation
import CoreMedia
import SlateCore

final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
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
```

Register `await runAutosaveChecks()` in `main.swift` after `await runProjectFileChecks()`.

- [ ] **Step 2: Run to see it fail**

Run: `swift run SlateChecks autosave`
Expected: build error `cannot find 'Autosaver'`.

- [ ] **Step 3: Implement**

Create `Sources/SlateCore/Autosave.swift`:

```swift
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
```

- [ ] **Step 4: Run all checks**

Run: `swift run SlateChecks --strict 2>&1 | tail -3`
Expected: `119 passed, 0 failed, 0 skipped` (113 + 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/SlateCore/Autosave.swift Sources/SlateChecks/AutosaveChecks.swift Sources/SlateChecks/main.swift
git commit -m "feat(core): debounced Autosaver and untitled autosave store"
```

---

### Task 13: Close-out — full run, docs, hand-off to Plan 2B

**Files:**
- Modify (disk only, gitignored): `MASTER_PLAN.md`
- Create: `docs/superpowers/handoffs/2026-09-30-plan2b-handoff.md`

- [ ] **Step 1: Full verification**

Run: `swift run SlateChecks --strict 2>&1 | tail -3` → expect `119 passed, 0 failed, 0 skipped`.
Run: `swift run SlateChecks phase0 2>&1 | tail -14` → expect the Mixed and Re-encode-all rows PASS; Selective rows may FAIL (known, hidden).
Run: `swift build 2>&1 | tail -3` → expect `Build complete!` (the app target must still compile: nothing in `Sources/Slate` was touched).

- [ ] **Step 2: Update `MASTER_PLAN.md`**

- `Done`: add `[date] Plan 2A implemented …` with the check count, plus the Task 6 result line if not yet there.
- `File Map`: add `ExpectedPTS`, `ReencodeProgress`, `ProjectFile`, `Autosave` to the `Sources/SlateCore/` list; check count 119.
- `In Progress`: replace the Plan 2 line with "Plan 2B (UI) to be written against the 2A APIs".
- `Next`: item 0 becomes "Write Plan 2B". Carry the list from the hand-off file.
- `Architecture Decisions`: add the three user rulings (Mixed Apple-only label; Selective hidden; new project = Constant + Re-encode all, target = highest fps, sticky after the user picks) and "validation failure refuses export in every mode".

- [ ] **Step 3: Write the Plan 2B hand-off**

Create `docs/superpowers/handoffs/2026-09-30-plan2b-handoff.md` with these sections (short, factual):
1. What 2A delivered (list the public APIs from the "Interfaces" blocks above).
2. What 2B must build (spec sections 2 and 3): `ProjectViewModel` (project, selection, project-wide undo, `FrameRateChoice` target that follows the highest fps until the user picks, then sticky), `ClipStripView` + `ClipStripMouseCapture` (AppKit mouse, drag reorder, Finder drops, context menu), Clip/Project player mode with `ProjectTimeMap` + `CompositionBuilder`, toolbar (Constant picker + Mixed toggle with the label text from Global Constraints, total duration, Export), rewritten `ExportSheet` (plan rows incl. reasons and audio format differences, stages Re-encoding k of n → Assembling → Validating, cancel, refused-export report), `.slate` open/save/save-as (Cmd+S), `Autosaver` wiring (2 s saved, `UntitledAutosaveStore` for untitled + restore offer on launch), Info.plist `.slate` document type `co.aceguardian.slate.project`, replacing the old `Sources/Slate/Services/Exporter.swift` and single-clip `EditorViewModel` flow, hotkeys from the spec.
3. Badge rule: yellow only when the clip's own timing would not copy (fps differs / timing not exact); in Constant mode every clip is re-encoded, so the badge must not simply mirror the plan action.
4. Open items to ask the user before writing 2B (one at a time, two options with a recommendation): e.g. whether Cmd+O on a second file adds to the project or opens a new window.
5. Environment gotchas (sandbox, heredocs, fixtures, `--strict`).

- [ ] **Step 4: Commit the hand-off and finish the branch**

```bash
git add docs/superpowers/handoffs/2026-09-30-plan2b-handoff.md
git commit -m "docs: Plan 2B hand-off"
```

Then use superpowers:finishing-a-development-branch.

---

## Self-review notes (spec coverage)

- Spec ruling 1 (Mixed label): text fixed in Global Constraints; shown in 2B. Ruling 2 (Selective hidden, default `.reencodeAll`, not stored): Tasks 2, 11. Ruling 3 (new project default, target = highest, sticky): Task 2 (list + default), sticky behaviour in 2B (view model). Ruling 4 (exact Mixed pts, acceptance step, refuse in every mode, Mixed `T_out` block): Tasks 4, 5, 6.
- Carry-over list: audio format (3), codecs (3), bitrate max (7), "k of n" (7), composition bound + clip name (8), cancel in validation (7), silence layout (9), fps picker `d` (2), ClipProbe (10), `--strict`/stale INVALID/precondition (1). Plan-row audio-difference text and hotkeys are 2B.
- Spec section 1 "Project file" and autosave: Tasks 11, 12. Sections 2 (UI) and 3 (export sheet stages) are 2B.
- Type names used across tasks: `FrameRateChoice`, `ExpectedPTS.mixed`, `ExportPlan.expectedPTS`, `ReencodeProgress.clipIndex`, `VideoEncodeSettings.matching(_ [ClipMedia])`, `CompositionError.audioTruncated(clip:seconds:)`, `CompositionError.offGrid`, `ReencodeError.clipAudioTruncated(clip:samples:)`, `ProjectFile`, `PathRelinking`, `Autosaver`, `UntitledAutosaveStore` — each defined in the task that first uses it.

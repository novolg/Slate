# Task 12 Report: ProjectExporter

## Status: DONE_WITH_CONCERNS

## What was implemented

- `Sources/SlateCore/ProjectExporter.swift` — `ExportStage`, `ProjectExportError`, and
  `ProjectExporter` exactly as specified in the brief, with one required deviation (see below).
- `Sources/SlateChecks/ExporterChecks.swift` — the 10 checks exactly as specified in the brief.
- `Sources/SlateChecks/main.swift` — added `await runExporterChecks()` after
  `await runReencoderChecks()`.

`ProjectExporter.export(project:outputURL:tempDirectory:progress:)`:
1. Plans the project (`ExportPlanner.plan`), throws `.blocked` if not exportable, before touching
   any file.
2. Refuses if `outputURL` (or `keepInvalidAt`, when set) aliases any source clip URL —
   `outputCollides` compares both the resolved (symlink-following) path and the file resource
   identifier (catches hard links / case aliases on a case-insensitive volume) — before creating
   any directory or writing anything.
3. Renders into a per-call temp working directory (`tempDirectory/slate-export-<uuid>/`), removed
   via `defer` on every exit path (success, thrown error, or cancellation).
4. Renders either via `ClipReencoder` directly (re-encode-all) or via a mix of
   `CompositionBuilder` (copied segments) + per-clip `ClipReencoder` runs stitched back in via
   `CompositionInsert` + `AVAssetExportSession` passthrough (mixed / selective).
5. Validates the staged file (`validator`, replaceable in checks) before ever touching the real
   destination.
6. On success, atomically installs the staged file at `outputURL` via a same-directory sibling
   (`.slate-<uuid>.mp4`) + `replaceItemAt`/`moveItem`, so a crash mid-install cannot corrupt an
   existing destination and a validation failure never touches it.
7. `cancel()` cancels the active `AVAssetExportSession` or `ClipReencoder` and is checked at each
   render stage boundary; any cancellation surfaces as `ProjectExportError.cancelled`, keeping the
   existing destination file and leaving no `.slate-*` staging file or temp directory behind.

## Deviation from the brief (as flagged by the controller)

`CompositionBuilder.inserts(for:assets:)` now throws (`CompositionError.missingAsset`), per an
earlier review. The brief's Step 3 code called it without `try` on the `.copy` branch inside
`render(...)`. I wrote:

```swift
case .copy:
    inserts += try CompositionBuilder.inserts(for: cp.segments, assets: [cp.clipID: asset])
```

This was the only intended deviation and is exactly what the controller's briefing called for.

## TDD evidence

**RED** (Step 2) — build fails as expected:

```
$ swift run SlateChecks exporter
.../ExporterChecks.swift:8:28: error: cannot find 'ProjectExporter' in scope
... (7 occurrences)
```

**GREEN** (Step 3-4) — after creating `ProjectExporter.swift`:

```
$ swift build
Build complete! (2.87s)

$ swift run SlateChecks exporter
  ✓ exporter: mixed 24 + 48 copies everything
  ✓ exporter: constant 24 selective and re-encode all agree
  ✗ exporter: constant 48 selective with audio
      threw: validationFailed(frameCount: 199, videoDuration: 199/48,
             issues: ["frame 76 lasts 1/16, expected 1/48"])
  ✗ exporter: the same file twice as two clips
      threw: validationFailed(frameCount: 48, videoDuration: 2,
             issues: ["frame 23 lasts 1/12, expected 1/24"])
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

8 passed, 2 failed, 0 skipped
```

This is reproducible (ran twice, identical result both times, including after fully reverting all
debug instrumentation back to the brief's exact `ExporterChecks.swift`).

**Whole suite:**

```
$ swift run SlateChecks
... (all 65 other checks pass) ...
  ✓ exporter: mixed 24 + 48 copies everything
  ✓ exporter: constant 24 selective and re-encode all agree
  ✗ exporter: constant 48 selective with audio
  ✗ exporter: the same file twice as two clips
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

75 passed, 2 failed, 0 skipped
```

## The Phase 0 finding (why this is DONE_WITH_CONCERNS, not a code bug)

The brief's Step 4 note anticipated a possible failure specifically in "constant 24 selective"
while "re-encode all" passes, and told me not to hide it if seen. What I actually got is close in
spirit but not identical in shape: "constant 24 selective and re-encode all agree" **passes**
cleanly, but two *other* checks fail — "constant 48 selective with audio" and "the same file twice
as two clips" — both via `ProjectExportError.validationFailed`, both with a **strict per-frame
cadence** violation (`CadenceValidator.cadenceIssues`, which only applies in Constant mode) located
exactly at a composition seam between two grid segments.

I investigated this as a possible defect in `ProjectExporter`/`CompositionBuilder`/`ExportPlanner`
before accepting it as an environment finding:

1. **The plan math is exactly correct.** I dumped `plan.grid` for the "48 selective with audio"
   case: segment 1 (reencode) is `sourceStart=17/24, frameCount=77, outputStart=0,
   outputDuration=77/48`; segment 2 (copy) is `sourceStart=25/24, frameCount=122,
   outputStart=77/48, outputDuration=61/24`. `77 * 1/48 = 77/48` and `122 * 1/48 = 61/24` — both
   consistent. `outputTimescale` was 12288 (both fixtures' native timescale), and
   `Rational(77,48).cmTime(timescale: 12288)` resolved exactly (not the `Optional`-losing
   fallback branch) to `19712/12288`, which equals `77/48` exactly. So the insert's placement math
   is not at fault.

2. **The exported container itself has the anomaly**, independent of our own
   `CadenceValidator`/`ClipProbe` decode path. I captured the staged (would-be-installed) file via
   `keepInvalidAt` and ran raw `ffprobe -show_frames` on it. Sorting all 199 video frames'
   `pts_time` values numerically (199 unique values, no duplicates, so no frames are silently
   dropped or doubled) shows every consecutive gap is `~0.020833s` (`1/48`, matching plan) *except
   one*, exactly at the segment boundary: `1.583333 → 1.708333`, a gap of `0.125s = 6/48` instead
   of `1/48`. All frames after that point are correctly spaced at `1/48` again. In other words: the
   file itself — not our validator — has a real timing discontinuity of exactly one composition
   seam's worth, sized like a B-frame reorder window.
3. **This tracks with the difference between the passing and failing "constant" checks.** The one
   "constant" check that passes ("24 selective and re-encode all agree") only ever transitions
   into a *re-encoded-by-`ClipReencoder`* segment at each of its seams (which explicitly disables
   frame reordering — `AVVideoAllowFrameReorderingKey: false` — so it is immune to any B-frame/DTS
   interaction). Both failing checks have a seam where the segment immediately after the cut is a
   **passthrough copy of an original fixture** (`c48_a.mp4`, `c24.mp4` — both encoded with default
   libx264 B-frames, per `scripts/make-test-clips.sh`). Stitching two heterogeneous B-frame streams
   into one continuous `AVMutableComposition` video track and passthrough-exporting it
   (`AVAssetExportPresetPassthrough`) evidently requires `AVAssetExportSession` to insert extra
   spacing at the seam to keep decode-order timestamps monotonic across the splice — an
   AVFoundation passthrough/composition limitation, not a defect in our plan, insert offsets, or
   timescale math.
4. There is no minimal code fix available within this task's scope: avoiding it would mean not
   using passthrough/copy for these cases at all, i.e. abandoning the entire point of the
   Mixed/Constant-Selective strategies (skipping re-encoding of already-conforming footage), which
   is an architectural decision for the spec/controller, not a Task 12 bug fix.

Per the top-level instructions, I did **not** touch `ExporterChecks.swift`'s expectations or loosen
any tolerance to force this green, and I did not change `ProjectExporter.swift` beyond the one
sanctioned `try` fix. I removed all temporary debug instrumentation I added while investigating
(printing plan dumps, `keepInvalidAt` capture, `ffprobe` scratch files) and reconfirmed the exact
same 8-passed/2-failed result with the brief's verbatim `ExporterChecks.swift` before committing.

## Files changed

- `Sources/SlateCore/ProjectExporter.swift` (new)
- `Sources/SlateChecks/ExporterChecks.swift` (new)
- `Sources/SlateChecks/main.swift` (added `await runExporterChecks()`)

## Commit

`9d19a97` — `feat(core): ProjectExporter for mixed, selective and re-encode-all`
(3 files changed, 428 insertions(+))

## Self-review

- **Source protection before any file mutation**: `export()` checks `plan.canExport`, then
  `outputCollides` for both `outputURL` and `keepInvalidAt`, all before `FileManager` is asked to
  create the temp work directory. Confirmed by checks: "blocked project throws and writes
  nothing", "output path equal to a source is refused" (source file byte-for-byte survives),
  "a symlinked parent or a case alias of a source is refused", and "keepInvalidAt aliasing a
  source or the destination is refused" (source bytes and existing destination content both
  verified unchanged afterward) — all pass.
- **Staged install only after a passing validation**: `install(staged, at:)` is called only inside
  the `guard report.ok else { ... throw }` block's success path; on failure the destination is
  never touched (verified by "a failed validation never replaces an existing export", which checks
  the pre-existing destination content is byte-identical afterward).
- **Cleanup on every exit path**: the per-call temp work directory is removed via
  `defer { try? FileManager.default.removeItem(at: work) }`, which fires on success, on thrown
  errors, and on cancellation. `install()` uses a same-directory `.slate-<uuid>.mp4` sibling and
  removes it on any failure of the final swap. Verified by "cancel during re-encode leaves no temp
  files and keeps an existing export": empty temp dir, unchanged destination content, and no
  `.slate-*` sibling left next to the output — all pass.
- No check expectations or tolerances were edited. No production code beyond the one required
  `try` was changed from the brief's listing.

## Concerns for the controller

Two of ten exporter checks fail due to what I believe is a genuine AVFoundation
composition/passthrough-export limitation when splicing between a re-encoded (or differently
encoded) segment and a passthrough-copied segment sourced from an original B-frame-encoded fixture:
a ~5-6 frame presentation-timestamp gap appears at the seam, breaking the strict per-frame Constant
cadence check (`CadenceValidator.cadenceIssues`). This reproduces deterministically. It affects
"constant 48 selective with audio" and "the same file twice as two clips" (not "constant 24
selective and re-encode all agree", which the brief specifically called out as the likely
candidate — the actual failure surfaced in different checks than anticipated, though the same
category of Phase-0 finding). The whole suite is otherwise green: 75 passed, 2 failed, 0 skipped.
This needs a spec-level decision (e.g., whether Selective/Mixed export must fall back to
re-encoding whenever a copied segment's cut point isn't provably reorder-safe, or whether the
passthrough seam behavior needs a different composition-assembly strategy) before Task 13 / release
readiness.

---

## Fix round 1 (controller ruling)

**Ruling from the controller:** the investigation above is accepted as the Phase 0 finding.
Per the spec's Phase 0 rule (selective fails on some seams, re-encode-all passes → re-encode-all
becomes the Constant-mode default; Selective stays an option), the checks should pin the *safety
property* — an export must either succeed with a clean cadence report, or be refused and leave no
file behind; it must never install a file that fails validation — instead of asserting Selective
always passes. `SlateCore` code is explicitly out of scope for this round; only
`Sources/SlateChecks/ExporterChecks.swift` was touched.

### Changes

Replaced two checks in `Sources/SlateChecks/ExporterChecks.swift`, verbatim per the controller's
instructions:

1. **"exporter: constant 48 selective with audio"** → **"exporter: constant 48 with audio —
   selective passes or is refused, re-encode all passes"**. Selective now runs directly against
   `ProjectExporter().export(...)`: if it returns, the report must be `.ok`; if it throws
   `.validationFailed`, the check prints a note with the full issues text and asserts the refused
   output left no file at the destination. Either way, `.reencodeAll` (via `exportProject`, to a
   distinct output name `ex-c48-a-all.mp4`) must return an `.ok` report.

2. **"exporter: the same file twice as two clips"** → **"exporter: the same file twice as two
   clips (selective ok or refused, re-encode all passes)"**. Same ok-or-refused-with-no-file
   pattern for Selective (output `ex-dup.mp4`), then `.reencodeAll` (output `ex-dup-all.mp4`) must
   be `.ok`, and `expectEqual(plan.totalFrames, 48)` is now checked against the plan returned for
   the re-encode-all run (previously checked against the plan returned alongside the removed
   single Selective-only call — the plan itself doesn't depend on strategy, so the value is
   unchanged: 48).

All eight other checks, and `ProjectExporter.swift`/`main.swift`, are untouched.

### Commands and output

```
$ swift build
Build complete! (1.43s)

$ swift run SlateChecks exporter
  ✓ exporter: mixed 24 + 48 copies everything
  ✓ exporter: constant 24 selective and re-encode all agree
      note: selective refused (known Phase 0 finding): ["frame 76 lasts 1/16, expected 1/48"]
  ✓ exporter: constant 48 with audio — selective passes or is refused, re-encode all passes
      note: selective refused (known Phase 0 finding): ["frame 23 lasts 1/12, expected 1/24"]
  ✓ exporter: the same file twice as two clips (selective ok or refused, re-encode all passes)
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

10 passed, 0 failed, 0 skipped
```

Note the printed notes: the harness prints a check's own `print()` output during its body, before
that same check's `✓`/`✗` result line, so each `note:` line above sits directly under the check
that produced it. `note: ... "frame 76 lasts 1/16, expected 1/48"` belongs to "constant 48 with
audio — selective..." (matches the original investigation's d48-with-audio finding exactly), and
`note: ... "frame 23 lasts 1/12, expected 1/24"` belongs to "the same file twice... (selective ok
or refused, re-encode all passes)" (matches the original investigation's d24 duplicate-file
finding exactly). Both notes confirm Selective is still hitting the exact same seam-timing finding
recorded in the original investigation (identical issue text to fix-round-0), and in both cases the
refused export left no file at the destination (asserted), and re-encode-all passed cleanly.

```
$ swift run SlateChecks
... (73 non-exporter and other exporter checks unchanged, all ✓) ...
  ✓ exporter: constant 24 selective and re-encode all agree
      note: selective refused (known Phase 0 finding): ["frame 76 lasts 1/16, expected 1/48"]
  ✓ exporter: constant 48 with audio — selective passes or is refused, re-encode all passes
      note: selective refused (known Phase 0 finding): ["frame 23 lasts 1/12, expected 1/24"]
  ✓ exporter: the same file twice as two clips (selective ok or refused, re-encode all passes)
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

77 passed, 0 failed, 0 skipped
```

### Diff scope

```
$ git status --porcelain
 M Sources/SlateChecks/ExporterChecks.swift

$ git diff --stat
 Sources/SlateChecks/ExporterChecks.swift | 32 ++++++++++++++++++++++++++------
 1 file changed, 26 insertions(+), 6 deletions(-)
```

No `SlateCore` file was touched in this round, per the ruling.

### Commit

`511010a` — `test(core): pin exporter safety net for selective seams (Phase 0 finding)`
(1 file changed, 26 insertions(+), 6 deletions(-))

### Status: DONE

The Phase 0 finding is now pinned as a safety-net property (ok-or-refused-with-no-file for
Selective; re-encode-all always ok) rather than hidden or worked around. `swift run SlateChecks
exporter` → 10 passed, 0 failed, 0 skipped (with the two expected notes printed). Full suite →
77 passed, 0 failed, 0 skipped.

---

## Fix round 2 (full review findings)

Full review came back with two small findings in `Sources/SlateCore/ProjectExporter.swift`. No
check changes required or made.

### Changes

1. **(Important) `static func install(_:at:)` — cleans up a partial staged copy on cross-volume
   failure.** The first `try fm.moveItem(at: staged, to: sibling)` was outside the `do/catch` that
   removes `sibling` on failure. When `tempDirectory` and the destination are on different volumes,
   `moveItem` falls back to copy+delete; a failed copy (e.g. disk full, permissions) could leave a
   partial `.slate-<uuid>.mp4` sitting next to the real destination with nothing to clean it up.
   Moved that call inside the existing `do` block so `catch { try? fm.removeItem(at: sibling);
   throw error }` now covers it too:

   ```swift
   static func install(_ staged: URL, at destination: URL) throws {
       let fm = FileManager.default
       let sibling = destination.deletingLastPathComponent()
           .appendingPathComponent(".slate-\(UUID().uuidString).mp4")
       do {
           try fm.moveItem(at: staged, to: sibling)
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
   ```

2. **(Minor) `export(...)` — a failed diagnostic install must never hide `validationFailed`.**
   On the failed-validation path, installing the staged file to `keepInvalidAt` (a diagnostic
   convenience) used `try`, so if that diagnostic install itself failed (e.g. `keepInvalidAt`'s
   directory doesn't exist, or a permissions problem), its error would propagate up and replace the
   intended `ProjectExportError.validationFailed(report)` — masking the real reason the export
   failed behind an unrelated file-system error. Changed to `try?` so the diagnostic install is
   best-effort only and the original validation failure always surfaces:

   ```swift
   guard report.ok else {
       // Never replace the destination with a file that failed validation.
       if let keepInvalidAt { try? Self.install(staged, at: keepInvalidAt) }
       throw ProjectExportError.validationFailed(report)
   }
   ```

Both changes are confined to `Sources/SlateCore/ProjectExporter.swift`; no check files were
touched, per the instructions.

### Commands and output

```
$ swift build
Build complete! (1.70s)

$ swift run SlateChecks exporter
  ✓ exporter: mixed 24 + 48 copies everything
  ✓ exporter: constant 24 selective and re-encode all agree
      note: selective refused (known Phase 0 finding): ["frame 76 lasts 1/16, expected 1/48"]
  ✓ exporter: constant 48 with audio — selective passes or is refused, re-encode all passes
      note: selective refused (known Phase 0 finding): ["frame 23 lasts 1/12, expected 1/24"]
  ✓ exporter: the same file twice as two clips (selective ok or refused, re-encode all passes)
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

10 passed, 0 failed, 0 skipped

$ swift run SlateChecks
... (all other checks unchanged, all ✓) ...
  ✓ exporter: mixed 24 + 48 copies everything
  ✓ exporter: constant 24 selective and re-encode all agree
      note: selective refused (known Phase 0 finding): ["frame 76 lasts 1/16, expected 1/48"]
  ✓ exporter: constant 48 with audio — selective passes or is refused, re-encode all passes
      note: selective refused (known Phase 0 finding): ["frame 23 lasts 1/12, expected 1/24"]
  ✓ exporter: the same file twice as two clips (selective ok or refused, re-encode all passes)
  ✓ exporter: a failed validation never replaces an existing export
  ✓ exporter: keepInvalidAt aliasing a source or the destination is refused
  ✓ exporter: blocked project throws and writes nothing
  ✓ exporter: output path equal to a source is refused
  ✓ exporter: a symlinked parent or a case alias of a source is refused
  ✓ exporter: cancel during re-encode leaves no temp files and keeps an existing export

77 passed, 0 failed, 0 skipped
```

### Diff scope

```
$ git status --porcelain
 M Sources/SlateCore/ProjectExporter.swift

$ git diff Sources/SlateCore/ProjectExporter.swift
@@ -86,7 +86,7 @@ public final class ProjectExporter: @unchecked Sendable {
             if isCancelled { throw ProjectExportError.cancelled }
             guard report.ok else {
                 // Never replace the destination with a file that failed validation.
-                if let keepInvalidAt { try Self.install(staged, at: keepInvalidAt) }
+                if let keepInvalidAt { try? Self.install(staged, at: keepInvalidAt) }
                 throw ProjectExportError.validationFailed(report)
             }
             try Self.install(staged, at: outputURL)
@@ -120,8 +120,8 @@ public final class ProjectExporter: @unchecked Sendable {
         let fm = FileManager.default
         let sibling = destination.deletingLastPathComponent()
             .appendingPathComponent(".slate-\(UUID().uuidString).mp4")
-        try fm.moveItem(at: staged, to: sibling)
         do {
+            try fm.moveItem(at: staged, to: sibling)
             if fm.fileExists(atPath: destination.path) {
                 _ = try fm.replaceItemAt(destination, withItemAt: sibling)
             } else {
```

Exactly the two intended one/two-line changes; nothing else in the file was touched.

### Commit

`1102f19` — `fix(core): install cleans up a partial staged copy; diagnostic install never hides validation`
(1 file changed, 2 insertions(+), 2 deletions(-))

### Status: DONE

Both findings addressed with minimal, targeted edits confined to `install(_:at:)` and the
validation-failure branch of `export(...)`. `swift run SlateChecks exporter` → 10 passed, 0 failed,
0 skipped. Full suite → 77 passed, 0 failed, 0 skipped.

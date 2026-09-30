# Handoff — Slate multi-clip, Plan 2B (UI)

Date: 2026-09-30. Written after Plan 2A (branch `feat/multi-clip-2a`). Read this, then `MASTER_PLAN.md`, then the spec (section "Plan 2 decisions" wins), then `docs/superpowers/plans/2026-09-30-multi-clip-core-fixes-and-project-file.md` (what 2A did).

## 1. What 2A delivered (all in `Sources/SlateCore`, 125/125 checks with `--strict`)

- Defaults: `Project()` = `.constant(frameDuration: 1/24)` + `.reencodeAll`. `FrameRateChoice.candidates(for:)` (unique `d`, fastest first) and `.highest(for:)`.
- Planner: `BlockReason.unsupportedCodec` (allowed avc1/hvc1/hev1), `.audioFormatMismatch`; reference clip = first readable supported clip; Mixed timescale overflow → `PlanBlocker.timescaleOverflow`.
- Mixed validation: `ExportPlan.expectedPTS`, `ExpectedPTS.mixed`, exact `CadenceValidator.mixedIssues` (no tolerance). Gate passed on generated fixtures (see MASTER_PLAN).
- Exporter: `.reencoding(clip: k, of: n, progress:)` is real; bitrate = max over clips; `cancel()` also interrupts validation; a failed validation throws `ProjectExportError.validationFailed(report)` and never touches the destination.
- Composition: `CompositionError.audioTruncated(clip:seconds:)`, `.offGrid`; `ReencodeError.clipAudioTruncated(clip:samples:)`.
- Files: `ProjectFile` (`.slate` v1: `init(project:savedAt:)`, `encoded()`, `decode(_:)`, `project(resolvingFrom:exists:)`, `write(to:)`, `load(from:) async`), `PathRelinking`, `ProjectFileError`. Hostile numbers throw `notAProject`.
- Autosave engine: `Autosaver(delay:write:onError:)` (`noteChange()`, `flush()`, `cancel()`), `UntitledAutosaveStore` (`defaultDirectory`, `save`, `pending`, `discard`).
- Harness: `swift run SlateChecks --strict [prefix]` fails on skips.

## 2. What 2B must build (spec sections 2 and 3)

- `ProjectViewModel` (project, selection, project-wide undo of clips order + segments + `fpsMode`, Clip/Project player mode). The FPS target follows `FrameRateChoice.highest` until the user picks a value, then it is sticky; a loaded `.slate` keeps its stored target. Per-clip trim logic moves out of `EditorViewModel` so `TimelineView` binds to the selected clip. `SegmentOps` id preservation stays load-bearing.
- `ClipStripView` + `ClipStripMouseCapture` (AppKit mouse handling, drag reorder, Finder drops with an insertion marker, `[+]`, context menu Duplicate / Remove / Show in Finder / Locate file…).
- Project player from `CompositionBuilder.inserts(for: plan.grid, …)` + `ProjectTimeMap`; Clip/Project toggle and the source-time vs project-time rules in the spec.
- Toolbar: Constant `[fps ▾]` picker / Mixed toggle, total duration, Export. Mixed label text: "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."
- Rewritten `ExportSheet`: plan rows with the planner reason (including audio format differences and `BlockReason`s), stages Re-encoding k of n → Assembling → Validating, Cancel, a refused-export report (validation failure), Reveal in Finder. Default name `<project>.mp4` (untitled single clip: `<basename> — trimmed.mp4`). Selective and the "Re-encode everything" checkbox are NOT shown.
- Badge rule: yellow only when the clip's own timing would not copy (fps differs / timing not exact). In Constant mode every clip is re-encoded, so the badge must not mirror the plan action.
- `.slate` open / save / save as (Cmd+S, Cmd+Shift+S), Info.plist document type `co.aceguardian.slate.project`, Autosave wiring (saved project: `Autosaver(delay: .seconds(2))` writing in place; untitled: `UntitledAutosaveStore` + restore offer on launch; discard after a clean save). Replace the old `Sources/Slate/Services/Exporter.swift` and the single-clip export flow.
- Hotkeys: `[` `]` clips, Tab toggles Clip/Project, Cmd+Backspace remove clip, Cmd+D duplicate.

## 3. Deferred items to carry (from the 2A ledger — none blocks 2B)

- 2B must decide how the view model builds `Segment`s so `ProjectFile.init` never sees a non-numeric `CMTime` (it traps on save).
- `Autosaver` now serialises writes and `flush()` waits for a running write; the write closure must still snapshot the state at write time. The write closure must capture its owner WEAKLY (a strong capture keeps the Autosaver alive and `deinit` never cancels the timer). Before `UntitledAutosaveStore.discard()` call `flush()` or wait for the last write, because a timer write that already started can still land after `discard()`.
- The 48 kHz export check does not assert the output audio rate directly (only end alignment); add that assertion when the export sheet gets audio rows.
- `CompositionBuilder.build` is also the Project preview path; a clip whose audio ends more than 1024 samples before its video now makes the build throw. 2B needs a tolerant or catch path for the preview (video-only preview or a clear card message).
- `ProjectFile.decode` does not reject duplicate clip ids (the planner blocks them, but SwiftUI Identifiable lists misbehave): reject or de-duplicate on load in 2B.
- `ProjectFile.init` traps on a non-numeric `CMTime` and autosave calls it on a timer: 2B's first view-model task must validate segments at creation or make `init` throwing.
- Audio-format differences (sample rate / channel count) are allowed in Constant + Re-encode all (converted by the reader) and blocked in Mixed and Constant + Selective; the export sheet rows should say so.
- `ClipProbe` throws on unreadable formats; a card should show that as a broken file, not a "format mismatch".
- `CompositionBuilder` treats an audio track whose `.timeRange` starts late as a shortfall (bound: 1024 samples). Unverified on real ComfyUI clips: if a real clip is refused, look here first.
- `ClipReencoder.swift:200` keeps a `?? cmTime` rounding fallback (unreachable given `T_out`).
- Checks: see the 2A ledger lines "minor (deferred)" (copied into the final review). NLE (Resolve) compatibility stays UNVERIFIED.

## 4. Ask the user before writing 2B (one at a time, two options with a recommendation)

- Does Cmd+O on a second file add it to the open project, or open a new window? (Recommend: add to the project; Cmd+Shift+O or a new window for another project.)
- What happens to the old single-clip Cmd+E flow? (Recommend: the same Export button, for a project with one clip.)

## 5. Environment gotchas

`swift build` / `swift run` need the sandbox disabled. Heredocs fail in the sandbox: use Write/Edit. Run `scripts/make-test-clips.sh` in a fresh checkout (now also writes `c24_trunc_a.mp4` and `c24_st_short_a.mp4`). Fixtures keep B-frames + edit lists on purpose. `MASTER_PLAN.md` is gitignored: update it on disk. App build: `scripts/build-app.sh debug`.

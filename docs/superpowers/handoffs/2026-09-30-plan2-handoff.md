# Handoff — Slate multi-clip, Plan 2 (UI + project file)

Date: 2026-09-30. Written at the end of the session that designed the feature
and executed Plan 1. Read this first, then `MASTER_PLAN.md`, then the spec.

## 1. What the user wants (short)

Slate is a personal macOS app (SwiftUI + AVFoundation, SPM, no Xcode) for
lossless trimming. The new feature: put many short AI-generated clips
(ComfyUI, ~10 × ~5 s, some RIFE-interpolated 24 → 48 fps) on one project,
trim each clip with the existing multi-segment timeline, and export one mp4,
without re-encoding where possible. Clips of different fps must be
conformable to one output fps by a toggle.

- **Spec (approved, binding):** `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md`
- **Plan 1 (done):** `docs/superpowers/plans/2026-09-29-multi-clip-core-phase0.md`
- **Plan 2 (to write):** UI, `.slate` project file, autosave, export sheet — spec sections 1 ("Project file"), 2 ("UI") and 3 ("Progress and result").

## 2. State of the code (main, after merge)

`main` contains Plan 1 (merged locally from `feat/multi-clip-core`, not pushed).
84/84 checks pass.

- `Sources/SlateCore/` — all logic, no UI:
  - `Rational` (exact timing math), `FrameTable` (per-frame pts in the track timeline), `Segment`/`SegmentOps` (+ auto "whole clip" segment, `commitMarked`), `ProjectModel` (`Project`, `Clip`, `ClipMedia`, `FPSMode`, `ConstantStrategy`).
  - `FrameGrid` (the single quantization policy), `ExportPlanner` (copy / re-encode / skipped / blocked per clip, blockers, output timescale), `FrameRetimer`, `ProjectTimeMap` (project time ↔ clip source time; use it for the Project player and card seeking).
  - `ClipProbe`, `CompositionBuilder` (also the source for the Project-mode preview composition), `ClipReencoder`, `ProjectExporter` (staged render → validate → install; source protection; cancel via `cancel()` or Task cancellation; single-use instance), `CadenceValidator`.
- `Sources/Slate/` — the app, UNCHANGED apart from `import SlateCore`. It still uses its own old single-file `Exporter.swift` and `EditorViewModel`. Plan 2 replaces that flow.
- `Sources/SlateChecks/` — assertion harness (`swift run SlateChecks [prefix]`) + `swift run SlateChecks phase0 [--clip24 P --clip48 P]`.
- `scripts/make-test-clips.sh` (dev fixtures via Homebrew ffmpeg, into `build/fixtures`), `scripts/phase0-ffprobe.sh` (per-file fps, duration histogram, pts monotonic check).

## 3. Environment gotchas (save yourself an hour)

- `swift build` / `swift run` fail inside the Claude sandbox (`xcode-select: unable to read data link`). Run them with the sandbox disabled.
- Shell heredocs fail in the sandbox. Write files with the Write/Edit tools.
- Run `scripts/make-test-clips.sh` once in a fresh checkout; without fixtures the media checks SKIP (exit code stays 0 — known minor).
- Fixtures keep libx264 B-frames + edit lists on purpose (ComfyUI Video Helper Suite writes that). Never "fix" a failure by adding `-bf 0`.
- `MASTER_PLAN.md` is gitignored; update it on disk at session end (CLAUDE.md rule).
- App build: `scripts/build-app.sh debug` → `build/Slate.app`.

## 4. Phase 0 result — decides Plan 2 defaults

Evidence: generated fixtures only. **NLE compatibility (DaVinci Resolve): UNVERIFIED** — the user skipped the manual check and will test in the finished app. The user's clips are private: never ask for them, never copy them into the repo.

| Mode | AVFoundation validator | ffmpeg decode / pts order |
|---|---|---|
| Constant + Re-encode all (24, 48, with audio) | pass | clean, monotonic |
| Constant + Selective | selective-48 fails; selective-24 passes | selective-24: ~300 h264 errors, 107/130 frames, pts go backwards |
| Mixed (with and without audio) | pass | 0 decode errors, but pts go backwards at the 24 → 48 join (the c48 part is placed 1/16 s early) |

Root cause (Mixed and Selective): passthrough puts two different avc1 format descriptions (c24 level 3.0, c48 level 3.1) and mid-GOP edit lists into one track; ffmpeg mishandles the second description's edits. Re-encode all writes one format description, no B-frames, one edit list. Details: `docs/superpowers/handoffs/plan1-records/`.

Decisions already made (rulings, recorded in the ledger):
- Constant mode default = **Re-encode all**.
- **Selective** is unsafe → label it experimental or hide it in the export sheet.
- **Mixed** is correct only for Apple/AVFoundation players today.

## 5. Open design questions — ask the user BEFORE writing Plan 2

Ask one at a time, 2 options max, with a recommendation (user preference).

1. **What to do with Mixed mode.** The user's main case (24 fps clips next to RIFE 48 fps clips) is exactly where Mixed breaks in ffmpeg-based players and upload pipelines. Options: (a) keep Mixed but label it "Apple players only" and point social/upload users to Constant + Re-encode all; (b) gate Mixed copy on identical format descriptions and re-encode the rest. Reviewer recommendation: (a) now, (b) later.
2. **Selective in the UI:** hide it, or show it as "experimental".
3. **Mixed validator (review item I2):** add exact expected-pts validation for Mixed (computable from grid + source frame tables) — likely yes, cheap.

## 6. Carry into Plan 2 (from the final reviews)

Fix before or while wiring the UI (a user would hit these):
- Audio format mismatch (sample rate / channels) is not blocked by `ExportPlanner` — block it for copy paths.
- Unsupported codecs (e.g. ProRes `.mov`) silently become H.264 in `VideoEncodeSettings.matching` — block them in the planner.
- Re-encode-all bitrate comes from the reference clip only — use the maximum over clips.
- Re-encode-all progress is always "1 of 1" — the export sheet needs "Re-encoding k of n".
- `CompositionBuilder` has no audio-shortfall bound (the re-encoder does) and `audioTruncated` does not name the clip.
- Validation cannot be interrupted by cancel.
- Silence buffers are built without a channel layout (mono verified, stereo not) — reuse the reader's format description.
- `Rational.frameDuration(fps:)` uses a Double match; prefer clip-derived `d` for the fps picker.

Everything else deferred is listed with file:line in `docs/superpowers/handoffs/plan1-records/sdd-ledger.md` (search "minor (deferred)").

## 7. How the user likes to work

- Talk in Ukrainian, ELI5 / Simplified Technical English, short sentences, 2 options max with a recommendation.
- Ask all real nuances before a plan. Spec → user review → plan → user picks execution.
- External review: the user runs Codex or a Claude Fable session in another herdr pane (`herdr agent list`, `herdr agent prompt <pane> "..." --wait`); send it read-only review requests and ask it to write the result to a file.
- Execution: subagent-driven with per-task review worked well (Plan 1: 13 tasks, several plan defects caught by reviewers).

## 8. Suggested first steps for the new session

1. Read this file, `MASTER_PLAN.md`, the spec, and `docs/superpowers/handoffs/plan1-records/final-review-fable.md`.
2. Run `scripts/make-test-clips.sh` and `swift run SlateChecks` (sandbox off) → expect 84/84.
3. Ask the open questions in section 5.
4. Update the spec with the answers, get approval, then write Plan 2 (writing-plans skill) and let the user pick the execution method.

# Multi-clip concat — design

Date: 2026-09-29
Status: revised after external review (frame grid, time mapping, auto
segment, project-mode editing, Phase 0 NLE gate); awaiting user review

## Goal

Extend Slate from "trim one mp4" to "assemble many short clips into one mp4".
Each clip can be trimmed with the existing multi-segment timeline (inner
segments, edges, zoom). Export is one file, stream-copied (no re-encode) by
default.

Primary use case: the user's AI generations from ComfyUI. Typical project is
~10 clips of ~5 s. Some clips are RIFE-interpolated (e.g. 24 → 48 fps, same
real-time speed, more frames). Retiming (slow-mo) is NOT wanted.

## Facts given by the user

- All clips in a project share resolution and codec.
- Audio: within one project either all clips have audio or none do.
- Output goes either to viewing/social (mixed fps is fine) or to an NLE
  (needs constant fps). Both must be supported by a toggle.

## Non-goals

- Transitions, titles, effects, multitrack.
- Auto-conforming resolution/codec mismatches (warn + block instead).
- Speed change / slow-mo retiming.
- Bundled ffmpeg.

## 1. Data model

- `Project`
  - `clips: [Clip]` — ordered.
  - `fpsMode: FPSMode` — `.mixed` or `.constant(target: Double)`.
  - Audio presence is derived from clips, not stored.
- `Clip`
  - `id: UUID`
  - `url` — stored as both project-relative and absolute path.
  - `segments: [Segment]` — existing `Segment` / `SegmentOps`, in the clip's own
    time base. `SegmentOps` id-preservation contract stays load-bearing.
  - Cached metadata (reloaded on open): duration, nominal fps, frame size,
    codec FourCC, hasAudio.
  - `status`: ok / missing file / format mismatch.
- A newly added clip gets one **auto** segment covering its full duration
  (`Segment.isAuto = true`). Rules:
  - While a clip holds only its auto segment, the first `O` commit
    **replaces** it with the marked range (instead of merging into it). This
    keeps today's additive I/O workflow: mark keep-ranges, everything else is
    dropped.
  - Dragging an edge of the auto segment turns it into a normal segment
    (`isAuto = false`). This is the "trim the ends" workflow.
  - Deleting the last segment leaves the clip with zero kept frames. The card
    shows `0.0 / 5.0 s` and the clip is skipped at export (not blocked).
    Undo restores the segment.
  - The timeline draws the auto segment in a lighter style with the label
    "whole clip".
- The same file may appear as several clips (duplicate).
- Undo/redo is project-wide: snapshots of `clips` (order + segments) and
  `fpsMode`.
- Opening a single mp4 (Cmd+O, Dock drop, file association) = project with one
  clip. There is one editor, not two modes.

### Project file `.slate`

- JSON, `Codable`, versioned (`"version": 1`). Contains no media.
- Missing media → clip marked red with "Locate file…" (relink). Resolution
  tries the relative path first, then the absolute path.
- Autosave:
  - Saved project: write in place 2 s after the last change (debounced).
  - Untitled project: write to
    `~/Library/Application Support/Slate/Autosave/`. On launch, offer to
    restore it.
- Info.plist declares the `.slate` document type
  (UTI `co.aceguardian.slate.project`).

## 2. UI

Layout top→bottom: toolbar, player, clip strip, timeline of selected clip,
status bar.

- **Toolbar:** FPS toggle `Mixed / Constant [48 ▾]` (picker lists only fps
  values present in the project, default = highest), total output duration,
  Export button.
- **Clip strip:** horizontal cards. Each card shows thumbnail, index, "kept /
  total" duration (e.g. `3.2 / 5.0 s`), fps badge, audio icon.
  - fps badge is yellow when the clip will be re-encoded (Constant mode,
    fps ≠ target).
  - Card is red when the file is missing or its format differs from the rest.
  - Drag a card to reorder. Drop files from Finder into the strip at an
    insertion marker, or anywhere in the window (appends). `[+]` button and
    Cmd+O accept multiple files.
  - Context menu: Duplicate, Remove, Show in Finder, Locate file…
  - Mouse handling goes through an `NSViewRepresentable` (same reason as
    `TimelineMouseCapture`: SwiftUI gestures were unreliable).
- **Timeline:** existing `TimelineView`, bound to the selected clip. Trim,
  zoom, handles, hotkeys unchanged.
- **Player mode toggle `Clip / Project`:**
  - Clip: plays the selected clip's full source (for trimming).
  - Project: plays an `AVMutableComposition` built from the **same grid
    segments as the export** (`[s', s' + N · d)` at `O_k`), rebuilt on every
    change. So joins, card seek positions, and total duration match the
    output exactly. The only difference: re-encoded clips preview their
    source frames, so a 48 fps clip in a Constant-24 project previews at 48.
    Timing is identical. A playhead marker moves across the strip. Clicking
    a card seeks to that clip's first grid segment `O_k`.
- **Time domains.** Two clocks exist: *source time* (inside one clip file)
  and *project time* (inside the assembled output). A pure `ProjectTimeMap`,
  built from the planner's grid segments, converts between them: project
  time → (clip, segment, source time), and back.
  - All edit commands (`I`, `O`, handle drag, segment delete, timeline click)
    work in source time only.
  - Project mode is preview-only. The selection follows the playhead: the
    clip under the playhead becomes selected, and its timeline shows a
    read-only playhead at the mapped source time. Editing controls are dimmed.
  - Any edit command or timeline click in Project mode first switches to Clip
    mode, pauses, and seeks the clip to the mapped source time. Then the
    command runs. So `I` pressed during project playback marks the exact
    frame the user saw.
  - Selecting another card while playing in Project mode seeks project time to
    that clip's first kept frame.
- **Empty state:** "Drop clips here".
- **New hotkeys:**
  - `[` / `]` — previous / next clip
  - `Tab` — toggle Clip / Project
  - `Cmd+Backspace` — remove selected clip
  - `Cmd+D` — duplicate clip
  - `Cmd+S` / `Cmd+Shift+S` — save / save as
  - `Backspace` keeps deleting the selected segment (unchanged).

## 3. Export

### Preflight

`ExportPlanner` (pure, testable) turns a `Project` into an `ExportPlan`: per
clip one of `copy`, `reencode(from:to:)`, or `blocked(reason)`. The export
sheet shows the plan before starting.

Blocking reasons: missing file, frame size ≠ project, codec ≠ project, audio
presence ≠ project, and **zero output frames after quantization**
(`Σ N_k = 0`, message: "All selections are shorter than one frame"). The
last check runs after `FrameGrid`, so a project whose only selection is
10 ms at 24 fps is blocked, not exported empty. The reference format is the
first valid clip.

The planner is pure and cheap. It re-runs on every edit, and its grid
segments feed export, Project preview, and `ProjectTimeMap` alike.

### Mixed mode

One `AVMutableComposition` (1 video + optional 1 audio track). Insert each
clip's kept segments in project order. Export with
`AVAssetExportPresetPassthrough` to `.mp4`. Each clip keeps its own frame
durations → output is VFR where fps differs. Nothing is re-encoded.

### Constant mode

Goal: every output video frame has duration `d = 1 / target` and the n-th
frame is presented at exactly `n · d`. Reported nominal fps is not enough.

#### Global frame grid (`FrameGrid`, pure)

All timing math uses **actual sample timestamps**, never nominal fps or
`minFrameDuration` (which is only a minimum and may be unknown).

- `ClipProbe` reads every video sample's pts and duration in presentation
  order (a 5 s clip has ~240 samples; this reuses the `KeyframeScanner`
  reader pass). It stores `frames: [(pts, duration)]` and the track timescale.
- **CFR check.** A clip is CFR when every frame duration and every gap between
  consecutive pts are equal, with a tolerance of 1 tick of the track
  timescale. Then `srcD` is that common duration. Otherwise the clip is VFR.
- `d` is a rational `CMTime`. If a CFR clip's `srcD` matches the target, use
  that exact `srcD` (this handles `1001/24000` for 23.976). Otherwise build
  `d` from the target value.
- **Copy eligibility (Constant mode).** A clip is copied only if it is CFR
  and `srcD == d` within 1 tick. Every other clip is re-encoded, including a
  VFR clip whose nominal fps equals the target. The plan row shows the reason
  ("fps differs" or "not constant frame rate").
- Each kept segment `[s, e)` of every clip becomes a **grid segment**
  `(clip, s', N)`:
  - `s'` = the actual source frame pts nearest to `s`.
  - Copy clips: `N` = number of source frames with pts in `[s', e)`. Since the
    clip is CFR with `srcD == d`, the range `[s', s' + N · d)` is exactly N
    whole frames.
  - Re-encode clips: `N = round((e − s) / d)`, clamped so `s' + N · d` does
    not pass the clip end (last pts + last duration).
  - Segments with `N = 0` are dropped. The plan lists each one as
    "shorter than one frame, skipped".
- Output offsets: grid segment k starts at `O_k = Σ_{j<k} N_j · d`. All offsets
  and durations are integer multiples of `d`, so joins cannot break cadence.
- **Mixed mode** uses the same builder without a global `d`. `s'` and the end
  are snapped to the nearest actual frame pts, `N` counts actual frames, and
  offsets add the actual frame durations. VFR sources work unchanged.

#### Copy clips

The composition inserts source range `[s', s' + N · d)` at `O_k`.

#### Re-encode clips (`FrameRetimer`, pure)

- For output frame `i` (0 ≤ i < N) of a grid segment, source time is
  `t_i = s' + i · d`. The retimer picks the source frame with the **largest
  actual pts `≤ t_i + ε`**. `ε` is 1 tick of the source track timescale. It
  only absorbs timescale rounding and is far smaller than a frame. Math is
  exact rational `CMTime` arithmetic.
- Result on 5 source frames: 24 → 48 picks `0,0,1,1,2,2,3,3,4,4`; 48 → 24
  picks `0,2,4,…`. Speed is unchanged. Works for VFR sources too, because it
  reads the pts list.
- Removed intervals are skipped because each grid segment maps on its own:
  kept ranges `[2, 3)` and `[4, 5)` give output `[0, 1)` from source 2…3 and
  output `[1, 2)` from source 4…5.
- Each written frame gets pts `local_offset + i · d` and duration `d`,
  including the last frame of the last segment.
- Pipeline: `AVAssetReader` (decoded frames, per grid segment via
  `timeRange`) → retimer → `AVAssetWriter`. One temp file per clip in
  `$TMPDIR`, holding all its grid segments back to back. Same codec and frame
  size as the project. Bitrate ≈ 2× source, floor 20 Mbit/s at 1080p.
- The composition inserts the temp file's full range at the clip's first
  `O_k`.

#### Audio

- For every grid segment the audio range is exactly the video range:
  source `[s', s' + N · d)` inserted at `O_k`. So audio and video share one
  output clock and drift cannot build up across joins.
- Copy clips: audio is passthrough. AAC packets (~21 ms) do not align with
  video frames, so the composition trims them with edit lists. Error stays
  under one packet per join and does not accumulate.
- Re-encode clips: audio is decoded and trimmed to the exact sample range,
  then encoded to AAC with the same sample rate and channel count.

#### Two strategies, one code path

- **Selective** (default if Phase 0 passes): re-encode only clips whose fps
  differs from the target, then do a passthrough concat.
- **Re-encode all** (checkbox in the export sheet: "Re-encode everything —
  max compatibility"): every clip goes through the retimer into **one**
  `AVAssetWriter`. The video track has one encoder session, one parameter
  set, and no per-cut edits. The audio track can still carry the AAC
  encoder-delay (priming) edit that `AVAssetWriter` writes to compensate
  encoder delay. That edit is expected and correct. Phase 0 tests an
  audio-bearing Re-encode-all file for sync in the NLE. This is the fallback
  for an NLE that rejects the selective output.
- If Phase 0 shows that selective output fails in the user's NLE, Constant
  mode defaults to Re-encode all, and Selective stays available as an option.

#### Validation (`CadenceValidator`)

After a Constant-mode export, read the output with `AVAssetReader` (decoded
frames, which respects edit lists):
- every frame duration is `d`,
- frame n has pts `n · d` (tolerance: 1 tick of the track timescale),
- frame count is `Σ N_k`,
- the first decoded audio sample is presented at 0 (± one AAC packet), so
  priming is compensated,
- audio duration is within one AAC packet of the video duration.

On failure the sheet shows which frames broke cadence. Mixed-mode export
checks only frame count and total duration.

#### Cleanup

Delete temp files on success, failure, and cancel.

### Progress and result

- Stages: `Re-encoding k of n` → `Assembling`. Cancel works in both stages.
- Default output name: `<project name>.mp4`. For an untitled single-clip
  project the old name stays `<basename> — trimmed.mp4`.
- Post-export check: see Validation above. Constant mode runs the full
  cadence check. Mixed mode checks frame count and total duration. A mismatch
  shows a warning with details.

### Unchanged

Cuts may sit mid-GOP. Passthrough keeps the whole GOP and hides the extra
frames with an edit list, same as today. How NLEs treat these edit lists is
part of the Phase 0 check.

## Phase 0 — feasibility gate (before any UI work)

The NLE use case is a real requirement, so it is tested first.

1. In `SlateChecks`, build a spike command that takes two real ComfyUI clips
   (one 24 fps, one 48 fps from RIFE, same codec and size). If the real clips
   have no audio, a generated clip pair with audio is also used, so the AAC
   priming path is tested. It cuts both mid-GOP and writes:
   - `phase0-mixed.mp4` (Mixed mode),
   - `phase0-selective.mp4` (Constant 24, selective),
   - `phase0-all.mp4` (Constant 24, re-encode all),
   - the same pair for Constant 48.
2. Automatic checks: `CadenceValidator` plus
   `ffprobe -show_frames` (ffprobe is installed at `/opt/homebrew/bin` for
   development only; it is not bundled).
3. Manual check by the user in their NLE: import each file and confirm the
   fps, no extra or missing frames at the joins, no black or frozen frames,
   and audio in sync.
4. Decision, recorded in `MASTER_PLAN.md`:
   - Selective passes → Selective is the default.
   - Selective fails, Re-encode all passes → Re-encode all is the default.
   - Both fail → stop and revisit the design before building UI.

The spike code is throwaway, but `FrameGrid`, `FrameRetimer`, and
`CadenceValidator` are written as the real modules, so they carry over.

## Code layout (new / changed)

- `Models/Project.swift`, `Models/Clip.swift`, `Models/FPSMode.swift`
- `Models/ProjectFile.swift` — Codable DTO + versioning
- `Services/ClipProbe.swift` — loads clip metadata
- `Services/ExportPlanner.swift` — pure
- `Models/ProjectTimeMap.swift` — pure, project time ↔ (clip, source time)
- `Services/FrameGrid.swift` — pure, kept segments → grid segments + offsets
- `Services/FrameRetimer.swift` — pure
- `Services/ClipReencoder.swift` — reader → retimer → writer (one clip, or
  all clips into one writer)
- `Services/CadenceValidator.swift` — reads output, checks frame timing
- `Services/Exporter.swift` — takes an `ExportPlan` instead of one asset
- `Services/Autosave.swift`
- `ViewModels/ProjectViewModel.swift` — project, selection, undo, player mode.
  Per-clip trim logic moves out of `EditorViewModel` so the existing
  `TimelineView` binds to the selected clip.
- `Views/ClipStripView.swift`, `Views/ClipStripMouseCapture.swift`
- `Views/ExportSheet.swift` — shows the plan and stages
- `Package.swift` — add `SlateCore` library + `SlateChecks` executable

## Testing

- XCTest is unavailable (CLT only). Shared logic moves into a library target
  `SlateCore` that both `Slate` and `SlateChecks` depend on. `SlateChecks` is
  an executable with a tiny assertion harness: `swift run SlateChecks`.
- Covered by checks: project JSON round-trip and version handling, relink path
  resolution, `ExportPlanner` (copy / reencode / blocked / skipped cases),
  CFR detection (CFR, VFR, and nominal-fps-equal-but-VFR goes to re-encode),
  `FrameGrid` (snapping to actual pts, `N` rounding, clamping at clip end,
  offsets are multiples of `d`, 23.976 rational math, `Σ N_k = 0` is
  blocked), `FrameRetimer` (exact pick sequences: 24→48 gives
  `0,0,1,1,2,2,3,3,4,4`, 48→24 gives `0,2,4`, 30→30 is identity, VFR input,
  kept ranges with gaps such as `[2,3)` + `[4,5)`, last-frame duration),
  preview composition and `ProjectTimeMap` use the same offsets as the
  export plan, `ProjectTimeMap` (both directions, segment edges, zero-length
  clips), auto-segment rules (first `O` replaces, edge drag converts),
  `SegmentOps` id preservation (regression guard).
- Integration: `CadenceValidator` runs on every generated export in the
  checks target.
- Manual: generated test clips (24 fps and 48 fps, with and without audio,
  made via AVAssetWriter in the checks target) plus the user's real ComfyUI
  clips. Verify output in QuickTime, and with `ffprobe` if available.

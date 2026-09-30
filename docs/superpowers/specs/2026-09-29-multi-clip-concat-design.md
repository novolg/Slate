# Multi-clip concat — design

Date: 2026-09-29
Status: approved by user 2026-09-29. Plan 1 (core + Phase 0) done and merged to `main` 2026-09-30. Phase 0 decided. Plan 2 (UI) next. Where the section "Plan 2 decisions" contradicts older text, it wins.

## Goal

Extend Slate from "trim one mp4" to "assemble many short clips into one mp4".
Each clip can be trimmed with the existing multi-segment timeline (inner
segments, edges, zoom). Export is one file. A new project starts in Constant +
Re-encode all (safe in AVFoundation and ffmpeg). Mixed mode stream-copies
(no re-encode) and is opt-in, "Apple players only" (see "Plan 2 decisions").

Primary use case: the user's AI generations from ComfyUI. Typical project is
~10 clips of ~5 s. Some clips are RIFE-interpolated (e.g. 24 → 48 fps, same
real-time speed, more frames). Retiming (slow-mo) is NOT wanted.

## Facts given by the user

- All clips in a project share resolution and codec.
- Audio: within one project either all clips have audio or none do.
- (Superseded: social/upload now routes to Constant; Mixed is Apple-only,
  see "Plan 2 decisions".) Output goes either to viewing/social (mixed fps is fine) or to an NLE
  (needs constant fps). Both must be supported by a toggle.

## Non-goals

- Transitions, titles, effects, multitrack.
- Auto-conforming resolution/codec mismatches (warn + block instead).
- Speed change / slow-mo retiming.
- Bundled ffmpeg.

## 1. Data model

- `Project`
  - `clips: [Clip]` — ordered.
  - `fpsMode: FPSMode` — `.mixed` or `.constant(frameDuration: Rational)`
    (the `.slate` file stores the fraction).
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

- **Toolbar:** FPS toggle `Constant [48 ▾] / Mixed` (picker lists only fps
  values present in the project, default = highest; new projects start in
  Constant — superseded order, see "Plan 2 decisions"), total output duration,
  Export button.
- **Clip strip:** horizontal cards. Each card shows thumbnail, index, "kept /
  total" duration (e.g. `3.2 / 5.0 s`), fps badge, audio icon.
  - fps badge is yellow when the clip's own timing would not copy (fps
    differs from the target, or frame timing not exact). The tooltip shows the
    planner's reason. In Constant mode every clip is re-encoded, so the badge
    does not show "Re-encode all" (superseded, see "Plan 2 decisions").
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
    segments as the export** (each grid segment at `O_k`), rebuilt on every
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
- **Arithmetic.** All timing math uses an exact `Rational` type (Int64
  numerator and denominator, reduced by gcd) converted from and to `CMTime`.
  Comparisons are exact. `round(x)` means `floor(x + 1/2)`.
- **Frame boundaries.** For a clip with frames `0…n−1`, the boundary set is
  `B = {pts_0, …, pts_{n−1}, clipEnd}` with `clipEnd = pts_{n−1} +
  duration_{n−1}`. Every snap goes to the nearest element of `B`. So a
  full-clip selection `[0, clipEnd)` keeps all n frames.
- **Exact CFR.** A clip is *exact CFR* when every frame duration and every gap
  between consecutive pts are **exactly equal** (no tolerance). Then `srcD`
  is that duration. Any other clip is treated as VFR, including jittered
  files such as 23.976 at timescale 90000 (durations 3753/3754). Jitter can
  add up across a clip (100 × 3754 then 100 × 3753 is 50 ticks off-grid in
  the middle), so no per-frame tolerance is safe for copying.
- `d` is exact, built from the target rate (`1/24`, `1/48`,
  `1001/24000`, …).
- **Copy eligibility (Constant mode).** A clip is copied only if it is exact
  CFR and `srcD == d` exactly. Then every copied frame sits exactly on the
  output grid, and every copied range is exactly `N · d` long. Every other
  clip is re-encoded, including a jittered or VFR clip whose nominal fps
  equals the target. The plan row shows the reason ("fps differs" or "frame
  timing not exact").
- **Output timescale.** The composition tracks and the re-encode writer use
  one timescale `T_out` in which `d` is a whole number of ticks and every
  copied clip's timescale divides `T_out` (lcm of those values). So all
  offsets are exact integers. Typical ComfyUI files (ffmpeg, 24 fps at 12288
  and 48 fps at 12288) give `T_out = 12288`. Phase 0 confirms this on the
  user's real clips with `ffprobe`.
- **Retimer tolerance `τ`.** This is the only tolerance in the spec, and it
  is used only when the retimer picks a source frame (see below). It is never
  used for copy eligibility or validation. `τ = 1 source tick` when
  `1 tick ≤ srcD / 100` (or ≤ 1% of the shortest frame for VFR), else
  `τ = 0`.

#### One quantization policy (`FrameGrid`, pure)

Quantization runs **before** the copy/re-encode choice, so the strategy can
never change the edit. "Re-encode everything" produces the same frame count
and offsets as "Selective".

For each kept segment `[s, e)`:
- `s'` = nearest element of `B` to `s`.
- `N = round((e − s) / D)`, where `D = d` in Constant mode and `D` = the
  clip's `srcD` in Mixed mode.
- Clamp `N` so `s' + N · D ≤ clipEnd` (the end is included, so a full clip
  keeps its last frame).
- `N = 0` → the segment is dropped and listed as "shorter than one frame,
  skipped". Example: `[0, 10 ms)` at 24 fps gives `N = 0` in every strategy,
  so a project with only that selection is blocked.
- Output offsets: segment k starts at `O_k = Σ_{j<k} N_j · D`.

In Constant mode every offset and duration is a multiple of `d`, so joins
cannot break cadence.

**Mixed mode with a non-exact-CFR clip** (no single `srcD`): `s'` and `e'`
are both snapped to the nearest element of `B`, `N` = number of source frames
in `[s', e')`, and the segment duration is `e' − s'`. Mixed mode copies
everything and makes no cadence promise, so jitter is fine there.

#### Copy clips

The composition inserts the source range `[pts_a, pts_{a+N})` at `O_k`, where
`pts_a = s'` (use `clipEnd` when `a + N = n`). These are exactly the N source
frames. In Constant mode copy clips are exact CFR with `srcD == d`, so the
range is exactly `N · d`, and segment k+1 starts exactly where segment k
ends. No gaps and no overlaps.

#### Re-encode clips (`FrameRetimer`, pure)

- For output frame `i` (0 ≤ i < N) of a grid segment, source time is
  `t_i = s' + i · d`. The retimer picks the source frame with the **largest
  actual pts `≤ t_i + τ`**. `τ` is the bounded tolerance above. It is 0 when a
  tick is coarse, so it can never move the choice to a later frame.
- Result on 5 source frames: 24 → 48 picks `0,0,1,1,2,2,3,3,4,4`, also at
  timescale 24. 48 → 24 picks `0,2,4,…`. Speed is unchanged. VFR sources
  work too, because the retimer reads the pts list.
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
  the same source range as the video segment, inserted at `O_k`. So audio and video share one
  output clock and drift cannot build up across joins.
- Copy clips: audio is passthrough. AAC packets (~21 ms) do not align with
  video frames, so the composition trims them with edit lists. Error stays
  under one packet per join and does not accumulate.
- Re-encode clips: audio is decoded and trimmed to the exact sample range,
  then encoded to AAC with the same sample rate and channel count.

#### Two strategies, one code path

> Superseded: Phase 0 made **Re-encode all** the only visible strategy and
> the default. Selective stays in code but is hidden. The "Re-encode
> everything" checkbox is removed. See "Plan 2 decisions".

- **Selective** (default if Phase 0 passes): re-encode only clips that fail
  copy eligibility (not exact CFR, or `srcD ≠ d`), then do a passthrough
  concat.
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
- every frame duration is exactly `d` (in `T_out` ticks),
- frame n has pts exactly `n · d` (no tolerance; the planner only allows
  exact inputs, so any mismatch is a real bug),
- frame count is `Σ N_k`,
- the first decoded audio sample is presented at 0 (± one AAC packet), so
  priming is compensated,
- audio duration is within one AAC packet of the video duration.

On failure the sheet shows which frames broke cadence. Mixed-mode export
checks frame count, total duration and (Plan 2) the exact expected pts list.
A failed validation refuses the export in every mode (superseded: no
"warning" path; see "Plan 2 decisions").

#### Cleanup

Delete temp files on success, failure, and cancel.

### Progress and result

- Stages: `Re-encoding k of n` → `Assembling` → `Validating`. Cancel works in
  all stages. A failed validation refuses the export and the sheet shows why.
- Default output name: `<project name>.mp4`. For an untitled single-clip
  project the old name stays `<basename> — trimmed.mp4`.
- Post-export check: see Validation above. Constant mode runs the full
  cadence check. Mixed mode checks frame count, total duration and the exact
  pts list. A mismatch refuses the export and the sheet shows the details
  (superseded: not a warning).

### Output safety

- The export refuses an output path that is a source clip. Paths are compared
  after resolving symlinks, and existing files by file identity, so symlinked
  folders, case aliases, and hard links are caught.
- The export renders and validates a staged file in the temp folder. Only after
  success, including a passing validation, does it replace the destination. A
  failed, invalid or cancelled export leaves
  an existing file at the destination unchanged.
- Decoder failures are errors. A frame is repeated only when the retimer picks
  the same source frame again, never because the reader stopped early. Source
  audio may be short by at most one AAC packet.

### Unchanged

Cuts may sit mid-GOP. Passthrough keeps the whole GOP and hides the extra
frames with an edit list, same as today. How NLEs treat these edit lists is
part of the Phase 0 check.

## Phase 0 — feasibility gate (before any UI work)

The NLE use case is a real requirement, so it is tested first.

1. The user's clips are private, so Phase 0 uses **generated** clips that
   match ComfyUI output (Video Helper Suite writes through ffmpeg/libx264):
   `scripts/make-test-clips.sh` uses the local dev-only ffmpeg to write a
   24 fps clip and a 48 fps clip interpolated from it (`minterpolate`, a
   stand-in for RIFE), both 640×360 H.264 yuv420p, default GOP, timescale
   12288, with and without AAC audio. The script also writes a jittered
   23.976 clip (timescale 90000) and a clip with a different size. Verified
   on 2026-09-29: ffmpeg writes 24 fps as 512 ticks and 48 fps as 256 ticks
   at timescale 12288, exact CFR. The spike command cuts both clips mid-GOP
   and writes:
   - `phase0-mixed.mp4` (Mixed mode),
   - `phase0-selective.mp4` (Constant 24, selective),
   - `phase0-all.mp4` (Constant 24, re-encode all),
   - the same pair for Constant 48.
2. Automatic checks: `CadenceValidator` plus
   `ffprobe -show_frames` (ffprobe is installed at `/opt/homebrew/bin` for
   development only; it is not bundled).
   The command also takes `--clip24 <path> --clip48 <path>`, so the user can
   run the video-only cases on their own clips locally. The files never leave
   their machine.
3. Optional manual check by the user in DaVinci Resolve (about 2 minutes):
   import each file and confirm the fps, no extra or missing frames at the
   joins, no black or frozen frames, and audio in sync. If the user skips it,
   Selective becomes the default based on the automatic checks alone, and
   "Re-encode everything" stays available as the fallback. The record then
   says "NLE compatibility: UNVERIFIED", never "passed".

**Phase 0 outcome (2026-09-30, generated fixtures only; NLE compatibility
UNVERIFIED):**

| Mode | AVFoundation validator | ffmpeg decode / pts order |
|---|---|---|
| Constant + Re-encode all (24, 48, audio) | pass | clean, monotonic |
| Constant + Selective | 48 fails; 24 passes | 24: ~300 h264 errors, 107/130 frames |
| Mixed (with/without audio) | pass (count + duration only) | 0 errors, pts go backwards at the 24 → 48 join (c48 part 1/16 s early) |

Root cause: passthrough concat puts two different `avc1` format descriptions
(level 3.0 vs 3.1) and mid-GOP edit lists in one track; ffmpeg mis-applies the
second description's edits. Re-encode all writes one description, no
B-frames, one edit list. Details: `docs/superpowers/handoffs/plan1-records/`.


4. Decision, recorded in `MASTER_PLAN.md` (the outcome above applies it):
   - Selective passes → Selective is the default.
   - Selective fails, Re-encode all passes → Re-encode all is the default.
   - Both fail → stop and revisit the design before building UI.

The spike code is throwaway, but `FrameGrid`, `FrameRetimer`, and
`CadenceValidator` are written as the real modules, so they carry over.

## Plan 2 decisions (2026-09-30, after Phase 0; these override earlier text)

User rulings:

1. **Mixed mode stays, labelled "Apple players only".** Exact label text:
   "Apple players only (QuickTime, Safari, Final Cut). For upload or other
   players use Constant." The export sheet shows it on Mixed. Gating Mixed
   copy on identical format descriptions is deferred.
2. **Selective is hidden** from the export sheet. The code stays in
   `SlateCore`. Constant mode has one visible strategy: Re-encode all.
   The "Re-encode everything" checkbox is removed.
   `Project.constantStrategy` defaults to `.reencodeAll`. The v1 `.slate`
   file does not store it. Checks: `Project().constantStrategy == .reencodeAll`;
   the planner marks every clip of a default Constant project as re-encode.
3. **New project default (user ruling 2026-09-30).** A new project starts in
   Constant + Re-encode all, target = highest fps present. `Project.init`
   default `fpsMode` changes from `.mixed` to Constant (the target is set
   when clips are added). An empty project is `.constant(1/24)`. The target
   follows "highest fps present" automatically until the user picks a value;
   after that it is sticky. A loaded `.slate` keeps its stored target. Mixed
   is opt-in. "Highest" compares exact
   `d` values (e.g. `1001/24000` vs `1/24`).
4. **Mixed gets exact pts validation.** Add a pure
   `expectedPTS(grid:, tables:) -> [Rational]`. `CadenceValidator` compares
   the decoded pts of a Mixed export to it exactly (no 1 ms tolerance).
   Frame count and total duration stay as secondary messages.
   - **Acceptance step, first task of Plan 2:** run the exact check on
     `phase0-mixed.mp4`, `phase0-mixed-audio.mp4` and the `ex-mixed` checks.
     Record pass/fail in `MASTER_PLAN.md`. If it fails, ruling 1 is reopened
     (gate Mixed copy on identical format descriptions, or re-encode at
     joins). No export-sheet work before this result.
   - **Validation failure = export refused in every mode.** The sheet shows
     the report. There is no "warning" path.
   - **Mixed `T_out`:** if the lcm of the copied timescales overflows, the
     planner blocks ("clip timescales cannot share one exact timeline"),
     same as Constant. No silent fallback in `ExportPlanner.outputTimescale`
     or `CompositionBuilder`. An exact grid always exists.

Carry-over fixes (from the Plan 1 final reviews), done in Plan 2:

- `ExportPlanner` blocks audio sample-rate / channel mismatch on copy paths.
- `ExportPlanner` blocks unsupported codecs in every mode (allowed: `avc1`,
  `hvc1`/`hev1`; e.g. ProRes is blocked) instead of
  `VideoEncodeSettings.matching` turning them into H.264.
- `ClipProbe` throws on an unreadable video or audio format description
  (today: codec `0` / silent "no audio").
- `SlateChecks` gets `--strict` (skips fail the run). `Phase0` removes a stale
  `*-INVALID.mp4` before exporting. The unreachable guard at
  `ProjectExporter.swift:184` becomes `preconditionFailure`.
- Other deferred minors: `plan1-records/final-review-fable.md` §Minor and
  `plan1-records/final-rereview-fable.md`.
- Re-encode all bitrate = maximum over all clips, not the reference clip.
- Re-encode all progress reports the real clip index ("Re-encoding k of n").
- `CompositionBuilder` gets the audio-shortfall bound (1024 samples, one AAC
  packet, same as `ClipReencoder`); `audioTruncated` names the clip.
- Validation is interruptible by cancel.
- Silence buffers reuse the reader's format description (channel layout).
- The fps picker lists the `srcD` values of exact-CFR clips. If there are
  none (e.g. only jittered 23.976), it falls back to
  `Rational.frameDuration(fps: nominalFPS)` per clip, and the plan row says
  "timing not exact".
- Export-sheet plan rows mention audio format differences.

NLE compatibility (DaVinci Resolve) stays UNVERIFIED until the user tests
the finished app.

## Code layout (updated 2026-09-30)

Already exists in `Sources/SlateCore/` (Plan 1, do not duplicate):
`Rational`, `FrameTable`, `Segment`, `KeyframeIndex`, `ProjectModel`
(`Project`, `Clip`, `ClipMedia`, `FPSMode`, `ConstantStrategy`), `FrameGrid`,
`ExportPlanner`, `FrameRetimer`, `ProjectTimeMap`, `ClipProbe`,
`CadenceValidator`, `CompositionBuilder`, `ClipReencoder`, `ProjectExporter`.
`Package.swift` already has `SlateCore` and `SlateChecks`.

New in Plan 2:
- `Sources/SlateCore/ProjectFile.swift` — Codable DTO + versioning (`.slate`)
- `Sources/SlateCore/Autosave.swift`
- `Sources/Slate/ViewModels/ProjectViewModel.swift` — project, selection,
  undo, player mode. Per-clip trim logic moves out of `EditorViewModel` so
  the existing `TimelineView` binds to the selected clip.
- `Sources/Slate/Views/ClipStripView.swift`, `ClipStripMouseCapture.swift`
- `Sources/Slate/Views/ExportSheet.swift` — exists (old single-clip sheet);
  rewritten to show the plan and stages

Replaced in Plan 2: the old single-clip `Sources/Slate/Services/Exporter.swift`
and `EditorViewModel` flow (the app now calls `ProjectExporter`).

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
- Named regression cases from review:
  - Mixed mode, full 5-frame clip `[0, clipEnd)` keeps all 5 frames.
  - Timescale 24 source: `τ = 0`, and 24→48 still picks
    `0,0,1,1,2,2,3,3,4,4`.
  - 23.976 at timescale 90000 (3753/3754 durations) is not exact CFR. It is
    re-encoded in Constant mode and copied in Mixed mode.
  - 100 frames × 3754 ticks then 100 × 3753 is not exact CFR and is
    re-encoded in Constant mode.
  - Exact 24 fps at timescale 12288 is copied, and the validator sees exact
    `n · d` pts after concat with a re-encoded 48→24 clip.
  - The retimer on a jittered 23.976 source (timescale 90000, `τ = 1 tick`)
    picks the same frames as **exact** picks (`τ = 0`) on the ideal rational
    23.976 source, for targets 1/24, 1/30, 1/48 over 2400 frames (verified
    with exact fractions on 2026-09-29).
  - `[0, 10 ms)` at 24 fps gives `N = 0` under Selective and under Re-encode
    all, and the plan is blocked.
  - For random projects, Selective and Re-encode all give identical `N_k`
    and `O_k`.
- Integration: `CadenceValidator` runs on every generated export in the
  checks target.
- Manual: generated test clips from `scripts/make-test-clips.sh` (24 fps and
  48 fps, with and without audio). Verify output in QuickTime, and with
  `ffprobe`. The user may also run the app on their own clips locally; those
  files never enter the repo.

# Multi-clip concat — design

Date: 2026-09-29
Status: approved in chat, awaiting written-spec review

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
- A newly added clip gets one segment covering its full duration.
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
  - Project: plays an `AVMutableComposition` of all kept segments in order
    (rebuilt on change). A playhead marker moves across the strip. Clicking a
    card in this mode seeks to that clip's start in the output.
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
presence ≠ project, no kept segments in the whole project. The reference
format is the first valid clip.

### Mixed mode

One `AVMutableComposition` (1 video + optional 1 audio track). Insert each
clip's kept segments in project order. Export with
`AVAssetExportPresetPassthrough` to `.mp4`. Each clip keeps its own frame
durations → output is VFR where fps differs. Nothing is re-encoded.

### Constant mode

1. For each `reencode` clip: `AVAssetReader` (decoded frames, kept ranges
   only) → `FrameRetimer` → `AVAssetWriter` into a temp file in `$TMPDIR`.
   - `FrameRetimer` (pure, testable) maps output frame n at `n / target` to
     the source frame with the nearest presentation time at or before it.
     This drops frames (48 → 24) or duplicates frames (24 → 48). Speed is
     unchanged.
   - Same codec and frame size as the project. High quality (bitrate ≈ 2× the
     source bitrate, floor 20 Mbit/s for 1080p).
   - Audio for these ranges is re-encoded to AAC with the same sample rate and
     channel count.
2. Build the composition as in Mixed mode. Re-encoded clips use their temp
   file (full range). `copy` clips use their kept segments.
3. Passthrough export.
4. Delete temp files on success, failure, and cancel.

Known risk: re-encoded clips carry different SPS/PPS, so the video track ends
up with several sample descriptions. QuickTime handles this. Verify in
Premiere/Resolve during manual testing. If an NLE rejects it, the fallback
(out of scope for v1) is re-encoding the whole output in Constant mode.

### Progress and result

- Stages: `Re-encoding k of n` → `Assembling`. Cancel works in both stages.
- Default output name: `<project name>.mp4`. For an untitled single-clip
  project the old name stays `<basename> — trimmed.mp4`.
- Post-export check: open the output, compare duration (± 1 frame per clip)
  and, in Constant mode, the fps against the plan. Show a warning on mismatch.

### Unchanged

Cuts may sit mid-GOP. Passthrough keeps the whole GOP and hides the extra
frames with an edit list, same as today.

## Code layout (new / changed)

- `Models/Project.swift`, `Models/Clip.swift`, `Models/FPSMode.swift`
- `Models/ProjectFile.swift` — Codable DTO + versioning
- `Services/ClipProbe.swift` — loads clip metadata
- `Services/ExportPlanner.swift` — pure
- `Services/FrameRetimer.swift` — pure
- `Services/ClipReencoder.swift` — reader → retimer → writer
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
  resolution, `ExportPlanner` (copy / reencode / blocked cases),
  `FrameRetimer` (24→48, 48→24, 30→30, rounding at segment edges),
  `SegmentOps` id preservation (regression guard).
- Manual: generated test clips (24 fps and 48 fps, with and without audio,
  made via AVAssetWriter in the checks target) plus the user's real ComfyUI
  clips. Verify output in QuickTime, and with `ffprobe` if available.

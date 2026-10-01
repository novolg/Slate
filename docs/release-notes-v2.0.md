# Slate v2.0 — Multi-clip projects

<p align="center">
  <img src="https://raw.githubusercontent.com/novolg/Slate/main/assets/screenshot-v2.png" alt="Slate v2 editor with four clips in the clip strip" width="900">
</p>

Slate v1 trimmed **one** mp4. Slate v2 joins **many clips into one video**.
Add clips, trim each one, put them in order, pick a frame rate, and export a single file with a clean, constant frame rate.

---

## What's new

### Many clips in one project
- **Add Clips** with the toolbar button, ⌘O, or drag files from Finder onto the window.
- Slate now opens **mp4, m4v and mov**.
- Each clip is a **card** in the new clip strip: number, poster frame, file name, kept / total seconds, an fps badge, and a speaker icon when the clip has audio.
- **Reorder** clips by dragging cards. A line shows where the card lands.
- Drop files on the strip to insert them at that spot. Drop them anywhere else to add them at the end.
- Right-click a card: **Duplicate**, **Remove**, **Show in Finder**, **Locate file…**.
- A new clip keeps its **whole length** ("whole clip") until you mark segments with `I` / `O`.

### Clip player and Project player
- **Clip** mode: the timeline and player show the selected clip. You trim here, the same way as in v1.
- **Project** mode: the player plays the **assembled result**, all clips in order. The selection follows the clip under the playhead, and a playhead line moves across the clip strip.
- Switch with the toolbar toggle or `Tab`. A double-click on a card opens that clip for editing.

### Frame-rate control
- **Constant** (default): every clip is re-encoded to **one** frame rate. The output has an exact, constant cadence that works everywhere (YouTube, social, any player, any editor).
  - The fps menu picks the target. **auto** follows the highest frame rate in the project.
  - Badges tell you what happens to each clip: **grey** = already matches, **yellow** = will be converted to the target fps.
- **Mixed**: clips are copied as they are, with no re-encode, and each keeps its own frame rate. Fast and lossless, but **only Apple players** (QuickTime, Safari, Final Cut) play the joins correctly. Slate shows this warning when you pick Mixed.

### New export sheet (⌘E)
- Before you export, the sheet shows the **plan**: mode, target fps, and one row per clip ("Re-encoded to 30 fps", "Skipped: nothing is kept", …).
- During export you see each stage: re-encoding clip N of M, assembling, validating.
- **Every export is validated** before Slate writes it. Slate checks each frame time and the audio sync. If the check fails, Slate writes **no file** and tells you which clip caused the problem.
- Slate **refuses unsafe exports up front** and tells you why. Examples: an unsupported codec, clips with and without audio in one project, or audio that ends before its video.
- Re-encodes use the source codec family (H.264 or HEVC) at the highest bitrate among your clips. Audio is AAC, and Slate fills gaps in the audio with silence.

### Project files (`.slate`)
- **⌘S / ⇧⌘S** save the project as a `.slate` file. **⌘O** opens one, or you can double-click it in Finder.
- Clip paths are saved **relative** to the project file first. You can move the whole folder and the project still opens.
- A missing clip shows as a **red card**. Use **Locate file…** to point it at the file again.
- **Autosave**: a saved project writes itself about 2 s after each change.
- **Crash recovery**: if you quit or crash with an untitled project, Slate offers to **restore** it at the next launch.

### Editing
- **Project-wide undo / redo** (⌘Z / ⇧⌘Z). This covers segment edits, clip order, add / remove / duplicate, mode and fps changes. One drag of a segment edge is one undo step.
- `I` and `O` mark the **exact frame** under the playhead, also during playback.
- Pressing `I` in Project mode jumps back to Clip mode and marks that frame in the clip.
- Clicks on a segment edge no longer move it by accident. A click on a segment body seeks.
- Menu commands are disabled while an export runs.

---

## New keyboard shortcuts

| Key | Action |
|---|---|
| `Tab` | toggle Clip / Project player |
| `[` / `]` | previous / next clip |
| `⌘N` | new project |
| `⌘O` | open clips or a `.slate` project |
| `⌘S` / `⇧⌘S` | save / save as |
| `⌘D` | duplicate selected clip |
| `⌘⌫` | remove selected clip |

All v1 shortcuts still work (Space, J/K/L, ←/→, I/O, Delete, Esc, ⌘Z, ⌘E, zoom).

---

## Changed behaviour (read this if you used v1)

- **Default export is no longer a pure stream copy.** Constant mode re-encodes every clip. This is the only way to get one exact frame rate that every player and editor handles correctly. If you want the v1-style copy without re-encode, use **Mixed** mode. Then only Apple players play the result correctly.
- **A new clip starts as "whole clip"** (fully kept), not empty. Press `I` / `O` to replace that with your own segments.
- **Quitting does not ask to save.** Saved projects autosave. Untitled projects are offered back at the next launch.

---

## Under the hood

- New `SlateCore` library holds all multi-clip logic: export planner, frame-exact timing math (rational numbers, no floating-point drift), frame retimer, composition builder, re-encoder, cadence validator, project file and autosave.
- New `SlateChecks` test harness: **160 checks** (`swift run SlateChecks --strict`). This replaces XCTest, which needs full Xcode.
- Still **no third-party dependencies**. Still builds with Command Line Tools only.

---

## Known limits

- **Mixed mode** joins between different frame rates play correctly in Apple players. ffmpeg-based tools (VLC, many web uploaders) can show them out of order. For upload, use Constant.
- **Compatibility with DaVinci Resolve and other editors is not verified yet** for Mixed exports. Constant exports are clean in AVFoundation and ffmpeg.
- One project cannot mix clips **with audio** and clips **without audio**. Export is refused with a clear message.
- The app is ad-hoc signed, not notarized (same as v1). See below.

---

## Install

Apple Silicon, macOS 14 (Sonoma) or newer.

1. Download `Slate-v2.0-macos.zip` below.
2. Unzip it. You get `Slate.app`.
3. Move `Slate.app` into `/Applications`.
4. **First launch:** right-click `Slate.app` → **Open** → confirm. Slate is ad-hoc signed, so Gatekeeper blocks a normal double-click the first time.

Build from source: `scripts/build-app.sh`, then `open build/Slate.app`.

**Full changelog:** https://github.com/novolg/Slate/compare/v1.0...v2.0

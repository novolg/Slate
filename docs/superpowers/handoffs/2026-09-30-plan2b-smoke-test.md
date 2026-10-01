# Slate multi-clip — manual smoke test (about 15 minutes)

Status when written: `swift build` is clean, `swift run SlateChecks --strict` gives 160 passed / 0 failed / 0 skipped, `scripts/build-app.sh` builds `build/Slate.app`. The GUI has never been run.

Fixtures are in `build/fixtures` (run `scripts/make-test-clips.sh` first if they are missing; it needs Homebrew ffmpeg). Start the app from your own terminal: `open build/Slate.app`.

Tick each line. Write the first failing step and what you saw.

1. [ ] Launch: `open build/Slate.app`. The window title is "Untitled". The window shows "Drop clips here", "mp4, m4v or mov files — or a .slate project", and the buttons Add Clips… and Open Project…. The toolbar shows only "Slate", Add Clips and Export (Export greyed out).
2. [ ] Drag `build/fixtures/c24.mp4` and `build/fixtures/c48.mp4` onto the window.
   - Two cards appear in a strip below the player, numbered 1 and 2, each with a poster, "5.0 / 5.0 s" and an fps badge ("24 fps", "48 fps"). No speaker icon (these two files have no audio).
   - The toolbar shows Clip / Project, Constant / Mixed (Constant selected), a menu reading "48 fps (auto)" and a summary such as "10.0 s · 480 frames".
   - Card 2 (48 fps) has a grey badge. Card 1 (24 fps) has a yellow badge. Hover card 1: the tooltip reads "c24.mp4 — This clip is 24 fps; it is re-encoded to 48 fps."
   - The timeline of the selected clip shows a light dashed segment labelled "whole clip".
3. [ ] Select card 1. Press Space (plays), Space (stops). Press `I` at about 1 s, `O` at about 2 s.
   - The "whole clip" segment is replaced by one yellow segment; the card says about "1.0 / 5.0 s".
4. [ ] Drag the right edge of the yellow segment. Release. Press ⌘Z once: the whole drag is undone in one step. ⇧⌘Z redoes it.
5. [ ] Press `]` then `[`: the selection (accent outline) moves between cards.
6. [ ] Right-click card 1: the menu offers Duplicate, Remove, Show in Finder, Locate file…. Choose Duplicate: a third card appears after card 1 and is selected. ⌘Z removes it. (⌘D also duplicates and ⌘⌫ removes the selected clip; both are in the Clip menu.)
7. [ ] Drag card 2 to the left of card 1: an accent-coloured line shows where it goes and the dragged card dims; after release the cards swap places (the 48 fps clip is now card 1).
8. [ ] Press Tab (or click "Project" in the toolbar): the toggle switches to "Project" (it may take a moment: the preview is built first). Entering Project mode does not start playback; the status bar reads "project". Press Space to play the assembled result. While it plays the selection follows the clip under the playhead and a white line moves across the cards in the strip (the playhead marker). Press `I` during playback: it switches back to Clip mode and sets the in-point on the frame you saw, inside the selected clip.
9. [ ] Toolbar: click Mixed. An orange line shows "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant." The fps menu disappears and no badge is yellow. Click Constant again; the menu returns.
10. [ ] ⌘E (or the toolbar Export button). The sheet is titled "Export". It shows "Constant 48 fps · every clip is re-encoded", a summary, and one row per clip saying what happens to it (in Constant mode every row reads "Re-encoded to 48 fps"). Click "Export…", choose a file in the save panel (default name "Slate export.mp4"). The sheet title changes to "Exporting…" and shows the stages "Starting…", "Re-encoding 1 of 2", "Re-encoding 2 of 2", "Validating" (there is no "Assembling" stage in Constant mode; it appears only in Mixed), then the title "Export complete" with the file path. Click "Reveal in Finder", then "Done". Open the file in QuickTime: it plays. Run `scripts/phase0-ffprobe.sh <the file>` if you want the fps and pts report.
11. [ ] ⌘S: choose a name, e.g. `test.slate`. The window title becomes "test" (no "— Edited"). Make a change: the title shows "test — Edited"; wait about 3 s: the title clears (autosave wrote the file).
12. [ ] Quit (⌘Q). Launch again and double-click `test.slate` (or ⌘O and choose it): the clips, segments and Constant 48 fps come back. The cards show posters again.
13. [ ] Rename `c24.mp4` to `c24x.mp4` (do not move the folder: relative paths resolve first, so a moved folder with `test.slate` inside still works), reopen the project: that card is red with "— / — s" and "—" for the fps badge; hover it: "c…mp4 — File is missing or unreadable."; with it selected the player says "This file is missing". Right-click → Locate file… and pick the file: the card recovers. Then rename the file back to `c24.mp4`; step 14 needs it.
14. [ ] ⌘N (choose Don't Save if asked): an empty "Untitled" project. Drop `c24.mp4` on the window, wait 3 s (title "Untitled — Edited"), then force-quit the app (Activity Monitor). Launch again: a dialog "Restore your unsaved project?" offers Restore. Restore: the clip is back and the title shows "Untitled — Edited".
15. [ ] Drop a text file (any `.txt`) on the window together with `c48.mp4`: `c48.mp4` is added; an "Error" alert names the text file ("x.txt: not a video file Slate can open (mp4, m4v, mov)"). The rest of the project is unchanged. (Dropping only the text file gives "Slate opens mp4, m4v and mov video files and .slate projects.")
16. [ ] Start from ⌘N (Don't Save), then add ONLY `build/fixtures/c24_a.mp4` and `build/fixtures/c24_trunc_a.mp4` (audio 0.5 s shorter than its video); mixing clips with and without audio blocks the plan. Tab to Project: a yellow note reads "Preview is silent: the audio of clip N ends before its video. Export will refuse it." Export: after "Export…" the sheet titled "Export failed" says which clip's audio ends more than one audio packet before its video, and nothing is written.
17. [ ] Keep at least one other clip with kept frames while you delete segments, otherwise ⌘E is disabled. The yellow "preview is silent" note from step 16 disappears after the first edit. Delete every segment of one clip (click the segment, press Backspace): the card shows "0.0 / 5.0 s" and the sheet row (⌘E) says "Skipped: nothing is kept". Remove all clips (⌘⌫ repeatedly, or right-click → Remove): the window returns to "Drop clips here", the toolbar Export button is greyed out and the File menu's Export… is disabled.

## Quit and unsaved changes

Quitting does not ask to save. A titled project is autosaved in place (about 2 s after each change). An untitled project is kept and offered back at the next launch. "Don't Save" in the New/Open prompt therefore rarely reverts a titled project, because its edits were already written.

## Known rough edges to watch

These were not verified by running the app. Report any that misbehave.

- Key focus after clicking the timeline: do Space, `I` and `O` still work, or does the click steal focus?
- The clip strip's own Finder drop (insertion line at the drop position) versus the window-wide drop (adds at the end): does the strip's handler win when you drop over it?
- Tooltips on the strip: the card tooltip comes from a mouse-capture layer, not from SwiftUI `.help`; check it appears after a short hover.
- Finder association of `.slate` files (double-click opens Slate) depends on the Info.plist type declaration and may need a Launch Services refresh or a second launch.
- Autosave on quit: does quitting with unsaved changes leave a titled project's file up to date and an untitled one restorable?
- Menu enable/disable refresh: do Export…, Undo/Redo and the Clip menu items grey and un-grey immediately as the project changes?
- Project-mode dimming of the timeline: in Project mode the timeline should look inactive; check it is clear and that clicks do the sensible thing.
- Drag feel of timeline edges (3 pt threshold): is a click on an edge ignored and a real drag smooth, without jumps?
- Verify that Fn+Delete deletes the selected segment (the code handles it; only a run can confirm).
- Verify that Tab and Backspace do nothing while a panel (open/save/locate) or alert is open (the code handles it; only a run can confirm).

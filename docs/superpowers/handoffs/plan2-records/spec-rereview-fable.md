# Scoped spec re-review — "Plan 2 decisions" edit (2026-09-30)

Reviewer: Claude Fable 5.1 (independent, read-only). Date: 2026-09-30.
Input: `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md` (uncommitted, 517 lines) against
`plan2-records/spec-review-fable.md`. No source or git state changed. Line numbers are spec lines
in the edited file.

## Findings

| Item | Status | Where |
|---|---|---|
| I1 `constantStrategy` default | ADDRESSED | 404-406: defaults to `.reencodeAll`, not stored in v1 `.slate`, two checks named. |
| I2 new project default (user: option a) | ADDRESSED | 10-12 Goal rewritten; 407-411 ruling 3: Constant + Re-encode all, target = highest exact `d`, Mixed opt-in. |
| I3 acceptance step | ADDRESSED | 416-420: exact check on `phase0-mixed(-audio)` + `ex-mixed` first, result to `MASTER_PLAN.md`, ruling 1 reopens on failure, no sheet work before. |
| I3 refuse in every mode | ADDRESSED | 421-422, 303-306, 317-320: no "warning" path. |
| I3 Mixed `T_out` block | ADDRESSED | 423-426: planner blocks on lcm overflow, no silent fallback in `ExportPlanner.outputTimescale` or `CompositionBuilder`. |
| M1 status line | ADDRESSED | 4. |
| M2 superseded markers | ADDRESSED, one residual | 10-12, 83-86, 89-92, 273-275, 303-306, 317-320, 385 done. Residual: 22-23 ("viewing/social (mixed fps is fine)") has no marker and now contradicts ruling 1. 365-370 (item 3, "Selective becomes the default") has no marker but the outcome block right after it makes the result clear. |
| M3 Phase 0 outcome | ADDRESSED | 371-383. Table and root cause match the measured evidence (1/16 s = 768 ticks at 12288; 107/130 frames; ~300 errors). |
| M4 picker for non-exact-CFR clips | ADDRESSED | 447-450 fallback to `frameDuration(fps: nominalFPS)`; 410-411 "highest" compares exact `d`. |
| M5 fps badge | ADDRESSED | 89-92. |
| M6 codec blocker scope | ADDRESSED | 431-433: every mode, allowed set `avc1`, `hvc1`/`hev1`. |
| M7 missing review minors | ADDRESSED | 434-440: `ClipProbe` throws, `--strict`, stale `*-INVALID.mp4`, `preconditionFailure`, pointer to both review files. |
| M8 Mixed label text | ADDRESSED | 397-399. |
| M9 `.slate` storage of `constantStrategy` | ADDRESSED | 404-405. |
| M10 code layout | ADDRESSED | 456-475. The "already exists" list matches the 14 files in `Sources/SlateCore/`. |
| M11 audio-shortfall bound value | ADDRESSED | 443-444 (1024 samples). |
| M12 Mixed `T_out` documented | ADDRESSED | 423-426 (as a block rule, not a fallback). |

No older text contradicts "Plan 2 decisions" on any point that changes Plan 2 work. The
remaining Constant-mode copy text (188-193, 231-237, 208-210) still describes the hidden Selective
path and the badge's "would copy" reason; it is consistent with rulings 2 and 3.

## New breakage

None Critical or Important.

Minor (from the new text; fix in the same edit):

- **409-410** — "`Project.init` default `fpsMode` changes from `.mixed` to Constant (the target is set
  when clips are added)". `FPSMode.constant(frameDuration:)` needs a value at init, and the spec
  does not say what an empty project holds, or what happens when the highest-fps clip is removed
  later. Suggest: default `.constant(frameDuration: Rational(1, 24))`; the target follows "highest"
  automatically until the user picks one in the toolbar, then it is sticky; a loaded `.slate` file
  keeps its stored target. One sentence each.
- **36** — `.constant(target: Double)` is stale. Code and every timing section use an exact
  `Rational` `d`. Say `.constant(frameDuration: Rational)`, so the `.slate` DTO (Plan 2) stores the
  fraction (num/den), never a Double.
- **22-23** — the M2 residual above: add "(superseded by Phase 0: Mixed is Apple players only, see
  Plan 2 decisions)".
- **370-371** — no blank line before "**Phase 0 outcome**" inside the numbered list. Markdown will
  fold the heading and the table into list item 3. Insert a blank line at 371 (and before 385).
- **472** — `Sources/Slate/Views/ExportSheet.swift` is listed under "New in Plan 2" but the file
  exists (old single-clip sheet). Say "rewritten".
- **314** — stages list omits `Validating`, which `ProjectExporter` reports (`progress(.validating)`)
  and which the sheet must show, since it can now refuse the export. Suggest
  "`Re-encoding k of n` → `Assembling` → `Validating`".

## Verdict

**All findings addressed.** No Critical or Important items. Six one-line minors above.

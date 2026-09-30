# Spec review — "Plan 2 decisions" section (uncommitted edit, 2026-09-30)

Reviewer: Claude Fable 5.1 (independent, read-only). Date: 2026-09-30.
Input: `docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md` on `main` (227c3a0) plus the
uncommitted diff (spec lines 369-400), `docs/superpowers/handoffs/2026-09-30-plan2-handoff.md`,
`MASTER_PLAN.md`, `plan1-records/final-review-fable.md`, `plan1-records/final-rereview-fable.md`, and
the code on `main`. Nothing in the repo was changed except this report. Line numbers below are spec
lines unless a file is named.

## Critical

None.

## Important

### I1. Ruling 2 leaves the model default on the hidden, unsafe path

- **Where:** lines 377-379; `Sources/SlateCore/ProjectModel.swift:70`
  (`constantStrategy: ConstantStrategy = .selective`); `Sources/SlateCore/ExportPlanner.swift:152-157`.
- **What:** the spec hides Selective and calls Re-encode all "the default", but says nothing about
  `Project.constantStrategy`. Its code default is `.selective`. The spec does not tell Plan 2 to flip
  it, and does not say what a `.slate` file without the field decodes to.
- **Why:** a `Project()` built by the UI, or a v1 file loaded from disk, would export through the hidden
  Selective path (two `avc1` descriptions, ffmpeg errors) while the sheet shows no control for it.
- **Fix:** add to ruling 2: "`Project.constantStrategy` defaults to `.reencodeAll`. The v1 `.slate`
  file does not store it." Add a check: `Project().constantStrategy == .reencodeAll`, and the planner
  on a default Constant project marks every clip `.reencode(.reencodeAll)`.

### I2. The default `fpsMode` of a new project is not stated, and the Goal text contradicts the rulings

- **Where:** lines 10-11 ("stream-copied (no re-encode) by default"), 21-22, 35, 82-84;
  `Sources/SlateCore/ProjectModel.swift:70` (`fpsMode: FPSMode = .mixed`).
- **What:** after rulings 1 and 2, Mixed is "Apple players only" and Constant re-encodes everything.
  The spec never says which mode a new project starts in. The code default is Mixed. The Goal line
  still promises stream copy by default.
- **Why:** this decides the first export of every project and the layout of the export sheet. The
  user's own case (24 fps clips next to RIFE 48 fps clips) is exactly where Mixed breaks in ffmpeg. A
  Plan 2 author reading top-down keeps Mixed as the default because the Goal says so.
- **Fix:** user decision. Record it in the Plan 2 section and rewrite lines 10-11.
  - (a) New project = Constant + Re-encode all, target = highest fps present. Mixed is opt-in and
    carries the "Apple players only" label.
  - (b) New project = Mixed (lossless), as the code does today.
  - Recommendation: (a). It is the only path clean in both AVFoundation and ffmpeg, and it matches
    the "social/upload → Constant" routing in ruling 1.
  - **User ruling (2026-09-30): (a).** A new project starts in Constant + Re-encode all, target =
    highest fps present. Mixed is opt-in with the "Apple players only" label. `Project.init` default
    `fpsMode` must change accordingly (`Sources/SlateCore/ProjectModel.swift:70`), and lines 10-11 of
    the spec must be rewritten.

### I3. Ruling 3 has no failure path, and two cases make the exact check fail on correct files

- **Where:** lines 380-383, 296-297, 309-310, 317-320; `Sources/SlateCore/ProjectExporter.swift:96-101`;
  `Sources/SlateCore/ExportPlanner.swift:164-192`; `Sources/SlateCore/CompositionBuilder.swift:67`.
- **What:**
  1. A failed validation *refuses* the export (`validationFailed`, destination untouched). Lines
     296-297 and 309-310 say Mixed "shows a warning". With exact pts validation, a Mixed export whose
     24→48 join AVFoundation places off the expected grid is refused, not warned. Review item I2
     showed the current validator cannot see that class of error. Nobody has yet shown that
     AVFoundation decodes `phase0-mixed.mp4` on the exact grid. If it does not, ruling 1 ("Mixed
     stays") is dead on arrival.
  2. In Mixed mode `outputTimescale` drops a required timescale on lcm overflow and returns the
     largest one; `CompositionBuilder` then lets AVFoundation round the insert position. An exact
     comparison fails on such a file although the build did what the spec allows.
- **Why:** Plan 2 must know whether the exact check is a gate (refuse) or a report (warn), and what
  happens when no exact grid exists.
- **Fix:**
  - Add an acceptance step to ruling 3: "Run the exact check on `phase0-mixed.mp4`,
    `phase0-mixed-audio.mp4` and the `ex-mixed` checks first. Record pass/fail in `MASTER_PLAN.md`.
    If it fails, ruling 1 is reopened (gate on identical format descriptions, or re-encode at joins)."
    Do this before any export-sheet work.
  - State: validation failure = export refused in every mode (matches lines 317-320); the sheet shows
    the report. Replace "warning" at 296-297 and 309-310.
  - State the Mixed `T_out` rule: when the lcm of the copied timescales overflows, the planner blocks
    ("clip timescales cannot share one exact timeline"), same as Constant. Then the exact check always
    has an exact grid. Overflow is rare (12288 and 90000 give 23 040 000, well under `Int32.max`), so
    blocking costs nothing.

## Minor

- **M1.** Line 4 status is stale. Suggest: "Plan 1 done, merged to `main` 2026-09-30. Phase 0 decided.
  Plan 2 next."
- **M2.** Superseded passages carry no marker: lines 10-11, 21-22, 82-84 (toggle text), 203-207
  ("Re-encode everything" checkbox), 268-282 (Selective default, checkbox), 296-297, 309-310,
  355-364. The new header says "override", but the handoff calls the spec binding and Plan 2 authors
  read top-down. Add "(superseded, see Plan 2 decisions)" at each spot, or edit the text.
- **M3.** The Phase 0 outcome is not in the spec. Lines 331-367 still read as a plan. Add the result
  table from handoff §4 (three rows) after line 364, plus the root cause (two format descriptions +
  mid-GOP edit lists).
- **M4.** Line 396, fps picker: a non-exact-CFR clip (jittered 23.976) has no `srcD`
  (`FrameTable.exactFrameDuration` is nil). Say what the picker lists then. Suggest: the set of `srcD`
  over exact-CFR clips; if that set is empty, `Rational.frameDuration(fps: nominalFPS)` per clip
  (Double match, already ruled acceptable) with the plan row "timing not exact". Also define
  "default = highest" when `1001/24000` and `1/24` both appear.
- **M5.** Lines 87-89, fps badge: with Re-encode all as the only Constant strategy, every card in
  Constant mode is yellow, so the badge says nothing. Suggest: yellow only when the clip's own timing
  would not copy (fps differs / timing not exact, i.e. the `.selective` decision); tooltip:
  "re-encoded (all clips are, in Constant mode); timing: exact 24 fps".
- **M6.** Line 388: say the codec blocker applies in every mode (Mixed passthrough of ProRes into
  `.mp4` also fails at export) and name the allowed set: `avc1`, `hvc1`/`hev1`.
  `VideoEncodeSettings.matching` (`Sources/SlateCore/ClipReencoder.swift:54-59`) maps anything else
  to H.264 today.
- **M7.** Lines 385-397 omit review items that touch Plan 2 UI or its evidence:
  `Sources/SlateCore/ClipProbe.swift:27, 31-37` (unreadable format → codec 0 / silent "no audio"; the
  red card would say "format mismatch" for the wrong reason; throw instead);
  `Sources/SlateChecks/Harness.swift:16-19` (skips exit 0; handoff §3 calls it known, and it now also
  hides the I1 regression check when fixtures are stale; add `--strict` in Plan 2's first task);
  `Sources/SlateChecks/Phase0.swift:71` (stale `*-INVALID.mp4` never removed);
  `Sources/SlateCore/ProjectExporter.swift:184` (unreachable guard → `preconditionFailure`).
  Add one line: "Other deferred minors: `plan1-records/final-review-fable.md` §Minor and
  `final-rereview-fable.md`." Handoff line 78 points only to the ledger, which lists task minors, not
  the review minors.
- **M8.** Ruling 1: give the exact label text so Plan 2 does not invent it. Suggest: Mixed —
  "Apple players only (QuickTime, Safari, Final Cut). For upload or other players use Constant."
- **M9.** Ruling 2: say whether the `.slate` file stores `constantStrategy`. Suggest: not stored in v1
  (ties to I1).
- **M10.** Lines 402-421 "Code layout" are stale. Logic lives in `Sources/SlateCore/`
  (`ProjectModel.swift` holds `Project`/`Clip`/`FPSMode`/`ConstantStrategy`; `ProjectExporter.swift`,
  not `Services/Exporter.swift`; `ProjectTimeMap.swift` is in SlateCore). `Sources/Slate/Services/Exporter.swift`
  and `EditorViewModel` are the old single-clip flow that Plan 2 replaces. `ProjectFile.swift`,
  `Autosave.swift`, `ProjectViewModel.swift`, `ClipStripView.swift` do not exist yet. Update so Plan 2
  does not duplicate a module.
- **M11.** Line 392: state the bound value (1024 samples, one AAC packet) so `CompositionBuilder` and
  `ClipReencoder` agree.
- **M12.** Lines 191-196: the Mixed `T_out` fallback is undocumented (see I3.2).

## Consistency with the handoff and MASTER_PLAN

- Rulings 1-3 match handoff §5: option (a), "hide", "yes". OK.
- The carry-over list equals handoff §6 plus "plan rows mention audio format differences". OK.
- `MASTER_PLAN.md` line 102 still lists the Mixed misplacement as "Unresolved; Plan 2 design
  question". After this edit, record ruling 1 there (controller's job).

## Verdict

**Ready after fixes.** Critical 0, Important 3. I1 and I3 are spec edits. I2 is decided by the user:
option (a), record it in the spec.

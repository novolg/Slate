# Independent review — feat/multi-clip-core (5efbcf5..3772ed9)

Reviewer: Claude Fable 5.1 (independent, read-only). Date: 2026-09-30.
Worktree: `.claude/worktrees/multi-clip-core`. No source, git state or branch was changed.
`MASTER_PLAN.md` was not updated (read-only request; the ledger assigns that to the controller).

## Scope and method

- Read: spec, plan (Global Constraints + Review Focus), `progress.md`, `deferred-and-rulings.md`,
  `final-fix-report.md`, both requested diffs, and every file under `Sources/SlateCore`,
  `Sources/SlateChecks`, `scripts/`, `Package.swift` at HEAD 3772ed9.
- Did not re-run the suite (81/81 reported).
- Ran read-only probes on the existing `build/fixtures` and `build/phase0` files with ffprobe and a
  small MP4 atom parser, plus one compiled probe for a single doubt (AVAssetWriter audio gaps).
  Probe files live in `build/review-scratch/` (gitignored, safe to delete):
  `stsd.py`, `gap.swift`, `gap`, `gap.mp4`.

### Fix wave 0dca9fd..3772ed9 — all six items verified present and correct

1. Mixed+audio case: `Phase0.swift:44`, check `ExporterChecks.swift:24-29`. Passes in AVFoundation.
2. ffprobe monotonic-pts pass: `scripts/phase0-ffprobe.sh:16-28`. Works (see Phase 0 section).
3. Comment on the Selective-24 check: `ExporterChecks.swift:31-33`. Accurate.
4. Task cancellation: `ProjectExporter.swift:72-111` (`withTaskCancellationHandler` → `cancel()`).
   Pre-cancelled Task also ends as `.cancelled` because `render`/`reencode` check the flag first.
   Check `ExporterChecks.swift:225-245`.
5. Single-use doc + check: `ProjectExporter.swift:31-37`, `ExporterChecks.swift:247-261`.
6. Duplicate clip ids blocked: `ExportPlanner.swift:119-128`, check `PlannerChecks.swift:89-95`.
   The only keyed-by-id trap (`ProjectExporter.swift:151`) is now unreachable.

## Critical

None found.

Timing math was traced by hand across FrameTable → FrameGrid → ExportPlanner → FrameRetimer →
ProjectTimeMap → CompositionBuilder → ClipReencoder → CadenceValidator. Snapping, `N = round((e−s)/D)`,
clip-end clamp, `notBefore` start pushing, output offsets, retimer picks, `T_out`, and the exact
`n·d` validator all match the spec. No overflow path can produce a silently wrong number: `Rational`
traps on overflow, and `lcm` overflow is a planner blocker (Constant) or a documented fallback (Mixed).
Source-file safety (`outputCollides` + staged `install`) covers symlinked parents, case aliases and
hard links. Cancel and failure paths remove the staged file, the work directory and the `.slate-*`
sibling, and never touch the destination.

## Important

### I1. Re-encode audio: a missing-sample gap is collapsed by AVAssetWriter, so later audio plays early

- **Where:** `Sources/SlateCore/ClipReencoder.swift:300-311` (`AudioCoverage.accept`),
  `:314-320` (`finish`), `:372-378` and `:383-387` (`AudioSampleSource.appendNext` on source end).
- **What:** When a source's audio ends before its kept video range (allowed shortfall ≤ 1024 samples)
  or a decoded buffer starts after the wanted sample, the code only *counts* the missing samples.
  Nothing is appended for them. The next piece is appended at its correct `outStartSample`, so the
  PCM stream handed to the writer has a timestamp gap.
- **Why it matters:** AVAssetWriter's AAC input does not preserve such a gap. Verified with
  `build/review-scratch/gap.swift`: appending PCM `[0, 1.0 s)` then `[1.5 s, 2.5 s)` yields an
  audio track of **2.0 s** with no discontinuity ("RESULT: gap COLLAPSED"). In **Re-encode all**
  (the Phase 0 default) every clip after a short-audio clip is shifted earlier by that clip's
  shortfall, and shortfalls accumulate. Up to one AAC packet (~23 ms at 44.1 kHz) per clip passes
  the validator's end check unnoticed; beyond that the export is *refused*, so a project of several
  `-shortest` clips kept to their end cannot be exported at all. The spec's claim "audio and video
  share one output clock and drift cannot build up across joins" does not hold on this path.
  Selective mode is unaffected (one writer per clip, nothing follows the gap).
- **Fix:** Pad instead of count. In `AudioSampleSource.appendNext`, when `accept` reports
  `lo > wantFrom` or `finish()` leaves `cursor < count`, append a zero-filled PCM buffer covering
  the missing samples at `outStartSample + wantFromRelative` (same format as the trimmed buffers)
  before continuing. Keep the `> 1024` error. Add a check: two clips whose audio is cut short
  (`ffmpeg -t 4.95` on the audio input, or `-shortest` with a shorter sine), Re-encode all,
  assert the export succeeds and `audioEnd == videoEnd` within one sample.

### I2. Mixed-mode validation cannot see seam timing errors although the expected frame list is known exactly

- **Where:** `Sources/SlateCore/CadenceValidator.swift:50-61` (`mixedIssues`), `:97-100` (`validate`).
- **What:** Mixed checks only frame count and total duration (±1 ms). The ledger records that a
  "seam timing wobble in Mixed can pass unnoticed". But Mixed copies frames, so the exact decoded
  pts sequence is computable from the grid: for each grid segment, the source pts in
  `[s', s'+D·N)` (or `[b[a], b[z])`) shifted by `O_k − s'`. ffprobe on `phase0-mixed.mp4` shows a
  1536-tick frame at the c24→c48 join and the whole c48 part 768 ticks early (below); the
  AVFoundation validator returns `ok`. Whether AVFoundation *itself* decodes those frames on time is
  therefore not proven by the current check.
- **Why it matters:** The Phase 0 statement "Mixed passes AVFoundation" rests on a validator that
  cannot fail for this class of error. Plan 2 will build the Project preview and the "lossless
  default" on Mixed.
- **Fix:** Add `expectedPTS(grid:, tables:) -> [Rational]` (pure, in `FrameGrid` or the validator)
  and compare `decodedTimes(...)` to it exactly in Mixed mode; keep count/duration as secondary
  messages. Drop the 1 ms tolerance (`:57`) — all inputs are exact. Unit-check it with the existing
  `c24`/`c48` frame tables and one deliberately shifted list.

### I3. Mixed and Selective outputs carry two sample descriptions plus mid-GOP edit lists; ffmpeg mis-applies them

- **Where:** `Sources/SlateCore/CompositionBuilder.swift:62-78` (one insert per source asset),
  `Sources/SlateCore/ProjectExporter.swift:177-205` (passthrough concat of heterogeneous inputs);
  spec §3 "Mixed mode" and "Two strategies, one code path".
- **What (measured, `build/review-scratch/stsd.py`):**

  | file | video `stsd` entries | `elst` entries | B-frames |
  |---|---|---|---|
  | c24.mp4 / c48.mp4 (fixtures) | 1 / 1 | 1 / 1 | 2 / 2 (High, level 3.0 vs **3.1**) |
  | phase0-mixed.mp4 | **2** (`avc1`,`avc1`) | 3 | 2 |
  | phase0-mixed-audio.mp4 | **2** video + **2** audio (`mp4a`,`mp4a`) | 3 + 3 | 2 |
  | phase0-selective-24.mp4 | **2** | 2 | 2 |
  | phase0-selective-48-INVALID.mp4 | **2** | 2 | 2 |
  | phase0-all-24.mp4 | 1 | 1 | 0 |

  The two fixtures differ in SPS (level 3.0 vs 3.1), so passthrough concat produces two `avc1`
  descriptions in one track, switching at the join, with every edit pointing mid-GOP. ffmpeg decodes
  `phase0-mixed.mp4` with **0 errors** but places the second description's edits wrong: video frame
  67 lasts 1536 ticks, the c48 part starts at 34560 instead of 35328 (768 early), last frame 65536
  instead of 66304; audio packet pts jump from 69114 back to 24769 at packet 71. The c48 fixture
  alone is monotonic in ffmpeg (the controller's refutation of the fixer's "inherent to c48" claim
  is correct).
- **Why it matters:** "Viewing/social" outputs are almost always transcoded by ffmpeg-based
  pipelines. The ruling "keep Mixed as the lossless default for viewing/social" is therefore not
  safe as worded. This is a design limit of AVFoundation passthrough concat, not a defect in
  Slate's math, but Plan 2 must decide on it before exposing Mixed as a default.
- **Fix (design, Plan 2):** either (a) label Mixed "for Apple/AVFoundation players only" and route
  "social/upload" to Constant + Re-encode all, or (b) gate Mixed copy on identical video/audio
  format descriptions across clips (one `stsd`), falling back to re-encode otherwise. Add the audio
  stream to `scripts/phase0-ffprobe.sh` (`-select_streams a:0`) so audio misplacement is visible.

## Minor

- `Sources/SlateCore/ClipReencoder.swift:79` — `try? removeItem(at: outputURL)` on a public API
  deletes whatever path the caller passes. Safe today (exporter passes only staged/work paths) but a
  latent source-deletion hazard for future callers. Guard with the same collision check or document
  "outputURL must be a fresh temp path" and assert it is under `tempDirectory`.
- `ClipReencoder.swift:126-159` — `Task.detached` + `Thread.sleep(0.002)` occupies a cooperative
  thread; cancellation of the *enclosing* Task never reaches `encode()` when used standalone (only
  via `ProjectExporter`). On error exits the `AVAssetReader`s held by `VideoFrameSource` /
  `AudioSampleSource` are not `cancelReading()`-ed (ledger: deferred). Add a cleanup that cancels
  both readers in the `catch` and on completion.
- `ClipReencoder.swift:263` — `currentIndex = frames.lastFrameIndex(atOrBefore: pts) ?? -1`. A
  decoded pts one tick *below* the table pts maps to the previous frame; the loop then accepts the
  *next* decoded frame as `want`, an off-by-one with no error. The probe check proves decoded ==
  table pts for the fixtures, so this is robustness only. Prefer exact match `pts == frames.pts[i]`
  and throw `missingFrame` otherwise.
- `Sources/SlateCore/ClipProbe.swift:113-125` — sample durations are not clipped to the edit
  segment or track range. An edit list that ends mid-sample makes `clipEnd > trackRange.end`, so
  `fits` can admit a frame `insertTimeRange` cannot supply. Clamp `duration` to
  `min(duration, sourceEnd − p)` and `rangeEnd − mapped`.
- `ClipProbe.swift:27, 31-37` — an unreadable video format description becomes codec `0`; an
  unreadable audio format silently becomes "no audio". Both then surface as confusing planner
  mismatches. Throw `ClipProbeError` instead.
- `Sources/SlateCore/ExportPlanner.swift:87` — only audio *presence* is compared. Differing sample
  rate/channels in Mixed passthrough is untested (ledger: deferred). Re-encode all handles it via
  reader conversion. Agree with deferral; note it in the plan row when Plan 2 shows the plan.
- `Sources/SlateCore/ProjectExporter.swift:165-167` — Re-encode all reports `reencoding(clip: 1, of: 1)`
  regardless of clip count (ledger: deferred). Derive the index from `videoSource.jobIndex`.
- `ProjectExporter.swift:184` — `guard let d … else { continue }` is unreachable (planner never
  returns `.reencode` in Mixed); make it a `preconditionFailure` so a future regression is loud.
- `ProjectExporter.swift:95` — validation is not interruptible; a cancel during `validating` is
  honoured only afterwards (ledger: deferred). Acceptable for v1; add `Task.checkCancellation()`
  between the video and audio passes when the validator becomes async-friendly.
- `Sources/SlateCore/CompositionBuilder.swift:67` — the `?? ins.outputStart.cmTime` fallback (Mixed
  `T_out` overflow) lets AVFoundation round the insert position. Acceptable only because Mixed makes
  no cadence promise; surface it as a plan warning rather than silently.
- `Sources/SlateCore/FrameTable.swift:44` — `Rational(1, Int64(timescale))` traps on `timescale == 0`
  (ledger: deferred). Add `precondition(timescale > 0)` in `init`.
- `Sources/SlateChecks/Harness.swift:16-19` — exit code is 0 when checks are *skipped*. Without
  fixtures, ~34 media checks skip and the run still "passes". Add a `--strict` flag (or make
  `phase0`/CI fail on skips) so "81/81" cannot be reported from a fixture-less run.
- `Sources/SlateChecks/ExporterChecks.swift:34-44` — asserts `sel.ok` for a seam configuration the
  ledger itself calls "not deterministic by seam type". Brittle against AVFoundation changes; use the
  same "ok or refused, and Re-encode all passes" shape as the 48 fps check.
- `ExporterChecks.swift:225-245` — `TaskCancelBox` race (acknowledged in the fix report). Cheap
  fix: cancel via `exporter.cancel()` *and* `task.cancel()` after `box.set`, or start the export
  only after the box is set using a `CheckedContinuation`.
- Missing check: Re-encode all output has **one** video format description, no B-frames, and
  monotonic pts — the properties that made it the default. Assert
  `track.load(.formatDescriptions).count == 1` and decoded pts strictly increasing in the
  `ex-c24-all` / `ex-dup-all` checks so an encoder-settings change cannot regress it silently.
- `Sources/SlateChecks/Phase0.swift:62-65` — `load()` sits outside the per-case `do/catch`; a bad
  `--clip24` path aborts the whole run (ledger: deferred, plan-mandated). `Phase0.swift:71` — a stale
  `*-INVALID.mp4` from an earlier run is never removed when the case later passes; remove it before
  exporting.
- `scripts/phase0-ffprobe.sh` — only the video stream is checked for monotonic pts; add the audio
  stream (see I3). The "frame durations" bucket list cannot show misplacement; keep, but the
  monotonic line is the useful signal.
- `Sources/SlateCore/Rational.swift:107-117` — `frameDuration(fps:)` Double matching (ruled
  acceptable). Plan 2 should derive `d` from the clips' exact `srcD` where possible, as the ruling says.

### Test quality (summary)

Good: exact-rational property checks (random projects, offsets multiples of `d`), named regression
cases from the spec reviews (adjacent selections, τ at coarse timescales, jittered 23.976, drift),
real AVFoundation round trips for probe/composition/reencoder/exporter, and safety checks that assert
"source bytes unchanged" and "previous export unchanged". Weak: the Mixed validator is too permissive
to make the Mixed end-to-end checks meaningful (I2); no check exercises an audio shortfall through the
writer (I1); skips count as success; no check pins the single-`stsd`/no-B-frame property of the
default path.

## Phase 0 decision assessment

Recorded decision: **Constant default = Re-encode all; Selective unsafe; Mixed passes AVFoundation but
ffmpeg sees a backward pts step at the 24→48 join.** Evidence level recorded as "NLE compatibility:
UNVERIFIED".

- **Re-encode all as the Constant default — supported.** `phase0-all-24`, `-all-48`, `-all-24-audio`
  pass the exact `n·d` validator (frame count, every duration, track end, audio start/end). The files
  have one `stsd`, one `elst`, no B-frames (`AVVideoAllowFrameReorderingKey: false`), movie and media
  timescale 12288. ffmpeg decodes 130 / 261 frames with **0** H.264 error lines and monotonic pts.
  Caveat: I1 affects exactly this path for short-audio sources; fix before relying on it with audio.
- **Selective unsafe — supported, and the two failure axes are independent.**
  `phase0-selective-48` fails the AVFoundation validator ("frame 138 lasts 1/16") yet ffmpeg decodes
  it cleanly and monotonically. `phase0-selective-24(-audio)` passes AVFoundation yet ffmpeg decodes
  only **107 of 130** frames with **300** error lines ("no frame!", "reference count overflow").
  Neither Selective file is good on both axes. Mechanism: two `avc1` descriptions (copied libx264
  vs re-encoded VideoToolbox) in one track with mid-GOP edits. The decision to make Selective
  non-default (experimental/hidden in Plan 2) is right.
- **Mixed — partly supported; two corrections to the record.**
  1. "Passes AVFoundation" is true only for count + duration; the validator cannot detect seam
     misplacement (I2). Treat as "not shown to fail", not "shown correct".
  2. The fix wave's report says ffmpeg emits H.264 errors for `phase0-mixed(-audio)`. It does not:
     0 error lines, 191 frames decoded. The controller's earlier "0 errors" was correct. What ffmpeg
     does show is misplaced *timing* of the second sample description's edits: video 768 ticks
     early with one 1536-tick frame at the join, audio packet pts jumping backward (I3).
  The corrected ruling ("AVFoundation-clean but ffmpeg misplaces frames at 24↔48 joins; not proven
  safe for upload pipelines; Plan 2 must decide") is the right summary. The earlier ruling "keep it
  as the lossless default for viewing/social" should be withdrawn in `MASTER_PLAN.md`, because
  social uploads are ffmpeg-transcoded.
- **NLE UNVERIFIED — correctly recorded.** No Resolve import, no user clips. Fixtures approximate
  ComfyUI/VHS output (libx264 default GOP, B-frames, timescale 12288) but the user's RIFE clips may
  differ (level, VUI). The `--clip24/--clip48` path exists for the user to run locally.
- **Root cause worth recording:** the ffmpeg-side problems in both Mixed and Selective come from
  multiple sample descriptions per track combined with mid-GOP edit lists, i.e. from AVFoundation
  passthrough concat of clips with different codec parameter sets. Only a single-encoder output
  (Re-encode all) avoids it. This explains why "re-encode at joins" would not by itself fix Mixed.

## Verdict

**Ready after fixes.**

- Must fix before merge: **I1** (pad audio gaps in `AudioSampleSource`; add the short-audio
  Re-encode-all check).
- Strongly recommended before Plan 2 builds on Mixed: **I2** (exact expected-pts validation in Mixed).
- Decision for Plan 2, record now: **I3** (Mixed is AVFoundation-safe only; route upload/social to
  Constant + Re-encode all, or gate Mixed copy on identical format descriptions).
- Minors are non-blocking; the `Harness` skip exit code and the single-`stsd` assertion are the two
  I would take now because they protect the evidence the decision rests on.

Counts: Critical 0, Important 3.

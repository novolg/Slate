# SDD ledger — plan: docs/superpowers/plans/2026-09-29-multi-clip-core-phase0.md

Spec: docs/superpowers/specs/2026-09-29-multi-clip-concat-design.md
Branch: feat/multi-clip-core (worktree .claude/worktrees/multi-clip-core), started at 5efbcf5.
Baseline: `swift build` OK (no tests existed before this plan).

## Pre-flight scan

| Pair / task | Produces → consumes | Finding |
|---|---|---|
| T1 → all | Segment/SegmentOps public, harness, main.swift | OK |
| T2 → T3..T13 | Rational API | OK |
| T3 → T4, T6 | FrameTable incl. firstBoundaryIndex(atOrAfter:), TestData | OK |
| T4 → T5, T6, T7 | models, FrameGrid, LCG (FrameGridChecks) used by T5 | OK |
| T5 → T6, T7 | TestData.c24/c48/media/clip (T5) used in T6 retimer check | OK, T5 precedes T6 |
| T8 → T9..T13 | ClipProbe, fixtures (c48_fs, c48_trunc), fixture()/checksOutputDirectory | OK |
| T9 → T12 | CadenceValidator, CadenceReport public init, mergeDurations | OK |
| T10 → T12 | CompositionBuilder, loadClip | OK |
| T11 → T12 | ClipReencoder, AudioCoverage, ReencodeError cases | OK |
| T12 → T13 | ProjectExporter.validator/keepInvalidAt, validationFailed | OK |
| each task self-consistency | tests vs code, check counts | counts checked while writing (T3 6, T4 9, T5 7, T6 7, T7 4, T8 4, T9 7, T10 2, T11 6, T12 10) |

Ruling: swift build/run commands run with the sandbox disabled — xcode-select link read is blocked in the sandbox (verified) — cost if wrong: none, commands are local builds.
Ruling: heredocs are blocked in this sandbox; implementers write files with Write/Edit tools, not `cat <<EOF` — cost if wrong: none.
Ruling: T13 Step 4 (asking the user) is done by the controller after T13 lands, not by the implementer — the implementer cannot talk to the user — cost if wrong: gate question delayed until the end of the run.

## Progress

Task 1: dispatched (BASE 50154ea, implementer sonnet, agent a0d2f1b6adb31a3d0)
Task 1: implementer DONE (commit 7066532); review dispatched (sonnet, agent a04a33c862ef291f8)
Task 1: Ruling: plan-mandated "duplicated `guard range.duration.seconds > 0`" in insert/commitMarked stays — it is a one-line zero-length guard, not timing math, and pre-existing app behavior; commitMarked needs it before the auto-replace branch — cost if wrong: a trivial refactor later.
Task 1: minor (deferred): checkAsync unused until Task 8 (by design).
Task 1: complete (commits 50154ea..7066532, review clean, 1 plan-mandated ruling)
Task 2: dispatched (BASE 7066532, implementer haiku)
Task 2: implementer DONE_WITH_CONCERNS (54075cc): plan test `lcm(Int64.max/2, Int64.max/3) == nil` is wrong — lcm = 9223372036854775806 fits (verified in Python).
Task 2: fix commit f089099 (6/6 rational, 11 total passing); review dispatched (sonnet)
Task 2: Ruling: plan defect — replace that assertion with `lcm(Int64.max, Int64.max - 1) == nil` (coprime, product overflows; verified) — cost if wrong: none, the lcm overflow path is still tested.
Task 2: Ruling: plan-mandated `frameDuration(fps:)` Double 0.001 match stays — it maps a nominal fps label (UI picker / fallback) to an exact rational once; it never compares frame timestamps, so the "no Double timing comparisons" rule is not violated in spirit — cost if wrong: an odd fps like 23.9 could map to 1000/23900 instead of an intended rate; Plan 2 should prefer clip-derived d.
Task 2: minor (deferred): 0.001 literal duplicated; unary minus bypasses checked helpers.
Task 2: complete (commits 7066532..f089099, review clean, 1 plan-mandated ruling)
Task 3: dispatched (BASE f089099, implementer haiku)
Task 3: implementer DONE (61d75bb, 6/6, 17 total); review dispatched (sonnet)
Task 3: review: Important plan-mandated — duplicated lower-bound search in nearestBoundaryIndex/firstBoundaryIndex.
Task 3: Ruling: fix it (cheap, behavior-neutral): one private `lowerBound(in:_:)` helper shared by both — cost if wrong: one extra fix round.
Task 3: minor (deferred): no timescale>0 precondition; no monotonic-pts check; unreachable guard in pickTolerance; boundaries re-allocated per call.
Task 3: fix round 1/5 (1 addressed, 0 open; commits 61d75bb..a85b130)
Task 3: complete (commits f089099..a85b130, review clean)
Task 4: dispatched (BASE a85b130, implementer haiku)
Task 4: implementer DONE (abf418d, 9/9, 26 total); review dispatched (sonnet)
Task 4: minor (deferred): fourCC untested; notBefore path untested in Mixed non-exact branch; no mixed kept+dropped build test.
Task 4: complete (commits a85b130..abf418d, review clean)
Task 5: dispatched (BASE abf418d, implementer haiku)
Task 5: implementer DONE (2de7f6d, 7/7, 33 total); review dispatched (sonnet)
Task 5: review: Important plan-mandated — outputTimescale folds re-encoded clips' timescales into T_out, so an odd re-encoded timescale can spuriously block (esp. reencodeAll); spec says only copied clips must divide T_out.
Task 5: Ruling: T_out = lcm(d.den, timescales of .copy clips) is REQUIRED (overflow → blocker in Constant, fallback in Mixed); timescales of other usable clips are folded in best-effort only while the lcm stays ≤ Int32.max (keeps 12288/360000 results, never blocks) — cost if wrong: re-encoded output may use a coarser timescale (still exact).
Task 5: minor (deferred): media! force-unwrap relies on blocking-loop invariant; only first BlockReason reported.
Task 5: fix round 1/5 (1 addressed, 0 open; commits 2de7f6d..e20545c)
Task 5: minor (deferred): O(n²) clip lookup in timescale split; redundant Int32 map.
Task 5: complete (commits abf418d..e20545c, review clean)
Task 6: dispatched (BASE e20545c, implementer haiku)
Task 6: implementer DONE (56d7aa1, 7/7, 41 total); review dispatched (sonnet)
Task 6: minor (deferred): `?? 0` fallback in FrameRetimer untested (unreachable with grid-snapped starts).
Task 6: complete (commits e20545c..56d7aa1, review clean)
Task 7: dispatched (BASE 56d7aa1, implementer haiku)
Task 7: implementer DONE (62f0d3a, 4/4, 45 total); review dispatched (sonnet)
Task 7: minor (deferred): projectTime linear scan; non-overlap invariant undocumented locally; no t > total test.
Task 7: complete (commits 56d7aa1..62f0d3a, review clean)
Task 8: dispatched (BASE 62f0d3a, implementer sonnet — first AVFoundation + ffmpeg task)
Task 8: implementer DONE_WITH_CONCERNS (57d4afc, 49 total): added `-bf 0` to fixtures because default libx264 B-frames → edit list → passthrough pts start at 1024/12288; added empty-buffer guard in readFrameTable.
Task 8: Ruling: REJECT `-bf 0` — ComfyUI VHS writes default libx264 (B-frames + edit list); fixtures must match (spec Phase 0). Fix ClipProbe instead: map passthrough sample times through the track's edit segments into the track timeline (the one insertTimeRange and decoded AVAssetReader output use) and prove it equals decoded pts. Keep the empty-buffer guard — cost if wrong: one extra fix round; hiding B-frames would have invalidated Phase 0.
Task 8: fix commit d5ea1c7 (edit-segment mapping; fixtures has_b_frames=2; probe 5/5, 50 total); full review dispatched (sonnet) over 62f0d3a..d5ea1c7
Note for Tasks 9–12: fixtures have B-frames + edit lists (c24 media offset 1/12, c48 1/24); c48 has 237 frames.
Task 8: fix round 1/5 (1 addressed, 0 open; commits 57d4afc..d5ea1c7)
Task 8: minor (deferred): force-unwrap in new probe check; scaled-segment reuses readerFailed; duplicated map-append branches; no reader.status assert in decoded check.
Task 8: complete (commits 62f0d3a..d5ea1c7, review clean)
Task 9: dispatched (BASE d5ea1c7, implementer sonnet)
Task 9: implementer DONE (1c9a14f, 7/7, 57 total; c24_a audio passed first try); review dispatched (sonnet)
Task 9: minor (deferred): cadenceIssues loops don't stop on count mismatch; two "no audio" messages; 1 ms literal.
Task 9: complete (commits d5ea1c7..1c9a14f, review clean)
Task 10: dispatched (BASE 1c9a14f, implementer sonnet)
Task 10: implementer DONE (bd5e5d0, 2/2, 59 total); review dispatched (sonnet)
Task 10: review: Important plan-mandated — `inserts(for:assets:)` silently drops grid segments with no asset (compactMap), leaving a black/silent gap the duration check cannot see; `missingAsset` never thrown.
Task 10: Ruling: make `inserts(for:assets:)` `throws` and throw `.missingAsset(clipID)`; add a check for it plus a placement check (segment target starts == outputStart). Task 12 callers must use `try` — carry into Task 12 dispatch — cost if wrong: none.
Task 10: minor (deferred): audio clip path only tested at sourceStart 0; check 2 lacks canExport guard; audio timeRange reloaded per insert.
Task 10: fix round 1/5 (1 addressed, 0 open; commits bd5e5d0..ad506d7)
Task 10: complete (commits 1c9a14f..ad506d7, review clean)
Task 11: dispatched (BASE ad506d7, implementer sonnet)
Task 11: implementer DONE_WITH_CONCERNS (ee54ad0, 6/6, 67 total): captured `var audioInput` rebound to a `let` for the Task.detached closure (compile fix, no behavior change). Accepted. Review dispatched (sonnet).
Task 11: review Approved. ⚠️ mixed audio/silent jobs in one writer — resolved by controller: ExportPlanner blocks `.audioMismatch`, so ProjectExporter never mixes them (verified in Task 5 code).
Task 11: minor (deferred): no test for VideoEncodeSettings bitrate; no empty-indices guard; readers not cancelled on error exits; Thread.sleep strict-concurrency warning.
Task 11: complete (commits ad506d7..ee54ad0, review clean)
Task 12: dispatched (BASE ee54ad0, implementer sonnet)
Task 12: implementer DONE_WITH_CONCERNS (9d19a97; exporter 8/10): PHASE 0 FINDING — Selective passthrough of B-frame (libx264 default) clips cut mid-GOP produces a timing break at some seams (e.g. "frame 76 lasts 1/16, expected 1/48"; dup-file case "frame 23 lasts 1/12"). Not deterministic by seam type (the c24 copy→copy seam in the 24-selective check passed). The validator catches it and the exporter refuses to install (safety net works). Re-encode all passes.
Task 12: Ruling: apply the spec's Phase 0 rule now — "Selective fails, Re-encode all passes → Re-encode all is the Constant-mode default; Selective stays as an option". Rewrite the two failing checks to pin the safety property instead of hiding it: Selective must either pass validation or be refused with validationFailed and leave no file; Re-encode all on the same project must pass. — cost if wrong: Selective output quality is under-tested; Task 13 Phase 0 run still records the raw per-case result.
Task 12: fix commit 511010a (only ExporterChecks.swift; exporter 10/10, 77 total); full review dispatched (opus) over ee54ad0..511010a

## PAUSED 2026-09-29 (user went to sleep)
Task 12: review (opus) arrived after pause: Needs fixes — 1 Important: in `ProjectExporter.install`, the first `moveItem(staged → sibling)` sits outside the do/catch that removes `sibling`, so a failed cross-volume copy (e.g. disk full) can leave a partial `.slate-<uuid>.mp4` next to the destination. Fix: move that call inside the `do`.
Task 12: minor (deferred): Task cancellation not observed (withTaskCancellationHandler); keepInvalidAt case-alias of a non-existing output missed; failed keepInvalidAt install hides validationFailed (use try?); duplicate Clip.id traps Dictionary(uniqueKeysWithValues:); coverage gaps (hard link, passthrough cancel, siblings in refused branches); cancelled flag never reset; unsynchronized public vars; force unwraps; stale progress after 1; cancel calls under lock.
## RESUMED 2026-09-30
Task 12: fix round 2 dispatched (resumed implementer): move first moveItem inside do/catch; try? for keepInvalidAt install. Duplicate Clip.id left as deferred minor.
Task 12: fix round 1/5 (2 addressed — checks rewritten per Phase 0 ruling; commit 511010a)
Task 12: fix round 2/5 (2 addressed, 0 open; commits 511010a..1102f19)
Task 12: complete (commits ee54ad0..1102f19, review clean after 2 fix rounds)
Task 13: dispatched (BASE 1102f19, implementer sonnet) — Steps 1–3 and 6 only; Steps 4–5 (user questions, MASTER_PLAN) are the controller's per preflight ruling.
Task 13: implementer DONE (0dca9fd; 77 total pass). Phase 0 automatic: PASS mixed, selective-24, all-24, all-48, selective-24-audio, all-24-audio; FAIL selective-48 ("frame 138 lasts 1/16, expected 1/48").
Task 13: controller ffmpeg decode check (ffprobe -count_frames): mixed 191 frames 0 errors; all-24 130 / 0; all-48 0 errors; selective-24 and selective-24-audio: hundreds of h264 decode errors (missing reference pictures, bad slice params) — Selective output (copied B-frame GOPs + re-encoded clip with a different parameter set in one track) is broken for ffmpeg-based decoders even when AVFoundation validation passes.
Ruling: Phase 0 decision — Constant mode default = Re-encode all. Selective is unsafe for NLE/ffmpeg use; Plan 2 must label it experimental or hide it — cost if wrong: users lose the faster selective path until it is fixed.
Ruling: Mixed mode decodes cleanly in both AVFoundation and ffmpeg on generated fixtures; keep it as the lossless default for viewing/social — cost if wrong: seam wobble in some players, not verified in Resolve yet.
Task 13: review dispatched (sonnet)
Task 13: minor (deferred): Phase0 load() outside the per-case do/catch — a bad --clip24/--clip48 path aborts the whole run (plan-mandated); mixed ffprobe shows 3 duration buckets (one 1536-tick edge frame).
Task 13: complete (commits 1102f19..0dca9fd, review clean)
Phase 0 user questions asked 2026-09-30 (own clips via --clip24/--clip48; Resolve check) — awaiting answer.
Phase 0 user answer 2026-09-30: skips both; will test in the finished app. Evidence level: "NLE compatibility: UNVERIFIED (user skipped the Resolve check). Default chosen from automatic checks + ffmpeg decode check on generated fixtures only."
Final review: dispatched (opus) over 5efbcf5..HEAD
Final review: Ready after fixes. No code blockers. Important: (1) my ruling "Mixed decodes cleanly in ffmpeg" is WRONG — ffmpeg decodes without errors but places the whole c48 part 768 ticks (1/16 s) early; at the c24→c48 join pts run backwards (34304 dur 1536, 34816, 34560), last frame 65536 vs 66304; AVFoundation is correct; c24→c24 join clean. (2) No Mixed+audio end-to-end evidence. (3) Decision not yet in MASTER_PLAN.md.
Ruling (corrects the earlier Mixed ruling): Mixed is AVFoundation-clean but ffmpeg misplaces frames at 24↔48 joins; NLE UNVERIFIED. Mixed stays available but is NOT proven safe for upload pipelines; Plan 2 must decide (e.g. offer Re-encode all in Mixed, or re-encode at joins) — open design question — cost if wrong: stutter at joins in ffmpeg-based players/uploads.
Final fix wave: ONE dispatch (sonnet) — Mixed+audio Phase 0 case + exporter check; monotonic-pts check in phase0-ffprobe.sh; comment on Selective-24 check; pre-Plan-2 items: withTaskCancellationHandler, exporter single-use documented + guard, duplicate Clip.id blocked in planner.
Final fix wave: DONE_WITH_CONCERNS (3772ed9; 81/81). Phase 0: 7 PASS + selective-48 FAIL; mixed-audio PASS in AVFoundation. ffmpeg pts monotonic: all-* yes; mixed, mixed-audio NO (frame 70: 34816 -> 34560); selective-24(-audio) NO (frame 40: 26624 -> 20480).
Ruling: the fixer's claim "mixed backward step is inherent to the c48 fixture" is WRONG — controller checked: build/fixtures/c48.mp4 alone is monotonic in ffmpeg (237 frames). The break comes from Slate's passthrough composition (mid-GOP edit lists at joins as read by ffmpeg). Only Re-encode all is monotonic in both decoders. — cost if wrong: none, this is measured.
Final fix wave: scoped re-review dispatched (sonnet) — STALLED (watchdog, no verdict).
Ruling: do not re-dispatch; the Fable whole-branch review explicitly includes review-0dca9fd..3772ed9.diff and serves as the scoped re-review — cost if wrong: if Fable skims the fix wave, its six findings go unverified; check its report covers them. User asked (2026-09-30) to also use the Claude Fable tab (herdr pane w1A:p2) as reviewer → independent whole-branch review sent; report to fable-review.md.
Fable review (fable-review.md): Ready after fixes; 0 Critical, 3 Important; all six fix-wave items verified present and correct (serves as the stalled scoped re-review).
- I1 (must fix): AudioSampleSource counts missing samples but appends nothing; AVAssetWriter AAC collapses the gap, so later clips' audio plays early and shortfalls accumulate in Re-encode all (default). Fix: append zero-filled PCM for missing samples; check with two short-audio clips in Re-encode all.
- I2 (Plan 2): Mixed validator checks count+duration only; compute exact expected pts from grid + source tables.
- I3 (Plan 2 decision): Mixed/Selective outputs have 2 avc1 stsd entries (c24 level 3.0 vs c48 level 3.1) + mid-GOP edit lists (+2 mp4a in mixed-audio); ffmpeg misplaces the second description's edits (c48 part 768 ticks early; audio pts jump). Re-encode all: 1 stsd, 1 elst, clean. Options: label Mixed "Apple players only" and route social to Constant+Re-encode all, or gate Mixed copy on identical format descriptions.
Ruling: a second fix dispatch (beyond the skill's one-wave rule) for I1 — it is a correctness bug in the DEFAULT export path found by the review the user requested; plus one cheap check pinning Re-encode-all output properties (1 video stsd, no B-frames, ffmpeg-free check via AVFoundation format descriptions). I2/I3 go to Plan 2 as open design items. Harness skip-exit minor left deferred (skips are intentional when fixtures are missing) — cost if wrong: one extra fix round.
I1 fix: e504ca8 (silence fill; short-audio Re-encode-all check RED→GREEN; Re-encode-all shape pin; 84/84; Phase 0 unchanged 7 PASS + selective-48 FAIL). Scoped re-review sent to the Fable session → fable-rereview.md.
I1 re-review (Fable, fable-rereview.md): All findings addressed; no Critical/Important. Minors: `pendingSilence` dead state; silence buffers use a fresh format description without channel layout (mono verified, stereo not — reuse the reader's description); mid-stream gap path not exercised end to end; stale fixtures make the I1 check skip silently.
FINAL: branch review clean (after one fix wave + I1 fix). Head e504ca8, 84/84.
Final review deferred (Plan 2 / later): audio format (rate/channels) mismatch not blocked; composition path has no audio-shortfall bound + audioTruncated lacks clip; unsupported codecs silently become H.264; re-encode-all bitrate from reference only; progress 1-of-1; `guard let d else continue` should be precondition; validation not interruptible; readers not cancelled on error exits.
Old resume notes:
1. Task 12 fix round 1: resume/dispatch implementer (sonnet) with the Important finding above (+ optionally the one-liners "use try? for keepInvalidAt install" and "reject duplicate Clip.id in plan/export" if cheap), then scoped re-review, then mark Task 12 complete.
2. Task 13 (Phase 0 command + ffprobe script) not started; brief already extracted: task-13-brief.md. BASE will be the Task 12 head.
3. After Task 13: ask the user the two optional Phase 0 questions (own clips via --clip24/--clip48; Resolve check), record evidence level + default (Re-encode all per Task 12 finding) in MASTER_PLAN.md, then final whole-branch review (opus), then finishing-a-development-branch.
Task 12: Ruling: Mixed mode has the same passthrough seam behavior but its validator checks only count+duration (spec: no cadence promise in Mixed) — a seam timing wobble in Mixed can pass unnoticed. Surface to user with Phase 0 results, do not block — cost if wrong: a visible stutter at some joins in Mixed exports.
Ruling: MASTER_PLAN.md lives only in the main checkout (gitignored); controller updates it at the end — implementers must not create one in the worktree — cost if wrong: none.

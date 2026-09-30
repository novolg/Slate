# Scoped re-review — I1 fix (3772ed9..e504ca8)

Reviewer: Claude Fable 5.1 (independent, read-only). Date: 2026-09-30.
Inputs: `review-3772ed9..e504ca8.diff`, `audio-gap-fix-report.md`, and the changed files at
HEAD e504ca8 (`Sources/SlateCore/ClipReencoder.swift`, `Sources/SlateChecks/ReencoderChecks.swift`,
`scripts/make-test-clips.sh`). Worktree is clean at e504ca8. No source or git state changed.
Suite not re-run (84/84 reported); the new fixture `build/fixtures/c24_short_a.mp4` is present
(video 5.000 s / 120 frames, audio 4.990 s), so the regression check runs rather than skips.

## Findings

### 1. I1 — audio gaps filled with silence: ADDRESSED

- `ClipReencoder.swift:310-323` — `AudioCoverage.accept` now returns `Accepted(gapBefore:, range:)`.
  `gapBefore = lo − wantFrom` is folded into `missing`, checked against the 1024 budget *before*
  `cursor` moves, and reported to the caller. `range == nil` implies `gapBefore == 0` (early return).
- `ClipReencoder.swift:329-337` — `finish()` returns the tail gap `count − cursor` (clamped ≥ 0),
  still throws `audioTruncated` past 1024. Unchanged budget.
- `ClipReencoder.swift:411-422, 427-436` — reader end / buffer past the piece end: silence covers
  exactly the tail `[outStart + count − gap, outStart + count)`. Position traced: `finish()` marks
  `[cursor, count)` missing and `gapStart = outStart + count − gap` is the same interval. Correct.
- `ClipReencoder.swift:438-449` — gap before a buffer: silence at
  `outStart + (lo − gapBefore − sourceStartSample)` = `outStart + (wantFrom − sourceStartSample)`,
  i.e. exactly where the missing source samples `[wantFrom, lo)` belong. The kept range is stashed
  in `pendingKept` and appended on the next call at `outStart + (lo − sourceStartSample)` — contiguous
  with the silence. Correct; no double accounting (`accept` is not re-run for the stashed buffer).
- `ClipReencoder.swift:478-522` — `appendSilence`: ASBD is Float32, packed, interleaved (flags
  `IsFloat|IsPacked`, no `NonInterleaved`), `bytesPerFrame = channels × 4`, `framesPerPacket = 1`,
  this piece's rate and channel count — the same layout the reader is asked for at `:530-538`
  (`AVLinearPCMBitDepthKey 32`, `IsFloat true`, `IsNonInterleaved false`, native endian). Block is
  allocated and explicitly zero-filled (`:506`); sample buffer has `count` samples, one timing entry
  of duration 1 tick at `rate`, one size entry of `bytesPerFrame` — the same timing convention as
  `appendKept` (`:462-466`). Correct.
- Emitted once per gap: each gap path either appends silence and `return true`s immediately, or
  stashes the kept buffer so the next call appends it without touching `coverage`. After
  `closePiece()` the coverage is gone, so `finish()` cannot run twice for one piece. Correct.
- Regression check `ReencoderChecks.swift:199-217` — two `c24_short_a` clips kept `(0, 5.0)`,
  Constant 24, Re-encode all, through `ProjectExporter`. Asserts export ok, first sample within one
  AAC packet of 0, and decoded audio end == `plan.totalDuration` within **one sample** via the raw
  PCM helper at `:22-55`. The fix report shows it failing before the fix (9.98 s vs 10.0 s, 882
  samples — under the validator's own 1024-sample slop, which confirms the original finding) and
  passing after. This is the right shape of evidence.

### 2. Re-encode-all output shape pinned: ADDRESSED

- `ReencoderChecks.swift:223-233` exports c24 + c48 with Re-encode all and calls
  `assertNoFrameReordering` (`:57-92`): exactly one video `formatDescription` (`:63`), and, reading
  passthrough samples, `dts == pts` for every sample (invalid dts treated as equal) plus strictly
  non-decreasing pts. That pins the single-`stsd` / no-B-frame / monotonic property. Correct and cheap.

## New breakage

None Critical or Important.

Minor:

- `ClipReencoder.swift:369, 393-397` — `pendingSilence` is declared and drained but never set. Every
  gap path appends silence immediately. Dead state; remove it or use it (harmless either way).
- `ClipReencoder.swift:478-500` — the silence buffer carries a freshly built format description
  (no channel layout), while decoded buffers carry the reader's description. The writer accepted the
  mix in the mono regression check; a stereo source is unverified. Robustness fix: cache
  `CMSampleBufferGetFormatDescription` from the piece's first decoded buffer (or build one in
  `open(_:)`) and reuse it for silence so every appended buffer shares one description.
- `ClipReencoder.swift:440-447` — the mid-stream `gapBefore` path (stash + flush) has unit coverage
  in `AudioCoverage` (`ReencoderChecks.swift:29-40`) but no end-to-end exercise; AVAssetReader LPCM
  output never produces a mid-stream gap on these fixtures. Acceptable as defensive code; note it.
- `scripts/make-test-clips.sh:22-28` — comment says "~4.99 s" and ffprobe agrees (4.990 s); fine.
  The fixture is only generated when the script is re-run; a stale `build/fixtures` from before this
  commit makes the I1 check *skip* (Harness exit 0 — the skip-exit-code minor from the main review
  still applies and now hides this specific check).

Cancel/cleanup: unchanged. `appendNext` still appends at most one buffer per call, the encode loop
still checks `isCancelled` every iteration, and silence buffers are transient. No regression.

## Verdict

**All findings addressed.**

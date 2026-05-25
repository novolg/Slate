# Engineering notes

## Keyframe model

H.264/H.265 streams are decoded forward from the previous I-frame. Cutting between keyframes leaves P/B frames whose references are missing — playback shows garbage until the next I-frame. Therefore a true zero-recoding cut is only valid at a sync sample (I-frame).

`AVAssetReader` exposes per-sample attachments. A sample is a sync sample iff `kCMSampleAttachmentKey_NotSync` is absent or `false`. Iterating the sample buffers and collecting `CMSampleBufferGetPresentationTimeStamp` for sync samples produces the keyframe index used for snapping cut points.

Cross-check command:

```sh
ffprobe -v error -select_streams v:0 -skip_frame nokey \
  -show_entries frame=pts_time -of csv=p=0 input.mp4
```

The `KeyframeScanner` output should match this within rounding (PTS time in `CMTime` rationals vs ffprobe's `Float64`).

## AVFoundation passthrough export

`AVAssetExportPresetPassthrough` preserves source codecs and copies sample data without decoding. Caveats:

- All segments must come from the same source asset (otherwise AVFoundation will re-encode for format unification).
- Boundaries that do not land on a sync sample may cause AVFoundation to silently re-encode the affected portion or fail outright. Pre-snap segment boundaries to keyframes in the editor model to avoid this.
- VFR and some H.265 variants have been reported to fall back to re-encoding. Verify by comparing `codec_name`, `profile`, `bit_rate`, and the first-byte sample size of the source vs the export with `ffprobe`.

## Bit-exactness verification

For a chosen segment `[A, B]` that lies exactly between two source keyframes, both of these should produce identical bytes:

```sh
ffmpeg -ss <A> -to <B> -i input.mp4 -c copy ref.mp4
ffmpeg -ss <A_in_export> -to <B_in_export> -i export.mp4 -c copy out.mp4
cmp ref.mp4 out.mp4
```

If `cmp` reports identity, the export is bit-exact. If not, re-run with `-bsf:v trace_headers` to inspect NAL unit differences.

## Activation policy quirk

A SwiftUI macOS app launched as a bare executable (no `.app` bundle) defaults to `NSApplicationActivationPolicy.prohibited` and will not show a window. Setting `.regular` in `App.init` is required for both bundle and non-bundle launches; `activate(ignoringOtherApps:)` brings it to the foreground on first launch.

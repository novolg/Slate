#!/usr/bin/env bash
# Dev-only: write ComfyUI-like test clips into build/fixtures (needs Homebrew ffmpeg).
# ComfyUI Video Helper Suite writes through ffmpeg/libx264, so these match its output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/fixtures"
mkdir -p "$OUT"

FF=(ffmpeg -loglevel error -y)
X264=(-c:v libx264 -pix_fmt yuv420p -crf 19)

# 24 fps, 5 s, with AAC audio (default GOP: one keyframe at the start).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=5 \
    "${X264[@]}" -c:a aac -b:a 128k -shortest "$OUT/c24_a.mp4"

# 48 fps stand-in for RIFE: motion-interpolated from the 24 fps clip.
"${FF[@]}" -i "$OUT/c24_a.mp4" -vf minterpolate=fps=48 "${X264[@]}" -c:a copy "$OUT/c48_a.mp4"

# Short-audio regression fixture (fable-review.md I1): 5 s video, ~4.99 s audio, no
# -shortest so the container keeps each stream's own natural length instead of trimming
# the video to match. Kept at (0, 5.0) — the clip's full length — this exercises the
# few-hundred-sample shortfall that Re-encode all must pad with silence rather than let
# AVAssetWriter's AAC input collapse into a timestamp gap.
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=4.99 \
    "${X264[@]}" -c:a aac -b:a 128k "$OUT/c24_short_a.mp4"

# Video-only versions.
"${FF[@]}" -i "$OUT/c24_a.mp4" -an -c:v copy "$OUT/c24.mp4"
"${FF[@]}" -i "$OUT/c48_a.mp4" -an -c:v copy "$OUT/c48.mp4"

# 23.976 fps at timescale 90000 (rounded tick durations).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24000/1001:duration=5 \
    "${X264[@]}" -video_track_timescale 90000 "$OUT/j23976.mp4"

# Different frame size (must be blocked when mixed with the others).
"${FF[@]}" -f lavfi -i testsrc2=size=320x180:rate=24:duration=2 "${X264[@]}" "$OUT/small24.mp4"

# Decoder-failure fixture: moov first, then cut the media data at 60 %.
"${FF[@]}" -i "$OUT/c48.mp4" -c copy -movflags +faststart "$OUT/c48_fs.mp4"
SIZE=$(stat -f%z "$OUT/c48_fs.mp4")
head -c $((SIZE * 6 / 10)) "$OUT/c48_fs.mp4" > "$OUT/c48_trunc.mp4"

echo "✓ fixtures in $OUT"

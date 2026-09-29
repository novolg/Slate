#!/usr/bin/env bash
# Dev-only: write ComfyUI-like test clips into build/fixtures (needs Homebrew ffmpeg).
# ComfyUI Video Helper Suite writes through ffmpeg/libx264, so these match its output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/fixtures"
mkdir -p "$OUT"

FF=(ffmpeg -loglevel error -y)
# -bf 0: no B-frames. Default libx264 B-frames give the first packets negative DTS,
# which forces an edit list (elst); AVFoundation's passthrough sample times then read
# in the pre-edit media timeline, so pts 0 is not the first displayed frame. CFR test
# fixtures need pts 0 == frame 0 with no edit-list offset.
X264=(-c:v libx264 -pix_fmt yuv420p -crf 19 -bf 0)

# 24 fps, 5 s, with AAC audio (default GOP: one keyframe at the start).
"${FF[@]}" -f lavfi -i testsrc2=size=640x360:rate=24:duration=5 \
    -f lavfi -i sine=frequency=440:sample_rate=44100:duration=5 \
    "${X264[@]}" -c:a aac -b:a 128k -shortest "$OUT/c24_a.mp4"

# 48 fps stand-in for RIFE: motion-interpolated from the 24 fps clip.
"${FF[@]}" -i "$OUT/c24_a.mp4" -vf minterpolate=fps=48 "${X264[@]}" -c:a copy "$OUT/c48_a.mp4"

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

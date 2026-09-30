#!/usr/bin/env bash
# Dev-only: independent frame-timing report for the Phase 0 files (needs Homebrew ffprobe).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$ROOT"/build/phase0/*.mp4; do
    echo "== $(basename "$f")"
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,r_frame_rate,avg_frame_rate,time_base,nb_frames \
        -of compact=p=0 "$f"
    echo "   frame durations (count × ticks):"
    ffprobe -v error -select_streams v:0 -show_entries frame=duration -of csv=p=0 "$f" \
        | sort | uniq -c | sed 's/^/     /'
    echo "   stream start / edit-list info:"
    ffprobe -v error -show_entries stream=index,codec_type,start_time,duration -of compact=p=0 "$f" \
        | sed 's/^/     /'
    # Per-frame video pts in presentation order, as ffmpeg decodes them. B-frames with
    # composition offsets (reordered output) show up here as a backward pts step.
    ffprobe -v error -select_streams v:0 -show_entries frame=pts -of csv=p=0 "$f" \
        | awk -F',' '
            NR == 1 { prev = $1; next }
            {
                if (!bad && ($1 + 0 < prev + 0)) { bad = 1; badn = NR; badprev = prev; badcur = $1 }
                prev = $1
            }
            END {
                if (bad) printf "   pts monotonic: NO (first backward step at frame %d: %s -> %s)\n", badn, badprev, badcur
                else print "   pts monotonic: yes"
            }'
done

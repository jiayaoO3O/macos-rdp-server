#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: run-agent-stream.sh <rdp-agent> <worker-socket> <display-index> <runtime-dir>" >&2
    exit 64
fi

agent=$1
socket=$2
display=$3
runtime=$4
generation_file="$runtime/agent-generation"
generation_tmp="$generation_file.$$"

case "$display" in
    ''|*[!0-9]*) echo "invalid display index: $display" >&2; exit 64 ;;
esac
test -x "$agent"
test -d "$runtime"

generation=0
if [ -r "$generation_file" ]; then
    IFS= read -r generation < "$generation_file" || true
    case "$generation" in
        ''|*[!0-9]*) generation=0 ;;
    esac
fi

# The worker is authoritative if it has accepted a newer generation than the
# local counter (for example, after a manual diagnostic run).
if [ -r "$runtime/worker.log" ]; then
    worker_generation=$(awk '
        match($0, /generation=[0-9]+/) {
            value = substr($0, RSTART + 11, RLENGTH - 11) + 0
            if (value > max) max = value
        }
        END { print max + 0 }
    ' "$runtime/worker.log")
    if [ "$worker_generation" -gt "$generation" ]; then
        generation=$worker_generation
    fi
fi

generation=$((generation + 1))
umask 077
printf '%s\n' "$generation" > "$generation_tmp"
mv -f "$generation_tmp" "$generation_file"
# Continuous ScreenCaptureKit capture removes the per-frame screenshot cost that
# caps the snapshot loop at the display's capture time (~35-45 ms -> ~22-25 fps).
# 60 fps target is what makes fast motion look smooth; the RDP worker only sends
# changed 64x64 tiles, so the wire cost stays proportional to what moves.
# Remove RDP_AGENT_CAPTURE_STREAM (or set 0) to fall back to the screenshot loop.
exec env RDP_AGENT_NO_PERMISSION_REQUEST=1 RDP_AGENT_DELTA_FRAMES=1 \
    RDP_AGENT_CAPTURE_STREAM=1 RDP_AGENT_TARGET_FPS=60 \
    RDP_AGENT_VIRTUAL_DISPLAY=1 \
    "$agent" stream-snapshot "$socket" "$display" 0 "$generation"
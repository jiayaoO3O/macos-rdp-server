#!/usr/bin/env python3
"""Smoke-test the saved Windows App device card without handling credentials."""

import argparse
import os
import platform
import re
import subprocess
import sys
import time


class Result:
    def __init__(self, passed, reason=""):
        self.passed = passed
        self.reason = reason


def evaluate_worker_log(text, minimum_tiles):
    """Require a codec negotiation event, a full raw/planar frame, and no logoff.

    NSCodec is a test-only path; production sessions normally log nscodec=0 and
    fall back to Planar/raw, so either value proves the codec negotiation ran.
    """
    if "event=authorized" not in text:
        return Result(False, "no authorized event")
    codec = re.search(r"event=peer_codecs nscodec=[01]\b", text)
    if not codec:
        return Result(False, "codec negotiation was not observed")

    auth_at = text.find("event=authorized")
    codec_at = codec.start()
    frames = re.findall(r"event=desktop_frame_sent\b[^\n]*", text)
    full_frame = None
    for frame in frames:
        frame_at = text.find(frame)
        tiles = re.search(r"\btiles=(\d+)", frame)
        batches = re.search(r"\bbatches=(\d+)", frame)
        if (frame_at > codec_at > auth_at and
                ("encoding=raw" in frame or "encoding=planar" in frame) and tiles and batches
                and int(tiles.group(1)) >= minimum_tiles
                and int(batches.group(1)) >= 1):
            full_frame = frame
            break
    if not full_frame:
        return Result(False, "no full desktop frame was observed")
    if "event=lease_released" in text or "ERRINFO_LOGOFF_BY_USER" in text:
        return Result(False, "session was released during the observation window")
    return Result(True)


def build_press_script(device_name):
    escaped = device_name.replace("\\", "\\\\").replace('"', '\\"')
    return f'''tell application "System Events"
  tell process "Windows App"
    set frontmost to true
    if (count of windows) is 0 then error "Windows App has no open window"
    set allElements to entire contents of window 1
    set foundCard to false
    repeat with elementRef in allElements
      try
        set elementName to name of elementRef as text
      on error
        set elementName to ""
      end try
      try
        set elementDescription to description of elementRef as text
      on error
        set elementDescription to ""
      end try
      if elementName contains "{escaped}" or elementDescription contains "{escaped}" then
        try
          perform action "AXPress" of elementRef
          set foundCard to true
          exit repeat
        end try
      end if
    end repeat
    if not foundCard then error "No pressable accessible element contains: {escaped}"
  end tell
end tell'''


def press_saved_device(device_name):
    script = build_press_script(device_name)
    return subprocess.run(["osascript", "-e", script], text=True, capture_output=True)


def windows_app_logs(seconds):
    command = [
        "log", "show", "--style", "compact", "--last", f"{seconds}s",
        "--predicate", 'process == "Windows App"',
    ]
    return subprocess.run(command, text=True, capture_output=True)


def summarize_unified_logs(text):
    categories = [
        ("Bitmap Decompression Failed", r"Bitmap Decompression Failed"),
        ("DecodeRLEBytes", r"DecodeRLEBytes"),
        ("PopulateCacCodecCaps", r"PopulateCacCodecCaps"),
        ("CoreData warning/error", r"CoreData|NSMergeConflict|failed saving to storage"),
    ]
    found = [label for label, pattern in categories if re.search(pattern, text, re.I)]
    return "\n".join(f"  {label}" for label in found) or "  no matching warnings/errors"


def summarize_worker_log(text):
    lines = text.splitlines()
    summary = [line for line in lines if "event=authorized" in line or "event=peer_codecs" in line]
    frames = [line for line in lines if "event=desktop_frame_sent" in line]
    if frames:
        summary.append(f"frames_sent={len(frames)} first={frames[0]}")
        if len(frames) > 1:
            summary.append(f"last={frames[-1]}")
    summary.extend(line for line in lines
                   if "event=lease_released" in line or "ERRINFO_LOGOFF_BY_USER" in line
                   or "STATE_RUN_FAILED" in line)
    return "\n".join(summary) or "  no matching Worker events"


def latest_authorized_offset(data):
    index = data.rfind(b"event=authorized")
    if index < 0:
        return None
    return data.rfind(b"\n", 0, index) + 1


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="rdp-live-diagnostic",
                        help="saved Windows App device card accessibility name")
    parser.add_argument("--worker-log", default=".runtime/worker.log")
    parser.add_argument("--existing-session", action="store_true",
                        help="observe the latest already-authorized session without pressing a device card")
    parser.add_argument("--duration", type=int, default=30,
                        help="seconds the session must remain active (default: 30)")
    parser.add_argument("--settle-seconds", type=int, default=3,
                        help="extra seconds to catch a disconnect at the observation boundary (default: 3)")
    parser.add_argument("--minimum-tiles", type=int, default=500,
                        help="minimum tiles and batches for a full frame (default: 500)")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if platform.system() != "Darwin":
        parser.error("this smoke test requires macOS")
    if args.duration < 1 or args.settle_seconds < 0 or args.minimum_tiles < 1:
        parser.error("duration and minimum-tiles must be positive; settle-seconds cannot be negative")
    started = time.time()
    try:
        if args.existing_session:
            with open(args.worker_log, "rb") as log:
                start_offset = latest_authorized_offset(log.read())
            if start_offset is None:
                print("FAIL: no authorized session found in Worker log", file=sys.stderr)
                return 2
            print(f"Observing latest authorized session for {args.duration}s without UI interaction.")
        else:
            with open(args.worker_log, "rb") as log:
                start_offset = os.fstat(log.fileno()).st_size
            pressed = press_saved_device(args.device)
            if pressed.returncode:
                print("FAIL: could not press saved device card. Check Windows App and Accessibility permission.",
                      file=sys.stderr)
                if pressed.stderr.strip():
                    print(pressed.stderr.strip(), file=sys.stderr)
                return 2
            print(f"Pressed saved device card '{args.device}'; observing session for {args.duration}s.")
    except OSError as error:
        print(f"FAIL: cannot read worker log {args.worker_log}: {error}", file=sys.stderr)
        return 2

    time.sleep(args.duration)
    if args.settle_seconds:
        time.sleep(args.settle_seconds)
    try:
        with open(args.worker_log, "rb") as log:
            log.seek(start_offset)
            worker_delta = log.read().decode("utf-8", errors="replace")
    except OSError as error:
        print(f"FAIL: cannot reread worker log: {error}", file=sys.stderr)
        return 2

    elapsed = max(1, int(time.time() - started) + 10)
    unified = windows_app_logs(elapsed)
    result = evaluate_worker_log(worker_delta, args.minimum_tiles)
    print("Worker log evidence:")
    print(summarize_worker_log(worker_delta))
    print("Windows App unified-log correlation:")
    if unified.returncode:
        print(f"  log show failed: {unified.stderr.strip()}")
    else:
        print(summarize_unified_logs(unified.stdout))

    if not result.passed:
        print(f"FAIL: {result.reason}", file=sys.stderr)
        return 1
    if unified.returncode:
        print("FAIL: could not correlate Windows App unified logs", file=sys.stderr)
        return 1
    print(f"PASS: authorized session remained active for at least {args.duration}s "
          f"(+{args.settle_seconds}s boundary check) and sent a full desktop frame.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

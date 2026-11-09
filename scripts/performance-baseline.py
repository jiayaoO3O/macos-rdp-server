#!/usr/bin/env python3
"""Measure existing Worker frame events without modifying the running service."""

import argparse
import json
import math
import os
import re
import sys
import time


def summarize(lines, seconds):
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError("observation window must be positive and finite")
    received, sent = set(), set()
    sizes, encodings = set(), set()
    sent_events = 0
    for line in lines:
        fields = dict(re.findall(r"(?:^|\s)([a-z_]+)=([^\s]+)", line))
        event = fields.get("event")
        if event not in ("agent_frame_received", "desktop_frame_sent"):
            continue
        generation, frame_id = fields.get("generation", ""), fields.get("frame_id", "")
        if not generation.isascii() or not generation.isdigit() or not frame_id.isascii() or not frame_id.isdigit():
            continue
        key = (int(generation), int(frame_id))
        if not all(key):
            continue
        if event == "agent_frame_received":
            received.add(key)
            width, height = fields.get("width", ""), fields.get("height", "")
            if width.isascii() and width.isdigit() and height.isascii() and height.isdigit():
                sizes.add(f"{width}x{height}")
        else:
            sent.add(key)
            sent_events += 1
            if fields.get("encoding") in ("raw", "planar"):
                encodings.add(fields["encoding"])
    return {"window_seconds": seconds, "received_unique_frames": len(received),
            "sent_unique_frames": len(sent), "sent_events": sent_events,
            "received_fps": len(received) / seconds, "sent_fps": len(sent) / seconds,
            "source_sizes": sorted(sizes), "encodings": sorted(encodings)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="active Worker log; observation starts at its current end")
    parser.add_argument("--seconds", type=float, default=30)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be positive and finite")
    try:
        with open(args.log, "rb") as log:
            log.seek(0, os.SEEK_END)
            identity = os.fstat(log.fileno())
            start = time.monotonic()
            lines, pending = [], b""
            while True:
                remaining = args.seconds - (time.monotonic() - start)
                if remaining <= 0:
                    break
                time.sleep(min(0.1, remaining))
                current = os.stat(args.log)
                if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino) or current.st_size < log.tell():
                    raise RuntimeError("Worker log was rotated or truncated during observation")
                pending += log.read()
                complete = pending.split(b"\n")
                pending = complete.pop()
                lines.extend(line.decode("utf-8", "replace") for line in complete
                             if b"event=agent_frame_received " in line or b"event=desktop_frame_sent " in line)
            result = summarize(lines, time.monotonic() - start)
    except (OSError, RuntimeError) as error:
        print(f"baseline failed: {error}", file=sys.stderr)
        return 1
    result["note"] = "Worker events only; not client-rendered FPS or end-to-end latency"
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

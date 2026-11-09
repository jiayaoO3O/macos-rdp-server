#!/usr/bin/env python3
"""Incremental-frame delivery correctness check (loopback).

Question this answers: when the agent sends a full frame and then a stream of
small incremental changes, does the client's framebuffer end up with exactly
the same pixels as if the final state had been delivered as one full frame?

Two probe sessions against the same isolated test worker/client:
  session A  fake agent sends frame 1 full, then N delta frames that change a
             few 64x64 tiles each (incremental delivery);
  session B  a fresh client connection receives the final pixel state as one
             full frame.

Both sessions run bin/rdp-probe -mode 9, which reports a framebuffer CRC-32.
PASS means the CRCs match: incremental delivery converged to the same client
framebuffer. This works unchanged against the current worker (planar always
full-frame) and against a worker that sends only dirty planar tiles.

This is a loopback protocol check, NOT Windows App / visual acceptance.
"""
import argparse
import importlib.util
import json
import random
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("benchmark_fps", ROOT / "scripts" / "benchmark-fps.py")
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)


def initial_pixels(width, height, seed):
    """Dense deterministic BGRA content (alpha byte fixed at 0)."""
    pixels = bytearray(random.Random(seed).randbytes(width * height * 4))
    pixels[3::4] = bytes(width * height)
    return pixels


def mutate_tiles(pixels, width, height, tiles, rng):
    """Change a 16x16 patch inside each given tile, returning the tiles to send."""
    for x, y, tile_width, tile_height in tiles:
        patch_x = x + min(8, max(0, tile_width - 1))
        patch_y = y + min(8, max(0, tile_height - 1))
        patch_width = min(16, tile_width - (patch_x - x))
        patch_height = min(16, tile_height - (patch_y - y))
        for row in range(patch_height):
            for column in range(patch_width):
                index = ((patch_y + row) * width + patch_x + column) * 4
                pixels[index:index + 4] = bytes((rng.randrange(256),
                                                 rng.randrange(256),
                                                 rng.randrange(256), 0))
    return tiles


def run_probe_blocking(probe_binary, port, width, height, seconds, password):
    command = [str(probe_binary), "-port", str(port), "-user", "alice",
               "-domain", "MACRDP", "-mode", "9",
               "-width", str(width), "-height", str(height)]
    return subprocess.run(
        command, input=password + "\n", text=True, capture_output=True,
        timeout=int(seconds) + 120,
        env=bench.clean_environment({"RDP_PROBE_BENCH_SECONDS": str(int(seconds))}))


def start_probe_async(probe_binary, port, width, height, seconds, password):
    command = [str(probe_binary), "-port", str(port), "-user", "alice",
               "-domain", "MACRDP", "-mode", "9",
               "-width", str(width), "-height", str(height)]
    probe = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=bench.clean_environment({"RDP_PROBE_BENCH_SECONDS": str(int(seconds))}))
    try:
        probe.stdin.write(password + "\n")
        probe.stdin.flush()
    except OSError as error:
        stdout, stderr = probe.communicate()
        raise bench.HarnessError("could not send the probe password: %s; stderr: %s"
                                 % (error, stderr[-1000:]))
    return probe


def finish_probe(probe, label, timeout=60):
    try:
        stdout, stderr = probe.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        probe.kill()
        stdout, stderr = probe.communicate()
        raise bench.HarnessError("%s probe did not finish in %d s; stderr: %s"
                                 % (label, timeout, stderr[-1000:]))
    if probe.returncode != 0:
        raise bench.HarnessError("%s probe failed rc=%d\nstdout: %s\nstderr: %s"
                                 % (label, probe.returncode, stdout[-1000:], stderr[-1000:]))
    return bench.parse_probe_bench(stdout)


def wait_activation(harness, probe, offset, timeout=25.0):
    """Wait for a probe's RDP activation, failing fast if the probe exits early."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if "event=peer_activate_complete" in harness.log_since(offset):
            return
        if probe.poll() is not None:
            stdout, stderr = probe.communicate()
            raise bench.HarnessError(
                "probe exited before RDP activation (rc=%d)\nstdout: %s\nstderr: %s\n"
                "worker log tail: %r"
                % (probe.returncode, stdout[-1000:], stderr[-1000:], harness.log_tail()))
        time.sleep(0.02)
    raise bench.HarnessError("timed out waiting for RDP activation; worker log tail: %r"
                             % harness.log_tail())


def parse_frame_stats(text):
    frames = bench.parse_frame_log(text)
    tiles = [frame["tiles"] for frame in frames if frame["tiles"] is not None]
    pdus = [frame["pdus"] for frame in frames if frame["pdus"] is not None]
    if not frames:
        return {"frames": 0, "mean_tiles_per_frame": None, "mean_pdus_per_frame": None}
    return {
        "frames": len(frames),
        "mean_tiles_per_frame": round(sum(tiles) / len(tiles), 2) if tiles else None,
        "mean_pdus_per_frame": round(sum(pdus) / len(pdus), 2) if pdus else None,
    }


def run_check(args):
    harness = bench.WorkerHarness(worker_binary=args.worker_binary,
                                  probe_binary=args.probe_binary,
                                  keep_temp=args.keep_temp)
    agent = None
    probe = None
    try:
        harness.start()
        width, height = args.width, args.height
        generation = 1
        tiles = bench.tile_grid(width, height)
        rng = random.Random(args.seed)
        pixels = initial_pixels(width, height, args.seed)

        agent = bench.FakeAgent(str(harness.agent_socket))
        agent.connect()

        # --- Session A: full frame, then incremental delta frames ------------
        frame_id = 1
        if not agent.send(bench.encode_full_frame_messages(pixels, width, height,
                                                           generation, frame_id)):
            raise bench.HarnessError("fake agent failed to send the session A initial frame")
        harness.wait_log("event=agent_frame_received", timeout=10.0)
        log_offset_a = harness.log_size()

        probe = start_probe_async(harness.probe_binary, harness.port, width, height,
                                  args.seconds, harness.password)
        wait_activation(harness, probe, log_offset_a)

        changed_per_frame = min(args.changed_tiles, len(tiles))
        for _step in range(args.incremental_frames):
            frame_id += 1
            changed = rng.sample(tiles, changed_per_frame)
            mutate_tiles(pixels, width, height, changed, rng)
            message = bench.encode_delta_frame_messages(pixels, width, height,
                                                        generation, frame_id, changed)
            if not agent.send(message):
                raise bench.HarnessError("fake agent failed to send incremental frame %d" % frame_id)
            time.sleep(args.frame_interval)
        # Wait until the worker says the final incremental frame went out.
        harness.wait_log("frame_id=%d batches=" % frame_id, offset=log_offset_a, timeout=10.0)
        final_frame_id = frame_id
        session_a = finish_probe(probe, "session A")
        probe = None
        window_a = harness.log_since(log_offset_a)
        harness.wait_log("event=peer_loop_ended", offset=log_offset_a, timeout=10.0)
        time.sleep(0.5)  # let the worker release the connection lease

        # --- Session B: same final pixels as one full frame, fresh client ----
        frame_id += 1
        if not agent.send(bench.encode_full_frame_messages(pixels, width, height,
                                                           generation, frame_id)):
            raise bench.HarnessError("fake agent failed to send the session B full frame")
        harness.wait_log("event=agent_frame_received generation=1 frame_id=%d" % frame_id,
                         offset=log_offset_a, timeout=10.0)
        log_offset_b = harness.log_size()
        completed_b = run_probe_blocking(harness.probe_binary, harness.port, width, height,
                                        args.seconds_full, harness.password)
        if completed_b.returncode != 0:
            raise bench.HarnessError(
                "session B probe failed rc=%d\nstdout: %s\nstderr: %s\nworker log tail: %r"
                % (completed_b.returncode, completed_b.stdout[-1000:],
                   completed_b.stderr[-1000:], harness.log_tail()))
        session_b = bench.parse_probe_bench(completed_b.stdout)
        window_b = harness.log_since(log_offset_b)

        crc_a = session_a["framebuffer_crc32"]
        crc_b = session_b["framebuffer_crc32"]
        stats_a = parse_frame_stats(window_a)
        stats_b = parse_frame_stats(window_b)
        passed = crc_a == crc_b
        checks = {
            "size": "%dx%d" % (width, height),
            "incremental_frames": args.incremental_frames,
            "changed_tiles_per_frame": changed_per_frame,
            "final_frame_id": final_frame_id,
            "session_a": {
                "seconds": session_a["seconds"],
                "framebuffer_crc32": crc_a,
                "bitmap_updates": session_a["bitmap_updates"],
                "bitmap_rectangles": session_a["bitmap_rectangles"],
                "worker_frames": stats_a["frames"],
                "mean_tiles_per_frame": stats_a["mean_tiles_per_frame"],
                "mean_pdus_per_frame": stats_a["mean_pdus_per_frame"],
            },
            "session_b": {
                "seconds": session_b["seconds"],
                "framebuffer_crc32": crc_b,
                "bitmap_updates": session_b["bitmap_updates"],
                "bitmap_rectangles": session_b["bitmap_rectangles"],
                "worker_frames": stats_b["frames"],
            },
            "worker_binary": str(harness.worker_binary),
            "worker_sha256": bench.file_sha256(harness.worker_binary),
            "scope": "loopback protocol check, not Windows App acceptance",
        }
        return passed, checks
    finally:
        if probe is not None:
            if probe.poll() is None:
                probe.kill()
                probe.communicate()
        if agent is not None:
            agent.close()
        harness.cleanup()
        if args.keep_temp and harness.directory is not None:
            sys.stderr.write("kept temp dir: %s\n" % harness.directory)


def report(passed, checks, args):
    print("Incremental frame convergence check")
    print("  scope: %s" % checks["scope"])
    print("  size: %s; session A: frame 1 full + %d incremental frames "
          "(%d of %d 64x64 tiles changed per frame)"
          % (checks["size"], checks["incremental_frames"],
             checks["changed_tiles_per_frame"], len(bench.tile_grid(args.width, args.height))))
    print("  worker: %s (sha256 %s)" % (checks["worker_binary"], checks["worker_sha256"][:16]))
    session_a = checks["session_a"]
    session_b = checks["session_b"]
    print("  session A (incremental): crc=%s frames=%s tiles/frame=%s pdus/frame=%s"
          % (session_a["framebuffer_crc32"], session_a["worker_frames"],
             session_a["mean_tiles_per_frame"], session_a["mean_pdus_per_frame"]))
    print("  session B (one full frame): crc=%s frames=%s"
          % (session_b["framebuffer_crc32"], session_b["worker_frames"]))
    total_tiles = len(bench.tile_grid(args.width, args.height))
    mean_tiles = session_a["mean_tiles_per_frame"]
    if mean_tiles is not None:
        if mean_tiles < total_tiles * 0.75:
            print("  note: worker delivered %.2f tiles/frame vs %d total tiles: incremental "
                  "dirty-tile delivery observed (task 1 optimisation active)" % (mean_tiles, total_tiles))
        else:
            print("  note: worker delivered %.2f tiles/frame vs %d total tiles: worker is "
                  "re-sending full frames (pre-optimisation behaviour)" % (mean_tiles, total_tiles))
    if passed:
        print("PASS: both sessions converged to the same client framebuffer CRC")
    else:
        print("FAIL: client framebuffer CRCs differ (%s vs %s)"
              % (session_a["framebuffer_crc32"], session_b["framebuffer_crc32"]))
    print("  (loopback check only; Windows App rendering still needs manual acceptance)")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Loopback correctness check: incremental frame delivery must converge to "
                    "the same client framebuffer as one full frame. Works before and after "
                    "the worker dirty-tile optimization; not Windows App acceptance.")
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=256)
    parser.add_argument("--incremental-frames", type=int, default=6)
    parser.add_argument("--changed-tiles", type=int, default=3,
                        help="64x64 tiles changed per incremental frame (default 3)")
    parser.add_argument("--frame-interval", type=float, default=0.1,
                        help="seconds between incremental frames (default 0.1)")
    parser.add_argument("--seconds", type=int, default=4,
                        help="session A probe bench window (default 4)")
    parser.add_argument("--seconds-full", type=int, default=3,
                        help="session B probe bench window (default 3)")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--worker-binary", default=str(bench.DEFAULT_WORKER_BINARY))
    parser.add_argument("--probe-binary", default=str(bench.DEFAULT_PROBE_BINARY))
    parser.add_argument("--json", default=None, help="write the check result JSON to this path")
    parser.add_argument("--keep-temp", action="store_true")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 1 <= args.width <= 16384 or not 1 <= args.height <= 16384:
        parser.error("--width/--height must be within 1..16384")
    if args.incremental_frames < 1:
        parser.error("--incremental-frames must be >= 1")
    if args.changed_tiles < 1:
        parser.error("--changed-tiles must be >= 1")
    if not 1 <= args.seconds <= 120 or not 1 <= args.seconds_full <= 120:
        parser.error("--seconds/--seconds-full must be within 1..120")
    try:
        passed, checks = run_check(args)
    except bench.HarnessError as error:
        sys.stderr.write("verify-incremental-frames: harness failure: %s\n" % error)
        return 2
    except KeyboardInterrupt:
        sys.stderr.write("verify-incremental-frames: interrupted\n")
        return 130
    checks["passed"] = passed
    report(passed, checks, args)
    if args.json:
        Path(args.json).write_text(json.dumps(checks, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Real-pipeline loopback benchmark: test worker + REAL ScreenCaptureKit agent + client.

The worker-only benchmark (scripts/benchmark-fps.py) uses a scripted fake agent,
so it cannot see the capture-stage cost that limits frame rate on this machine.
This harness measures the real pipeline on loopback:

  * an isolated test worker (private temp dir, random 127.0.0.1 port,
    self-signed certificate, throwaway SAM) started like scripts/test-protocol.py;
  * the real signed capture agent, run as
    "rdp-agent stream-snapshot <temp sock> 0 0 <generation>"
    with RDP_AGENT_NO_PERMISSION_REQUEST=1 and RDP_AGENT_DELTA_FRAMES=1;
  * a visible 1024x768 animated window (scripts/motion-window.swift, compiled
    on demand into the private temp dir) so ScreenCaptureKit actually sees
    changing pixels;
  * bin/rdp-probe -mode 9 as the real FreeRDP client.

Reported numbers (all over the probe's own bench window):
  agent_fps_produced     worker "event=agent_frame_received" count / window
  worker_fps_delivered   worker "event=desktop_frame_sent" count / window
  agent_*_ms_mean        snapshot_timing capture / conversion / ipc / loop means
  tiles_per_frame, pdus_per_frame, bytes_per_frame, worker Mbit/s
  client PDU/s, client Mbit/s, client framebuffer CRC-32

This is a loopback link/pipeline benchmark, NOT Windows App rendered-FPS or
visual acceptance. It runs its own worker + agent and never touches the live
service's .runtime state or port 3389. The live capture agent (if running keeps
capturing the same display, including the motion window) is extra background
load and is recorded in the environment note.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("benchmark_fps", ROOT / "scripts" / "benchmark-fps.py")
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)

DEFAULT_AGENT_BINARY = ROOT / "bin" / "RDPAgent.app" / "Contents" / "MacOS" / "rdp-agent"
DEFAULT_MOTION_SOURCE = ROOT / "scripts" / "motion-window.swift"

# The capture agent evolved: older builds logged
#   event=snapshot_timing samples=30 width=W height=H capture_ms=X conversion_ms=Y ipc_ms=Z
# while newer builds append source/requested_width/requested_height/image_*/target_fps/loop_ms.
# Match the stable prefix, then parse the optional key=value tail.
SNAPSHOT_TIMING_PATTERN = re.compile(
    r"event=snapshot_timing samples=(\d+) width=(\d+) height=(\d+) "
    r"capture_ms=([\d.]+) conversion_ms=([\d.]+) ipc_ms=([\d.]+)(?P<rest>[^\n]*)")
AGENT_FRAME_PATTERN = re.compile(
    r"event=agent_frame_received generation=\d+ frame_id=\d+ width=(\d+) height=(\d+)")


# ---------------------------------------------------------------------------
# Pure helpers (unit-tested by scripts/test-benchmark-fps.py)
# ---------------------------------------------------------------------------

def parse_snapshot_timings(text):
    """Parse the agent's event=snapshot_timing summary lines (old and new format)."""
    timings = []
    for match in SNAPSHOT_TIMING_PATTERN.finditer(text):
        record = {
            "samples": int(match.group(1)),
            "width": int(match.group(2)),
            "height": int(match.group(3)),
            "capture_ms": float(match.group(4)),
            "conversion_ms": float(match.group(5)),
            "ipc_ms": float(match.group(6)),
        }
        for token in match.group("rest").split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            try:
                if key in ("loop_ms",):
                    record[key] = float(value)
                elif key in ("requested_width", "requested_height", "image_width",
                             "image_height", "target_fps"):
                    record[key] = int(value)
                elif key in ("source", "convert"):
                    record[key] = value
            except ValueError:
                continue
        timings.append(record)
    return timings


def mean_field(records, field):
    values = [record[field] for record in records if record.get(field) is not None]
    if not values:
        return None
    return round(sum(values) / float(len(values)), 3)


def agent_source_sizes(worker_text):
    """Distinct agent capture sizes seen in the window ("WxH", in first-seen order)."""
    sizes = []
    for match in AGENT_FRAME_PATTERN.finditer(worker_text):
        size = "%sx%s" % (match.group(1), match.group(2))
        if size not in sizes:
            sizes.append(size)
    return sizes


def motion_seconds_for(window_seconds):
    """Window lifetime budget: client window plus agent startup/settle margin."""
    return max(int(window_seconds) + 12, 15)


def parse_agent_env(overrides):
    """Agent environment: the required benchmark settings plus optional KEY=VALUE overrides."""
    env = {
        "RDP_AGENT_NO_PERMISSION_REQUEST": "1",
        "RDP_AGENT_DELTA_FRAMES": "1",
    }
    for entry in overrides or []:
        if "=" not in entry:
            raise bench.HarnessError("--agent-env expects KEY=VALUE, got %r" % entry)
        key, value = entry.split("=", 1)
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise bench.HarnessError("--agent-env has an invalid variable name: %r" % key)
        env[key] = value
    return env


def build_live_summary(probe, frames, worker_text, agent_text, width, height):
    """Combine probe statistics, worker frame lines and agent timing lines."""
    result = bench.summarize(probe, frames, "live-agent", width, height)
    window = probe["seconds"]
    agent_frames = worker_text.count("event=agent_frame_received")
    timings = parse_snapshot_timings(agent_text)
    result.update({
        "agent_frames_received": agent_frames,
        "agent_fps_produced": round(agent_frames / window, 3),
        "worker_fps_delivered": result["sent_fps"],
        "agent_source_sizes": agent_source_sizes(worker_text),
        "agent_timing_lines": len(timings),
        "agent_timing_samples": sum(timing["samples"] for timing in timings),
        "agent_capture_ms_mean": mean_field(timings, "capture_ms"),
        "agent_conversion_ms_mean": mean_field(timings, "conversion_ms"),
        "agent_ipc_ms_mean": mean_field(timings, "ipc_ms"),
        "agent_loop_ms_mean": mean_field(timings, "loop_ms"),
        "agent_target_fps": timings[-1].get("target_fps") if timings else None,
        "agent_conversion_strategies": sorted({
            timing["convert"] for timing in timings if "convert" in timing}),
        "agent_timing_note": "snapshot_timing lines are per-30-iteration means; the harness "
                            "waits for one warm-up flush before opening the client window so "
                            "the reported means cover the measured window",
    })
    return result


def live_environment_note(live_agent_preexisting):
    """Background conditions and scope of this real-pipeline measurement."""
    parts = [
        "real-pipeline loopback benchmark: isolated test worker + real ScreenCaptureKit "
        "capture agent + on-screen 1024x768 motion window + bin/rdp-probe -mode 9; "
        "NOT Windows App / rendered-FPS acceptance",
    ]
    try:
        load = os.getloadavg()
        parts.append("loadavg=%.2f/%.2f/%.2f" % load)
    except OSError:
        pass
    if live_agent_preexisting:
        parts.append("live service capture agent was already running and also captures this "
                     "display (including the motion window), adding capture/CPU load")
    else:
        parts.append("no pre-existing live capture agent detected")
    parts.append("absolute values include real capture/conversion cost and are not "
                 "comparable to the fake-agent worker-only benchmark")
    return "; ".join(parts)


def collect_warnings(result, motion_alive_through_probe, width, height, agent_timing_warm=True):
    warnings = []
    if not agent_timing_warm:
        warnings.append("agent timing did not flush before the client window; "
                        "agent_*_ms means may be unavailable or partial")
    if not motion_alive_through_probe:
        warnings.append("motion window exited before the client window ended; later frames "
                        "may have captured a static screen")
    sizes = result["agent_source_sizes"]
    if len(sizes) > 1:
        warnings.append("agent capture size changed during the window (resize path): %s"
                        % ", ".join(sizes))
    elif sizes and sizes[0] != "%dx%d" % (width, height):
        warnings.append("agent captured at %s while the client requested %dx%d; the worker "
                        "rescaled every frame (extra cost)" % (sizes[0], width, height))
    if result["agent_timing_lines"] == 0:
        warnings.append("no event=snapshot_timing lines in the window; agent timing unavailable")
    if not sizes:
        warnings.append("no event=agent_frame_received lines in the window")
    if result["sent_fps"] < result["agent_fps_produced"] * 0.25:
        warnings.append("worker delivered far fewer frames than the agent produced; the client "
                        "or worker is the limiter for this run")
    return warnings


# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

def file_size(path):
    try:
        return path.stat().st_size
    except OSError:
        return 0


def read_since(path, offset):
    return read_range(path, offset, None)


def read_range(path, start, end):
    try:
        with open(path, "rb") as handle:
            handle.seek(start)
            data = handle.read() if end is None else handle.read(max(0, end - start))
        return data.decode("utf-8", "replace")
    except OSError:
        return ""


def compile_motion(source, output, swiftc="swiftc"):
    """Compile the on-demand motion generator into the private temp dir."""
    source = Path(source)
    if not source.is_file():
        raise bench.HarnessError("motion source not found: %s" % source)
    compiler = shutil.which(swiftc) or (swiftc if Path(swiftc).is_file() else None)
    if not compiler:
        raise bench.HarnessError("swiftc not found; install Xcode command line tools")
    try:
        completed = subprocess.run([compiler, str(source), "-o", str(output)],
                                   capture_output=True, text=True, timeout=240)
    except subprocess.TimeoutExpired:
        raise bench.HarnessError("swiftc timed out compiling %s" % source)
    if completed.returncode != 0:
        raise bench.HarnessError("failed to compile %s:\n%s"
                                 % (source, completed.stderr[-2000:]))
    Path(output).chmod(0o755)
    return Path(output)


class MotionWindow:
    """Visible animated window that ScreenCaptureKit can see."""

    def __init__(self, binary, seconds, log_path):
        self.binary = Path(binary)
        self.seconds = seconds
        self.log_path = Path(log_path)
        self.process = None
        self._handle = None
        self.started_at = None

    def start(self):
        self._handle = open(self.log_path, "w+")
        self.process = subprocess.Popen(
            [str(self.binary)], stdout=self._handle, stderr=self._handle,
            env=bench.clean_environment({"MOTION_SECONDS": str(self.seconds)}))
        self.started_at = time.monotonic()

    def wait_ready(self, timeout=20.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise bench.HarnessError(
                    "motion window exited before becoming ready (rc=%d); log: %r"
                    % (self.process.returncode, read_since(self.log_path, 0)[-1000:]))
            if "motion_ready" in read_since(self.log_path, 0):
                return
            time.sleep(0.02)
        raise bench.HarnessError("motion window did not become ready within %d s" % timeout)

    def alive(self):
        return self.process is not None and self.process.poll() is None

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process = None
        if self._handle is not None:
            self._handle.close()
            self._handle = None


def start_capture_agent(agent_binary, socket_path, generation, log_path, agent_env):
    handle = open(log_path, "w+")
    process = subprocess.Popen(
        [str(agent_binary), "stream-snapshot", str(socket_path), "0", "0", str(generation)],
        stdout=handle, stderr=handle,
        env=bench.clean_environment(agent_env))
    return process, handle


def wait_for_agent_frames(harness, agent_process, agent_log_path, timeout=40.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if "event=agent_frame_received" in harness.log_text():
            return
        agent_log = read_since(agent_log_path, 0)
        if "Screen Recording permission is missing" in agent_log:
            raise bench.HarnessError(
                "the capture agent lacks macOS Screen Recording permission (TCC); grant it "
                "to bin/RDPAgent.app and retry. Agent log: %r" % agent_log[-1000:])
        if agent_process.poll() is not None:
            raise bench.HarnessError(
                "capture agent exited before sending frames (rc=%d); worker log tail: %r; "
                "agent log: %r"
                % (agent_process.returncode, harness.log_tail(), agent_log[-2000:]))
        time.sleep(0.05)
    raise bench.HarnessError(
        "timed out waiting for the capture agent to send a frame; worker log tail: %r; "
        "agent log: %r"
        % (harness.log_tail(), read_since(agent_log_path, 0)[-2000:]))


def wait_for_agent_warmup(agent_log_path, timeout=25.0):
    """Wait for the agent's first 30-iteration timing flush (timing windows align after it)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if "event=snapshot_timing" in read_since(agent_log_path, 0):
            return True
        time.sleep(0.05)
    return False


def stop_process(process, timeout=5.0):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def live_agent_preexisting():
    try:
        completed = subprocess.run(["pgrep", "-f", "rdp-agent stream"], capture_output=True, text=True)
        return bool(completed.stdout.strip())
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def resolve_motion(args, harness):
    if args.motion_binary:
        binary = Path(args.motion_binary)
        if not binary.is_file():
            raise bench.HarnessError("motion binary not found: %s" % binary)
        return binary, None
    source = Path(args.motion_source) if args.motion_source else DEFAULT_MOTION_SOURCE
    binary = compile_motion(source, harness.directory / "motion-window", args.swiftc)
    return binary, source


def run_live_benchmark(args):
    harness = bench.WorkerHarness(worker_binary=args.worker_binary,
                                  probe_binary=args.probe_binary,
                                  keep_temp=args.keep_temp)
    motion = None
    agent_process = None
    agent_handle = None
    live_result = None
    preexisting = live_agent_preexisting()
    loadavg_start = os.getloadavg() if hasattr(os, "getloadavg") else None
    try:
        harness.start()
        motion_binary, motion_source = resolve_motion(args, harness)
        motion_seconds = args.motion_seconds or motion_seconds_for(args.seconds)
        motion = MotionWindow(motion_binary, motion_seconds, harness.directory / "motion.log")
        motion.start()
        motion.wait_ready()
        time.sleep(0.5)  # let the first window frames reach the display

        generation = args.generation or int(time.time())
        agent_env = parse_agent_env(args.agent_env)
        agent_log_path = harness.directory / "agent.log"
        agent_process, agent_handle = start_capture_agent(
            args.agent_binary, harness.agent_socket, generation, agent_log_path, agent_env)
        wait_for_agent_frames(harness, agent_process, agent_log_path)
        agent_timing_warm = wait_for_agent_warmup(agent_log_path)
        if args.settle_seconds:
            time.sleep(args.settle_seconds)

        worker_offset = harness.log_size()
        agent_offset = file_size(agent_log_path)
        probe = bench.run_probe(harness.probe_binary, harness.port, args.width,
                                args.height, args.seconds, harness.password)
        motion_alive_through_probe = motion.alive()
        time.sleep(0.1)  # let the peer teardown flush
        worker_end_offset = harness.log_size()
        agent_end_offset = file_size(agent_log_path)
        if probe.returncode != 0:
            raise bench.HarnessError(
                "probe failed rc=%d\nstdout: %s\nstderr: %s\nworker log tail: %r"
                % (probe.returncode, probe.stdout[-2000:], probe.stderr[-2000:],
                   harness.log_tail()))
        worker_window = read_range(harness.log_path, worker_offset, worker_end_offset)
        agent_window = read_range(agent_log_path, agent_offset, agent_end_offset)
        probe_stats = bench.parse_probe_bench(probe.stdout)
        frames = bench.parse_frame_log(worker_window)
        result = build_live_summary(probe_stats, frames, worker_window, agent_window,
                                    args.width, args.height)
        result.update({
            "agent_binary": str(args.agent_binary),
            "agent_sha256": bench.file_sha256(args.agent_binary),
            "agent_generation": generation,
            "agent_env": agent_env,
            "worker_binary": str(harness.worker_binary),
            "worker_sha256": bench.file_sha256(harness.worker_binary),
            "probe_binary": str(harness.probe_binary),
            "probe_sha256": bench.file_sha256(harness.probe_binary),
            "motion": {
                "binary": str(motion_binary),
                "source": str(motion_source) if motion_source else None,
                "source_sha256": (bench.file_sha256(motion_source) if motion_source else None),
                "seconds": motion_seconds,
                "window_title": "RDP motion probe",
                "alive_through_probe": motion_alive_through_probe,
            },
            "settle_seconds": args.settle_seconds,
            "agent_timing_warmed_up": agent_timing_warm,
            "log_windows": {
                "worker_offset": worker_offset,
                "worker_end_offset": worker_end_offset,
                "worker_bytes_read": len(worker_window),
                "agent_offset": agent_offset,
                "agent_end_offset": agent_end_offset,
                "agent_bytes_read": len(agent_window),
            },
            "environment_note": live_environment_note(preexisting),
            "loadavg_start": (round(loadavg_start[0], 2), round(loadavg_start[1], 2),
                              round(loadavg_start[2], 2)) if loadavg_start else None,
            "loadavg_end": (round(os.getloadavg()[0], 2), round(os.getloadavg()[1], 2),
                            round(os.getloadavg()[2], 2)) if hasattr(os, "getloadavg") else None,
            "warnings": collect_warnings(result, motion_alive_through_probe,
                                         args.width, args.height, agent_timing_warm),
        })
        live_result = result
        return result
    finally:
        if agent_process is not None and agent_process.poll() is None:
            stop_process(agent_process)
        if agent_handle is not None:
            agent_handle.close()
        if motion is not None:
            motion.stop()
        harness.cleanup()
        if args.keep_temp and harness.directory is not None:
            sys.stderr.write("kept temp dir: %s\n" % harness.directory)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="Real-pipeline loopback RDP benchmark: isolated test worker + real "
                    "ScreenCaptureKit capture agent + on-screen motion + bin/rdp-probe "
                    "-mode 9. Loopback measurement only; not Windows App acceptance.")
    parser.add_argument("--width", type=int, default=2940,
                        help="client-requested desktop width (default 2940, live display size)")
    parser.add_argument("--height", type=int, default=1912,
                        help="client-requested desktop height (default 1912, live display size)")
    parser.add_argument("--seconds", type=float, default=12.0,
                        help="client bench window in seconds (1..120, default 12)")
    parser.add_argument("--motion-seconds", type=float, default=0.0,
                        help="motion window lifetime; 0 = auto (seconds + 12)")
    parser.add_argument("--settle-seconds", type=float, default=1.5,
                        help="wait after the first agent frame before the client window (default 1.5)")
    parser.add_argument("--generation", type=int, default=0,
                        help="agent generation value; 0 = current epoch seconds")
    parser.add_argument("--worker-binary", default=str(bench.DEFAULT_WORKER_BINARY))
    parser.add_argument("--probe-binary", default=str(bench.DEFAULT_PROBE_BINARY))
    parser.add_argument("--agent-binary", default=str(DEFAULT_AGENT_BINARY))
    parser.add_argument("--motion-source", default=str(DEFAULT_MOTION_SOURCE))
    parser.add_argument("--motion-binary", default=None,
                        help="use a precompiled motion generator instead of compiling the source")
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--agent-env", action="append", default=[], metavar="KEY=VALUE",
                        help="extra environment variable for the capture agent (repeatable), "
                             "e.g. RDP_AGENT_CAPTURE_STREAM=1 or RDP_AGENT_TARGET_FPS=60")
    parser.add_argument("--json", default=None, help="write the JSON summary to this path")
    parser.add_argument("--keep-temp", action="store_true")
    return parser


def validate_arguments(parser, args):
    if not 1 <= args.seconds <= 120:
        parser.error("--seconds must be within 1..120")
    if args.motion_seconds < 0 or args.motion_seconds > 600:
        parser.error("--motion-seconds must be within 0..600")
    if args.settle_seconds < 0 or args.settle_seconds > 60:
        parser.error("--settle-seconds must be within 0..60")
    if not 1 <= args.width <= 16384 or not 1 <= args.height <= 16384:
        parser.error("--width/--height must be within 1..16384")
    if not Path(args.agent_binary).is_file():
        parser.error("--agent-binary not found: %s (run make agent-build/agent-app)" % args.agent_binary)
    try:
        parse_agent_env(args.agent_env)
    except bench.HarnessError as error:
        parser.error(str(error))
    if args.json:
        parent = Path(args.json).expanduser().resolve().parent
        if not parent.is_dir():
            parser.error("--json parent directory does not exist: %s" % parent)


def report(result):
    sys.stderr.write(
        "benchmark-live-agent: size=%s sent_fps=%.2f agent_fps=%.2f "
        "capture_ms=%s conversion_ms=%s ipc_ms=%s tiles/frame=%.1f pdus/frame=%.1f "
        "worker_mbit/s=%.1f client_pdu/s=%.1f crc=%s\n"
        % (result["desktop_size"], result["worker_fps_delivered"],
           result["agent_fps_produced"], result["agent_capture_ms_mean"],
           result["agent_conversion_ms_mean"], result["agent_ipc_ms_mean"],
           result["tiles_per_frame"], result["pdus_per_frame"],
           result["worker_mbit_per_s"], result["client_pdu_per_s"],
           result["client_framebuffer_crc32"]))


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_arguments(parser, args)
    try:
        result = run_live_benchmark(args)
    except bench.HarnessError as error:
        sys.stderr.write("benchmark-live-agent: harness failure: %s\n" % error)
        return 1
    except KeyboardInterrupt:
        sys.stderr.write("benchmark-live-agent: interrupted\n")
        return 130
    output = json.dumps(result, indent=2)
    print(output)
    if args.json:
        Path(args.json).write_text(output + "\n")
    report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Repeatable loopback frame-rate benchmark for the macOS RDP worker.

Why this exists: the Windows App client cannot be automated on this machine
(macOS TCC), so rendered frame rate cannot be measured from a script. This
harness measures the *server side of the link* on loopback instead:

  * an isolated test worker (private temp dir, random 127.0.0.1 port,
    self-signed certificate, throwaway SAM) started exactly like
    scripts/test-protocol.py starts one;
  * a scripted fake capture agent speaking the existing private Unix-socket
    IPC wire format (magic "RDPA", big-endian version 1);
  * bin/rdp-probe in benchmark mode (-mode 9, RDP_PROBE_BENCH_SECONDS) as the
    real FreeRDP client, which counts received bitmap PDUs/rectangles/bytes
    and reports a framebuffer CRC-32.

The worker's own "event=desktop_frame_sent ..." lines provide the per-frame
tiles / PDUs / bytes picture; the probe provides the client-side view.

Scenarios:
  small   one full frame, then every frame changes --changed-tiles 64x64 tiles
  full    one full frame, then every frame changes every 64x64 tile
  static  one full frame only (measures the idle/one-shot case)

Content model: synthetic sparse tiles (a few random colour bytes per 64x64
tile on a zero background). It is deterministic for a given --seed, keeps the
plane count/content stable between runs, and reproduces the reference numbers
from the 2026-11-07 hand-off run. Absolute Mbit/s therefore is NOT comparable
to a real desktop capture (real screenshot content compresses differently);
compare before/after numbers produced by this same harness.

This is a loopback link benchmark, not Windows App / rendered-FPS acceptance.
Never touches .runtime/ and never listens on port 3389.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKER_BINARY = ROOT / "bin" / "rdp-worker"
DEFAULT_PROBE_BINARY = ROOT / "bin" / "rdp-probe"
OPENSSL = Path("/opt/homebrew/opt/openssl@3/bin/openssl")

# --- Agent IPC wire format (kept in sync with scripts/test-protocol.py) ------
MAGIC = b"RDPA"
IPC_VERSION = 1
MSG_FRAME_BEGIN = 2       # >QQIIB generation, frame_id, width, height, bpp
MSG_FRAME_CHUNK = 7       # >QQI  generation, frame_id, offset + pixel bytes
MSG_CAPTURE_SIZE = 9      # >II   width, height (worker -> agent)
MSG_DELTA_BEGIN = 10      # >QQIIBI generation, frame_id, width, height, bpp, tiles
MSG_DELTA_TILE = 11       # >QQIIHH generation, frame_id, x, y, width, height + pixels
MSG_DELTA_END = 12        # >QQI  generation, frame_id, tiles
IPC_HEADER_BYTES = 12
FRAME_CHUNK_MAX = 65516   # worker rejects payloads > 64 KiB
BPP = 4
TILE = 64

FRAME_LOG_PATTERN = re.compile(
    r"event=desktop_frame_sent generation=(\d+) frame_id=(\d+) "
    r"batches=(\d+) tiles=(\d+) bytes=(\d+) pdus=(\d+) encoding=(\w+)")
LEGACY_FRAME_LOG_PATTERN = re.compile(
    r"event=desktop_frame_sent generation=(\d+) frame_id=(\d+) "
    r"batches=(\d+) tiles=(\d+) encoding=(\w+)")


class HarnessError(RuntimeError):
    """The benchmark could not produce a trustworthy measurement."""


# ---------------------------------------------------------------------------
# Pure helpers (unit-tested by scripts/test-benchmark-fps.py)
# ---------------------------------------------------------------------------

def ipc_message(message_type, payload):
    """Encode one agent IPC message (12-byte header + payload)."""
    payload = bytes(payload)
    if len(payload) > 0xFFFFFFFF:
        raise HarnessError("agent IPC payload too large")
    return MAGIC + struct.pack(">HHI", IPC_VERSION, message_type, len(payload)) + payload


def tile_grid(width, height, tile=TILE):
    """Return (x, y, width, height) for every 64x64 tile, clipped at the edges."""
    if width < 1 or height < 1:
        raise HarnessError("desktop size must be positive")
    tiles = []
    for y in range(0, height, tile):
        for x in range(0, width, tile):
            tiles.append((x, y, min(tile, width - x), min(tile, height - y)))
    return tiles


def tile_pixels(frame, width, x, y, tile_width, tile_height):
    """Copy one tile out of a BGRA frame buffer (bytes)."""
    out = bytearray()
    for row in range(tile_height):
        start = ((y + row) * width + x) * 4
        out += frame[start:start + tile_width * 4]
    return bytes(out)


def encode_full_frame_messages(pixels, width, height, generation, frame_id):
    """Encode one full-frame IPC upload (type 2 begin + type 7 chunks)."""
    expected = width * height * BPP
    if len(pixels) != expected:
        raise HarnessError("full frame buffer is %d bytes, expected %d" % (len(pixels), expected))
    buffer = memoryview(bytes(pixels))
    parts = [ipc_message(MSG_FRAME_BEGIN,
                         struct.pack(">QQIIB", generation, frame_id, width, height, BPP))]
    for offset in range(0, expected, FRAME_CHUNK_MAX):
        chunk = buffer[offset:offset + FRAME_CHUNK_MAX]
        parts.append(ipc_message(MSG_FRAME_CHUNK,
                                 struct.pack(">QQI", generation, frame_id, offset) + chunk))
    return b"".join(parts)


def encode_delta_frame_messages(frame, width, height, generation, frame_id, tiles):
    """Encode one delta-frame IPC upload (type 10 begin + type 11 tiles + type 12 end)."""
    if not tiles:
        raise HarnessError("a delta frame needs at least one tile")
    parts = [ipc_message(MSG_DELTA_BEGIN,
                         struct.pack(">QQIIBI", generation, frame_id, width, height,
                                     BPP, len(tiles)))]
    for x, y, tile_width, tile_height in tiles:
        pixels = tile_pixels(frame, width, x, y, tile_width, tile_height)
        parts.append(ipc_message(MSG_DELTA_TILE,
                                 struct.pack(">QQIIHH", generation, frame_id,
                                             x, y, tile_width, tile_height) + pixels))
    parts.append(ipc_message(MSG_DELTA_END,
                             struct.pack(">QQI", generation, frame_id, len(tiles))))
    return b"".join(parts)


def parse_probe_bench(stdout):
    """Parse the single "bench ..." line printed by bin/rdp-probe -mode 9."""
    line = None
    for candidate in stdout.splitlines():
        if candidate.startswith("bench "):
            line = candidate
            break
    if line is None:
        raise HarnessError("probe did not print a bench line; stdout tail: %r" % stdout[-500:])
    fields = {}
    for token in line.split()[1:]:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value
    required = ("seconds", "bitmap_updates", "bitmap_rectangles", "bitmap_bytes",
                "pdu_per_s", "mbit_per_s", "framebuffer_crc32")
    missing = [key for key in required if key not in fields]
    if missing:
        raise HarnessError("probe bench line is missing %s: %r" % (", ".join(missing), line))
    result = {
        "seconds": float(fields["seconds"]),
        "bitmap_updates": int(fields["bitmap_updates"]),
        "bitmap_rectangles": int(fields["bitmap_rectangles"]),
        "bitmap_bytes": int(fields["bitmap_bytes"]),
        "pdu_per_s": float(fields["pdu_per_s"]),
        "mbit_per_s": float(fields["mbit_per_s"]),
        "framebuffer_crc32": "0x%08x" % int(fields["framebuffer_crc32"], 16),
    }
    if result["seconds"] <= 0:
        raise HarnessError("probe reported a non-positive bench window: %r" % line)
    if "gdi" in fields:
        match = re.fullmatch(r"(\d+)x(\d+)", fields["gdi"])
        if match:
            result["gdi_width"] = int(match.group(1))
            result["gdi_height"] = int(match.group(2))
    return result


def parse_frame_log(text):
    """Parse worker event=desktop_frame_sent lines (new and legacy formats)."""
    frames = []
    for match in FRAME_LOG_PATTERN.finditer(text):
        frames.append({
            "generation": int(match.group(1)),
            "frame_id": int(match.group(2)),
            "batches": int(match.group(3)),
            "tiles": int(match.group(4)),
            "bytes": int(match.group(5)),
            "pdus": int(match.group(6)),
            "encoding": match.group(7),
        })
    if not frames:
        for match in LEGACY_FRAME_LOG_PATTERN.finditer(text):
            frames.append({
                "generation": int(match.group(1)),
                "frame_id": int(match.group(2)),
                "batches": int(match.group(3)),
                "tiles": int(match.group(4)),
                "bytes": None,
                "pdus": None,
                "encoding": match.group(5),
            })
    return frames


def _mean(values):
    return sum(values) / float(len(values)) if values else 0.0


def summarize(probe, frames, scenario, width, height):
    """Turn probe statistics + worker frame lines into the benchmark JSON summary."""
    if not frames:
        raise HarnessError("worker logged no event=desktop_frame_sent lines during the window")
    window = probe["seconds"]
    byte_frames = [frame for frame in frames if frame["bytes"] is not None]
    pdu_frames = [frame for frame in frames if frame["pdus"] is not None]
    if not byte_frames or not pdu_frames:
        raise HarnessError("worker frame log lacks bytes=/pdus= fields; rebuild bin/rdp-worker")
    total_bytes = sum(frame["bytes"] for frame in byte_frames)
    encodings = sorted({frame["encoding"] for frame in frames})
    return {
        "scenario": scenario,
        "desktop_width": width,
        "desktop_height": height,
        "desktop_size": "%dx%d" % (width, height),
        "window_seconds": round(window, 3),
        "frames_sent": len(frames),
        "sent_fps": round(len(frames) / window, 3),
        "tiles_per_frame": round(_mean([frame["tiles"] for frame in frames]), 3),
        "pdus_per_frame": round(_mean([frame["pdus"] for frame in pdu_frames]), 3),
        "bytes_per_frame": round(_mean([frame["bytes"] for frame in byte_frames]), 3),
        "worker_mbit_per_s": round(total_bytes * 8.0 / 1e6 / window, 3),
        "client_pdu_per_s": probe["pdu_per_s"],
        "client_mbit_per_s": probe["mbit_per_s"],
        "client_framebuffer_crc32": probe["framebuffer_crc32"],
        "client_seconds": probe["seconds"],
        "client_bitmap_updates": probe["bitmap_updates"],
        "client_bitmap_rectangles": probe["bitmap_rectangles"],
        "client_bitmap_bytes": probe["bitmap_bytes"],
        "encoding": ",".join(encodings),
    }


def environment_note():
    """Describe background conditions and the scope of the measurement."""
    parts = [
        "loopback benchmark: isolated test worker + scripted fake agent + "
        "bin/rdp-probe -mode 9; NOT Windows App / rendered-FPS acceptance",
    ]
    try:
        load = os.getloadavg()
        parts.append("loadavg=%.2f/%.2f/%.2f" % load)
    except OSError:
        pass
    try:
        live = subprocess.run(["pgrep", "-f", "rdp-agent"], capture_output=True, text=True)
        if live.stdout.strip():
            parts.append("live capture agent process detected; it can add capture/CPU load and noise")
        else:
            parts.append("live capture agent not detected")
    except OSError:
        pass
    parts.append("content model: synthetic sparse 64x64 tile markers, so absolute Mbit/s is "
                 "not comparable to a real desktop capture")
    return "; ".join(parts)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def clean_environment(extra=None):
    """Inherit the caller environment without test hooks that would change worker behavior."""
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("RDP_TEST_", "RDP_PROBE_", "RDP_TRANSPORT_DUMP"))}
    env["WLOG_LEVEL"] = "ERROR"
    if extra:
        env.update(extra)
    return env


# ---------------------------------------------------------------------------
# Fake capture agent
# ---------------------------------------------------------------------------

class FrameProducer:
    """Deterministic synthetic content and IPC messages for one scenario."""

    def __init__(self, width, height, scenario, changed_tiles, seed=20261107):
        self.width = width
        self.height = height
        self.scenario = scenario
        self.changed_tiles = changed_tiles
        self.random = random.Random(seed)
        self.tiles = tile_grid(width, height)
        self.frame = bytearray(width * height * BPP)
        for x, y, _w, _h in self.tiles:
            self._mark_tile(x, y)
        self.frame_id = 0

    def _mark_tile(self, x, y):
        index = (y * self.width + x) * BPP
        self.frame[index:index + 4] = bytes((self.random.randrange(256),
                                             self.random.randrange(256),
                                             self.random.randrange(256), 0))

    def initial_messages(self, generation=1):
        self.frame_id = 1
        return encode_full_frame_messages(self.frame, self.width, self.height,
                                          generation, self.frame_id)

    def next_messages(self, generation=1):
        self.frame_id += 1
        if self.scenario == "full":
            changed = self.tiles
            for x, y, _w, _h in changed:
                self._mark_tile(x, y)
            return encode_full_frame_messages(self.frame, self.width, self.height,
                                              generation, self.frame_id)
        changed = self.random.sample(self.tiles, min(self.changed_tiles, len(self.tiles)))
        for x, y, _w, _h in changed:
            self._mark_tile(x, y)
        return encode_delta_frame_messages(self.frame, self.width, self.height,
                                           generation, self.frame_id, changed)


class FakeAgent:
    """One connection to the worker's private agent Unix socket."""

    def __init__(self, socket_path, connect_timeout=10.0):
        self.socket_path = socket_path
        self.connect_timeout = connect_timeout
        self.socket = None
        self._reader = None
        self._size_lock = threading.Lock()
        self._requested_size = None

    def connect(self):
        deadline = time.monotonic() + self.connect_timeout
        last_error = None
        while time.monotonic() < deadline:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(self.socket_path)
            except OSError as error:
                last_error = error
                sock.close()
                time.sleep(0.02)
                continue
            self.socket = sock
            self._reader = threading.Thread(target=self._read_worker_messages, daemon=True)
            self._reader.start()
            return
        raise HarnessError("fake agent could not connect to %s: %s"
                           % (self.socket_path, last_error))

    @staticmethod
    def _read_exact(sock, length):
        data = bytearray()
        while len(data) < length:
            chunk = sock.recv(length - len(data))
            if not chunk:
                return None
            data += chunk
        return bytes(data)

    def _read_worker_messages(self):
        sock = self.socket
        try:
            while True:
                header = self._read_exact(sock, IPC_HEADER_BYTES)
                if header is None or header[:4] != MAGIC:
                    return
                version, message_type, length = struct.unpack(">HHI", header[4:])
                if version != IPC_VERSION or length > 1024 * 1024:
                    return
                payload = self._read_exact(sock, length)
                if payload is None:
                    return
                if message_type == MSG_CAPTURE_SIZE and len(payload) == 8:
                    with self._size_lock:
                        self._requested_size = struct.unpack(">II", payload)
        except OSError:
            return

    def requested_size(self):
        with self._size_lock:
            return self._requested_size

    def send(self, data):
        if self.socket is None:
            raise HarnessError("fake agent is not connected")
        try:
            self.socket.sendall(data)
            return True
        except OSError:
            return False

    def close(self):
        if self.socket is not None:
            try:
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.socket.close()
            self.socket = None


class AgentPump(threading.Thread):
    """Send scenario frames at a fixed offered rate until stopped."""

    def __init__(self, agent, producer, frames_per_second):
        super().__init__(daemon=True)
        self.agent = agent
        self.producer = producer
        self.frames_per_second = frames_per_second
        self.stop_event = threading.Event()
        self.error = None
        self.frames_sent = 0
        self.started_at = None
        self.finished_at = None

    def run(self):
        self.started_at = time.monotonic()
        target = self.started_at
        interval = 1.0 / self.frames_per_second
        try:
            while not self.stop_event.is_set():
                if not self.agent.send(self.producer.next_messages()):
                    break
                self.frames_sent += 1
                target += interval
                delay = target - time.monotonic()
                if delay > 0:
                    self.stop_event.wait(delay)
                else:
                    target = time.monotonic()
        except Exception as error:  # keep the thread from dying silently
            self.error = error
        finally:
            self.finished_at = time.monotonic()

    def stop(self, timeout=5.0):
        self.stop_event.set()
        if self.is_alive():
            self.join(timeout)
        if self.error is not None:
            raise HarnessError("fake agent pump failed: %s" % self.error)

    def offered_fps(self):
        if not self.started_at or not self.finished_at or self.finished_at <= self.started_at:
            return 0.0
        return self.frames_sent / (self.finished_at - self.started_at)


# ---------------------------------------------------------------------------
# Isolated test worker
# ---------------------------------------------------------------------------

def reserve_loopback_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    if port == 3389:
        raise HarnessError("reserved port collision with the live service; refusing to continue")
    return port


class WorkerHarness:
    """Private temp dir + config + worker process, mirroring scripts/test-protocol.py."""

    def __init__(self, worker_binary=DEFAULT_WORKER_BINARY,
                 probe_binary=DEFAULT_PROBE_BINARY, keep_temp=False):
        self.worker_binary = Path(worker_binary)
        self.probe_binary = Path(probe_binary)
        self.keep_temp = keep_temp
        self.directory = None
        self.log_path = None
        self.agent_socket = None
        self.port = None
        self.password = None
        self.process = None
        self._log_handle = None

    def _check_binaries(self):
        for path in (self.worker_binary, self.probe_binary):
            if not path.is_file():
                raise HarnessError("binary not found: %s (run make build)" % path)
            if not os.access(path, os.X_OK):
                raise HarnessError("binary is not executable: %s" % path)
        if not OPENSSL.is_file():
            raise HarnessError("missing %s (install Homebrew OpenSSL 3)" % OPENSSL)

    def _write_private(self, path, text):
        path.write_text(text)
        path.chmod(0o600)

    def start(self, timeout=15.0):
        self._check_binaries()
        base = Path(tempfile.mkdtemp(prefix="rdp-bench-", dir=tempfile.gettempdir()))
        os.chmod(base, 0o700)
        resolved = base.resolve()
        repo = ROOT.resolve()
        if resolved == repo or repo in resolved.parents:
            raise HarnessError("refusing to run the harness inside the repository: %s" % resolved)
        self.directory = base
        self.password = secrets.token_urlsafe(24)
        self.port = reserve_loopback_port()
        key_path = base / "key.pem"
        cert_path = base / "cert.pem"
        subprocess.run(
            [str(OPENSSL), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key_path), "-out", str(cert_path), "-days", "1",
             "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key_path.chmod(0o600)
        cert_path.chmod(0o600)
        hashed = subprocess.run(
            [str(ROOT / "bin" / "rdpctl"), "hash-stdin"],
            input=self.password + "\n", text=True, capture_output=True, check=True).stdout.strip()
        sam_path = base / "sam"
        self._write_private(sam_path, "alice:MACRDP::%s:\n" % hashed)
        config_path = base / "config.json"
        self._write_private(config_path, json.dumps({
            "address": "127.0.0.1",
            "port": self.port,
            "account": "alice",
            "enabled": True,
            "test_pattern": False,
            "certificate": str(cert_path),
            "key": str(key_path),
            "sam": str(sam_path),
        }))
        agent_dir = base / "agent"
        agent_dir.mkdir(mode=0o700)
        os.chmod(agent_dir, 0o700)
        self.agent_socket = agent_dir / "s"
        self.log_path = base / "worker.log"
        self._log_handle = open(self.log_path, "w+")
        self.process = subprocess.Popen(
            [str(self.worker_binary), "-config", str(config_path),
             "-agent-socket", str(self.agent_socket)],
            stdout=self._log_handle, stderr=self._log_handle,
            env=clean_environment())
        self._wait_for(["event=agent_ipc_listening", "event=listening"], timeout)

    def _wait_for(self, needles, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise HarnessError("worker exited before becoming ready; log tail: %r"
                                   % self.log_tail())
            text = self.log_text()
            if all(needle in text for needle in needles):
                return
            time.sleep(0.02)
        raise HarnessError("timed out waiting for %r in worker log; tail: %r"
                           % (needles, self.log_tail()))

    def log_text(self):
        if self.log_path is None:
            return ""
        try:
            return self.log_path.read_text(errors="replace")
        except OSError:
            return ""

    def log_tail(self, limit=4000):
        return self.log_text()[-limit:]

    def log_size(self):
        if self.log_path is None or not self.log_path.exists():
            return 0
        return self.log_path.stat().st_size

    def log_since(self, offset):
        with open(self.log_path, "rb") as handle:
            handle.seek(offset)
            return handle.read().decode("utf-8", "replace")

    def wait_log(self, needle, offset=0, timeout=20.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise HarnessError("worker exited while waiting for %r; log tail: %r"
                                   % (needle, self.log_tail()))
            text = self.log_since(offset)
            if needle in text:
                return text
            time.sleep(0.02)
        raise HarnessError("timed out waiting for %r in worker log; tail: %r"
                           % (needle, self.log_tail()))

    def stop(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process = None
        if self._log_handle is not None:
            self._log_handle.close()
            self._log_handle = None

    def cleanup(self):
        self.stop()
        if self.directory is not None and not self.keep_temp:
            shutil.rmtree(self.directory, ignore_errors=True)
            self.directory = None


# ---------------------------------------------------------------------------
# Benchmark driver
# ---------------------------------------------------------------------------

def run_probe(probe_binary, port, width, height, seconds, password):
    bench_seconds = max(1, min(120, int(round(seconds))))
    command = [str(probe_binary), "-port", str(port), "-user", "alice",
               "-domain", "MACRDP", "-mode", "9",
               "-width", str(width), "-height", str(height)]
    try:
        return subprocess.run(
            command, input=password + "\n", text=True, capture_output=True,
            timeout=bench_seconds + 120,
            env=clean_environment({"RDP_PROBE_BENCH_SECONDS": str(bench_seconds)}))
    except subprocess.TimeoutExpired:
        raise HarnessError("probe did not finish within %d s" % (bench_seconds + 120))


def run_benchmark(args):
    harness = WorkerHarness(worker_binary=args.worker_binary,
                            probe_binary=args.probe_binary,
                            keep_temp=args.keep_temp)
    agent = None
    pump = None
    loadavg_start = os.getloadavg() if hasattr(os, "getloadavg") else None
    try:
        harness.start()
        agent = FakeAgent(str(harness.agent_socket))
        agent.connect()
        producer = FrameProducer(args.width, args.height, args.scenario,
                                 args.changed_tiles, seed=args.seed)
        if not agent.send(producer.initial_messages()):
            raise HarnessError("fake agent failed to send the initial full frame")
        harness.wait_log("event=agent_frame_received", timeout=10.0)
        log_offset = harness.log_size()

        if args.scenario != "static":
            pump = AgentPump(agent, producer, args.frames_per_second)
            pump.start()

        started = time.monotonic()
        probe = run_probe(harness.probe_binary, harness.port, args.width,
                          args.height, args.seconds, harness.password)
        elapsed = time.monotonic() - started
        if pump is not None:
            pump.stop()
        if probe.returncode != 0:
            raise HarnessError(
                "probe failed rc=%d\nstdout: %s\nstderr: %s\nworker log tail: %r"
                % (probe.returncode, probe.stdout[-2000:], probe.stderr[-2000:],
                   harness.log_tail()))
        time.sleep(0.1)  # let the worker flush any final frame line
        window_text = harness.log_since(log_offset)
        probe_stats = parse_probe_bench(probe.stdout)
        frames = parse_frame_log(window_text)
        result = summarize(probe_stats, frames, args.scenario, args.width, args.height)
        agent_frames_received = window_text.count("event=agent_frame_received")
        result.update({
            "target_fps": args.frames_per_second,
            "changed_tiles": args.changed_tiles,
            "agent_frames_published": producer.frame_id - 1,
            "agent_fps_achieved": round(pump.offered_fps(), 3) if pump else 0.0,
            "agent_frames_received": agent_frames_received,
            "agent_capture_size_requested": (
                {"width": agent.requested_size()[0], "height": agent.requested_size()[1]}
                if agent.requested_size() else None),
            "client_gdi_size": (
                "%dx%d" % (probe_stats["gdi_width"], probe_stats["gdi_height"])
                if "gdi_width" in probe_stats else None),
            "elapsed_seconds": round(elapsed, 3),
            "worker_binary": str(harness.worker_binary),
            "worker_sha256": file_sha256(harness.worker_binary),
            "probe_binary": str(harness.probe_binary),
            "probe_sha256": file_sha256(harness.probe_binary),
            "environment_note": environment_note(),
            "loadavg_start": (round(loadavg_start[0], 2), round(loadavg_start[1], 2),
                              round(loadavg_start[2], 2)) if loadavg_start else None,
            "loadavg_end": (round(os.getloadavg()[0], 2), round(os.getloadavg()[1], 2),
                            round(os.getloadavg()[2], 2)) if hasattr(os, "getloadavg") else None,
            "warnings": collect_warnings(result, probe_stats, args),
        })
        return result
    finally:
        if pump is not None:
            try:
                pump.stop()
            except HarnessError:
                pass
        if agent is not None:
            agent.close()
        harness.cleanup()
        if args.keep_temp and harness.directory is not None:
            sys.stderr.write("kept temp dir: %s\n" % harness.directory)


def collect_warnings(result, probe_stats, args):
    warnings = []
    size = "%dx%d" % (args.width, args.height)
    if probe_stats.get("gdi_width") is not None:
        gdi = "%dx%d" % (probe_stats["gdi_width"], probe_stats["gdi_height"])
        if gdi != size:
            warnings.append("client gdi size %s differs from requested %s" % (gdi, size))
    if args.scenario == "static":
        warnings.append("static scenario delivers one frame; sent_fps is 1/window_seconds")
    elif result["sent_fps"] < args.frames_per_second * 0.9:
        warnings.append("worker did not keep up with the offered %g fps (client-side limit "
                        "can also cap this)" % args.frames_per_second)
    if result["encoding"] == "":
        warnings.append("worker did not report an encoding")
    return warnings


def build_argument_parser():
    parser = argparse.ArgumentParser(
        description="Repeatable loopback RDP worker frame-rate benchmark "
                    "(test worker + fake agent + bin/rdp-probe -mode 9). "
                    "Loopback measurement only; not Windows App acceptance.")
    parser.add_argument("--scenario", default="small", choices=["small", "full", "static"])
    parser.add_argument("--width", type=int, default=1472)
    parser.add_argument("--height", type=int, default=960)
    parser.add_argument("--seconds", type=float, default=10.0,
                        help="client bench window in seconds (1..120, default 10)")
    parser.add_argument("--frames-per-second", type=float, default=30.0,
                        help="offered agent frame rate (default 30)")
    parser.add_argument("--changed-tiles", type=int, default=8,
                        help="64x64 tiles changed per frame for --scenario small (default 8)")
    parser.add_argument("--seed", type=int, default=20261107,
                        help="deterministic content seed (default 20261107)")
    parser.add_argument("--worker-binary", default=str(DEFAULT_WORKER_BINARY))
    parser.add_argument("--probe-binary", default=str(DEFAULT_PROBE_BINARY))
    parser.add_argument("--json", default=None, help="write the JSON summary to this path")
    parser.add_argument("--keep-temp", action="store_true",
                        help="keep the temp worker dir for debugging (path printed to stderr)")
    return parser


def validate_arguments(parser, args):
    if not 1 <= args.seconds <= 120:
        parser.error("--seconds must be within 1..120")
    if args.frames_per_second <= 0 or args.frames_per_second > 240:
        parser.error("--frames-per-second must be within (0, 240]")
    if args.changed_tiles < 1:
        parser.error("--changed-tiles must be >= 1")
    if not 1 <= args.width <= 16384 or not 1 <= args.height <= 16384:
        parser.error("--width/--height must be within 1..16384")
    if args.json:
        parent = Path(args.json).expanduser().resolve().parent
        if not parent.is_dir():
            parser.error("--json parent directory does not exist: %s" % parent)


def main(argv=None):
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    validate_arguments(parser, args)
    try:
        result = run_benchmark(args)
    except HarnessError as error:
        sys.stderr.write("benchmark-fps: harness failure: %s\n" % error)
        return 1
    except KeyboardInterrupt:
        sys.stderr.write("benchmark-fps: interrupted\n")
        return 130
    output = json.dumps(result, indent=2, sort_keys=False)
    print(output)
    if args.json:
        Path(args.json).write_text(output + "\n")
    sys.stderr.write(
        "benchmark-fps: scenario=%s size=%s sent_fps=%.2f tiles/frame=%.1f "
        "pdus/frame=%.1f client_pdu/s=%.2f client_mbit/s=%.2f crc=%s\n"
        % (result["scenario"], result["desktop_size"], result["sent_fps"],
           result["tiles_per_frame"], result["pdus_per_frame"],
           result["client_pdu_per_s"], result["client_mbit_per_s"],
           result["client_framebuffer_crc32"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

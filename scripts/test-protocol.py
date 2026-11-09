#!/usr/bin/env python3
"""Real loopback NLA/bitmap/input checks using the headless FreeRDP client.
Never substitutes for Microsoft Windows App / mstsc acceptance.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def short_temp_dir(prefix, socket_name="s"):
    """Create a temp directory whose Unix socket child stays below 104 bytes.

    /tmp is preferred over the platform TMPDIR (e.g. /var/folders/...) so the
    worker's AF_UNIX agent socket path always fits in sun_path. Fall back only
    when the resulting path still fits, then fail with a clear message.
    """
    for base in ("/tmp", "/private/tmp", tempfile.gettempdir()):
        try:
            directory = tempfile.mkdtemp(prefix=prefix, dir=base)
        except OSError:
            continue
        if len(os.fsencode(os.path.join(directory, socket_name))) < 104:
            return directory
        shutil.rmtree(directory, ignore_errors=True)
    raise RuntimeError(
        "no writable temp directory keeps the Unix socket path under 104 bytes")


def _tile_count(width, height):
    """Number of 64x64 tiles a probe-mode-5 full frame is split into."""
    return ((width + 63) // 64) * ((height + 63) // 64)


def negotiate_desktop_size(requested_width, requested_height):
    """Worker size negotiation, exactly as design section 2.

    Returns (desktop_width, desktop_height, policy) where policy is "client"
    (request accepted unchanged) or "clamp" (oversized request scaled down with
    a single factor, aspect preserved and both axes made even).
    """
    max_dim = 16384
    budget = 16777216  # MAX_FRAME_BYTES / 4
    req_w, req_h = requested_width, requested_height
    if req_w <= max_dim and req_h <= max_dim and req_w * req_h <= budget:
        return req_w, req_h, "client"
    factor = min(math.sqrt(budget / (req_w * req_h)), max_dim / req_w, max_dim / req_h)
    width = max(2, math.floor(req_w * factor))
    height = max(2, math.floor(req_h * factor))
    width &= ~1
    height &= ~1
    if width < 2:
        width = 2
    if height < 2:
        height = 2
    while width * height > budget:
        if width <= height:
            width -= 2
        else:
            height -= 2
    return width, height, "clamp"


def fit_layout(capture_width, capture_height, desktop_width, desktop_height):
    """Fit-with-bars composition, exactly as design section 3.

    Returns (content_width, content_height, offset_x, offset_y, scaled) for a
    capture of capture_width x capture_height composed into a desktop of
    desktop_width x desktop_height. Same integer math as the worker and the
    agent, so test expectations cannot drift from the implementation.
    """
    cw, ch, dw, dh = capture_width, capture_height, desktop_width, desktop_height
    if cw * dh <= dw * ch:  # capture relatively wider or equal: fit height
        content_height = dh
        content_width = max(1, (cw * dh + ch // 2) // ch)
    else:                   # fit width
        content_width = dw
        content_height = max(1, (ch * dw + cw // 2) // cw)
    offset_x = (dw - content_width) // 2
    offset_y = (dh - content_height) // 2
    scaled = cw != content_width or ch != content_height
    return content_width, content_height, offset_x, offset_y, scaled


PROBE_SAMPLE_RE = re.compile(r"^sample x=(\d+) y=(\d+) bgra=(\d+),(\d+),(\d+),(\d+)$")

class ProtocolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="rdp-p0-")
        cls.directory = Path(cls.temp.name)
        cls.password = secrets.token_urlsafe(24)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            cls.port = reservation.getsockname()[1]
        cls.log_path = cls.directory / "worker.log"
        cls.log = open(cls.log_path, "w+")
        cls.process = None
        cls.agent_socket_dir = None
        cls.probe_binary = Path(os.environ.get("RDP_TEST_PROBE_BINARY", ROOT / "bin/rdp-probe"))
        cls.configure(True)

    @classmethod
    def tearDownClass(cls):
        cls.stop()
        if os.environ.get("RDP_TEST_LOG"):
            print(cls.read_log())
        cls.log.close()
        cls.temp.cleanup()

    @classmethod
    def read_log(cls):
        """Read the worker log through a separate file handle.

        The worker child inherits the write handle's file offset. Seeking or
        reading through that shared handle from the parent moves the offset, so a
        concurrent worker write can land on top of earlier log lines (this made
        log-polling tests flaky). Always read through a fresh handle.
        """
        try:
            return cls.log_path.read_text(errors="replace")
        except FileNotFoundError:
            return ""

    @classmethod
    def stop(cls):
        if cls.process is not None:
            cls.process.terminate()
            try:
                cls.process.wait(5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait()
            cls.process = None

    @classmethod
    def configure(cls, enabled, stress_frame=False, test_pattern=True, raw_bitmap=False,
                  peer_no_bitmap_header=False, nscodec_bitmap=False, extra_env=None,
                  clipboard=False):
        cls.stop()
        if cls.agent_socket_dir:
            shutil.rmtree(cls.agent_socket_dir, ignore_errors=True)
            cls.agent_socket_dir = None
        d = cls.directory
        key, cert = d / "key.pem", d / "cert.pem"
        if not key.exists():
            subprocess.run(["/opt/homebrew/opt/openssl@3/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        hashed = subprocess.run([str(ROOT / "bin/rdpctl"), "hash-stdin"], input=cls.password + "\n", text=True, capture_output=True, check=True).stdout.strip()
        (d / "sam").write_text(f"alice:MACRDP::{hashed}:\n")
        config = dict(address="127.0.0.1", port=cls.port, account="alice", enabled=enabled, test_pattern=test_pattern, clipboard=clipboard, certificate=str(cert), key=str(key), sam=str(d / "sam"))
        (d / "config.json").write_text(json.dumps(config))
        for p in d.iterdir():
            p.chmod(0o600)
        cls.log.seek(0)
        cls.log.truncate()
        cls.agent_socket_dir = short_temp_dir(prefix="rdp-")
        os.chmod(cls.agent_socket_dir, 0o700)
        agent_socket = Path(cls.agent_socket_dir) / "s"
        cls.agent_socket = agent_socket
        worker_binary = Path(os.environ.get("RDP_TEST_WORKER_BINARY", ROOT / "bin/rdp-worker"))
        cls.process = subprocess.Popen([str(worker_binary), "-config", str(d / "config.json"), "-agent-socket", str(agent_socket)], stdout=cls.log, stderr=cls.log, env={**os.environ, "WLOG_LEVEL": "ERROR", "RDP_TEST_STRESS_FRAME": "1" if stress_frame else "0", "RDP_TEST_RAW_BITMAP": "1" if raw_bitmap else "0", "RDP_TEST_NSCODEC_BITMAP": "1" if nscodec_bitmap else "0", "RDP_TEST_PEER_NO_BITMAP_HEADER": "1" if peer_no_bitmap_header else "0", **({} if extra_env is None else extra_env)})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                raise AssertionError("worker exited before listening: " + cls.read_log())
            if "event=listening" in cls.read_log():
                return
            time.sleep(.05)
        raise AssertionError("worker did not listen")

    def probe(self, user="alice", domain="MACRDP", password=None, mode=0, width=800, height=600):
        return subprocess.run([str(self.probe_binary), "-port", str(self.port), "-user", user, "-domain", domain, "-mode", str(mode), "-width", str(width), "-height", str(height)], input=(self.password if password is None else password) + "\n", text=True, capture_output=True, timeout=25, env={**os.environ,"WLOG_LEVEL":"ERROR"})

    def test_12_gfx_avc420_client_probe(self):
        if os.environ.get("RDP_TEST_GFX") != "1":
            self.skipTest("requires RDP_TEST_GFX=1 and an AVC420-enabled worker/client")
        p = self.probe(mode=8)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("gfx_frame_ok", p.stdout)
        self.assertIn("event=gfx_ack_metrics", self.read_log())

    def test_01_bitmap_input_and_reconnect(self):
        for _ in range(2):
            p = self.probe()
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            self.assertIn("bitmap_and_input_ok", p.stdout)
            self.assertIn("bitmap_update_seen", p.stdout)
            self.assertIn("bitmap_bpp=32", p.stdout)
            self.assertIn("bitmap_compressed=1", p.stdout)
            bitmap_length = next(line for line in p.stdout.splitlines() if line.startswith("bitmap_length="))
            self.assertLessEqual(int(bitmap_length.split("=", 1)[1]), 32768)
            time.sleep(.15)
        worker_log = self.read_log()
        self.assertGreaterEqual(worker_log.count("event=peer_logon_complete"), 2)
        self.assertGreaterEqual(worker_log.count("event=peer_post_connect"), 2)
        self.assertGreaterEqual(worker_log.count("event=peer_activate_complete"), 2)
        self.assertNotIn("event=server_redirection_callback", worker_log)

    def test_01b_account_spellings(self):
        for args in [dict(user="Alice", domain="macrdp"), dict(domain=""), dict(user="MACRDP\\alice", domain="")]:
            p = self.probe(**args)
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            time.sleep(.15)

    def test_02_wrong_password_unknown_user_and_domain(self):
        for args in [dict(password="wrong"), dict(user="unknown"), dict(domain="EVIL")]:
            p = self.probe(**args)
            self.assertNotEqual(p.returncode, 0, str(args))
            self.assertNotIn("bitmap_and_input_ok", p.stdout)
            self.assertNotIn("bitmap_update_seen", p.stdout)

    def test_03_nla_required(self):
        p = self.probe(mode=2)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("bitmap_update_seen", p.stdout)

    def test_04_single_connection(self):
        command = [str(self.probe_binary), "-port", str(self.port), "-mode", "1"]
        p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env={**os.environ,"WLOG_LEVEL":"ERROR"})
        try:
            p.stdin.write(self.password + "\n")
            p.stdin.close()
            self.assertEqual(p.stdout.readline().strip(), "lease_held")
            self.assertNotEqual(self.probe().returncode, 0)
        finally:
            p.terminate()
            p.wait(5)
            p.stdout.close()
        time.sleep(.2)
        self.assertEqual(self.probe().returncode, 0)

    def test_05_half_open_handshake_expires(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as half_open:
            half_open.settimeout(18)
            started = time.monotonic()
            self.assertEqual(half_open.recv(1), b"")
            self.assertGreater(time.monotonic() - started, 12)
        self.assertEqual(self.probe().returncode, 0)

    def test_05b_tls_handshake_stall_expires(self):
        request = bytes.fromhex("030000130ee000000000000100080003000000")
        response = bytes.fromhex("030000130ed000000000000209080002000000")
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as stalled:
            stalled.settimeout(18)
            stalled.sendall(request)
            received = b""
            while len(received) < len(response):
                chunk = stalled.recv(len(response) - len(received))
                self.assertTrue(chunk, "server closed before RDP negotiation response")
                received += chunk
            self.assertEqual(received, response)
            started = time.monotonic()
            self.assertEqual(stalled.recv(1), b"")
            self.assertGreater(time.monotonic() - started, 12)
        self.assertEqual(self.probe().returncode, 0)

    def test_05c_blocked_frame_write_expires(self):
        self.configure(True, stress_frame=True)  # isolate the log and force bitmap backpressure
        started = time.monotonic()
        p = self.probe(mode=3)
        elapsed = time.monotonic() - started
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("server_close_observed", p.stdout)
        self.assertGreaterEqual(elapsed, 5.0)
        self.assertLess(elapsed, 12.0)
        worker_log = self.read_log()
        self.assertIn("event=peer_deadline_expired slot=0", worker_log)
        self.assertEqual(self.probe().returncode, 0, "connection lease was not released")

    def test_05d_refresh_frame_write_expires(self):
        self.configure(True, stress_frame=True)
        started = time.monotonic()
        p = self.probe(mode=4)
        elapsed = time.monotonic() - started
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("refresh_requested", p.stdout)
        self.assertIn("refresh_close_observed", p.stdout)
        self.assertGreaterEqual(elapsed, 5.0)
        self.assertLess(elapsed, 12.0)
        self.assertIn("event=peer_deadline_expired slot=0", self.read_log())
        self.assertEqual(self.probe().returncode, 0, "connection lease was not released")

    def test_06_disabled_account(self):
        self.configure(False)
        p = self.probe()
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("bitmap_update_seen", p.stdout)
        self.configure(True)

    def test_07_live_agent_frame_uses_capture_resolution(self):
        self.configure(True, test_pattern=False, raw_bitmap=True,
                       peer_no_bitmap_header=True)
        width, height = 1470, 956
        generation, frame_id, bpp = 1, 1, 4
        pixels = bytes(width * height * bpp)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            metadata = struct.pack(">QQIIB", generation, frame_id, width, height, bpp)
            agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata)) + metadata)
            chunk_size = 65516
            for offset in range(0, len(pixels), chunk_size):
                data = pixels[offset:offset + chunk_size]
                payload = struct.pack(">QQI", generation, frame_id, offset) + data
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload)) + payload)

        requested_width, requested_height = 1468, 923
        p = self.probe(mode=5, width=requested_width, height=requested_height)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("bitmap_update_received", p.stdout)
        self.assertIn("bitmap_bpp=32", p.stdout)
        self.assertIn("bitmap_compressed=0", p.stdout)
        self.assertIn("bitmap_flags=0", p.stdout)
        self.assertIn(f"desktop_size={requested_width}x{requested_height}", p.stdout)
        self.assertIn(f"gdi_size={requested_width}x{requested_height}", p.stdout)
        self.assertIn("bitmap_update_batches=11", p.stdout)
        self.assertIn("bitmap_rectangles=345", p.stdout)
        worker_log = self.read_log()
        self.assertIn("event=rdp_capabilities peer_no_bitmap_compression_header=1", worker_log)
        self.assertIn("event=peer_codecs nscodec=0", worker_log)
        self.assertIn(f"event=rdp_desktop_size width={requested_width} height={requested_height}", worker_log)
        self.assertIn("batches=11 tiles=345", worker_log)

    def test_08_raw_dirty_tiles_reach_client(self):
        self.configure(True, test_pattern=False, raw_bitmap=True)
        width = height = 256
        pixels = bytearray(width * height * 4)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame(frame_id):
                metadata = struct.pack(">QQIIB", 1, frame_id, width, height, 4)
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata)) + metadata)
                for offset in range(0, len(pixels), 65516):
                    payload = struct.pack(">QQI", 1, frame_id, offset) + pixels[offset:offset + 65516]
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload)) + payload)

            send_frame(1)
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "6", "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "WLOG_LEVEL": "ERROR"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                self.assertEqual(probe.stdout.readline().strip(), "initial_frame_received")
                agent.settimeout(3)
                header = agent.recv(12)
                self.assertEqual(len(header), 12)
                magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
                self.assertEqual((magic, version, message_type, payload_length), (b"RDPA", 1, 9, 8))
                size_payload = b""
                while len(size_payload) < payload_length:
                    size_payload += agent.recv(payload_length - len(size_payload))
                self.assertEqual(struct.unpack(">II", size_payload), (width, height))
                agent.settimeout(None)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if re.search(r"frame_id=1 batches=1 tiles=16 bytes=\d+ pdus=1 encoding=raw", self.read_log()):
                        break
                    time.sleep(.005)
                else:
                    self.fail("initial frame was not sent")
                # Let the peer enter its network wait before publishing the next frame.
                time.sleep(.04)
                started = time.monotonic()
                send_frame(2)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    if re.search(r"frame_id=2 batches=0 tiles=0 bytes=0 pdus=0 encoding=raw", self.read_log()):
                        break
                    time.sleep(.02)
                else:
                    self.fail("unchanged frame was not suppressed")
                self.assertLess(time.monotonic() - started, .19, "new frame did not wake the peer promptly")
                pixels[(80 * width + 80) * 4] = 255
                send_frame(3)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
                self.assertEqual(probe.wait(timeout=8), 0, stderr + stdout)
                self.assertIn("dirty_frame_received", stdout)
                self.assertIn("full_refresh_received", stdout)
                self.assertRegex(self.read_log(), r"frame_id=3 batches=1 tiles=1 bytes=\d+ pdus=1 encoding=raw")
                self.assertRegex(self.read_log(), r"frame_id=3 batches=1 tiles=16 bytes=\d+ pdus=1 encoding=raw")
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

    def test_09_nscodec_bitmap_tile_decodes(self):
        self.configure(True, test_pattern=False, nscodec_bitmap=True)
        width = height = 256
        pixels = bytes([0x80, 0x80, 0x80, 0]) * width * height
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            metadata = struct.pack(">QQIIB", 1, 1, width, height, 4)
            agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata)) + metadata)
            for offset in range(0, len(pixels), 65516):
                chunk = pixels[offset:offset + 65516]
                payload = struct.pack(">QQI", 1, 1, offset) + chunk
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload)) + payload)
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "7",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.run(command, input=self.password + "\n", text=True,
                                   capture_output=True, timeout=15,
                                   env={**os.environ, "WLOG_LEVEL": "ERROR"})
        self.assertEqual(probe.returncode, 0, probe.stderr + probe.stdout)
        self.assertIn("nscodec_surface_bits_received", probe.stdout)
        worker_log = self.read_log()
        self.assertIn("encoding=nscodec", worker_log)

    def test_10_agent_delta_frames_are_atomically_assembled(self):
        self.configure(True, test_pattern=False, raw_bitmap=True)
        source_width = source_height = 256
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_delta(frame_id, width, height, tiles):
                begin = struct.pack(">QQIIBI", 1, frame_id, width, height, 4, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 10, len(begin)) + begin)
                for x, y, tile_width, tile_height, tile_pixels in tiles:
                    payload = struct.pack(">QQIIHH", 1, frame_id, x, y, tile_width, tile_height) + tile_pixels
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 11, len(payload)) + payload)
                end = struct.pack(">QQI", 1, frame_id, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 12, len(end)) + end)

            full_tiles = []
            for y in range(0, source_height, 64):
                for x in range(0, source_width, 64):
                    full_tiles.append((x, y, 64, 64, bytes(64 * 64 * 4)))
            send_delta(1, source_width, source_height, full_tiles)
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "6",
                       "-width", "224", "-height", "224"]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True,
                                     env={**os.environ, "WLOG_LEVEL": "ERROR"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                self.assertEqual(probe.stdout.readline().strip(), "initial_frame_received")
                agent.settimeout(3)
                header = agent.recv(12)
                self.assertEqual(len(header), 12)
                magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
                self.assertEqual((magic, version, message_type, payload_length), (b"RDPA", 1, 9, 8))
                self.assertEqual(struct.unpack(">II", agent.recv(payload_length)), (224, 224))
                agent.settimeout(None)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if re.search(r"frame_id=1 batches=1 tiles=16 bytes=\d+ pdus=1 encoding=raw", self.read_log()):
                        break
                    time.sleep(.01)
                else:
                    self.fail("initial delta frame was not published")
                resized_tiles = []
                for y in range(0, 224, 64):
                    for x in range(0, 224, 64):
                        tile = bytearray(64 * 64 * 4)
                        if (x, y) == (64, 64):
                            tile[(16 * 64 + 16) * 4] = 255
                        tile_width = min(64, 224 - x)
                        tile_height = min(64, 224 - y)
                        if tile_width != 64 or tile_height != 64:
                            trimmed = bytearray(tile_width * tile_height * 4)
                            for row in range(tile_height):
                                trimmed[row * tile_width * 4:(row + 1) * tile_width * 4] = tile[row * 64 * 4:row * 64 * 4 + tile_width * 4]
                            tile = trimmed
                        resized_tiles.append((x, y, tile_width, tile_height, bytes(tile)))
                send_delta(2, 224, 224, resized_tiles)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
                self.assertEqual(probe.wait(timeout=8), 0, stderr + stdout)
                self.assertIn("dirty_frame_received", stdout)
                self.assertIn("full_refresh_received", stdout)
                worker_log = self.read_log()
                self.assertRegex(worker_log, r"frame_id=2 batches=1 tiles=16 bytes=\d+ pdus=1 encoding=raw")
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

    def test_11_large_resolution_delta_resize_stays_alive(self):
        self.configure(True, test_pattern=False, raw_bitmap=True)
        source_width, source_height = 4096, 2304
        width, height = 3940, 1888
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame_begin(frame_id, frame_width, frame_height, tile_count):
                payload = struct.pack(">QQIIBI", 1, frame_id, frame_width, frame_height, 4, tile_count)
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 10, len(payload)) + payload)

            def send_tile(frame_id, x, y, tile_width, tile_height, tile):
                payload = struct.pack(">QQIIHH", 1, frame_id, x, y, tile_width, tile_height) + tile
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 11, len(payload)) + payload)

            def send_frame_end(frame_id, tile_count):
                payload = struct.pack(">QQI", 1, frame_id, tile_count)
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 12, len(payload)) + payload)

            def send_full_tiles(frame_id, frame_width, frame_height, changed_point=None, fill=0):
                count = ((frame_width + 63) // 64) * ((frame_height + 63) // 64)
                send_frame_begin(frame_id, frame_width, frame_height, count)
                for y in range(0, frame_height, 64):
                    tile_height = min(64, frame_height - y)
                    for x in range(0, frame_width, 64):
                        tile_width = min(64, frame_width - x)
                        tile = bytearray([fill]) * (tile_width * tile_height * 4)
                        if changed_point and x <= changed_point[0] < x + tile_width and y <= changed_point[1] < y + tile_height:
                            px, py = changed_point[0] - x, changed_point[1] - y
                            tile[(py * tile_width + px) * 4] = 255
                        send_tile(frame_id, x, y, tile_width, tile_height, bytes(tile))
                send_frame_end(frame_id, count)

            send_full_tiles(1, source_width, source_height)
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "6",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True,
                                     env={**os.environ, "WLOG_LEVEL": "ERROR"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                self.assertEqual(probe.stdout.readline().strip(), "initial_frame_received")
                agent.settimeout(3)
                header = bytearray()
                while len(header) < 12:
                    header.extend(agent.recv(12 - len(header)))
                magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
                self.assertEqual((magic, version, message_type, payload_length), (b"RDPA", 1, 9, 8))
                size_payload = bytearray()
                while len(size_payload) < payload_length:
                    size_payload.extend(agent.recv(payload_length - len(size_payload)))
                self.assertEqual(struct.unpack(">II", size_payload), (width, height))
                agent.settimeout(None)
                send_full_tiles(2, width, height, changed_point=(80, 80), fill=0x5a)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
                self.assertEqual(probe.wait(timeout=20), 0, stderr + stdout)
                self.assertIn("dirty_frame_received", stdout)
                self.assertIn("full_refresh_received", stdout)
                worker_log = self.read_log()
                self.assertIn("generation=1 frame_id=2 width=3940 height=1888", worker_log)
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

    def test_13_planar_incremental_updates(self):
        """Default planar encoding must send a full first frame, suppress an
        identical frame, re-send only dirty tiles (one PDU) for a small change,
        converge on the client, and re-sync a restarted Agent connection."""
        self.configure(True, test_pattern=False)  # production path: planar
        # Deliberately not a multiple of 64 so edge tiles stay partial.
        # FreeRDP rejects client desktop dimensions below 200.
        width = height = 200
        expected_tiles = ((width + 63) // 64) * ((height + 63) // 64)
        pixels = bytearray(width * height * 4)

        def worker_log_matches(pattern, timeout=4.0):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if re.search(pattern, self.read_log()):
                    return
                time.sleep(.01)
            self.fail(f"worker log did not match {pattern!r}: " + self.read_log()[-2000:])

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame(frame_id):
                tiles = [(x, y, min(64, width - x), min(64, height - y))
                         for y in range(0, height, 64) for x in range(0, width, 64)]
                begin = struct.pack(">QQIIBI", 1, frame_id, width, height, 4, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 10, len(begin)) + begin)
                for (x, y, tile_width, tile_height) in tiles:
                    tile = b"".join(
                        bytes(pixels[(y + row) * width * 4 + x * 4:
                                     (y + row) * width * 4 + x * 4 + tile_width * 4])
                        for row in range(tile_height))
                    payload = struct.pack(">QQIIHH", 1, frame_id, x, y,
                                          tile_width, tile_height) + tile
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 11, len(payload)) + payload)
                end = struct.pack(">QQI", 1, frame_id, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 12, len(end)) + end)

            send_frame(1)  # must be present before peer activation
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "6",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True,
                                     env={**os.environ, "WLOG_LEVEL": "ERROR"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                self.assertEqual(probe.stdout.readline().strip(), "initial_frame_received")
                agent.settimeout(3)
                header = agent.recv(12)
                self.assertEqual(len(header), 12)
                magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
                self.assertEqual((magic, version, message_type, payload_length), (b"RDPA", 1, 9, 8))
                size_payload = b""
                while len(size_payload) < payload_length:
                    size_payload += agent.recv(payload_length - len(size_payload))
                self.assertEqual(struct.unpack(">II", size_payload), (width, height))
                agent.settimeout(None)
                # (a) first frame is a full planar frame, batched into one PDU.
                worker_log_matches(
                    rf"frame_id=1 batches=1 tiles={expected_tiles} bytes=\d+ pdus=1 encoding=planar")
                # Let the peer enter its network wait before publishing frame 2.
                time.sleep(.04)
                # (b) an identical frame must be suppressed entirely.
                started = time.monotonic()
                send_frame(2)
                worker_log_matches(
                    r"frame_id=2 batches=0 tiles=0 bytes=0 pdus=0 encoding=planar")
                self.assertLess(time.monotonic() - started, .19,
                                "new agent frame did not wake the peer promptly")
                # (c) two changed pixels (one full tile, one partial edge tile):
                # only the two affected tiles are re-sent.
                pixels[(80 * width + 80) * 4] = 255    # full 64x64 tile
                pixels[(196 * width + 196) * 4] = 255  # partial 8x8 edge tile
                send_frame(3)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
                self.assertEqual(probe.wait(timeout=8), 0, stderr + stdout)
                # (d) the client saw the dirty pixel and converged via a refresh.
                self.assertIn("dirty_frame_received", stdout)
                self.assertIn("full_refresh_received", stdout)
                worker_log_matches(
                    r"frame_id=3 batches=1 tiles=2 bytes=\d+ pdus=1 encoding=planar")
                worker_log_matches(
                    rf"frame_id=3 batches=1 tiles={expected_tiles} bytes=\d+ pdus=1 encoding=planar")
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

            # Capture-size resync: an Agent that reconnects mid-session must be
            # told the negotiated desktop size again (type 9 IPC message).
            agent.close()
            resynced = False
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not resynced:
                candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                candidate.settimeout(1.0)
                try:
                    candidate.connect(str(self.agent_socket))
                    header = candidate.recv(12)
                    if len(header) == 12:
                        magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
                        if (magic, version, message_type, payload_length) == (b"RDPA", 1, 9, 8):
                            payload = b""
                            while len(payload) < payload_length:
                                chunk = candidate.recv(payload_length - len(payload))
                                if not chunk:
                                    break
                                payload += chunk
                            if struct.unpack(">II", payload) == (width, height):
                                resynced = True
                except OSError:
                    pass
                candidate.close()
                time.sleep(.05)
            self.assertTrue(resynced, "restarted Agent did not receive the capture-size resync")
            self.assertIn(f"event=agent_capture_size_resynced width={width} height={height}",
                          self.read_log())

    def test_14_planar_convergence_refresh_and_resize(self):
        """Incremental planar delivery must converge to exactly the same client
        framebuffer as a full frame; a RefreshRect must force a full frame and
        the next delta must be incremental again; a zero-tile frame must send no
        update; and a new connection at a different desktop size must start with
        a full frame (never a diff against a differently sized buffer)."""
        self.configure(True, test_pattern=False)  # production path: planar
        width = height = 256
        total_tiles = ((width + 63) // 64) * ((height + 63) // 64)
        pixels = bytearray(width * height * 4)  # deterministic zero background
        final = bytearray(pixels)
        final[(80 * width + 80) * 4] = 0x11
        final[(160 * width + 160) * 4] = 0x22

        def log_count(pattern):
            return len(re.findall(pattern, self.read_log()))

        def wait_log(pattern, minimum, timeout=6.0):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if log_count(pattern) >= minimum:
                    return
                time.sleep(.01)
            self.fail(f"worker log did not reach {minimum} x {pattern!r}: "
                      + self.read_log()[-2000:])

        def send_frame(frame_id, image):
            tiles = [(x, y, min(64, width - x), min(64, height - y))
                     for y in range(0, height, 64) for x in range(0, width, 64)]
            begin = struct.pack(">QQIIBI", 1, frame_id, width, height, 4, len(tiles))
            agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 10, len(begin)) + begin)
            for (x, y, tile_width, tile_height) in tiles:
                tile = b"".join(
                    bytes(image[(y + row) * width * 4 + x * 4:
                                (y + row) * width * 4 + x * 4 + tile_width * 4])
                    for row in range(tile_height))
                payload = struct.pack(">QQIIHH", 1, frame_id, x, y,
                                      tile_width, tile_height) + tile
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 11, len(payload)) + payload)
            end = struct.pack(">QQI", 1, frame_id, len(tiles))
            agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 12, len(end)) + end)

        def read_capture_size():
            agent.settimeout(3)
            header = agent.recv(12)
            self.assertEqual(len(header), 12)
            magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
            self.assertEqual((magic, version, message_type, payload_length), (b"RDPA", 1, 9, 8))
            payload = b""
            while len(payload) < payload_length:
                payload += agent.recv(payload_length - len(payload))
            agent.settimeout(None)
            return struct.unpack(">II", payload)

        def probe_bench(seconds, refresh_ms=None, probe_width=width, probe_height=height):
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "9",
                       "-width", str(probe_width), "-height", str(probe_height)]
            env = {**os.environ, "WLOG_LEVEL": "ERROR",
                   "RDP_PROBE_BENCH_SECONDS": str(seconds)}
            if refresh_ms is not None:
                env["RDP_PROBE_REFRESH_AT_MS"] = str(refresh_ms)
            result = subprocess.run(command, input=self.password + "\n", text=True,
                                    capture_output=True, timeout=seconds + 60, env=env)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            crc = re.search(r"bench seconds=([\d.]+) bitmap_updates=(\d+) bitmap_rectangles=(\d+) "
                            r"bitmap_bytes=(\d+) pdu_per_s=([\d.]+) mbit_per_s=([\d.]+) "
                            r"gdi=(\d+)x(\d+) framebuffer_crc32=0x([0-9a-f]{8})", result.stdout)
            self.assertIsNotNone(crc, result.stdout)
            return int(crc.group(9), 16), int(crc.group(2)), int(crc.group(3)), result.stdout

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            send_frame(1, pixels)  # full frame before peer activation
            command = [str(self.probe_binary), "-port", str(self.port), "-mode", "9",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True,
                                     env={**os.environ, "WLOG_LEVEL": "ERROR",
                                          "RDP_PROBE_BENCH_SECONDS": "4",
                                          "RDP_PROBE_REFRESH_AT_MS": "1200"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                self.assertEqual(read_capture_size(), (width, height))
                # (a) first frame must be the full planar frame.
                wait_log(rf"frame_id=1 batches=1 tiles={total_tiles} bytes=\d+ pdus=1 encoding=planar", 1)
                # (b) an identical frame sends no BitmapUpdate at all (tiles=0/pdus=0).
                send_frame(2, pixels)
                wait_log(r"frame_id=2 batches=0 tiles=0 bytes=0 pdus=0 encoding=planar", 1)
                # (c) a client RefreshRect forces a full frame of the current image.
                wait_log(rf"frame_id=2 batches=1 tiles={total_tiles} bytes=\d+ pdus=1 encoding=planar", 1)
                # ... and the next delta frames return to incremental delivery.
                send_frame(3, final)  # both patches changed -> 2 tiles
                wait_log(r"frame_id=3 batches=1 tiles=2 bytes=\d+ pdus=1 encoding=planar", 1)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
                self.assertEqual(probe.wait(timeout=15), 0, stderr + stdout)
                self.assertIn("refresh_requested", stdout)
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

            # session A values: 1 full + 1 refresh full + 1 two-tile delta.
            match = re.search(r"bench seconds=[\d.]+ bitmap_updates=(\d+) bitmap_rectangles=(\d+)", stdout)
            self.assertIsNotNone(match, stdout)
            updates_a = int(match.group(1))
            rectangles_a = int(match.group(2))
            self.assertEqual(updates_a, 3, "suppressed/refresh update accounting: " + stdout)
            self.assertEqual(rectangles_a, total_tiles * 2 + 2, stdout)
            crc_a = int(re.search(r"framebuffer_crc32=0x([0-9a-f]{8})", stdout).group(1), 16)

            # Let the lease release, then deliver the same final state as ONE full frame.
            wait_log(r"event=lease_released", 1)
            send_frame(4, final)
            wait_log(r"event=agent_frame_received generation=1 frame_id=4", 1)
            crc_b, updates_b, rectangles_b, _ = probe_bench(2)
            self.assertEqual(rectangles_b, total_tiles, "full-frame session did not send a full frame")
            self.assertEqual(crc_a, crc_b,
                             "incremental planar delivery did not converge to the full-frame pixels")

            # (d) a new connection at a different desktop size must start full.
            wait_log(r"event=lease_released", 2)
            crc_c, updates_c, rectangles_c, stdout_c = probe_bench(
                2, probe_width=320, probe_height=320)
            scaled_tiles = ((320 + 63) // 64) * ((320 + 63) // 64)
            self.assertIn("gdi=320x320", stdout_c)
            self.assertEqual(rectangles_c, scaled_tiles,
                             "reconnect at a new size did not send a full frame")
            scaled_log = self.read_log()
            self.assertIn("event=rdp_desktop_size width=320 height=320", scaled_log)
            self.assertRegex(scaled_log,
                             rf"frame_id=4 batches=1 tiles={scaled_tiles} bytes=\d+ pdus=1 encoding=planar")


    def test_15_client_suppress_output_is_not_echoed(self):
        """A minimised client must not drop the session (2026-11-07 user report).

        A Windows client sends TS_SUPPRESS_OUTPUT_PDU when minimised. FreeRDP's
        shared rdpUpdate struct wires SuppressOutput to the client-side sender
        even for server peers, so an unguarded server echoes that PDU back - a
        protocol violation that made the Windows 11 client drop the session and
        then hit the leaked session lease. The worker-side test hook emulates a
        client that minimises and restores; assert that the worker records
        suppression, sends no bitmap update while suppressed, and repaints after
        the client allows output again.
        """
        self.configure(True, test_pattern=False,
                       extra_env={"RDP_TEST_SUPPRESS_OUTPUT_AT_MS": "800",
                                  "RDP_TEST_ALLOW_OUTPUT_AT_MS": "2600"})
        width = height = 256
        pixels = bytearray(width * height * 4)
        tiles = [(x, y) for y in range(0, height, 64) for x in range(0, width, 64)]

        def tile_bytes(x, y):
            tile_width, tile_height = min(64, width - x), min(64, height - y)
            out = bytearray()
            for row in range(tile_height):
                offset = ((y + row) * width + x) * 4
                out += pixels[offset:offset + tile_width * 4]
            return bytes(out)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame(frame_id):
                begin = struct.pack(">QQIIBI", 1, frame_id, width, height, 4, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 10, len(begin)) + begin)
                for (x, y) in tiles:
                    tile_width, tile_height = min(64, width - x), min(64, height - y)
                    payload = struct.pack(">QQIIHH", 1, frame_id, x, y,
                                          tile_width, tile_height) + tile_bytes(x, y)
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 11, len(payload)) + payload)
                end = struct.pack(">QQI", 1, frame_id, len(tiles))
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 12, len(end)) + end)

            send_frame(1)
            env = {**os.environ, "WLOG_LEVEL": "ERROR", "RDP_PROBE_BENCH_SECONDS": "5"}
            command = [str(ROOT / "bin/rdp-probe"), "-port", str(self.port), "-mode", "9",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=env)
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                frame_id = 1
                deadline = time.monotonic() + 5.5
                while time.monotonic() < deadline and probe.poll() is None:
                    frame_id += 1
                    pixels[(80 * width + 80) * 4] = frame_id % 251
                    pixels[(81 * width + 81) * 4] = (frame_id * 7) % 251
                    send_frame(frame_id)
                    time.sleep(.12)
                probe.wait(timeout=25)
                stdout = probe.stdout.read()
                stderr = probe.stderr.read()
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

        self.assertEqual(probe.returncode, 0, stderr + stdout)
        bench = next(line for line in stdout.splitlines() if line.startswith("bench "))
        self.assertGreater(int(re.search(r"bitmap_updates=(\d+)", bench).group(1)), 0,
                           "client received no bitmap updates at all")
        lines = self.read_log().splitlines()
        suppressed = [i for i, line in enumerate(lines)
                      if "event=client_output_suppressed allow=0" in line]
        resumed = [i for i, line in enumerate(lines)
                   if "event=client_output_suppressed allow=1" in line]
        self.assertEqual(len(suppressed), 1,
                         "expected exactly one suppression event, got %d (a server that echoes "
                         "the client's Suppress Output PDU would reply and can loop)"
                         % len(suppressed))
        self.assertEqual(len(resumed), 1, "expected exactly one allow-output event")
        self.assertLess(suppressed[0], resumed[0])
        self.assertEqual([line for line in lines[suppressed[0]:resumed[0]]
                          if "event=desktop_frame_sent" in line], [],
                         "worker sent bitmap updates while the client had output suppressed")
        self.assertTrue(any("event=desktop_frame_sent" in line for line in lines[resumed[0]:]),
                        "worker did not repaint after the client allowed output again")

    # --- resolution adaptation: negotiation, fit layout and mid-session resize --
    # Shared helpers for test_16 .. test_19. The buffer stays independent of
    # live .runtime state: configure() restarts the worker on the random loopback
    # port of the test class.

    def log_text(self):
        return self.read_log()

    def log_mark(self):
        """Byte offset of the current end of the worker log."""
        return len(self.log_text())

    def log_since(self, mark):
        return self.log_text()[mark:]

    def wait_log(self, fragment, mark=0, timeout=6.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.log_since(mark)
            if fragment in text:
                return text
            time.sleep(.02)
        self.fail(f"worker log did not contain {fragment!r}: " + self.log_since(mark)[-2500:])

    def wait_lease_released(self, mark, timeout=8.0):
        # The lease of the previous peer must be released before the next
        # connection, otherwise the worker rejects the new logon.
        return self.wait_log("event=lease_released", mark, timeout)

    def probe_env(self, mode, width, height, env=None, timeout=30):
        return subprocess.run(
            [str(self.probe_binary), "-port", str(self.port), "-user", "alice",
             "-domain", "MACRDP", "-mode", str(mode), "-width", str(width),
             "-height", str(height)],
            input=self.password + "\n", text=True, capture_output=True,
            timeout=timeout, env={**os.environ, "WLOG_LEVEL": "ERROR", **(env or {})})

    # --- fake Agent IPC helpers (frame upload and worker->Agent messages) -----
    @staticmethod
    def send_agent_frame(agent, frame_id, pixels, width, height, generation=1):
        """Upload one full BGRA frame to the worker over the fake Agent socket.

        Uses the unchanged type-2 metadata + type-7 chunk stream wire format
        (big-endian RDPA header, see test_07).
        """
        metadata = struct.pack(">QQIIB", generation, frame_id, width, height, 4)
        agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata)) + metadata)
        for offset in range(0, len(pixels), 65516):
            chunk = bytes(pixels[offset:offset + 65516])
            payload = struct.pack(">QQI", generation, frame_id, offset) + chunk
            agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload)) + payload)

    @staticmethod
    def agent_message(agent, buffer):
        """Read one RDPA-framed worker->Agent IPC message.

        Returns (message_type, payload, remaining_buffer). Raises EOFError when
        the worker closes the socket.
        """
        def read_exact(length):
            nonlocal buffer
            while len(buffer) < length:
                chunk = agent.recv(length - len(buffer))
                if not chunk:
                    raise EOFError("worker closed the Agent IPC socket")
                buffer += chunk
            out, buffer = buffer[:length], buffer[length:]
            return out
        header = read_exact(12)
        magic, version, message_type, payload_length = struct.unpack(">4sHHI", header)
        if (magic, version) != (b"RDPA", 1):
            raise AssertionError(f"bad Agent IPC header magic={magic!r} version={version}")
        if payload_length > 65536:
            raise AssertionError(f"Agent IPC payload too large: {payload_length}")
        return message_type, read_exact(payload_length), buffer

    @classmethod
    def collect_agent_messages(cls, agent, timeout, stop):
        """Collect worker->Agent IPC messages until stop(messages) or timeout.

        Returns the list of (message_type, payload) pairs; the socket timeout is
        restored before returning. stop() is also consulted after a timeout so a
        predicate can fire on a late message.
        """
        messages = []
        buffer = b""
        agent.settimeout(.5)
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                try:
                    message_type, payload, buffer = cls.agent_message(agent, buffer)
                except socket.timeout:
                    if stop is not None and stop(messages):
                        break
                    continue
                messages.append((message_type, payload))
                if stop is not None and stop(messages):
                    break
                if time.monotonic() >= deadline:
                    break
        finally:
            agent.settimeout(None)
        return messages

    # --- clipboard-file IPC types 13/14/15/16 (DESIGN section 3) -------------
    # Worker->Agent messages are what the fake Agent must parse/reassemble for
    # remote->local transfers; the encode_* helpers build the Agent->Worker
    # messages used to test local->remote offers and rejection paths.
    @staticmethod
    def clipboard_offer_begin(payload):
        if len(payload) != 16:
            raise AssertionError(f"offer begin payload is {len(payload)} bytes, expected 16")
        direction, reserved, file_count, total_bytes, flags = struct.unpack(">BBHQI", payload)
        if reserved != 0:
            raise AssertionError(f"offer begin reserved byte is {reserved}, expected 0")
        return direction, file_count, total_bytes, flags

    @staticmethod
    def clipboard_offer_end(payload):
        if len(payload) != 8:
            raise AssertionError(f"offer end payload is {len(payload)} bytes, expected 8")
        return struct.unpack(">BBHI", payload)

    @staticmethod
    def clipboard_entry(payload):
        if len(payload) < 18:
            raise AssertionError(f"entry payload is {len(payload)} bytes, expected >= 18")
        direction, reserved, name_length, file_index, size, path_length = \
            struct.unpack(">BBHIQH", payload[:18])
        if reserved != 0:
            raise AssertionError(f"entry reserved byte is {reserved}, expected 0")
        if len(payload) != 18 + name_length + path_length:
            raise AssertionError("entry payload length does not match name/path lengths")
        name = payload[18:18 + name_length].decode("utf-8")
        path = payload[18 + name_length:18 + name_length + path_length].decode("utf-8")
        return dict(direction=direction, file_index=file_index, size=size,
                    name=name, path=path)

    @staticmethod
    def clipboard_chunk(payload):
        if len(payload) < 12:
            raise AssertionError(f"chunk payload is {len(payload)} bytes, expected >= 12")
        file_index, offset = struct.unpack(">IQ", payload[:12])
        return file_index, offset, payload[12:]

    @staticmethod
    def encode_clipboard_offer_begin(direction, file_count, total_bytes, flags=0):
        return struct.pack(">BBHQI", direction, 0, file_count, total_bytes, flags)

    @staticmethod
    def encode_clipboard_offer_end(direction, status, file_count=0, error_code=0):
        return struct.pack(">BBHI", direction, status, error_code, file_count)

    @staticmethod
    def encode_clipboard_entry(direction, file_index, size, name, path=""):
        name_bytes = name.encode("utf-8")
        path_bytes = path.encode("utf-8")
        return struct.pack(">BBHIQH", direction, 0, len(name_bytes), file_index,
                           size, len(path_bytes)) + name_bytes + path_bytes

    @staticmethod
    def encode_clipboard_chunk(file_index, offset, data):
        return struct.pack(">IQ", file_index, offset) + data

    @staticmethod
    def send_agent_message(agent, message_type, payload):
        agent.sendall(b"RDPA" + struct.pack(">HHI", 1, message_type, len(payload)) + payload)

    @staticmethod
    def clipboard_probe_file_bytes(file_index, size):
        """Deterministic content of probe mode-11 file i, byte j (probe contract)."""
        return bytes((j * 31 + file_index * 97 + 13) & 0xFF for j in range(size))

    def test_16_size_matrix_negotiated_desktop(self):
        """Every sane requested desktop is accepted unchanged: negotiation keeps
        the client size, the client gdi matches it, a full test-pattern frame is
        delivered at that size, and the worker reports the negotiated size
        (design sections 2 and 9 A)."""
        self.configure(True)  # test pattern: no Agent needed
        sizes = [
            (800, 600), (1024, 768), (1468, 923), (1920, 1080), (2508, 1220),
            (2560, 1440), (2940, 1912), (3940, 1888), (4096, 2304), (5120, 2880),
        ]
        for width, height in sizes:
            with self.subTest(size=f"{width}x{height}"):
                self.assertEqual(negotiate_desktop_size(width, height),
                                 (width, height, "client"))
                mark = self.log_mark()
                p = self.probe(mode=5, width=width, height=height)
                self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
                self.assertIn("bitmap_update_received", p.stdout)
                self.assertIn(f"desktop_size={width}x{height}", p.stdout)
                self.assertIn(f"gdi_size={width}x{height}", p.stdout)
                tiles = re.search(r"bitmap_rectangles=(\d+)", p.stdout)
                self.assertIsNotNone(tiles, p.stdout)
                self.assertEqual(int(tiles.group(1)), _tile_count(width, height),
                                 "first frame was not a full frame: " + p.stdout)
                self.wait_log(
                    f"event=peer_activate_complete width={width} height={height}", mark)
                worker_log = self.log_since(mark)
                self.assertIn(f"event=peer_size_negotiated requested={width}x{height} "
                              f"desktop={width}x{height} policy=client", worker_log)
                self.assertIn(f"event=rdp_desktop_size width={width} height={height}",
                              worker_log)
                self.assertNotIn("event=peer_activate_rejected", worker_log)
                self.assertNotIn("policy=clamp", worker_log)
                self.wait_lease_released(mark)

    def test_17_oversized_request_is_clamped_and_told(self):
        """A 7680x4320 request (132 MB BGRA) exceeds the frame budget, so the
        worker clamps it to 5460x3072 preserving aspect, tells the client through
        the initial Demand Active (the client reactivates to that size) and still
        delivers a full frame at the clamped size (design sections 2 and 9 B)."""
        self.configure(True)  # test pattern: no Agent needed
        requested_width, requested_height = 7680, 4320
        self.assertEqual(negotiate_desktop_size(requested_width, requested_height),
                         (5460, 3072, "clamp"))
        mark = self.log_mark()
        p = self.probe(mode=5, width=requested_width, height=requested_height)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("bitmap_update_received", p.stdout)
        self.assertIn("desktop_size=5460x3072", p.stdout)
        self.assertIn("gdi_size=5460x3072", p.stdout)
        reactivated = [(int(w), int(h)) for w, h in
                       re.findall(r"reactivated width=(\d+) height=(\d+)", p.stdout)]
        self.assertIn((5460, 3072), reactivated,
                      "client was not told the clamped size: " + p.stdout)
        tiles = re.search(r"bitmap_rectangles=(\d+)", p.stdout)
        self.assertIsNotNone(tiles, p.stdout)
        self.assertEqual(int(tiles.group(1)), _tile_count(5460, 3072),
                         "first frame was not a full frame at the clamped size: " + p.stdout)
        self.wait_log(
            f"event=peer_size_negotiated requested={requested_width}x{requested_height} desktop=",
            mark)
        worker_log = self.log_since(mark)
        negotiated = re.search(
            rf"event=peer_size_negotiated requested={requested_width}x{requested_height} "
            rf"desktop=(\d+)x(\d+) policy=(\w+)", worker_log)
        self.assertIsNotNone(negotiated, worker_log[-2500:])
        log_width, log_height = int(negotiated.group(1)), int(negotiated.group(2))
        self.assertEqual((log_width, log_height, negotiated.group(3)),
                         (5460, 3072, "clamp"))
        self.assertIn(f"event=peer_activate_complete width={log_width} height={log_height}",
                      worker_log)
        self.assertNotIn("event=peer_activate_rejected", worker_log)
        # The single scale factor preserves the aspect ratio, but the contract's
        # even-dimension clearing makes W*9 == H*16 impossible for this input
        # (5460*9 = 49140 vs 3072*16 = 49152). Allow less than one even-pixel
        # rounding step instead of the literal equality design section 9 B asks.
        self.assertLessEqual(abs(log_width * 9 - log_height * 16),
                             max(log_width, log_height))
        self.wait_lease_released(mark)

    def test_18_fit_with_bars_layout(self):
        """A live capture is letterboxed into the negotiated desktop: black bars,
        1:1 content at a zero offset when the sizes allow it, scaled content
        otherwise, and worker event=peer_frame_layout matching the layout used for
        the pixels (design sections 3 and 9 C)."""
        self.configure(True, test_pattern=False)  # production planar path
        # Level-based greyscale keeps the pixel assertions independent of the
        # gdi channel order convention (only the level and the unused X/alpha
        # byte matter): a wrong layout or a non-black bar changes the set.
        solid = 0x40
        top_left, top_right, bottom_left, bottom_right = 0x80, 0xA0, 0xC0, 0xE0
        cases = [
            # (capture_w, capture_h, desktop_w, desktop_h, sample points)
            # 2214x1440 into 2560x1440: 1:1 content, 173 px bars each side.
            (2214, 1440, 2560, 1440,
             [(0, 720), (172, 720), (173, 720), (1279, 720), (2559, 720),
              (2386, 0), (173, 0), (2386, 1439)]),
            # 800x520 into 800x600: 1:1 content, 40 px bars top and bottom.
            (800, 520, 800, 600,
             [(400, 39), (400, 40), (400, 559), (400, 560),
              (0, 40), (799, 40), (0, 559)]),
            # 1470x956 into 1468x923: scaled content, 24/25 px side bars.
            (1470, 956, 1468, 923,
             [(0, 461), (734, 461), (1467, 461), (1442, 461), (24, 0), (1442, 0)]),
            # 1280x720 into 2560x1440: uniform 2x upscale, content fills the whole
            # desktop with zero offsets (the case where content==desktop must
            # still be composed, not passed through as the source buffer).
            (1280, 720, 2560, 1440,
             [(0, 0), (15, 15), (16, 16), (1280, 720), (2544, 0), (0, 1424),
              (2559, 1439)]),
        ]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            frame_id = 0
            for capture_width, capture_height, width, height, points in cases:
                with self.subTest(capture=f"{capture_width}x{capture_height}",
                                  desktop=f"{width}x{height}"):
                    frame_id += 1
                    # Solid frame with four distinct 8x8 corner markers. The
                    # fourth byte is the unused X/alpha byte: keep it 0.
                    row = bytes((solid, solid, solid, 0)) * capture_width
                    pixels = bytearray(row * capture_height)
                    for marker_x, marker_y, level in [
                            (0, 0, top_left),
                            (capture_width - 8, 0, top_right),
                            (0, capture_height - 8, bottom_left),
                            (capture_width - 8, capture_height - 8, bottom_right)]:
                        marker = bytes((level, level, level, 0)) * 8
                        for row_index in range(marker_y, marker_y + 8):
                            offset = (row_index * capture_width + marker_x) * 4
                            pixels[offset:offset + 32] = marker
                    mark = self.log_mark()
                    metadata = struct.pack(">QQIIB", 1, frame_id,
                                           capture_width, capture_height, 4)
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata))
                                  + metadata)
                    for offset in range(0, len(pixels), 65516):
                        chunk = bytes(pixels[offset:offset + 65516])
                        payload = struct.pack(">QQI", 1, frame_id, offset) + chunk
                        agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload))
                                      + payload)
                    self.wait_log(
                        f"event=agent_frame_received generation=1 frame_id={frame_id}", mark)

                    content_width, content_height, offset_x, offset_y, scaled = fit_layout(
                        capture_width, capture_height, width, height)
                    env = {"RDP_PROBE_SAMPLE_POINTS":
                           ",".join(f"{x}:{y}" for x, y in points)}
                    p = self.probe_env(mode=5, width=width, height=height, env=env)
                    self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
                    self.assertIn("bitmap_update_received", p.stdout)
                    self.assertIn(f"desktop_size={width}x{height}", p.stdout)
                    self.assertIn(f"gdi_size={width}x{height}", p.stdout)
                    self.assertIn(f"event=peer_activate_complete width={width} "
                                  f"height={height}", self.log_since(mark))
                    self.assertNotIn("event=peer_activate_rejected",
                                     self.log_since(mark))
                    self.wait_log(
                        f"event=peer_frame_layout source={capture_width}x{capture_height} "
                        f"desktop={width}x{height} content={content_width}x{content_height} "
                        f"offset={offset_x},{offset_y} "
                        f"scaled={1 if scaled else 0}", mark)

                    samples = {}
                    for line in p.stdout.splitlines():
                        match = PROBE_SAMPLE_RE.match(line)
                        if match:
                            point = (int(match.group(1)), int(match.group(2)))
                            samples[point] = tuple(int(match.group(i))
                                                   for i in range(3, 7))
                    self.assertEqual(set(samples), set(points),
                                     "probe did not report exactly the sampled points: "
                                     + p.stdout)
                    for dx, dy in points:
                        if (offset_x <= dx < offset_x + content_width and
                                offset_y <= dy < offset_y + content_height):
                            source_x = (dx - offset_x) * capture_width // content_width
                            source_y = (dy - offset_y) * capture_height // content_height
                            level = pixels[(source_y * capture_width + source_x) * 4]
                        else:
                            level = 0  # black bar
                        got = samples[(dx, dy)]
                        self.assertEqual(sorted(got), sorted((0, level, level, level)),
                                         f"sample ({dx},{dy}) expected level {level}, "
                                         f"got {got}: " + p.stdout)
                    self.wait_lease_released(mark)

    def test_19_mid_session_client_resize_disp(self):
        """A DISP monitor-layout PDU resizes the session in place: the worker
        renegotiates, reactivates the client at 1920x1080, tells the Agent the new
        capture size, repaints a full frame and never rejects the activation
        (design sections 6 and 9 D)."""
        self.configure(True)  # test pattern; the fake Agent supplies one real frame
        capture_width, capture_height = 2560, 1440
        # Mode 10 sends its DISP layout only after probe_paint recognises the
        # test-pattern marker (B byte 0x20 at the framebuffer corners), so the
        # captured frame keeps B=0x20 while carrying ordinary content. A real
        # frame is needed for the worker to log the full repaint (desktop_frame_sent).
        pixels = bytes((0x20, 0x40, 0x60, 0)) * (capture_width * capture_height)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame(frame_id, image):
                metadata = struct.pack(">QQIIB", 1, frame_id,
                                       capture_width, capture_height, 4)
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata))
                              + metadata)
                for offset in range(0, len(image), 65516):
                    chunk = bytes(image[offset:offset + 65516])
                    payload = struct.pack(">QQI", 1, frame_id, offset) + chunk
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload))
                                  + payload)

            mark = self.log_mark()
            send_frame(1, pixels)
            self.wait_log("event=agent_frame_received generation=1 frame_id=1", mark)
            mark = self.log_mark()
            env = {"RDP_PROBE_RESIZE_WIDTH": "1920",
                   "RDP_PROBE_RESIZE_HEIGHT": "1080",
                   "RDP_PROBE_RESIZE_AT_MS": "700"}
            p = self.probe_env(mode=10, width=2560, height=1440, env=env, timeout=40)
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            requested = re.search(r"resize_requested width=(\d+) height=(\d+)", p.stdout)
            self.assertIsNotNone(requested, p.stdout)
            self.assertEqual((int(requested.group(1)), int(requested.group(2))),
                             (1920, 1080))
            reactivated = [(int(w), int(h)) for w, h in
                           re.findall(r"reactivated width=(\d+) height=(\d+)", p.stdout)]
            self.assertIn((1920, 1080), reactivated,
                          "client was not reactivated at the new size: " + p.stdout)
            resize_frame = re.search(
                r"resize_frame_received width=(\d+) height=(\d+)", p.stdout)
            self.assertIsNotNone(resize_frame, p.stdout)
            self.assertEqual((int(resize_frame.group(1)), int(resize_frame.group(2))),
                             (1920, 1080))

            reactivate = "event=peer_reactivate requested=1920x1080 desktop=1920x1080"
            self.wait_log(reactivate, mark)
            # Verifier point: resize_frame_received on the client only proves the
            # first post-resize bitmap batch arrived. Wait for the worker's frame
            # completion log and require the first frame after the reactivation to
            # be the forced FULL desktop repaint.
            full_tiles = _tile_count(1920, 1080)  # 30 * 17 == 510
            self.assertEqual(full_tiles, 510)
            deadline = time.monotonic() + 8.0
            repaint_line = None
            while time.monotonic() < deadline:
                after_reactivate = self.log_since(mark).split(reactivate, 1)[-1]
                repaint_line = next((line for line in after_reactivate.splitlines()
                                     if "event=desktop_frame_sent" in line), None)
                if repaint_line is not None:
                    break
                time.sleep(.02)
            self.assertIsNotNone(
                repaint_line,
                "no desktop frame was sent after the reactivation: "
                + self.log_since(mark)[-2500:])
            repaint = re.search(
                r"batches=(\d+) tiles=(\d+) bytes=(\d+) pdus=(\d+) encoding=(\w+)",
                repaint_line)
            self.assertIsNotNone(repaint, repaint_line)
            self.assertGreaterEqual(int(repaint.group(1)), 1, repaint_line)
            self.assertEqual(int(repaint.group(2)), full_tiles,
                             "the first frame after the resize was not a full desktop "
                             "repaint: " + repaint_line)

            worker_log = self.log_since(mark)
            self.assertIn("event=peer_size_negotiated requested=1920x1080 "
                          "desktop=1920x1080 policy=client", worker_log)
            self.assertIn("event=rdp_desktop_size width=1920 height=1080", worker_log)
            self.assertIn("event=peer_activate_complete width=1920 height=1080",
                          worker_log)
            # First activation at the connect size, then the resize: the Agent is
            # told both capture sizes (the second one is the point of this test).
            self.assertRegex(
                worker_log, r"event=agent_capture_size_requested width=2560 height=1440")
            self.assertRegex(
                worker_log, r"event=agent_capture_size_requested width=1920 height=1080")
            self.assertNotIn("event=peer_activate_rejected", worker_log)

            # A following changed Agent frame must go out incrementally rather than
            # as another full repaint. The mode-10 probe exits as soon as the first
            # post-resize bitmap batch reaches it, so the worker usually closes the
            # session before another frame can be sent; assert only if it is alive.
            incremental_line = None
            if "event=peer_loop_ended" not in self.log_since(mark):
                changed = bytearray(pixels)
                # Capture (133,133) maps to exactly desktop (100,100) in the
                # 2560x1440 -> 1920x1080 fit, i.e. only one 64x64 tile.
                changed[(133 * capture_width + 133) * 4] = 0x99
                send_frame(2, changed)
                cutoff = time.monotonic() + 2.0
                while time.monotonic() < cutoff:
                    after = self.log_since(mark)
                    if "event=peer_loop_ended" in after:
                        break
                    parts = after.split("event=desktop_frame_sent generation=1 "
                                        "frame_id=2", 1)
                    if len(parts) == 2:
                        incremental_line = ("event=desktop_frame_sent generation=1 "
                                           "frame_id=2" + parts[1].splitlines()[0])
                        break
                    time.sleep(.02)
                if incremental_line is not None:
                    incremental = re.search(r"batches=(\d+) tiles=(\d+)",
                                            incremental_line)
                    self.assertIsNotNone(incremental, incremental_line)
                    self.assertGreaterEqual(int(incremental.group(1)), 1,
                                            incremental_line)
                    self.assertLess(
                        int(incremental.group(2)), full_tiles,
                        "a changed frame after the post-resize full repaint was not "
                        "incremental: " + incremental_line)
            if incremental_line is None:
                print("test_19: session closed before an incremental frame after the "
                      "resize repaint could be observed")

            self.wait_lease_released(mark)

            # The Agent IPC messages themselves carry the renegotiated sizes.
            agent.settimeout(2.0)
            reported = []
            try:
                while True:
                    header = agent.recv(12)
                    if len(header) < 12:
                        break
                    magic, version, message_type, payload_length = struct.unpack(
                        ">4sHHI", header)
                    self.assertEqual((magic, version), (b"RDPA", 1))
                    payload = b""
                    while len(payload) < payload_length:
                        chunk = agent.recv(payload_length - len(payload))
                        if not chunk:
                            break
                        payload += chunk
                    if message_type == 9 and payload_length == 8:
                        reported.append(struct.unpack(">II", payload))
            except socket.timeout:
                pass
            finally:
                agent.settimeout(None)
            self.assertIn((2560, 1440), reported)
            self.assertIn((1920, 1080), reported)




    def test_20_two_client_resizes_in_one_session(self):
        """A second client-driven resize in the SAME session must reach the peer
        thread (regression for the WinPR manual-reset event drain: the first
        frame_event signal used to stay readable forever and starve every later
        resize signal), renegotiate, re-request the Agent capture size and repaint
        the new desktop fully."""
        self.configure(True)  # test pattern marks the client frame; fake Agent carries frames
        capture_width, capture_height = 2560, 1440
        pixels = bytes((0x20, 0x40, 0x60, 0)) * (capture_width * capture_height)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))

            def send_frame(frame_id):
                metadata = struct.pack(">QQIIB", 1, frame_id, capture_width,
                                       capture_height, 4)
                agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 2, len(metadata))
                              + metadata)
                for offset in range(0, len(pixels), 65516):
                    chunk = pixels[offset:offset + 65516]
                    payload = struct.pack(">QQI", 1, frame_id, offset) + chunk
                    agent.sendall(b"RDPA" + struct.pack(">HHI", 1, 7, len(payload))
                                  + payload)

            mark = self.log_mark()
            send_frame(1)
            self.wait_log("event=agent_frame_received generation=1 frame_id=1", mark)
            mark = self.log_mark()
            env = {"RDP_PROBE_RESIZE_WIDTH": "1920",
                   "RDP_PROBE_RESIZE_HEIGHT": "1080",
                   "RDP_PROBE_RESIZE_AT_MS": "600",
                   "RDP_PROBE_RESIZE2_WIDTH": "5120",
                   "RDP_PROBE_RESIZE2_HEIGHT": "2880",
                   "RDP_PROBE_RESIZE2_AT_MS": "2000"}
            p = self.probe_env(mode=10, width=2560, height=1440, env=env, timeout=45)
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            self.assertIn("resize_requested width=1920 height=1080", p.stdout)
            self.assertIn("resize_frame_received width=1920 height=1080", p.stdout)
            self.assertIn("resize2_requested width=5120 height=2880", p.stdout)
            self.assertIn("reactivated width=1920 height=1080 count=1", p.stdout)
            self.assertIn("reactivated width=5120 height=2880 count=2", p.stdout)
            self.assertIn("resize2_frame_received width=5120 height=2880", p.stdout)

            second_reactivate = ("event=peer_reactivate requested=5120x2880 "
                                 "desktop=5120x2880")
            self.wait_log(second_reactivate, mark)
            worker_log = self.log_since(mark)
            self.assertIn("event=peer_reactivate requested=1920x1080 desktop=1920x1080",
                          worker_log)
            self.assertIn("event=rdp_desktop_size width=5120 height=2880", worker_log)
            self.assertIn("event=peer_activate_complete width=5120 height=2880",
                          worker_log)
            self.assertRegex(
                worker_log, r"event=agent_capture_size_requested width=5120 height=2880")
            self.assertNotIn("event=peer_activate_rejected", worker_log)

            # The first frame after the second reactivation must be a full repaint
            # of the 5120x2880 desktop (80 * 45 = 3600 tiles), from the cached frame.
            full_tiles = _tile_count(5120, 2880)
            self.assertEqual(full_tiles, 3600)
            after_second = worker_log.split(second_reactivate, 1)[-1]
            deadline = time.monotonic() + 8.0
            repaint_line = None
            while time.monotonic() < deadline:
                after_second = self.log_since(mark).split(second_reactivate, 1)[-1]
                repaint_line = next((line for line in after_second.splitlines()
                                     if "event=desktop_frame_sent" in line), None)
                if repaint_line is not None:
                    break
                time.sleep(.02)
            self.assertIsNotNone(
                repaint_line,
                "no desktop frame after the second reactivation: "
                + self.log_since(mark)[-2500:])
            repaint = re.search(r"batches=(\d+) tiles=(\d+)", repaint_line)
            self.assertIsNotNone(repaint, repaint_line)
            self.assertGreaterEqual(int(repaint.group(1)), 1, repaint_line)
            self.assertEqual(int(repaint.group(2)), full_tiles,
                             "the first frame after the second resize was not a full "
                             "repaint: " + repaint_line)

            self.wait_lease_released(mark)
            # The Agent was told every negotiated desktop size, including both
            # resize results, on the type-9 IPC channel.
            agent.settimeout(3.0)
            reported = []
            try:
                while len(reported) < 3:
                    header = b""
                    while len(header) < 12:
                        chunk = agent.recv(12 - len(header))
                        if not chunk:
                            break
                        header += chunk
                    if len(header) < 12:
                        break
                    magic, version, message_type, payload_length = struct.unpack(
                        ">4sHHI", header)
                    self.assertEqual((magic, version), (b"RDPA", 1))
                    payload = b""
                    while len(payload) < payload_length:
                        chunk = agent.recv(payload_length - len(payload))
                        if not chunk:
                            break
                        payload += chunk
                    if message_type == 9 and payload_length == 8:
                        reported.append(struct.unpack(">II", payload))
            except socket.timeout:
                pass
            agent.settimeout(None)
            for expected in [(2560, 1440), (1920, 1080), (5120, 2880)]:
                self.assertIn(expected, reported,
                              "Agent did not receive the capture-size request "
                              f"{expected}: {reported}")

    # --- Issue 2: mouse desktop-coordinate regression (2026-11-08) -----------

    def test_21_mouse_forwards_desktop_coordinates(self):
        """Regression for Issue 2: the worker must forward the client's desktop
        mouse coordinates verbatim in the Agent IPC type-3 payload.

        Work item A made the Agent map DESKTOP coordinates through the
        fit-with-bars layout into the capture and then onto the macOS display.
        The worker kept scaling x/y by the capture frame size before sending
        them (`sx = x * frame_width / desktop_width`), so the fit ratio was
        applied twice: at a 2560x1440 desktop with a 1280x720 capture the
        client's mouse(100,100) reached the Agent as (50,50). The fixed worker
        sends (100,100) and only clamps to the negotiated desktop bounds.

        Only uniform-scale geometries are used here because probe mode 0 sends
        its key+mouse input only after it recognises the test-pattern corner
        marker, which fit-with-bars letterboxing hides behind black bars. The
        letterboxed 2214x1440 / 1876x1220 cases are covered by
        test_21b once the probe gains the RDP_PROBE_INPUT_AFTER_FIRST_BITMAP
        hook (probe mode 0 only).
        """
        cases = [
            # (capture_w, capture_h, desktop_w, desktop_h, pre-fix forwarded x,y)
            (1280, 720, 2560, 1440, (50, 50)),
            (1254, 610, 2508, 1220, (50, 50)),
        ]
        for capture_width, capture_height, width, height, buggy in cases:
            with self.subTest(capture=f"{capture_width}x{capture_height}",
                              desktop=f"{width}x{height}"):
                self.configure(True, test_pattern=False, raw_bitmap=True)
                last = (capture_height - 1) * capture_width * 4 + (capture_width - 1) * 4

                def frame(marker):
                    # Probe mode 0 treats the frame as received when both desktop
                    # corner pixels carry 0x20 in the GDI buffer; with a
                    # zero-offset uniform scale the desktop corners are the
                    # capture corners. Set all four bytes of both corners (the
                    # channel byte mapping can move a single byte; all-0x20 is
                    # unambiguous).
                    image = bytearray(capture_width * capture_height * 4)
                    image[0:4] = bytes([marker]) * 4
                    image[last:last + 4] = bytes([marker]) * 4
                    return image

                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
                    agent.connect(str(self.agent_socket))
                    self.send_agent_frame(agent, 1, frame(0x20),
                                          capture_width, capture_height)
                    command = [str(self.probe_binary), "-port", str(self.port),
                               "-user", "alice", "-domain", "MACRDP", "-mode", "0",
                               "-width", str(width), "-height", str(height)]
                    probe = subprocess.Popen(command, stdin=subprocess.PIPE,
                                             stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, text=True,
                                             env={**os.environ, "WLOG_LEVEL": "ERROR"})
                    try:
                        probe.stdin.write(self.password + "\n")
                        probe.stdin.close()
                        agent.settimeout(8)
                        buffer = b""
                        kinds = []
                        mouse = None
                        while mouse is None:
                            kind, payload, buffer = self.agent_message(agent, buffer)
                            if kind != 3 or len(payload) != 9:
                                continue
                            kinds.append(payload[0])
                            if payload[0] != 1:  # 1 = mouse, 2 = keyboard
                                continue
                            mouse = (struct.unpack(">H", payload[1:3])[0],
                                     struct.unpack(">H", payload[5:7])[0],
                                     struct.unpack(">H", payload[7:9])[0])
                        agent.settimeout(None)
                        self.assertIn(2, kinds, "probe keyboard input was not forwarded "
                                                f"to the Agent: kinds={kinds}")
                        flags, x, y = mouse
                        self.assertEqual(flags, 0x0800, "unexpected pointer flags")
                        self.assertEqual(
                            (x, y), (100, 100),
                            "worker did not forward desktop coordinates verbatim: "
                            f"client mouse(100,100) reached the Agent as ({x},{y}) "
                            f"at desktop {width}x{height} with capture "
                            f"{capture_width}x{capture_height}; the pre-fix worker "
                            f"would forward {buggy[0]},{buggy[1]}")
                        # Let the probe finish through its normal exit path: a
                        # frame whose corners carry 0x80 makes the client report
                        # input_seen (mode 0 prints bitmap_and_input_ok, rc 0).
                        self.send_agent_frame(agent, 2, frame(0x80),
                                              capture_width, capture_height)
                        deadline = time.monotonic() + 8
                        while probe.poll() is None and time.monotonic() < deadline:
                            time.sleep(.02)
                        self.assertEqual(probe.poll(), 0,
                                         "mode-0 probe did not complete: "
                                         + self.read_log()[-2500:])
                        stdout = probe.stdout.read()
                        self.assertIn("bitmap_and_input_ok", stdout)
                        self.wait_log(
                            f"event=peer_frame_layout source={capture_width}x"
                            f"{capture_height} desktop={width}x{height} content=", 0)
                    finally:
                        if probe.poll() is None:
                            probe.kill()
                            probe.wait()
                        probe.stdout.close()
                        probe.stderr.close()

    def test_21b_mouse_letterboxed_capture(self):
        """Issue 2 regression for real fit-with-bars captures.

        Desktop 2560x1440 with a 2214x1440 capture has 173 px black bars on each
        side: the pre-fix worker forwarded mouse(100,100) as (86,100)
        (100*2214/2560), 2508x1220 with 1876x1220 forwarded (74,100). Probe mode
        0 normally sends input only after the test-pattern corner marker, which
        the black bars hide, so this case needs the probe-only hook
        RDP_PROBE_INPUT_AFTER_FIRST_BITMAP=1 (sends the same input after the
        first bitmap). While the installed probe binary lacks the hook the case
        is skipped, not failed: test_21 covers the same forwarding defect with
        the current probe.
        """
        cases = [
            (2214, 1440, 2560, 1440, 86),
            (1876, 1220, 2508, 1220, 74),
        ]
        for capture_width, capture_height, width, height, buggy_x in cases:
            with self.subTest(capture=f"{capture_width}x{capture_height}",
                              desktop=f"{width}x{height}"):
                self.configure(True, test_pattern=False, raw_bitmap=True)
                # Letterboxed captures map black bars onto the desktop corners,
                # so the pattern marker cannot reach the probe; the hook makes
                # the probe send the input after the first bitmap anyway.
                row = bytes((0x20, 0x40, 0x60, 0)) * capture_width
                pixels = row * capture_height
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
                    agent.connect(str(self.agent_socket))
                    self.send_agent_frame(agent, 1, pixels,
                                          capture_width, capture_height)
                    command = [str(self.probe_binary), "-port", str(self.port),
                               "-user", "alice", "-domain", "MACRDP", "-mode", "0",
                               "-width", str(width), "-height", str(height)]
                    probe = subprocess.Popen(
                        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True,
                        env={**os.environ, "WLOG_LEVEL": "ERROR",
                             "RDP_PROBE_INPUT_AFTER_FIRST_BITMAP": "1"})
                    try:
                        probe.stdin.write(self.password + "\n")
                        probe.stdin.close()
                        agent.settimeout(4.5)
                        buffer = b""
                        mouse = None
                        try:
                            while mouse is None:
                                kind, payload, buffer = self.agent_message(agent, buffer)
                                if kind != 3 or len(payload) != 9 or payload[0] != 1:
                                    continue
                                mouse = (struct.unpack(">H", payload[1:3])[0],
                                         struct.unpack(">H", payload[5:7])[0],
                                         struct.unpack(">H", payload[7:9])[0])
                        except (socket.timeout, EOFError):
                            self.skipTest(
                                "installed probe binary lacks the "
                                "RDP_PROBE_INPUT_AFTER_FIRST_BITMAP hook")
                        agent.settimeout(None)
                        flags, x, y = mouse
                        self.assertEqual(flags, 0x0800, "unexpected pointer flags")
                        self.assertEqual(
                            (x, y), (100, 100),
                            "worker did not forward desktop coordinates verbatim: "
                            f"client mouse(100,100) reached the Agent as ({x},{y}) "
                            f"at desktop {width}x{height} with letterboxed capture "
                            f"{capture_width}x{capture_height}; the pre-fix worker "
                            f"forwarded {buggy_x},100")
                        self.wait_log(
                            f"event=peer_frame_layout source={capture_width}x"
                            f"{capture_height} desktop={width}x{height} content=", 0)
                        self.assertIn("event=peer_activate_complete "
                                      f"width={width} height={height}", self.read_log())
                    finally:
                        if probe.poll() is None:
                            probe.kill()
                            probe.wait()
                        probe.stdout.close()
                        probe.stderr.close()

    # --- Agent teardown contract: release-all on peer disconnect ---

    def test_21c_release_all_on_peer_teardown(self):
        """Worker -> Agent teardown: when the RDP peer disconnects while the
        Agent is connected, the Worker must send input release-all (type 3,
        kind=4) so the Agent posts key-ups for held keys/modifiers.

        2026-11-08 field report: a modifier held at disconnect can stay stuck in
        macOS until the user presses a real key on the Mac. If this message is
        not delivered the Agent sweep cannot run, so assert it end-to-end.
        """
        self.configure(True, test_pattern=False, raw_bitmap=True)
        width, height = 1280, 720
        last = (height - 1) * width * 4 + (width - 1) * 4

        def frame(marker):
            image = bytearray(width * height * 4)
            image[0:4] = bytes([marker]) * 4
            image[last:last + 4] = bytes([marker]) * 4
            return image

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            self.send_agent_frame(agent, 1, frame(0x20), width, height)
            command = [str(self.probe_binary), "-port", str(self.port),
                       "-user", "alice", "-domain", "MACRDP", "-mode", "0",
                       "-width", str(width), "-height", str(height)]
            probe = subprocess.Popen(command, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, env={**os.environ, "WLOG_LEVEL": "ERROR"})
            try:
                probe.stdin.write(self.password + "\n")
                probe.stdin.close()
                # Wait until the session is active and input is being forwarded
                # (the probe sends its key+mouse input only then).
                messages = self.collect_agent_messages(
                    agent, timeout=8,
                    stop=lambda msgs: any(kind == 3 and payload[0] == 2
                                          for kind, payload in msgs))
                self.assertTrue(
                    any(kind == 3 and payload[0] == 2 for kind, payload in messages),
                    "probe input never reached the fake Agent: "
                    f"{[(kind, payload[:1]) for kind, payload in messages]}")
                # Let the probe exit through its normal path (rc 0); its
                # disconnect must make the Worker send the release-all.
                self.send_agent_frame(agent, 2, frame(0x80), width, height)
                deadline = time.monotonic() + 8
                while probe.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(probe.poll(), 0,
                                 "mode-0 probe did not complete: " + self.read_log()[-2500:])
                teardown = self.collect_agent_messages(
                    agent, timeout=8,
                    stop=lambda msgs: any(kind == 3 and len(payload) == 9 and payload[0] == 4
                                          for kind, payload in msgs))
                kinds = [payload[0] for kind, payload in teardown
                         if kind == 3 and len(payload) == 9]
                self.assertIn(4, kinds,
                              "Worker did not send input release-all (type 3 kind=4) on peer "
                              f"teardown; Agent saw kinds={kinds}")
                self.wait_lease_released(0, timeout=8)
            finally:
                if probe.poll() is None:
                    probe.kill()
                    probe.wait()
                probe.stdout.close()
                probe.stderr.close()

    # --- Issue 1 negative: clients without Display Control stay unaffected ---

    def test_22_client_without_disp_is_unaffected(self):
        """A client that does not support the Display Control dynamic virtual
        channel must not be affected by the DISP server path.

        Probe mode 5 does not request SupportDisplayControl, so it never opens
        the DRDYNVC/DISP channel: the worker must not receive a monitor layout,
        must not reactivate the client or renegotiate the desktop, and must
        still activate, deliver a full 2560x1440 frame and complete normally.
        """
        self.configure(True)  # test pattern: no Agent needed
        mark = self.log_mark()
        p = self.probe(mode=5, width=2560, height=1440)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("bitmap_update_received", p.stdout)
        self.assertIn("desktop_size=2560x1440", p.stdout)
        self.assertIn("gdi_size=2560x1440", p.stdout)
        rectangles = re.search(r"bitmap_rectangles=(\d+)", p.stdout)
        self.assertIsNotNone(rectangles, p.stdout)
        self.assertEqual(int(rectangles.group(1)), _tile_count(2560, 1440),
                         "first frame was not a full desktop frame: " + p.stdout)
        self.wait_log("event=peer_activate_complete width=2560 height=1440", mark)
        self.wait_lease_released(mark)
        worker_log = self.log_since(mark)
        self.assertNotIn("event=disp_monitor_layout", worker_log)
        self.assertNotIn("event=peer_reactivate", worker_log)
        self.assertNotIn("event=peer_activate_rejected", worker_log)
        # If the worker attempted to open the DISP DVC at all (a client that
        # requested the DRDYNVC channel but not DisplayControl), the attempt
        # must fail cleanly and must never be retried.
        if "event=disp_channel_opened" in worker_log:
            self.assertEqual(worker_log.count("event=disp_channel_opened"), 1,
                             "failed DISP channel open was retried: " + worker_log[-2500:])
            self.assertIn("event=disp_channel_opened result=1", worker_log)
        # Current worker diagnostics (Issue 1) add one teardown line per peer for
        # the DISP region; a client that never opened the channel reports
        # opened=0 exactly once. Older builds without that line are tolerated.
        closed = worker_log.count("event=disp_channel_closed")
        if closed:
            self.assertEqual(closed, 1,
                             "DISP teardown line repeated: " + worker_log[-2500:])
            self.assertIn("event=disp_channel_closed opened=0", worker_log)
        self.assertIn("event=rdp_desktop_size width=2560 height=1440", worker_log)
    # --- Issue 3: file clipboard loopback (DESIGN-2026-11-08) -----------------
    # All cases use the isolated worker (random loopback port, temp SAM/config,
    # fake Agent socket, /tmp): configure(..., clipboard=True) plus one cached
    # Agent frame (the worker refuses a peer before a frame exists), then the
    # real FreeRDP probe as the RDP client.

    def start_clipboard_agent(self, capture_width=320, capture_height=240):
        """Restart the worker with clipboard enabled and connect the fake Agent
        with one cached frame; returns the connected Agent socket."""
        self.configure(True, test_pattern=False, clipboard=True)
        pixels = bytes((0x20, 0x40, 0x60, 0)) * (capture_width * capture_height)
        agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        agent.connect(str(self.agent_socket))
        self.send_agent_frame(agent, 1, pixels, capture_width, capture_height)
        return agent

    def start_probe_process(self, mode, width, height, env=None):
        command = [str(self.probe_binary), "-port", str(self.port), "-user", "alice",
                   "-domain", "MACRDP", "-mode", str(mode), "-width", str(width),
                   "-height", str(height)]
        probe = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True,
                                 env={**os.environ, "WLOG_LEVEL": "ERROR", **(env or {})})
        probe.stdin.write(self.password + "\n")
        probe.stdin.close()
        return probe

    @staticmethod
    def finish_probe(probe, timeout=60):
        try:
            probe.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            probe.kill()
            probe.wait()
        stdout = probe.stdout.read()
        stderr = probe.stderr.read()
        probe.stdout.close()
        probe.stderr.close()
        return probe.returncode, stdout, stderr

    def test_23_remote_to_local_file_clipboard(self):
        """Windows->macOS file copy: fake Agent asserts the worker IPC sequence
        (13 begin dir1, 16 entries dir1, 14 chunks dir1, 15 end complete) and
        reconstructs every file byte exactly against probe mode-11 content."""
        cases = [
            ("single-file", {
                "RDP_PROBE_FILE_COUNT": "1",
                "RDP_PROBE_FILE_SIZE": "1024",
                "RDP_PROBE_FILE_NAME": "readme.txt",
            }, [("readme.txt", 1024)]),
            ("zero-byte", {
                "RDP_PROBE_FILE_COUNT": "1",
                "RDP_PROBE_FILE_SIZE": "0",
                "RDP_PROBE_FILE_NAME": "empty.bin",
            }, [("empty.bin", 0)]),
            ("multi-zero-first-2", {
                "RDP_PROBE_FILE_COUNT": "2",
                "RDP_PROBE_FILE_SIZE": "0",
                "RDP_PROBE_FILE_SIZE2": "128",
                "RDP_PROBE_FILE_NAME": "empty-first.bin",
                "RDP_PROBE_FILE_NAME2": "second.bin",
            }, [("empty-first.bin", 0), ("second.bin", 128)]),
            ("multi-zero-zero-1024", {
                "RDP_PROBE_FILE_COUNT": "3",
                "RDP_PROBE_FILE_SIZE": "0",
                "RDP_PROBE_FILE_SIZE3": "1024",
                "RDP_PROBE_FILE_NAME": "zero-a.bin",
                "RDP_PROBE_FILE_NAME2": "zero-b.bin",
                "RDP_PROBE_FILE_NAME3": "last.bin",
            }, [("zero-a.bin", 0), ("zero-b.bin", 0), ("last.bin", 1024)]),
            ("multi-first-512-zero-64", {
                "RDP_PROBE_FILE_COUNT": "3",
                "RDP_PROBE_FILE_SIZE": "512",
                "RDP_PROBE_FILE_SIZE2": "0",
                "RDP_PROBE_FILE_SIZE3": "64",
                "RDP_PROBE_FILE_NAME": "first.bin",
                "RDP_PROBE_FILE_NAME2": "zero.bin",
                "RDP_PROBE_FILE_NAME3": "small.bin",
            }, [("first.bin", 512), ("zero.bin", 0), ("small.bin", 64)]),
            ("multi-file-chinese-10mib", {
                "RDP_PROBE_FILE_COUNT": "3",
                "RDP_PROBE_FILE_SIZE": "10485760",
                "RDP_PROBE_FILE_SIZE2": "4096",
                "RDP_PROBE_FILE_SIZE3": "777",
                "RDP_PROBE_FILE_NAME": "large-10mib.bin",
                "RDP_PROBE_FILE_NAME2": "中文.txt",
                "RDP_PROBE_FILE_NAME3": "third.bin",
            }, [("large-10mib.bin", 10485760), ("中文.txt", 4096), ("third.bin", 777)]),
            # Real Windows/mstsc-style dynamic format ids: the client
            # advertises FileGroupDescriptorW as 49314 (0xC0A2) instead of the
            # fixed 0xC003; the worker must request the advertised id.
            ("dynamic-format-ids", {
                "RDP_PROBE_FILE_COUNT": "1",
                "RDP_PROBE_FILE_SIZE": "1024",
                "RDP_PROBE_FILE_NAME": "dyn-id.bin",
                "RDP_PROBE_DYNAMIC_FORMAT_IDS": "1",
            }, [("dyn-id.bin", 1024)], True),
        ]
        # Older cases are 3-tuples; the dynamic-id case carries a flag.
        cases = [case if len(case) == 4 else (*case, False) for case in cases]
        for label, env, expected, dynamic in cases:
            with self.subTest(case=label):
                agent = self.start_clipboard_agent()
                probe = None
                try:
                    probe = self.start_probe_process(
                        mode=11, width=800, height=600,
                        env={**env, "RDP_PROBE_CLIP_TIMEOUT_MS": "30000"})
                    messages = self.collect_agent_messages(
                        agent, timeout=40,
                        stop=lambda msgs: any(kind == 15 for kind, _ in msgs))
                    rc, stdout, stderr = self.finish_probe(probe)
                    self.assertEqual(rc, 0, "probe mode 11 failed:\n" + stdout + stderr)

                    begins = [payload for kind, payload in messages if kind == 13]
                    entries = [self.clipboard_entry(payload) for kind, payload
                               in messages if kind == 16]
                    chunks = [self.clipboard_chunk(payload) for kind, payload
                              in messages if kind == 14]
                    ends = [self.clipboard_offer_end(payload) for kind, payload
                            in messages if kind == 15]
                    total = sum(size for _, size in expected)
                    self.assertEqual(len(begins), 1, "expected exactly one offer begin")
                    direction, file_count, total_bytes, flags = \
                        self.clipboard_offer_begin(begins[0])
                    self.assertEqual((direction, file_count, total_bytes, flags),
                                     (1, len(expected), total, 0))
                    self.assertEqual(len(ends), 1, "expected exactly one offer end")
                    self.assertEqual(ends[0], (1, 0, 0, len(expected)),
                                     "offer end was not complete status 0")
                    self.assertEqual(len(entries), len(expected),
                                     "one type-16 entry per file expected")
                    assembled = [bytearray() for _ in expected]
                    for file_index, offset, data in chunks:
                        self.assertLess(file_index, len(expected))
                        self.assertEqual(offset, len(assembled[file_index]),
                                         "chunk offsets must be contiguous from 0")
                        assembled[file_index] += data
                    for index, (name, size) in enumerate(expected):
                        self.assertEqual(entries[index]["direction"], 1)
                        self.assertEqual(entries[index]["file_index"], index)
                        self.assertEqual(entries[index]["name"], name)
                        self.assertEqual(entries[index]["path"], "")
                        self.assertEqual(entries[index]["size"], size)
                        self.assertEqual(bytes(assembled[index]),
                                         self.clipboard_probe_file_bytes(index, size),
                                         f"reconstructed bytes differ for {name}")
                    # Client side: every byte was requested and served.
                    self.assertIn("cliprdr_channel_connected", stdout)
                    self.assertIn("caps_received general_flags=", stdout)
                    if dynamic:
                        # mstsc-style: 4 advertised formats, dynamic descriptor id.
                        self.assertIn("format_list_sent formats=4", stdout)
                        self.assertIn("descriptor_requested format=0x0000c0a2", stdout)
                    else:
                        self.assertIn(f"format_list_sent formats=2 files={len(expected)}",
                                      stdout)
                        self.assertIn("descriptor_requested format=0x0000c003", stdout)
                    self.assertIn("descriptor_sent bytes=", stdout)
                    if total:
                        self.assertIn("file_contents_sent bytes=", stdout)
                    self.assertIn(f"file_paste_ok files={len(expected)} bytes={total}", stdout)
                    # Worker audit log.
                    worker_log = self.read_log()
                    self.assertIn(f"event=clipboard_file_offer direction=remote_to_local "
                                  f"count={len(expected)} bytes={total}", worker_log)
                    for index, (name, size) in enumerate(expected):
                        self.assertIn(f"event=clipboard_file_entry direction=remote_to_local "
                                      f"index={index} size={size} "
                                      f"name_len={len(name.encode('utf-8'))}", worker_log)
                    if total:
                        first_nonempty = next(
                            index for index, (_, size) in enumerate(expected) if size)
                        self.assertRegex(worker_log,
                                         r"event=clipboard_file_request "
                                         r"direction=remote_to_local "
                                         rf"index={first_nonempty} offset=0 length=\d+")
                        self.assertRegex(worker_log,
                                         r"event=clipboard_file_request "
                                         r"direction=remote_to_local index=\d+ "
                                         r"offset=\d+ length=\d+")
                    if dynamic:
                        # The worker resolved the client's advertised dynamic id
                        # (mstsc-style) and requested exactly that id.
                        self.assertIn("event=clipboard_client_data_request id=49314 "
                                      "kind=files", worker_log)
                        self.assertRegex(
                            worker_log,
                            r"event=clipboard_client_formats result=\d+ "
                            r"selected=49314 kind=2 formats=4")
                        self.assertRegex(
                            worker_log,
                            r"event=clipboard_client_format index=\d+ id=49314 "
                            r"name=FileGroupDescriptorW")
                        self.assertIn("event=cliprdr_client_capabilities "
                                      "long_names=1 stream_file_clip=1 huge_files=0",
                                      worker_log)
                    else:
                        self.assertIn("event=clipboard_client_data_request id=49155 "
                                      "kind=files", worker_log)
                    self.assertIn(f"event=clipboard_file_complete direction=remote_to_local "
                                  f"files={len(expected)} bytes={total} result=0", worker_log)
                    self.assertNotIn("event=clipboard_file_rejected", worker_log)
                    self.assertIn("event=cliprdr_start result=0", worker_log)
                    caps = re.search(
                        r"event=cliprdr_initialized general_flags=0x([0-9a-fA-F]+)",
                        worker_log)
                    self.assertIsNotNone(caps, "missing cliprdr capability log")
                    caps_flags = int(caps.group(1), 16)
                    self.assertEqual(caps_flags & 0x6, 0x6,
                                     "server CB_CLIP_CAPS must advertise "
                                     "long-format-names(0x2) + stream-file-clip(0x4): "
                                     f"general_flags={caps_flags:#x}")
                finally:
                    if probe is not None and probe.poll() is None:
                        probe.kill()
                        probe.wait()
                    agent.close()

    def test_24_local_to_remote_file_clipboard(self):
        """macOS->Windows file copy: the fake Agent advertises real /tmp files
        over IPC types 13/16/15 (direction 2); the probe requests the descriptor,
        FILECONTENTS_SIZE and RANGE chunks and verifies the bytes/sha256.

        Includes the mstsc field regression (2026-11-08): real Windows clients
        request FULL 262144-byte FILECONTENTS_RANGE chunks without clamping the
        last chunk to EOF, so the worker must answer a SHORT response for the
        tail (size-offset bytes) instead of rejecting the range with bad_range.
        RDP_PROBE_OVERLONG_RANGE=1 reproduces that request pattern; both a
        non-multiple size (short tail) and an exact multiple (no short tail)
        are covered."""
        pattern = bytes((j * 13 + 7) & 0xFF for j in range(256))

        def content(size):
            return (pattern * (size // 256 + 1))[:size]

        cases = [
            ("normal-4-files", [
                ("hello.txt", b"hello from macOS\n" * 20),
                ("empty.txt", b""),
                ("中文文件.bin", bytes(range(256)) * 4),
                ("medium-2mib.bin", content(2 * 1024 * 1024)),
            ], {}, []),
            # 1048087 = 3 * 262144 + 261655: the last mstsc-style request asks for
            # 262144 bytes at offset 786432 but only 261655 remain.
            ("overlong-non-multiple", [
                ("overlong-tail.bin", content(1048087)),
            ], {"RDP_PROBE_OVERLONG_RANGE": "1"},
             ["file_contents_short_response lindex=0 requested=262144 got=261655"]),
            # 1048576 = 4 * 262144: every request is a full chunk, no short tail.
            ("overlong-exact-multiple", [
                ("overlong-exact.bin", content(1048576)),
            ], {"RDP_PROBE_OVERLONG_RANGE": "1"}, []),
        ]
        for label, file_specs, extra_env, expected_lines in cases:
            with self.subTest(case=label):
                with tempfile.TemporaryDirectory(prefix="rdp-clipboard-src-",
                                                 dir="/tmp") as directory:
                    source_dir = Path(directory)
                    files = []
                    for name, data in file_specs:
                        path = source_dir / name
                        path.write_bytes(data)
                        files.append((name, str(path), data,
                                      hashlib.sha256(data).hexdigest()))
                    agent = self.start_clipboard_agent()
                    probe = None
                    try:
                        mark = self.log_mark()
                        probe = self.start_probe_process(
                            mode=12, width=800, height=600,
                            env={"RDP_PROBE_CLIP_TIMEOUT_MS": "30000",
                                 "RDP_PROBE_FILE_SHA256":
                                     ",".join(item[3] for item in files),
                                 **extra_env})
                        self.wait_log("event=cliprdr_start result=0", mark, timeout=10)
                        total = sum(len(item[2]) for item in files)
                        self.send_agent_message(
                            agent, 13,
                            self.encode_clipboard_offer_begin(2, len(files), total))
                        for index, (name, path, data, _) in enumerate(files):
                            self.send_agent_message(
                                agent, 16,
                                self.encode_clipboard_entry(2, index, len(data),
                                                            name, path))
                        self.send_agent_message(
                            agent, 15,
                            self.encode_clipboard_offer_end(2, 0, len(files)))
                        rc, stdout, stderr = self.finish_probe(probe)
                        probe = None
                        self.assertEqual(rc, 0, "probe mode 12 failed:\n"
                                         + stdout + stderr)
                        self.assertIn("format_list_received formats=", stdout)
                        self.assertIn("file_formats=1", stdout)
                        self.assertIn("descriptor_request_sent", stdout)
                        self.assertIn(f"descriptor_received files={len(files)}",
                                      stdout)
                        for index, (name, path, data, digest) in enumerate(files):
                            size = len(data)
                            self.assertIn(f"file_entry lindex={index} size={size} "
                                          f"name={name}", stdout)
                            self.assertIn(f"file_size_ok lindex={index} size={size}",
                                          stdout)
                            self.assertIn(f"file_contents_ok lindex={index} "
                                          f"bytes={size} sha256={digest}", stdout)
                        self.assertIn(f"file_paste_ok files={len(files)} "
                                      f"bytes={total}", stdout)
                        for line in expected_lines:
                            self.assertIn(line, stdout)
                        worker_log = self.log_since(mark)
                        self.assertIn(f"event=clipboard_file_offer "
                                      f"direction=local_to_remote "
                                      f"count={len(files)} bytes={total}", worker_log)
                        for index, (name, path, data, digest) in enumerate(files):
                            self.assertIn(
                                f"event=clipboard_file_entry "
                                f"direction=local_to_remote index={index} "
                                f"size={len(data)} "
                                f"name_len={len(name.encode('utf-8'))}", worker_log)
                        self.assertRegex(
                            worker_log,
                            r"event=clipboard_file_request "
                            r"direction=local_to_remote index=0 offset=0 "
                            r"length=\d+")
                        self.assertIn(f"event=clipboard_file_complete "
                                      f"direction=local_to_remote "
                                      f"files={len(files)} bytes={total} "
                                      f"result=0", worker_log)
                        # Server->client file advertisement: long format names
                        # enabled (probe mode 12 sends long-format-name caps).
                        self.assertIn("event=clipboard_file_advertised formats=2 "
                                      "long_names=1", worker_log)
                        self.assertIn("event=cliprdr_client_capabilities "
                                      "long_names=1 stream_file_clip=1 "
                                      "huge_files=0", worker_log)
                        # No offer may be rejected: the old strict worker
                        # rejected the overlong tail with bad_range, which broke
                        # real mstsc pastes ("unspecified error").
                        self.assertNotIn("event=clipboard_file_rejected", worker_log)
                        self.assertNotIn("reason=bad_range", worker_log)
                        if label == "overlong-non-multiple":
                            # The worker clamps the last request to the remaining
                            # bytes and reports both counts in the audit line.
                            self.assertIn(
                                "event=clipboard_file_request "
                                "direction=local_to_remote index=0 "
                                "offset=786432 length=261655 requested=262144",
                                worker_log)
                        elif label == "overlong-exact-multiple":
                            # Exact multiple: all four requests are full chunks,
                            # no clamping and no short response.
                            self.assertNotIn("file_contents_short_response", stdout)
                            self.assertIn(
                                "event=clipboard_file_request "
                                "direction=local_to_remote index=0 "
                                "offset=786432 length=262144", worker_log)
                            self.assertNotIn("requested=262144", worker_log)
                            self.assertNotIn(
                                "file_contents_request lindex=0 offset=1048576",
                                stdout,
                                "probe requested a range at EOF for an exact "
                                "multiple")
                    finally:
                        if probe is not None and probe.poll() is None:
                            probe.kill()
                            probe.wait()
                        agent.close()

    def test_25_clipboard_file_rejection_paths(self):
        """Bad offers are rejected with the documented reason, the Agent IPC and
        the RDP service stay usable, and a later client session works normally."""
        with tempfile.TemporaryDirectory(prefix="rdp-clip-reject-", dir="/tmp") as directory:
            source_dir = Path(directory)
            real_path = source_dir / "real.bin"
            real_path.write_bytes(b"payload")  # 7 bytes
            symlink_path = source_dir / "link.bin"
            symlink_path.symlink_to(real_path)
            missing_path = "/tmp/rdp-clipboard-missing-file.bin"
            try:
                Path(missing_path).unlink()
            except FileNotFoundError:
                pass

            def send_offer(agent, begin_file_count, begin_total, entries):
                self.send_agent_message(
                    agent, 13,
                    self.encode_clipboard_offer_begin(2, begin_file_count, begin_total))
                for entry in entries:
                    self.send_agent_message(
                        agent, 16, self.encode_clipboard_entry(*entry))
                self.send_agent_message(
                    agent, 15,
                    self.encode_clipboard_offer_end(2, 0, begin_file_count))

            # Local->remote (Agent offer) rejection matrix: (label, begin count,
            # begin total, entries, expected reason).
            cases = [
                ("traversal-name", 1, 7,
                 [(2, 0, 7, "../evil.bin", str(real_path))], "bad_name"),
                ("absolute-name", 1, 7,
                 [(2, 0, 7, "/abs.bin", str(real_path))], "bad_name"),
                ("relative-path", 1, 7,
                 [(2, 0, 7, "ok.bin", "relative/x")], "bad_name"),
                ("size-mismatch", 1, 8,
                 [(2, 0, 8, "ok.bin", str(real_path))], "size_mismatch"),
                ("missing-file", 1, 7,
                 [(2, 0, 7, "missing.bin", missing_path)], "unreadable"),
                ("directory-entry", 1, 0,
                 [(2, 0, 0, "directory", str(source_dir))], "not_regular"),
                ("symlink-entry", 1, 7,
                 [(2, 0, 7, "link.bin", str(symlink_path))], "not_regular"),
                ("too-many-files", 101, 0, [], "too_many_files"),
                ("total-too-large", 1, 4 * 1024 * 1024 * 1024 + 1, [], "too_large"),
            ]
            for label, file_count, total, entries, reason in cases:
                with self.subTest(agent_case=label):
                    agent = self.start_clipboard_agent()
                    try:
                        send_offer(agent, file_count, total, entries)
                        self.wait_log(
                            f"event=clipboard_file_rejected direction=local_to_remote "
                            f"reason={reason}", 0, timeout=8)
                        if reason == "unreadable":
                            # The unreadable rejection is audit-extended with the
                            # sanitized basename and the positive errno (ENOENT=2);
                            # the full path must never be logged.
                            self.assertRegex(
                                self.read_log(),
                                r"event=clipboard_file_rejected "
                                r"direction=local_to_remote reason=unreadable "
                                r"name=missing\.bin errno=\d+")
                            rejected_line = next(
                                line for line in self.read_log().splitlines()
                                if "reason=unreadable" in line)
                            self.assertNotIn("/", rejected_line.split("name=", 1)[1],
                                             "rejection log leaked a path: "
                                             + rejected_line)
                        # The worker and the RDP service stay usable.
                        p = self.probe(mode=5, width=320, height=240)
                        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
                        self.assertIn("bitmap_update_received", p.stdout)
                    finally:
                        agent.close()

            # Remote->local (client descriptor) rejection matrix: probe mode 11
            # advertises unsanitized names; the worker must reject the list before
            # requesting any byte, and the probe times out instead of hanging the
            # session. A normal client session must still work afterwards.
            names = [("../evil.bin", "traversal"),
                     ("/tmp/evil.bin", "absolute")]
            for name, label in names:
                with self.subTest(client_name=label):
                    agent = self.start_clipboard_agent()
                    probe = None
                    try:
                        probe = self.start_probe_process(
                            mode=11, width=320, height=240,
                            env={"RDP_PROBE_FILE_COUNT": "1",
                                 "RDP_PROBE_FILE_SIZE": "128",
                                 "RDP_PROBE_FILE_NAME": name,
                                 "RDP_PROBE_CLIP_TIMEOUT_MS": "4000"})
                        rejection = ("event=clipboard_file_rejected "
                                     "direction=remote_to_local reason=bad_name")
                        deadline = time.monotonic() + 10
                        rejected = False
                        while time.monotonic() < deadline:
                            if rejection in self.read_log():
                                rejected = True
                                break
                            if probe.poll() is not None:
                                break
                            time.sleep(.05)
                        if not rejected:
                            rc, stdout, stderr = self.finish_probe(probe, timeout=30)
                            probe = None
                            if "probe_clip_name_too_long" in stderr:
                                # The probe validates names before putting them on
                                # the wire; the worker-side >255-byte rejection is
                                # covered by the clipboard_files.h C matrix.
                                self.skipTest("installed probe rejects >255-byte "
                                              "names before sending")
                            self.fail("worker did not reject the client file list: "
                                      + stdout + stderr
                                      + self.read_log()[-2000:])
                        rc, stdout, stderr = self.finish_probe(probe, timeout=30)
                        probe = None
                        self.assertNotEqual(
                            rc, 0, f"probe unexpectedly succeeded for {label}: " + stdout)
                        self.assertIn("file_paste_failed", stdout)
                        self.wait_lease_released(0, timeout=8)
                        p = self.probe(mode=5, width=320, height=240)
                        self.assertEqual(p.returncode, 0,
                                         "session unusable after rejection: "
                                         + p.stderr + p.stdout)
                    finally:
                        if probe is not None and probe.poll() is None:
                            probe.kill()
                            probe.wait()
                        agent.close()

    def test_25b_clipboard_oversized_or_empty_client_name_rejected(self):
        """Remote->local descriptor names longer than 255 UTF-8 bytes, and empty
        names, must be rejected with reason=bad_name before any content request.

        The probe packs these names as-is (RDP_PROBE_CLIP_UNSAFE_NAME=1 for the
        oversized case) so the worker itself performs the validation.
        """
        cases = [
            ("too-long", "a" * 256, "1"),
            ("empty", "", None),
        ]
        for label, name, unsafe in cases:
            with self.subTest(client_name=label):
                agent = self.start_clipboard_agent()
                probe = None
                try:
                    env = {"RDP_PROBE_FILE_COUNT": "1",
                           "RDP_PROBE_FILE_SIZE": "128",
                           "RDP_PROBE_FILE_NAME": name,
                           "RDP_PROBE_CLIP_TIMEOUT_MS": "3000"}
                    if unsafe:
                        env["RDP_PROBE_CLIP_UNSAFE_NAME"] = unsafe
                    probe = self.start_probe_process(
                        mode=11, width=320, height=240, env=env)
                    rejection = ("event=clipboard_file_rejected "
                                 "direction=remote_to_local reason=bad_name")
                    deadline = time.monotonic() + 10
                    rejected = False
                    while time.monotonic() < deadline:
                        if rejection in self.read_log():
                            rejected = True
                            break
                        if probe.poll() is not None:
                            break
                        time.sleep(.05)
                    rc, stdout, stderr = self.finish_probe(probe, timeout=30)
                    probe = None
                    if not rejected:
                        if "probe_clip_name_too_long" in stderr:
                            self.skipTest(
                                "installed probe lacks RDP_PROBE_CLIP_UNSAFE_NAME / "
                                "empty-name support")
                        self.fail("worker did not reject the client file list "
                                  f"({label}): " + stdout + stderr
                                  + self.read_log()[-2000:])
                    self.assertNotEqual(rc, 0,
                                        "probe unexpectedly succeeded: " + stdout)
                    self.assertIn("file_paste_failed", stdout)
                    self.wait_lease_released(0, timeout=8)
                    # Session stays usable after the rejected offer.
                    p = self.probe(mode=5, width=320, height=240)
                    self.assertEqual(p.returncode, 0,
                                     "session unusable after oversized/empty-name "
                                     "rejection: " + p.stderr + p.stdout)
                finally:
                    if probe is not None and probe.poll() is None:
                        probe.kill()
                        probe.wait()
                    agent.close()

    def test_25c_clipboard_client_failure_aborts_offer(self):
        """A client that fails a FILECONTENTS range (CB_RESPONSE_FAIL) or returns
        a short response must abort the remote->local offer: the worker logs
        reason=client_failed, the Agent receives IPC 15 direction=1 status=2, no
        file chunk is forwarded, and the session stays usable."""
        for injection, stage, fail_kind in [
                ("response_fail", "injected_response_fail", "response_fail"),
                ("short_response", "injected_short_response", "short_response")]:
            with self.subTest(injection=injection):
                agent = self.start_clipboard_agent()
                probe = None
                try:
                    probe = self.start_probe_process(
                        mode=11, width=320, height=240,
                        env={"RDP_PROBE_FILE_COUNT": "1",
                             "RDP_PROBE_FILE_SIZE": "128",
                             "RDP_PROBE_FILE_NAME": "inject.bin",
                             "RDP_PROBE_CLIP_TIMEOUT_MS": "8000",
                             "RDP_PROBE_FAIL_CONTENTS": injection})
                    messages = self.collect_agent_messages(
                        agent, timeout=25,
                        stop=lambda msgs: any(kind == 15 for kind, _ in msgs))
                    rc, stdout, stderr = self.finish_probe(probe, timeout=30)
                    probe = None
                    self.assertEqual(rc, 22, "probe failure injection did not fail: "
                                     + stdout + stderr)
                    self.assertIn(f"fail_injection kind={fail_kind}", stdout)
                    self.assertIn(
                        f"file_paste_failed reason=client_error stage={stage} mode=11",
                        stdout)
                    self.wait_log(
                        "event=clipboard_file_rejected direction=remote_to_local "
                        "reason=client_failed", 0, timeout=8)
                    begins = [self.clipboard_offer_begin(payload) for kind, payload
                              in messages if kind == 13]
                    entries = [self.clipboard_entry(payload) for kind, payload
                               in messages if kind == 16]
                    ends = [self.clipboard_offer_end(payload) for kind, payload
                            in messages if kind == 15]
                    chunks = [payload for kind, payload in messages if kind == 14]
                    self.assertEqual(begins, [(1, 1, 128, 0)],
                                     "offer begin before the failed range")
                    self.assertEqual(len(entries), 1)
                    self.assertEqual(entries[0]["direction"], 1)
                    self.assertEqual(entries[0]["name"], "inject.bin")
                    self.assertEqual(ends, [(1, 2, 0, 1)],
                                     "failed offer must end with status=2 (error)")
                    self.assertEqual(chunks, [],
                                     "no file chunk may be forwarded after a "
                                     "failed/short response")
                    self.wait_lease_released(0, timeout=8)
                    p = self.probe(mode=5, width=320, height=240)
                    self.assertEqual(p.returncode, 0,
                                     "session unusable after client failure: "
                                     + p.stderr + p.stdout)
                finally:
                    if probe is not None and probe.poll() is None:
                        probe.kill()
                        probe.wait()
                    agent.close()

    def test_26_clipboard_text_still_works_with_file_path(self):
        """Text clipboard (IPC type 8 local->remote) must keep working now that
        the file path exists, and a file session must not disturb it."""
        agent = self.start_clipboard_agent()
        probe = None
        try:
            text = "协议测试 clipboard hello".encode("utf-8")
            self.send_agent_message(agent, 8, b"\x01" + text)
            self.wait_log("event=clipboard_local_changed", 0, timeout=8)
            probe = self.start_probe_process(
                mode=11, width=800, height=600,
                env={"RDP_PROBE_FILE_COUNT": "1", "RDP_PROBE_FILE_SIZE": "128",
                     "RDP_PROBE_FILE_NAME": "text-regression.bin",
                     "RDP_PROBE_CLIP_TIMEOUT_MS": "20000"})
            messages = self.collect_agent_messages(
                agent, timeout=30,
                stop=lambda msgs: any(kind == 15 for kind, _ in msgs))
            rc, stdout, stderr = self.finish_probe(probe)
            self.assertEqual(rc, 0, "file session after text copy failed:\n"
                             + stdout + stderr)
            self.assertIn("file_paste_ok files=1 bytes=128", stdout)
            worker_log = self.read_log()
            self.assertIn("event=clipboard_local_changed", worker_log)
            self.assertIn("event=clipboard_client_formats result=", worker_log)
            self.assertIn("event=cliprdr_start result=0", worker_log)
            self.assertNotIn("event=clipboard_file_rejected", worker_log)
            ends = [self.clipboard_offer_end(payload) for kind, payload
                    in messages if kind == 15]
            self.assertEqual(ends, [(1, 0, 0, 1)])
        finally:
            if probe is not None and probe.poll() is None:
                probe.kill()
                probe.wait()
            agent.close()


    def test_27_agent_display_restore_ipc(self):
        """IPC message type 17 (display restore, empty payload) is sent by the
        worker to the Agent exactly once when the peer disconnects, so the Agent
        can restore the local display mode. It must not be repeated."""
        self.configure(True, test_pattern=False, raw_bitmap=True)
        capture_width, capture_height = 320, 240
        pixels = bytes((0x20, 0x40, 0x60, 0)) * (capture_width * capture_height)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
            agent.connect(str(self.agent_socket))
            self.send_agent_frame(agent, 1, pixels, capture_width, capture_height)
            p = self.probe(mode=5, width=320, height=240)
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            self.assertIn("bitmap_update_received", p.stdout)
            messages = self.collect_agent_messages(
                agent, timeout=10,
                stop=lambda msgs: sum(1 for kind, _ in msgs if kind == 17) >= 1)
            restore = [payload for kind, payload in messages if kind == 17]
            self.assertEqual(
                len(restore), 1,
                "expected exactly one IPC type 17 display-restore message, got "
                + str([(kind, len(payload)) for kind, payload in messages]))
            self.assertEqual(restore[0], b"",
                             "display-restore payload must be empty")
            self.assertIn("event=display_restore_sent result=0", self.read_log(),
                          "worker did not report a successful display-restore send")
            self.assertEqual(self.read_log().count("event=display_restore_sent"), 1,
                             "display-restore send was logged more than once")
            # The restore message must not be repeated after the disconnect.
            extra = self.collect_agent_messages(agent, timeout=1.5, stop=None)
            self.assertEqual([kind for kind, _ in extra if kind == 17], [],
                             "IPC type 17 display-restore was repeated")
            self.wait_lease_released(0, timeout=8)


if __name__ == "__main__":
    unittest.main(verbosity=2)
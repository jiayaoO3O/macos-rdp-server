#!/usr/bin/env python3
"""Headless integration test for the custom 16:9 virtual display.

Runs the real `rdp-agent stream-snapshot` live-capture path against a fake
Worker Unix socket and proves the end-to-end feature with the feature gate on:

  1. the Agent starts capturing the physical display (no virtual display yet),
  2. the fake Worker sends IPC type 9 (desktop box 2560x1440),
  3. the Agent spawns the `virtual-display` child, the child creates a 2560x1440
     virtual display, mirrors the physical display onto it and announces
     `display_id=<id> width=2560 height=1440`,
  4. ScreenCaptureKit (`rdp-agent displays`) sees a 2560x1440 display and the
     Agent's frames switch to exactly 2560x1440 (1:1 capture, policy exact),
  5. the fake Worker sends IPC type 17 and closes the socket: the Agent tears the
     child down (unmirror) and the display arrangement is back to the original
     single native display.

Safety: the Agent/child restore the display on stdin EOF, SIGTERM and SIGKILL
(the child's XPC connection removes the virtual display when the process dies),
so the `finally` block only needs to terminate the Agent and wait for the
arrangement to be restored. The script exits non-zero if anything is left over.

Prerequisite: `swift build -c release --package-path native/macos`
(`make test-virtual-display` does that). Screen Recording permission is needed
for the `rdp-agent displays` checks, same as any other capture diagnostic.
"""

import argparse
import os
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "native" / "macos" / ".build" / "release" / "rdp-agent"
SOCKET_PATH = f"/tmp/rdp-vdtest-{os.getpid()}.sock"

DESKTOP_WIDTH = 2560
DESKTOP_HEIGHT = 1440
FRAME_READY = 2
FRAME_CHUNK = 7
CAPTURE_SIZE = 9
FRAME_DELTA_BEGIN = 10
FRAME_TILE = 11
FRAME_DELTA_END = 12
DISPLAY_RESTORE = 17
HEADER = struct.Struct(">4sHHI")


def rdp_message(message_type, payload=b""):
    return HEADER.pack(b"RDPA", 1, message_type, len(payload)) + payload


def capture_size_payload(width, height):
    return struct.pack(">II", width, height)


class StderrCollector(threading.Thread):
    """Reads the Agent's stderr line by line so the test can react to events."""

    def __init__(self, stream):
        super().__init__(daemon=True)
        self.stream = stream
        self.lines = []
        self.lock = threading.Lock()
        self.done = threading.Event()

    def run(self):
        for raw in self.stream:
            line = raw.decode("utf-8", "replace").rstrip()
            with self.lock:
                self.lines.append(line)
        self.done.set()

    def snapshot(self):
        with self.lock:
            return list(self.lines)

    def count(self, needle):
        with self.lock:
            return sum(1 for line in self.lines if needle in line)

    def wait_for_count(self, needle, count, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.count(needle) >= count:
                return True
            time.sleep(0.05)
        return False

    def wait_for(self, needle, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for line in self.lines:
                    if needle in line:
                        return line
            time.sleep(0.05)
        return None


class DisplayProbe:
    """Uses the Agent's own `displays` command (ScreenCaptureKit) read-only."""

    def __init__(self, binary):
        self.binary = binary

    def parse(self):
        result = subprocess.run([str(self.binary), "displays"], capture_output=True,
                                text=True, timeout=15)
        if result.returncode != 0:
            raise AssertionError(
                f"rdp-agent displays failed: {result.stderr.strip() or result.returncode}")
        displays = []
        for line in result.stdout.splitlines():
            fields = dict(part.split("=", 1) for part in line.split() if "=" in part)
            displays.append({
                "index": int(fields["index"]),
                "id": int(fields["id"]),
                "points": fields["points"],
                "pixels": fields["pixels"],
            })
        return displays


class FakeWorker:
    """Minimal RDPA v1 Unix-socket endpoint speaking only types 9 and 17."""

    def __init__(self, path):
        import socket
        self.path = path
        if os.path.exists(path):
            os.unlink(path)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(path)
        self.socket.listen(1)
        self.connection = None
        self.buffer = b""
        self.pending = None
        self.frames = []

    def accept(self, timeout):
        self.socket.settimeout(timeout)
        self.connection, _ = self.socket.accept()
        self.connection.settimeout(timeout)

    def send(self, message_type, payload=b""):
        self.connection.sendall(rdp_message(message_type, payload))

    def _read_exact(self, count):
        while len(self.buffer) < count:
            chunk = self.connection.recv(65536)
            if not chunk:
                raise ConnectionError("agent closed the socket")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _read_message(self):
        if self.pending is not None:
            message, self.pending = self.pending, None
            return message
        magic, version, message_type, length = HEADER.unpack(self._read_exact(HEADER.size))
        if magic != b"RDPA" or version != 1:
            raise AssertionError(f"bad RDPA header: {magic!r} v{version}")
        return message_type, self._read_exact(length)

    def read_frame(self):
        """Reads one Agent frame.

        Handles both wire paths: full frames (type 2 frameReady + type 7 chunk
        messages) and delta frames when the Agent runs with
        RDP_AGENT_DELTA_FRAMES=1 (type 10 begin + type 11 tiles + type 12 end).
        """
        while True:
            message_type, payload = self._read_message()
            if message_type == FRAME_READY:
                if len(payload) != 25:
                    raise AssertionError(f"frameReady payload length {len(payload)} != 25")
                generation, frame_id, width, height, bpp = struct.unpack(">QQIIB", payload)
                # Consume the pixel chunks so the stream stays aligned; the next
                # message may already be the next frame.
                while True:
                    chunk_type, chunk_payload = self._read_message()
                    if chunk_type == FRAME_CHUNK:
                        continue
                    self.pending = (chunk_type, chunk_payload)
                    break
                frame = {"generation": generation, "frame_id": frame_id,
                         "width": width, "height": height, "bpp": bpp}
                self.frames.append(frame)
                return frame
            if message_type == FRAME_DELTA_BEGIN:
                if len(payload) != 29:
                    raise AssertionError(f"frameDeltaBegin payload length {len(payload)} != 29")
                generation, frame_id, width, height, bpp, tile_count = struct.unpack(
                    ">QQIIBI", payload)
                tile_index = 0
                while True:
                    tile_type, tile_payload = self._read_message()
                    if tile_type == FRAME_TILE:
                        tile_index += 1
                        continue
                    if tile_type == FRAME_DELTA_END:
                        break
                    self.pending = (tile_type, tile_payload)
                    break
                if tile_index != tile_count:
                    raise AssertionError(f"delta frame {tile_index} tiles != {tile_count}")
                frame = {"generation": generation, "frame_id": frame_id,
                         "width": width, "height": height, "bpp": bpp}
                self.frames.append(frame)
                return frame

    def close(self):
        try:
            if self.connection is not None:
                self.connection.close()
        finally:
            self.connection = None
            self.socket.close()
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass


class VirtualDisplayIntegrationTest(unittest.TestCase):
    def setUp(self):
        if not BINARY.exists():
            self.fail(f"missing {BINARY}; run: swift build -c release --package-path native/macos")
        self.probe = DisplayProbe(BINARY)
        self.before = self.probe.parse()
        self.assertGreaterEqual(len(self.before), 1)
        self.native_display_id = self.before[0]["id"]
        self.native_points = self.before[0]["points"]
        self.native_pixels = self.before[0]["pixels"]
        self.agent = None
        self.stderr = None

    def tearDown(self):
        self.stop_agent()

    def set_panel_mode(self, width, height):
        """Force the physical panel to a pixel size (test/deployment helper)."""
        environment = dict(os.environ)
        environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        result = subprocess.run(
            [str(BINARY), "set-display-mode", str(width), str(height)],
            capture_output=True, text=True, timeout=20, env=environment)
        self.assertEqual(result.returncode, 0,
                         f"set-display-mode {width}x{height} failed: {result.stderr.strip()}")
        self.assertIn("result=0", result.stdout)
        displays = self.probe.parse()
        self.assertEqual(displays[0]["pixels"], f"{width}x{height}",
                         f"panel not at {width}x{height}: {displays}")

    def restore_native_mode(self):
        native_width, native_height = (int(part) for part in self.native_pixels.split("x"))
        self.set_panel_mode(native_width, native_height)

    def wait_for_restored_native(self, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            displays = self.probe.parse()
            if (len(displays) == 1 and displays[0]["pixels"] == self.native_pixels
                    and displays[0]["points"] == self.native_points):
                return
            time.sleep(0.1)
        self.fail(f"panel not restored to native {self.native_pixels}: {self.probe.parse()}")

    def start_agent(self, virtual_display_enabled=True, stream_capture=False):
        worker = FakeWorker(SOCKET_PATH)
        self.addCleanup(worker.close)
        environment = dict(os.environ)
        environment["RDP_AGENT_MATCH_DISPLAY_MODE"] = "0"
        if virtual_display_enabled:
            environment["RDP_AGENT_VIRTUAL_DISPLAY"] = "1"
        else:
            environment.pop("RDP_AGENT_VIRTUAL_DISPLAY", None)
        # Keep the child's teardown audible but avoid the capture-stream path.
        environment.pop("RDP_AGENT_CAPTURE_STREAM", None)
        environment.pop("RDP_AGENT_DELTA_FRAMES", None)
        environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        if stream_capture:
            # Mirror the deployed LaunchAgent wrapper configuration.
            environment["RDP_AGENT_CAPTURE_STREAM"] = "1"
            environment["RDP_AGENT_DELTA_FRAMES"] = "1"
            environment["RDP_AGENT_TARGET_FPS"] = "60"
        environment["RDP_AGENT_NO_PERMISSION_REQUEST"] = "1"
        self.agent = subprocess.Popen(
            [str(BINARY), "stream-snapshot", SOCKET_PATH, "0", "0", "9142"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.stderr = StderrCollector(self.agent.stderr)
        self.stderr.start()
        worker.accept(timeout=15)
        self.addCleanup(lambda: self.terminate_agent())
        return worker

    def terminate_agent(self):
        if self.agent is not None and self.agent.poll() is None:
            self.agent.terminate()
            try:
                self.agent.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.agent.kill()
                self.agent.wait(timeout=5)
        if self.agent is not None and self.agent.stdout is not None:
            try:
                self.agent.stdout.close()
            except Exception:
                pass

    def stop_agent(self):
        self.terminate_agent()
        # The child restores on its own; give WindowServer a moment and verify.
        deadline = time.time() + 10
        while time.time() < deadline:
            displays = self.probe.parse()
            if len(displays) == 1 and displays[0]["pixels"] == self.native_pixels:
                return
            time.sleep(0.1)
        self.fail(f"display arrangement not restored after teardown: {self.probe.parse()}")

    def wait_for_any_frame(self, worker, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                frame = worker.read_frame()
            except (TimeoutError, OSError):
                continue
            if frame is not None:
                return frame
        self.fail("no Agent frame before type 9: " + "\n".join(self.stderr.snapshot()))

    def wait_for_frame_size(self, worker, width, height, timeout):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                frame = worker.read_frame()
            except (TimeoutError, OSError):
                continue
            if frame is None:
                continue
            last = frame
            if frame["width"] == width and frame["height"] == height:
                return frame
        self.fail(f"no {width}x{height} frame within {timeout}s; last frame: {last}")

    def test_virtual_display_2560x1440_capture_and_restore(self):
        worker = self.start_agent()
        # The Agent starts capturing the physical display before any type 9.
        first = self.wait_for_any_frame(worker, timeout=20)
        self.assertEqual(first["bpp"], 4)

        # Fake Worker negotiates the 16:9 desktop box.
        worker.send(CAPTURE_SIZE, capture_size_payload(DESKTOP_WIDTH, DESKTOP_HEIGHT))

        ready = self.stderr.wait_for("event=virtual_display_ready", timeout=15)
        self.assertIsNotNone(ready, "no virtual_display_ready event: " +
                             "\n".join(self.stderr.snapshot()))
        self.assertIn("result=0", ready)
        self.assertIn("width=2560", ready)
        self.assertIn("height=1440", ready)
        ready_ms = int(ready.split("ms=")[1].split()[0])

        # ScreenCaptureKit sees the 2560x1440 virtual display (temporarily the
        # only display; the physical one mirrors it).
        displays = self.probe.parse()
        virtual = [d for d in displays if d["points"] == "2560x1440"]
        self.assertTrue(virtual, f"no 2560x1440 SCDisplay while mirrored: {displays}")
        self.assertEqual(virtual[0]["pixels"], "2560x1440")

        # The Agent's own frames become exactly 2560x1440 (1:1 capture).
        frame = self.wait_for_frame_size(worker, 2560, 1440, timeout=15)
        self.assertEqual(frame["width"], 2560)
        self.assertEqual(frame["height"], 1440)
        self.assertIn("display_size_changed native=2560x1440", "\n".join(self.stderr.snapshot()))

        # A second type 9 does not recreate the virtual display in v1.
        worker.send(CAPTURE_SIZE, capture_size_payload(1920, 1200))
        ignored = self.stderr.wait_for("event=virtual_display_resize_ignored", timeout=10)
        self.assertIsNotNone(ignored, "no virtual_display_resize_ignored event")
        self.assertIn("desktop=1920x1200", ignored)
        self.assertIn("current=2560x1440", ignored)

        # Type 17 peer teardown: unmirror and restore the original arrangement.
        worker.send(DISPLAY_RESTORE)
        teardown = self.stderr.wait_for("event=virtual_display_teardown", timeout=10)
        self.assertIsNotNone(teardown, "no virtual_display_teardown event")
        self.assertIn("result=0", teardown)
        worker.close()

        # Agent exits (socket closed); display arrangement is restored.
        self.agent.wait(timeout=15)
        self.stop_agent()
        restored = self.probe.parse()
        self.assertEqual(len(restored), 1, f"expected one display, got {restored}")
        self.assertEqual(restored[0]["id"], self.native_display_id)
        self.assertEqual(restored[0]["points"], self.native_points)
        self.assertEqual(restored[0]["pixels"], self.native_pixels)
        self.assertIn("event=display_state_after",
                      "\n".join(self.stderr.snapshot()))

        # Fix-round evidence: child stderr is captured, the physical mode is
        # saved and explicitly restored, and the parent verified the panel.
        log = "\n".join(self.stderr.snapshot())
        self.assertIn("event=virtual_display_child_stderr line=", log,
                      "child stderr is not captured by the parent")
        self.assertIn("virtual_display_child_mode_saved", log)
        self.assertIn("virtual_display_child_mode_restored_result=0", log)
        self.assertIn("virtual_display_physical_restore result=0 reason=teardown", log)
        self.assertNotIn("event=virtual_display_spawn result=1", log)
        self.assertNotIn("event=virtual_display_retry", log)

        # Report the measured numbers for the evidence trail.
        print(f"EVENT=measured ready_ms={ready_ms} native_before=1 "
              f"virtual_2560x1440=1 frames_2560x1440=1 teardown_result=0 restored_native=1")


    def test_feature_gate_off_keeps_historical_physical_capture(self):
        """Default OFF (no RDP_AGENT_VIRTUAL_DISPLAY): no child, no display change."""
        worker = self.start_agent(virtual_display_enabled=False)
        first = self.wait_for_any_frame(worker, timeout=20)
        self.assertEqual(first["bpp"], 4)
        worker.send(CAPTURE_SIZE, capture_size_payload(DESKTOP_WIDTH, DESKTOP_HEIGHT))
        # Desktop box 2560x1440 into the native 2940x1912 display => fit 2214x1440.
        frame = self.wait_for_frame_size(worker, 2214, 1440, timeout=15)
        self.assertEqual(frame["width"], 2214)
        self.assertIsNone(self.stderr.wait_for("event=virtual_display", timeout=0.5),
                          "virtual display must not start when the gate is off")
        displays = self.probe.parse()
        self.assertEqual(len(displays), 1, f"feature off changed the display set: {displays}")
        self.assertEqual(displays[0]["points"], self.native_points)
        worker.send(DISPLAY_RESTORE)
        worker.close()
        self.agent.wait(timeout=15)
        self.stop_agent()
        print("EVENT=measured feature_gate_off=1 child_spawned=0 frames_fit_2214x1440=1 "
              "restored_native=1")

    def test_agent_termination_restores_display(self):
        """Crash/kill path: the Agent is SIGTERM'ed while the virtual display is up.

        The child's stdin reaches EOF when the Agent dies, so it unmirrors and
        exits; WindowServer then removes the virtual display. No leftover child
        may remain, and the display arrangement must be restored.
        """
        worker = self.start_agent()
        self.wait_for_any_frame(worker, timeout=20)
        worker.send(CAPTURE_SIZE, capture_size_payload(DESKTOP_WIDTH, DESKTOP_HEIGHT))
        ready = self.stderr.wait_for("event=virtual_display_ready", timeout=15)
        self.assertIsNotNone(ready, "no virtual_display_ready event")
        displays = self.probe.parse()
        self.assertTrue(any(d["points"] == "2560x1440" for d in displays),
                        f"virtual display not up: {displays}")
        # Terminate the Agent without any IPC teardown. SIGTERM is handled by
        # the capture loop's graceful stop flag, but a fake worker that stops
        # reading frames can leave the writer blocked on a full socket buffer;
        # closing the socket unblocks it (like a worker that went away).
        self.agent.terminate()
        time.sleep(0.5)
        worker.close()
        try:
            self.agent.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.agent.kill()
            self.agent.wait(timeout=10)
        self.stop_agent()
        self.assertEqual(len(self.probe.parse()), 1)
        leftover = subprocess.run(["pgrep", "-f", f"{BINARY} virtual-display"],
                                  capture_output=True, text=True)
        self.assertEqual(leftover.stdout.strip(), "",
                         f"leftover virtual-display child: {leftover.stdout.strip()}")
        print("EVENT=measured agent_termination=1 display_restored=1 leftover_child=0")


    def test_stream_capture_with_virtual_display(self):
        """The deployed capture mode (SCStream + delta frames) keeps working.

        The LaunchAgent wrapper runs `RDP_AGENT_CAPTURE_STREAM=1
        RDP_AGENT_DELTA_FRAMES=1 RDP_AGENT_TARGET_FPS=60`; the virtual display
        must not force the slower snapshot fallback and the streamed frames must
        become exactly 2560x1440.
        """
        worker = self.start_agent(stream_capture=True)
        first = self.wait_for_any_frame(worker, timeout=25)
        self.assertEqual(first["bpp"], 4)
        worker.send(CAPTURE_SIZE, capture_size_payload(DESKTOP_WIDTH, DESKTOP_HEIGHT))
        ready = self.stderr.wait_for("event=virtual_display_ready", timeout=15)
        self.assertIsNotNone(ready, "no virtual_display_ready event: " +
                             "\n".join(self.stderr.snapshot()))
        frame = self.wait_for_frame_size(worker, 2560, 1440, timeout=25)
        self.assertIn("display_size_changed native=2560x1440", "\n".join(self.stderr.snapshot()))
        worker.send(DISPLAY_RESTORE)
        teardown = self.stderr.wait_for("event=virtual_display_teardown", timeout=10)
        self.assertIsNotNone(teardown)
        self.assertIn("result=0", teardown)
        worker.close()
        self.agent.wait(timeout=15)
        log = "\n".join(self.stderr.snapshot())
        self.assertNotIn("event=capture_stream_fallback", log,
                         "SCStream fell back to snapshot; virtual display broke the stream")
        self.assertIn("event=capture_config source=stream", log)
        self.stop_agent()
        self.assertEqual(len(self.probe.parse()), 1)
        print("EVENT=measured stream_capture=1 frames_2560x1440=1 stream_fallback=0 "
              "teardown_result=0 restored_native=1")


    def test_multi_session_reconnect_cycles(self):
        """Field sequence on one Agent process: 2560x1440, 1920x1080, 2560x1440.

        Each reconnect must spawn/ready successfully and the panel must be back
        to the Agent's startup native mode after every teardown (the 2026-11-08
        field bug left it at 1920x1080 after the second session, which made every
        later 2560x1440 spawn time out).
        """
        worker = self.start_agent()
        self.wait_for_any_frame(worker, timeout=20)
        cycles = [(2560, 1440), (1920, 1080), (2560, 1440)]
        ready_ms_values = []
        for width, height in cycles:
            ready_before = self.stderr.count("event=virtual_display_ready")
            teardown_before = self.stderr.count("event=virtual_display_teardown")
            worker.send(CAPTURE_SIZE, capture_size_payload(width, height))
            self.assertTrue(
                self.stderr.wait_for_count("event=virtual_display_ready", ready_before + 1, timeout=20),
                f"no ready for {width}x{height}: " + "\n".join(self.stderr.snapshot()[-15:]))
            with self.stderr.lock:
                ready_line = [line for line in self.stderr.lines
                              if "event=virtual_display_ready" in line][-1]
            self.assertIn("result=0", ready_line)
            ready_ms_values.append(int(ready_line.split("ms=")[1].split()[0]))
            # Exactly 1:1 capture of the negotiated box once the virtual display
            # is up (native == desktop box).
            self.wait_for_frame_size(worker, width, height, timeout=20)
            worker.send(DISPLAY_RESTORE)
            self.assertTrue(
                self.stderr.wait_for_count("event=virtual_display_teardown",
                                           teardown_before + 1, timeout=15),
                f"no teardown after {width}x{height}")
            with self.stderr.lock:
                teardown_lines = [line for line in self.stderr.lines
                                  if "event=virtual_display_teardown" in line]
            self.assertIn("result=0", teardown_lines[-1])
            self.wait_for_restored_native()
        log = "\n".join(self.stderr.snapshot())
        self.assertNotIn("event=virtual_display_spawn result=1", log)
        self.assertNotIn("event=virtual_display_retry", log)
        self.assertIn("virtual_display_child_mode_restored_result=0", log)
        worker.close()
        self.agent.wait(timeout=15)
        self.stop_agent()
        print(f"EVENT=measured multi_session=3 ready_ms={ready_ms_values} "
              f"spawn_failures=0 restored_native_after_each=1")

    def test_panel_recovers_from_non_native_mode(self):
        """A panel left in a scaled mode by an earlier session must recover.

        Simulates the field aftermath exactly: the Agent is already running with
        the native startup mode (2940x1912 recorded), then something leaves the
        panel at 1920x1080 (the field failure), and the next 2560x1440 session
        starts. The child must force the Agent's startup mode before mirroring,
        become ready, and restore the panel to that startup mode on teardown.
        """
        worker = self.start_agent()
        try:
            self.wait_for_any_frame(worker, timeout=20)
            # Leave the panel in a scaled mode AFTER the Agent captured its startup
            # mode, reproducing the field failure state.
            self.set_panel_mode(1920, 1200)
            worker.send(CAPTURE_SIZE, capture_size_payload(DESKTOP_WIDTH, DESKTOP_HEIGHT))
            ready = self.stderr.wait_for("event=virtual_display_ready result=0", timeout=20)
            self.assertIsNotNone(ready, "spawn failed from a non-native panel mode: " +
                                 "\n".join(self.stderr.snapshot()))
            self.wait_for_frame_size(worker, DESKTOP_WIDTH, DESKTOP_HEIGHT, timeout=20)
            log = "\n".join(self.stderr.snapshot())
            # The child forced the Agent's startup mode before creating/mirroring.
            self.assertIn("virtual_display_child_mode_restored_result=0_"
                          f"saved={self.native_pixels}_current={self.native_pixels}_"
                          "reason=pre_session", log)
            self.assertIn("event=virtual_display_child_stderr line=", log)
            worker.send(DISPLAY_RESTORE)
            teardown = self.stderr.wait_for("event=virtual_display_teardown", timeout=15)
            self.assertIsNotNone(teardown)
            self.assertIn("result=0", teardown)
            worker.close()
            self.agent.wait(timeout=15)
            self.wait_for_restored_native()
            print(f"EVENT=measured non_native_mid_session=1920x1200 session=2560x1440 "
                  f"ready=1 startup_mode_restored={self.native_pixels}")
        finally:
            worker.close()
            self.stop_agent()
            self.restore_native_mode()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verbose", action="store_true", help="stream agent stderr to console")
    args = parser.parse_args()
    if args.verbose:
        os.environ["RDP_VD_TEST_VERBOSE"] = "1"
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(VirtualDisplayIntegrationTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()

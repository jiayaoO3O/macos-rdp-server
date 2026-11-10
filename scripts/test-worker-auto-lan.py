#!/usr/bin/env python3
"""Verify address=auto binds one private LAN address and can stop cleanly."""

import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "bin/rdp-worker"


@contextlib.contextmanager
def short_temp_directory(prefix, socket_name):
    """Temp directory whose AF_UNIX socket path stays below 104 bytes.

    /tmp is tried first because the platform TMPDIR (/var/folders/...) is often
    too long for sun_path; fall back only when the resulting path still fits.
    """
    for base in ("/tmp", "/private/tmp", tempfile.gettempdir()):
        try:
            directory = tempfile.mkdtemp(prefix=prefix, dir=base)
        except OSError:
            continue
        if len(os.fsencode(os.path.join(directory, socket_name))) >= 104:
            shutil.rmtree(directory, ignore_errors=True)
            continue
        try:
            yield Path(directory)
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        return
    raise RuntimeError(
        "no writable temp directory keeps the Unix socket path under 104 bytes")


def write_auto_lan_config(directory, port):
    os.chmod(directory, 0o700)
    for name, content in (("sam", "alice:MACRDP::dummy:\n"),
                          ("key.pem", "not loaded until a client connects\n"),
                          ("cert.pem", "not loaded until a client connects\n")):
        path = directory / name
        path.write_text(content)
        os.chmod(path, 0o600)
    config = {
        "address": "auto", "allow_lan": True, "port": port,
        "account": "alice", "enabled": False,
        "certificate": str(directory / "cert.pem"),
        "key": str(directory / "key.pem"), "sam": str(directory / "sam"),
    }
    config_path = directory / "config.json"
    config_path.write_text(json.dumps(config))
    os.chmod(config_path, 0o600)
    return config_path, directory / "agent.sock"


class AutoLANWorkerTest(unittest.TestCase):
    def test_auto_address_starts_on_private_lan_and_supervisor_stops_child(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect(("192.0.2.1", 9))
            route_ip = route.getsockname()[0]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserve:
            reserve.bind((route_ip, 0))
            port = reserve.getsockname()[1]

        with short_temp_directory("worker-auto-lan-", "agent.sock") as directory:
            config_path, agent_socket = write_auto_lan_config(directory, port)
            process = subprocess.Popen(
                [str(WORKER), "-config", str(config_path), "-agent-socket", str(agent_socket)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                env={**os.environ, "RDP_TEST_RAW_BITMAP": "1", "WLOG_LEVEL": "ERROR"},
            )
            output = []
            deadline = time.monotonic() + 15
            try:
                selected = None
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    line = process.stdout.readline()
                    if line:
                        output.append(line)
                        match = re.search(r"event=lan_address_selected interface=([^ ]+) address=([^ ]+)", line)
                        if match:
                            selected = (match.group(1), match.group(2))
                        if selected and "event=listening" in line:
                            break
                self.assertIsNotNone(selected, "no selected LAN address; output=" + "".join(output))
                print(f"auto_lan_interface={selected[0]} address={selected[1]}")
                with socket.create_connection((selected[1], port), timeout=2):
                    pass
                process.terminate()
                process.communicate(timeout=8)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_supervised_child_restart_replaces_stale_socket(self):
        """A restarted FreeRDP child must still be able to create agent.sock."""
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect(("192.0.2.1", 9))
            route_ip = route.getsockname()[0]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserve:
            reserve.bind((route_ip, 0))
            port = reserve.getsockname()[1]

        with short_temp_directory("worker-restart-", "agent.sock") as directory:
            config_path, agent_socket = write_auto_lan_config(directory, port)
            process = subprocess.Popen(
                [str(WORKER), "-config", str(config_path), "-agent-socket", str(agent_socket)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                env={**os.environ, "RDP_TEST_RAW_BITMAP": "1", "WLOG_LEVEL": "ERROR"},
            )
            output = []

            def read_until(deadline, first_pid=None):
                """Return (started_pid, listening) observed before the deadline."""
                started = None
                listening = False
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    line = process.stdout.readline()
                    if not line:
                        continue
                    output.append(line)
                    match = re.search(r"event=lan_worker_started .*pid=(\d+)", line)
                    if match:
                        candidate = int(match.group(1))
                        if first_pid is None or candidate != first_pid:
                            started = candidate
                    if "event=agent_ipc_listening" in line and (started is not None):
                        listening = True
                        break
                return started, listening

            try:
                first_pid, listening = read_until(time.monotonic() + 15)
                self.assertIsNotNone(first_pid,
                                     "supervisor never started the child; output=" + "".join(output))
                self.assertTrue(listening, "first child never listened; output=" + "".join(output))
                os.kill(first_pid, signal.SIGKILL)
                second_pid, listening = read_until(time.monotonic() + 15, first_pid=first_pid)
                self.assertIsNotNone(second_pid,
                                     "supervisor did not restart the child; output=" + "".join(output))
                self.assertTrue(listening,
                                "restarted child could not listen on the stale socket; output="
                                + "".join(output))
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(2)
                    client.connect(str(agent_socket))
                process.terminate()
                process.communicate(timeout=8)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_managed_supervisor_stops_when_parent_dies(self):
        """A Worker spawned by the App must not survive an App crash/SIGKILL."""
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect(("192.0.2.1", 9))
            route_ip = route.getsockname()[0]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserve:
            reserve.bind((route_ip, 0))
            port = reserve.getsockname()[1]

        with short_temp_directory("worker-managed-", "agent.sock") as directory:
            config_path, agent_socket = write_auto_lan_config(directory, port)
            log_path = directory / "worker.log"
            # This wrapper stands in for the App: it spawns the Worker, waits
            # for it to listen, then exits, reparenting the Worker to launchd.
            wrapper = r"""
import subprocess, sys, time
log_path = sys.argv[1]
log = open(log_path, "ab")
process = subprocess.Popen(sys.argv[2:], stdout=log, stderr=log)
deadline = time.time() + 15
while time.time() < deadline:
    with open(log_path, "rb") as handle:
        if b"event=listening" in handle.read():
            break
    if process.poll() is not None:
        break
    time.sleep(0.1)
print(process.pid, flush=True)
time.sleep(0.2)
"""
            environment = {**os.environ, "RDP_TEST_RAW_BITMAP": "1",
                           "WLOG_LEVEL": "ERROR", "RDP_WORKER_MANAGED_BY_APP": "1"}
            completed = subprocess.run(
                [sys.executable, "-c", wrapper, str(log_path), str(WORKER),
                 "-config", str(config_path), "-agent-socket", str(agent_socket)],
                capture_output=True, text=True, timeout=30, env=environment,
            )
            self.assertEqual(completed.returncode, 0,
                             "wrapper failed: %s" % completed.stderr.strip())
            self.assertRegex(completed.stdout.strip(), r"^\d+$",
                             "wrapper did not report the Worker PID: %r" % completed.stdout)
            output = log_path.read_text(errors="replace")
            self.assertIn("event=listening", output,
                          "Worker never listened before the parent exited:\n" + output)
            try:
                deadline = time.monotonic() + 10
                leftover = ""
                while time.monotonic() < deadline:
                    completed = subprocess.run(["pgrep", "-fl", str(directory)],
                                               capture_output=True, text=True)
                    leftover = completed.stdout.strip()
                    if not leftover:
                        break
                    time.sleep(0.2)
                self.assertEqual(leftover, "",
                                 "managed Worker was orphaned: " + leftover)
                self.assertIn("event=worker_parent_exited",
                              log_path.read_text(errors="replace"),
                              "Worker did not log parent-exit cleanup")
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    probe.bind((route_ip, port))
            finally:
                completed = subprocess.run(["pgrep", "-f", str(directory)],
                                           capture_output=True, text=True)
                for pid in completed.stdout.split():
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except (ProcessLookupError, ValueError):
                        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)

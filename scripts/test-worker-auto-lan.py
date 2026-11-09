#!/usr/bin/env python3
"""Verify address=auto binds one private LAN address and can stop cleanly."""

import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
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


class AutoLANWorkerTest(unittest.TestCase):
    def test_auto_address_starts_on_private_lan_and_supervisor_stops_child(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
            route.connect(("192.0.2.1", 9))
            route_ip = route.getsockname()[0]
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reserve:
            reserve.bind((route_ip, 0))
            port = reserve.getsockname()[1]

        with short_temp_directory("worker-auto-lan-", "agent.sock") as directory:
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
            agent_socket = directory / "agent.sock"
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


if __name__ == "__main__":
    unittest.main(verbosity=2)

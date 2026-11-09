#!/usr/bin/env python3
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("agent-launchd.py")
SPEC = importlib.util.spec_from_file_location("agent_launchd", SCRIPT)
launchd = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launchd)
APP_SCRIPT = Path(__file__).with_name("package-agent-app.py")
APP_SPEC = importlib.util.spec_from_file_location("package_agent_app", APP_SCRIPT)
agent_app = importlib.util.module_from_spec(APP_SPEC)
APP_SPEC.loader.exec_module(agent_app)


class LaunchAgentPlistTests(unittest.TestCase):
    def test_builds_user_agent_for_private_runtime_paths(self):
        root = Path("/Users/example/rdp-server")
        socket_path = root / ".runtime/agent-compat.sock"
        job = launchd.build_job(root, socket_path)
        self.assertEqual(job["Label"], "com.rdp-server.agent")
        self.assertEqual(job["ProgramArguments"], [
            str(root / "scripts/run-agent-stream.sh"),
            str(root / "bin/RDPAgent.app/Contents/MacOS/rdp-agent"),
            str(socket_path),
            "0",
            str(root / ".runtime"),
        ])
        self.assertTrue(job["RunAtLoad"])
        self.assertEqual(job["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(job["ThrottleInterval"], 10)
        self.assertEqual(job["StandardOutPath"], str(root / ".runtime/agent-launchd.log"))

    def test_packages_agent_with_a_stable_tcc_bundle_identity(self):
        info = agent_app.build_info_plist()
        self.assertEqual(info["CFBundleIdentifier"], "com.rdp-server.agent")
        self.assertEqual(info["CFBundleExecutable"], "rdp-agent")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertTrue(info["LSUIElement"])
        self.assertIn(
            '=designated => identifier "com.rdp-server.agent"',
            agent_app.codesign_arguments(Path("/tmp/RDPAgent.app")),
        )

    def test_wrapper_advances_generation_beyond_worker_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / ".runtime"
            runtime.mkdir()
            agent = root / "rdp-agent"
            agent.write_text(
                "#!/bin/sh\n"
                "test \"$RDP_AGENT_NO_PERMISSION_REQUEST\" = 1 || exit 77\n"
                "printf '%s\\n' \"$*\"\n"
            )
            agent.chmod(0o700)
            (runtime / "worker.log").write_text(
                "event=agent_frame_received generation=13 frame_id=1\n"
            )
            wrapper = Path(__file__).with_name("run-agent-stream.sh")
            result = subprocess.run(
                [str(wrapper), str(agent), str(runtime / "agent.sock"), "0", str(runtime)],
                text=True,
                capture_output=True,
                env={**os.environ, "MOCK_STATUS": "screen_recording=granted accessibility=granted"},
                check=True,
            )
            self.assertEqual(result.stdout.strip(), f"stream-snapshot {runtime / 'agent.sock'} 0 0 14")
            self.assertEqual((runtime / "agent-generation").read_text(), "14\n")

    def test_wrapper_exits_cleanly_without_screen_recording_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / ".runtime"
            runtime.mkdir()
            agent = root / "rdp-agent"
            agent.write_text(
                "#!/bin/sh\n"
                "test \"$RDP_AGENT_NO_PERMISSION_REQUEST\" = 1 || exit 77\n"
                "printf '%s\\n' 'Screen Recording permission is missing'\n"
                "exit 0\n"
            )
            agent.chmod(0o700)
            wrapper = Path(__file__).with_name("run-agent-stream.sh")
            result = subprocess.run(
                [str(wrapper), str(agent), str(runtime / "agent.sock"), "0", str(runtime)],
                text=True,
                capture_output=True,
                env=os.environ.copy(),
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("Screen Recording", result.stdout)
            self.assertEqual((runtime / "agent-generation").read_text(), "1\n")


if __name__ == "__main__":
    unittest.main()

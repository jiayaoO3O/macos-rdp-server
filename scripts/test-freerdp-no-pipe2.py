#!/usr/bin/env python3
"""Ensure the FreeRDP/WinPR build cannot weak-import pipe2 on macOS.

macOS 26.5.1 libSystem does not export _pipe2; a build that references it
crashes in winpr_event_init() with PC=0. The dependency build disables the
CMake probe instead of editing FreeRDP sources, so this test guards the build
configuration and (optionally) the produced binary.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WINPR = ROOT / ".deps/freerdp-3.32.2/winpr/libwinpr"


class NoPipe2CompatibilityTest(unittest.TestCase):
    def test_builder_disables_pipe2_cmake_probe(self):
        builder = (ROOT / "scripts/build-freerdp.sh").read_text(encoding="utf-8")
        self.assertIn("-DWINPR_HAVE_PIPE2=OFF", builder)
        self.assertIn("FREERDP_BUILD_DIR", builder)
        self.assertIn("FREERDP_INSTALL_PREFIX", builder)

    def test_upstream_pipe2_call_sites_stay_guarded(self):
        """Upstream keeps pipe2() behind WINPR_HAVE_PIPE2; we only switch it off."""
        for relative in ("synch/event.c", "pipe/pipe.c", "synch/semaphore.c"):
            source = (WINPR / relative).read_text(encoding="utf-8")
            with self.subTest(source=relative):
                if "pipe2(" in source:
                    self.assertIn("WINPR_HAVE_PIPE2", source)

    def test_built_winpr_has_no_pipe2_import(self):
        import os
        import subprocess

        binary = os.environ.get("RDP_TEST_WINPR_DYLIB")
        if not binary:
            self.skipTest("set RDP_TEST_WINPR_DYLIB to a freshly built WinPR dylib")
        undefined = subprocess.check_output(["nm", "-u", binary], text=True)
        self.assertNotIn("_pipe2", undefined)


if __name__ == "__main__":
    unittest.main()

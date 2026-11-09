#!/usr/bin/env python3
"""Verify the FreeRDP dependency build stays loadable on macOS 26 and 27.

Root cause of the macOS 26.5.1 worker SIGSEGV: WinPR weak-imports `_pipe2`,
which only macOS 27 libSystem exports, so the import slot is NULL on 26 and
the call jumps to PC=0 inside winpr_event_init().

Two build settings keep the symbol out without editing FreeRDP sources:

* an explicit macOS SDK (CMAKE_OSX_SYSROOT) - CMake's availability-aware
  probes then reject pipe2 because the deployment target is macOS 14;
* -DWINPR_HAVE_PIPE2=OFF, which forces the portable pipe()+fcntl() path.

This test pins both, plus the isolated build/install directories that let the
two SDK variants coexist under .deps/ without clobbering each other.
"""
from pathlib import Path
import os
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FreeRDPSDKSelectionTest(unittest.TestCase):
    def setUp(self):
        self.builder = (ROOT / "scripts/build-freerdp.sh").read_text(encoding="utf-8")

    def test_builder_selects_explicit_sdk(self):
        self.assertIn("-DCMAKE_OSX_SYSROOT=", self.builder)
        self.assertIn("MACOSX_SDK_ROOT", self.builder)

    def test_builder_forces_portable_pipe_fallback(self):
        self.assertIn("-DWINPR_HAVE_PIPE2=OFF", self.builder)

    def test_builder_keeps_minimum_macos_14(self):
        self.assertIn("-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", self.builder)

    def test_builder_supports_isolated_build_and_install_dirs(self):
        self.assertIn("FREERDP_BUILD_DIR", self.builder)
        self.assertIn("FREERDP_INSTALL_PREFIX", self.builder)

    def test_builder_disables_optional_opus(self):
        # Homebrew opus ships headers CMake cannot find on this host; the
        # product does not use opus, and a failed probe must not break a clean
        # dependency build.
        self.assertIn("-DWITH_OPUS=OFF", self.builder)

    def test_sdk_build_cache_disables_pipe2(self):
        """When a configured cache exists, it must have pipe2 off for macOS 14."""
        candidates = [os.environ.get("FREERDP_BUILD_DIR"), ".deps/build-macos26", ".deps/build"]
        for candidate in candidates:
            if not candidate:
                continue
            cache = Path(candidate) / "CMakeCache.txt"
            if not cache.is_absolute():
                cache = ROOT / cache
            if not cache.is_file():
                continue
            text = cache.read_text(encoding="utf-8")
            self.assertIn("CMAKE_OSX_DEPLOYMENT_TARGET:UNINITIALIZED=14.0", text)
            self.assertRegex(text, r"WINPR_HAVE_PIPE2:(?:INTERNAL|UNINITIALIZED)=\n")
            return
        self.skipTest("no configured FreeRDP CMake cache found")


if __name__ == "__main__":
    unittest.main()

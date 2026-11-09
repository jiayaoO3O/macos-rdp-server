#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class FrameGenerationTest(unittest.TestCase):
    def test_new_generation_is_new_even_when_frame_id_restarts(self):
        source = r'''
#include "frame_generation.h"
int main(void) {
  if (!rdp_frame_is_new(82, 1, 81, 408)) return 1;
  if (rdp_frame_is_new(81, 500, 82, 1)) return 2;
  if (!rdp_frame_is_new(82, 2, 82, 1)) return 3;
  if (rdp_frame_is_new(82, 1, 82, 1)) return 4;
  return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "frame-test"
            result = subprocess.run(
                ["cc", "-std=c11", "-I", str(ROOT / "internal/worker"),
                 "-x", "c", "-", "-o", str(executable)],
                input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"comparison case {result.returncode} failed")


if __name__ == "__main__":
    unittest.main()

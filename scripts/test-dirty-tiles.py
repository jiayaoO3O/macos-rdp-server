#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class DirtyTilesTest(unittest.TestCase):
    def test_changed_tiles_and_edge_tiles(self):
        source = r'''
#include "dirty_tiles.h"
#include <string.h>
int main(void) {
 unsigned char previous[65*65*4] = {0}, current[65*65*4] = {0};
 if (!rdp_tile_changed(current, NULL, 65, 0, 0, 64, 64)) return 1;
 if (rdp_tile_changed(current, previous, 65, 0, 0, 64, 64)) return 2;
 current[(64*65+64)*4+2] = 1;
 if (!rdp_tile_changed(current, previous, 65, 64, 64, 1, 1)) return 3;
 if (rdp_tile_changed(current, previous, 65, 0, 0, 64, 64)) return 4;
 current[(7*65+8)*4] = 2;
 if (!rdp_tile_changed(current, previous, 65, 0, 0, 64, 64)) return 5;
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "test"
            compile_result = subprocess.run(["cc", "-std=c11", "-I", str(ROOT / "internal/worker"), "-x", "c", "-", "-o", str(executable)], input=source, text=True, capture_output=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(executable)])
            self.assertEqual(result.returncode, 0, f"case {result.returncode} failed")


if __name__ == "__main__":
    unittest.main()

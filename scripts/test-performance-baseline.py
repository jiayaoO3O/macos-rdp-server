#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("performance_baseline", Path(__file__).with_name("performance-baseline.py"))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class BaselineTest(unittest.TestCase):
    def test_counts_unique_frames_per_generation_and_reports_window_rates(self):
        events = [
            "event=agent_frame_received generation=1 frame_id=8 width=4 height=3 bytes=48",
            "event=agent_frame_received generation=2 frame_id=1 width=4 height=3 bytes=48",
            "event=desktop_frame_sent generation=1 frame_id=8 batches=1 tiles=1 encoding=raw",
            "event=desktop_frame_sent generation=1 frame_id=8 batches=1 tiles=1 encoding=raw",
            "event=desktop_frame_sent generation=2 frame_id=1 batches=1 tiles=1 encoding=raw",
            "event=clipboard_local_changed secret=never-report-this",
        ]
        result = baseline.summarize(events, 10.0)
        self.assertEqual(result["received_unique_frames"], 2)
        self.assertEqual(result["sent_unique_frames"], 2)
        self.assertEqual(result["sent_events"], 3)
        self.assertEqual(result["received_fps"], 0.2)
        self.assertEqual(result["sent_fps"], 0.2)
        self.assertEqual(result["source_sizes"], ["4x3"])
        self.assertEqual(result["encodings"], ["raw"])
        self.assertNotIn("never-report-this", str(result))

    def test_ignores_malformed_and_non_frame_events(self):
        result = baseline.summarize(["event=desktop_frame_sent generation=2 frame_id=nope", "event=other generation=1 frame_id=2"], 2)
        self.assertEqual(result["sent_unique_frames"], 0)
        self.assertEqual(result["sent_fps"], 0)

    def test_rejects_nonpositive_window(self):
        with self.assertRaises(ValueError):
            baseline.summarize([], 0)


if __name__ == "__main__":
    unittest.main()

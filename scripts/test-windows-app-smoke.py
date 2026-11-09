#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("windows-app-smoke.py")
SPEC = importlib.util.spec_from_file_location("windows_app_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class WorkerLogTests(unittest.TestCase):
    def test_observation_uses_a_post_window_settle_period(self):
        args = smoke.build_parser().parse_args([])
        self.assertEqual(args.duration, 30)
        self.assertEqual(args.settle_seconds, 3)

    def test_finds_latest_authorization_line_for_existing_session_mode(self):
        log = (b"event=authorized old\nlease\n"
               b"event=authorized backend=authorized-session\nframe\n")
        offset = smoke.latest_authorized_offset(log)
        self.assertEqual(log[offset:], b"event=authorized backend=authorized-session\nframe\n")

    def test_latest_authorization_offset_starts_at_line_boundary(self):
        log = b"prefix event=authorized old\nstatus\nevent=authorized new\n"
        offset = smoke.latest_authorized_offset(log)
        self.assertEqual(log[offset:], b"event=authorized new\n")

    def test_accepts_authorized_full_frame_that_stays_connected(self):
        log = "\n".join([
            "2026/11/04 14:00:00 event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=1",
            "event=desktop_frame_sent generation=5 frame_id=1 batches=576 tiles=576 encoding=raw",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertTrue(result.passed)
        self.assertEqual(result.reason, "")

    def test_accepts_raw_fallback_without_advertising_nscodec(self):
        log = "\n".join([
            "event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=0",
            "event=desktop_frame_sent generation=5 frame_id=1 batches=1 tiles=576 encoding=raw",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertTrue(result.passed, result.reason)

    def test_accepts_full_planar_frame_for_production_encoding(self):
        log = "\n".join([
            "event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=1",
            "event=desktop_frame_sent generation=5 frame_id=1 batches=576 tiles=576 encoding=planar",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertTrue(result.passed)

    def test_rejects_session_released_before_observation_window(self):
        log = "\n".join([
            "event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=1",
            "event=desktop_frame_sent generation=5 frame_id=1 batches=576 tiles=576 encoding=raw",
            "event=lease_released",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertFalse(result.passed)
        self.assertIn("released", result.reason)

    def test_rejects_partial_frame(self):
        log = "\n".join([
            "event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=1",
            "event=desktop_frame_sent generation=5 frame_id=1 batches=2 tiles=2 encoding=raw",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertFalse(result.passed)
        self.assertIn("full desktop frame", result.reason)


class AccessibilityScriptTests(unittest.TestCase):
    def test_press_script_walks_accessibility_elements_and_uses_axpress(self):
        script = smoke.build_press_script("device \"name\"")
        self.assertIn("repeat with elementRef in allElements", script)
        self.assertIn('perform action "AXPress"', script)
        self.assertIn("description of elementRef", script)
        self.assertIn('device \\"name\\"', script)

    def test_smoke_cli_can_observe_existing_connection_without_pressing_card(self):
        args = smoke.build_parser().parse_args(["--existing-session"])
        self.assertTrue(args.existing_session)


class UnifiedLogSummaryTests(unittest.TestCase):
    def test_summarizes_coredata_without_echoing_private_record_details(self):
        summary = smoke.summarize_unified_logs(
            'Windows App: failed saving to storage: username="private-user"\n'
            'Windows App: PopulateCacCodecCaps failed!\n'
            'Windows App: Bitmap Decompression Failed\n'
        )
        self.assertIn("CoreData warning/error", summary)
        self.assertIn("PopulateCacCodecCaps", summary)
        self.assertIn("Bitmap Decompression Failed", summary)
        self.assertNotIn("private-user", summary)


class WorkerLogSummaryTests(unittest.TestCase):
    def test_summarizes_repeated_frame_events(self):
        summary = smoke.summarize_worker_log("\n".join([
            "event=authorized backend=authorized-session",
            "event=peer_codecs nscodec=1",
            "event=desktop_frame_sent generation=10 frame_id=22 batches=576 tiles=576 encoding=raw",
            "event=desktop_frame_sent generation=10 frame_id=23 batches=576 tiles=576 encoding=raw",
        ]))
        self.assertIn("event=authorized", summary)
        self.assertIn("frames_sent=2", summary)
        self.assertIn("frame_id=22", summary)
        self.assertIn("frame_id=23", summary)

    def test_rejects_frame_before_authentication(self):
        log = "\n".join([
            "event=desktop_frame_sent generation=5 frame_id=1 batches=576 tiles=576 encoding=raw",
            "event=peer_codecs nscodec=1",
            "event=authorized backend=authorized-session",
        ])
        result = smoke.evaluate_worker_log(log, minimum_tiles=500)
        self.assertFalse(result.passed)
        self.assertIn("full desktop frame", result.reason)


if __name__ == "__main__":
    unittest.main()

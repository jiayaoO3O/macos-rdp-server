#!/usr/bin/env python3
"""Unit tests for scripts/benchmark-fps.py parsing/summary helpers.

No worker or network is needed: these tests cover the IPC message encoders,
probe/worker log parsers and the JSON summary math, so a regression in the
harness bookkeeping fails fast before any real benchmark runs.

Run with: python3 scripts/test-benchmark-fps.py
"""
import importlib.util
import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bench = _load("benchmark_fps", "scripts/benchmark-fps.py")


def decode_messages(blob):
    """Split a concatenated agent IPC stream into (type, payload) pairs."""
    messages = []
    position = 0
    while position < len(blob):
        magic = blob[position:position + 4]
        version, message_type, length = struct.unpack(">HHI", blob[position + 4:position + 12])
        payload = blob[position + 12:position + 12 + length]
        if magic != bench.MAGIC or version != bench.IPC_VERSION:
            raise AssertionError("bad IPC header at offset %d" % position)
        if len(payload) != length:
            raise AssertionError("truncated IPC payload at offset %d" % position)
        messages.append((message_type, payload))
        position += 12 + length
    return messages


class IpcMessageTests(unittest.TestCase):
    def test_header_layout(self):
        message = bench.ipc_message(bench.MSG_DELTA_END, struct.pack(">QQI", 1, 2, 3))
        self.assertEqual(message[:4], b"RDPA")
        version, message_type, length = struct.unpack(">HHI", message[4:12])
        self.assertEqual(version, 1)
        self.assertEqual(message_type, bench.MSG_DELTA_END)
        self.assertEqual(length, 20)
        self.assertEqual(len(message), 12 + 20)

    def test_full_frame_round_trip(self):
        width, height = 130, 70
        pixels = bytes((index * 7) & 0xFF for index in range(width * height * 4))
        blob = bench.encode_full_frame_messages(pixels, width, height, generation=3, frame_id=4)
        messages = decode_messages(blob)
        self.assertEqual(messages[0][0], bench.MSG_FRAME_BEGIN)
        self.assertEqual(struct.unpack(">QQIIB", messages[0][1]), (3, 4, width, height, 4))
        assembled = bytearray()
        for message_type, payload in messages[1:]:
            self.assertEqual(message_type, bench.MSG_FRAME_CHUNK)
            generation, frame_id, offset = struct.unpack(">QQI", payload[:20])
            self.assertEqual((generation, frame_id), (3, 4))
            self.assertEqual(offset, len(assembled))
            self.assertLessEqual(len(payload), 65536)
            assembled += payload[20:]
        self.assertEqual(bytes(assembled), pixels)

    def test_full_frame_rejects_wrong_size(self):
        with self.assertRaises(bench.HarnessError):
            bench.encode_full_frame_messages(b"\x00" * 12, 4, 4, 1, 1)

    def test_delta_frame_round_trip(self):
        width, height = 130, 70
        tiles = bench.tile_grid(width, height)
        frame = bytearray(width * height * 4)
        for x, y, _tile_width, _tile_height in tiles:
            index = (y * width + x) * 4
            frame[index:index + 4] = b"\x01\x02\x03\x00"
        blob = bench.encode_delta_frame_messages(frame, width, height, 1, 2, tiles)
        messages = decode_messages(blob)
        self.assertEqual(messages[0][0], bench.MSG_DELTA_BEGIN)
        generation, frame_id, begin_width, begin_height, bpp, count = struct.unpack(
            ">QQIIBI", messages[0][1])
        self.assertEqual((generation, frame_id, begin_width, begin_height, bpp, count),
                         (1, 2, width, height, 4, len(tiles)))
        self.assertEqual(messages[-1][0], bench.MSG_DELTA_END)
        self.assertEqual(struct.unpack(">QQI", messages[-1][1]), (1, 2, len(tiles)))
        for message_type, payload in messages[1:-1]:
            self.assertEqual(message_type, bench.MSG_DELTA_TILE)
            generation, frame_id, x, y, tile_width, tile_height = struct.unpack(
                ">QQIIHH", payload[:28])
            self.assertEqual((generation, frame_id), (1, 2))
            self.assertIn((x, y, tile_width, tile_height), tiles)
            self.assertEqual(len(payload), 28 + tile_width * tile_height * 4)

    def test_delta_frame_requires_tiles(self):
        with self.assertRaises(bench.HarnessError):
            bench.encode_delta_frame_messages(bytearray(16), 2, 2, 1, 1, [])


class TileGridTests(unittest.TestCase):
    def test_exact_multiple(self):
        tiles = bench.tile_grid(192, 128)
        self.assertEqual(len(tiles), 3 * 2)
        self.assertEqual(tiles[0], (0, 0, 64, 64))
        self.assertEqual(tiles[-1], (128, 64, 64, 64))

    def test_clipped_edges(self):
        tiles = bench.tile_grid(130, 70)
        self.assertEqual(len(tiles), 3 * 2)
        self.assertEqual(tiles[-1], (128, 64, 2, 6))
        self.assertTrue(all(width <= 64 and height <= 64 for _x, _y, width, height in tiles))

    def test_rejects_empty(self):
        with self.assertRaises(bench.HarnessError):
            bench.tile_grid(0, 64)


class FrameProducerTests(unittest.TestCase):
    def test_small_scenario_changes_only_requested_tiles(self):
        producer = bench.FrameProducer(256, 192, "small", changed_tiles=3, seed=1)
        producer.initial_messages()
        before = bytearray(producer.frame)
        blob = producer.next_messages()
        messages = decode_messages(blob)
        self.assertEqual(messages[0][0], bench.MSG_DELTA_BEGIN)
        changed = [struct.unpack(">QQIIHH", payload[:28])[2:6] for _type, payload in messages
                   if _type == bench.MSG_DELTA_TILE]
        self.assertEqual(len(changed), 3)
        self.assertEqual(producer.frame_id, 2)
        changed_pixels = 0
        for index, (old, new) in enumerate(zip(before, producer.frame)):
            if old != new:
                changed_pixels += 1
        self.assertLessEqual(changed_pixels, 3 * 4)

    def test_full_scenario_changes_every_tile(self):
        producer = bench.FrameProducer(256, 192, "full", changed_tiles=1, seed=1)
        before = bytes(producer.frame)
        blob = producer.next_messages()
        messages = decode_messages(blob)
        self.assertEqual(messages[0][0], bench.MSG_FRAME_BEGIN)
        after = bytes(producer.frame)
        for x, y, _width, _height in bench.tile_grid(256, 192):
            index = (y * 256 + x) * 4
            self.assertNotEqual(before[index:index + 4], after[index:index + 4],
                                "tile %d,%d did not change" % (x, y))

    def test_frame_ids_increase(self):
        producer = bench.FrameProducer(128, 128, "small", changed_tiles=1, seed=1)
        producer.initial_messages()
        self.assertEqual(producer.frame_id, 1)
        producer.next_messages()
        producer.next_messages()
        self.assertEqual(producer.frame_id, 3)


class ProbeBenchParserTests(unittest.TestCase):
    def test_full_line(self):
        probe = bench.parse_probe_bench(
            "noise\nbench seconds=5.000 bitmap_updates=42 bitmap_rectangles=2500 "
            "bitmap_bytes=12345678 pdu_per_s=8.40 mbit_per_s=19.753 gdi=1472x960 "
            "framebuffer_crc32=0x1A2B3C4D\nbitmap_update_seen\n")
        self.assertEqual(probe["seconds"], 5.0)
        self.assertEqual(probe["bitmap_updates"], 42)
        self.assertEqual(probe["bitmap_rectangles"], 2500)
        self.assertEqual(probe["bitmap_bytes"], 12345678)
        self.assertEqual(probe["pdu_per_s"], 8.40)
        self.assertEqual(probe["mbit_per_s"], 19.753)
        self.assertEqual(probe["framebuffer_crc32"], "0x1a2b3c4d")
        self.assertEqual((probe["gdi_width"], probe["gdi_height"]), (1472, 960))

    def test_line_without_gdi_field(self):
        probe = bench.parse_probe_bench(
            "bench seconds=10.000 bitmap_updates=42 bitmap_rectangles=2500 "
            "bitmap_bytes=12345678 pdu_per_s=4.20 mbit_per_s=9.877 "
            "framebuffer_crc32=0x1a2b3c4d")
        self.assertEqual(probe["seconds"], 10.0)
        self.assertNotIn("gdi_width", probe)

    def test_missing_line_raises(self):
        with self.assertRaises(bench.HarnessError):
            bench.parse_probe_bench("gfx_frame_ok\n")

    def test_missing_field_raises(self):
        with self.assertRaises(bench.HarnessError):
            bench.parse_probe_bench("bench seconds=5 bitmap_updates=1")

    def test_zero_window_raises(self):
        with self.assertRaises(bench.HarnessError):
            bench.parse_probe_bench("bench seconds=0 bitmap_updates=1 bitmap_rectangles=1 "
                                    "bitmap_bytes=1 pdu_per_s=0 mbit_per_s=0 "
                                    "framebuffer_crc32=0x0")


class FrameLogParserTests(unittest.TestCase):
    def test_current_format(self):
        text = (
            "event=agent_frame_received generation=1 frame_id=1 width=2944 height=1920 bytes=1\n"
            "event=desktop_frame_sent generation=1 frame_id=1 batches=1380 tiles=1380 "
            "bytes=718940 pdus=1380 encoding=planar\n"
            "unrelated line\n"
            "event=desktop_frame_sent generation=1 frame_id=2 batches=2 tiles=3 "
            "bytes=1024 pdus=2 encoding=planar\n")
        frames = bench.parse_frame_log(text)
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[0], {"generation": 1, "frame_id": 1, "batches": 1380,
                                     "tiles": 1380, "bytes": 718940, "pdus": 1380,
                                     "encoding": "planar"})
        self.assertEqual(frames[1]["pdus"], 2)

    def test_legacy_format_without_size_fields(self):
        frames = bench.parse_frame_log(
            "event=desktop_frame_sent generation=1 frame_id=1 batches=1380 tiles=1380 "
            "encoding=planar\n")
        self.assertEqual(len(frames), 1)
        self.assertIsNone(frames[0]["bytes"])
        self.assertIsNone(frames[0]["pdus"])

    def test_no_lines(self):
        self.assertEqual(bench.parse_frame_log("event=listening\n"), [])


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.probe = {
            "seconds": 5.0,
            "pdu_per_s": 10.0,
            "mbit_per_s": 20.0,
            "bitmap_updates": 50,
            "bitmap_rectangles": 100,
            "bitmap_bytes": 100,
            "framebuffer_crc32": "0xdeadbeef",
        }
        self.frames = [
            {"generation": 1, "frame_id": 1, "batches": 2, "tiles": 10,
             "bytes": 1000000, "pdus": 2, "encoding": "planar"},
            {"generation": 1, "frame_id": 2, "batches": 4, "tiles": 20,
             "bytes": 3000000, "pdus": 4, "encoding": "planar"},
        ]

    def test_summary_numbers(self):
        summary = bench.summarize(self.probe, self.frames, "small", 2944, 1920)
        self.assertEqual(summary["scenario"], "small")
        self.assertEqual(summary["desktop_size"], "2944x1920")
        self.assertEqual((summary["desktop_width"], summary["desktop_height"]), (2944, 1920))
        self.assertEqual(summary["window_seconds"], 5.0)
        self.assertEqual(summary["frames_sent"], 2)
        self.assertAlmostEqual(summary["sent_fps"], 0.4, places=6)
        self.assertEqual(summary["tiles_per_frame"], 15.0)
        self.assertEqual(summary["pdus_per_frame"], 3.0)
        self.assertEqual(summary["bytes_per_frame"], 2000000.0)
        self.assertAlmostEqual(summary["worker_mbit_per_s"], 6.4, places=6)
        self.assertEqual(summary["client_pdu_per_s"], 10.0)
        self.assertEqual(summary["client_mbit_per_s"], 20.0)
        self.assertEqual(summary["client_framebuffer_crc32"], "0xdeadbeef")
        self.assertEqual(summary["encoding"], "planar")

    def test_no_frames_raises(self):
        with self.assertRaises(bench.HarnessError):
            bench.summarize(self.probe, [], "small", 100, 100)

    def test_legacy_frames_rejected(self):
        with self.assertRaises(bench.HarnessError):
            bench.summarize(self.probe, [{"generation": 1, "frame_id": 1, "batches": 1,
                                          "tiles": 1, "bytes": None, "pdus": None,
                                          "encoding": "planar"}], "small", 100, 100)

    def test_multiple_encodings_are_listed(self):
        frames = self.frames + [{"generation": 1, "frame_id": 3, "batches": 1, "tiles": 1,
                                 "bytes": 1, "pdus": 1, "encoding": "raw"}]
        summary = bench.summarize(self.probe, frames, "full", 100, 100)
        self.assertEqual(summary["encoding"], "planar,raw")


class EnvironmentNoteTests(unittest.TestCase):
    def test_note_states_scope(self):
        note = bench.environment_note()
        self.assertIn("loopback", note)
        self.assertIn("NOT Windows App", note)
        self.assertIn("loadavg", note)


class CleanEnvironmentTests(unittest.TestCase):
    def test_strips_test_hooks(self):
        import os
        os.environ["RDP_TEST_RAW_BITMAP"] = "1"
        os.environ["RDP_TRANSPORT_DUMP"] = "/tmp/should-not-leak"
        os.environ["RDP_PROBE_BENCH_SECONDS"] = "9"
        try:
            env = bench.clean_environment()
        finally:
            del os.environ["RDP_TEST_RAW_BITMAP"]
            del os.environ["RDP_TRANSPORT_DUMP"]
            del os.environ["RDP_PROBE_BENCH_SECONDS"]
        self.assertNotIn("RDP_TEST_RAW_BITMAP", env)
        self.assertNotIn("RDP_TRANSPORT_DUMP", env)
        self.assertNotIn("RDP_PROBE_BENCH_SECONDS", env)
        self.assertEqual(env["WLOG_LEVEL"], "ERROR")

    def test_extra_values_override(self):
        env = bench.clean_environment({"RDP_PROBE_BENCH_SECONDS": "5"})
        self.assertEqual(env["RDP_PROBE_BENCH_SECONDS"], "5")


class VerifyHelpersTests(unittest.TestCase):
    """Helpers shared with scripts/verify-incremental-frames.py."""

    @classmethod
    def setUpClass(cls):
        cls.verify = _load("verify_incremental_frames", "scripts/verify-incremental-frames.py")

    def test_initial_pixels_is_deterministic_and_alpha_zero(self):
        first = self.verify.initial_pixels(32, 16, 7)
        second = self.verify.initial_pixels(32, 16, 7)
        other = self.verify.initial_pixels(32, 16, 8)
        self.assertEqual(len(first), 32 * 16 * 4)
        self.assertEqual(first, second)
        self.assertNotEqual(first, other)
        self.assertEqual(set(first[3::4]), {0})

    def test_mutate_tiles_stays_inside_tiles(self):
        import random as random_module
        width, height = 130, 70
        pixels = self.verify.initial_pixels(width, height, 3)
        before = bytes(pixels)
        tiles = bench.tile_grid(width, height)
        self.verify.mutate_tiles(pixels, width, height, tiles, random_module.Random(5))
        changed = [index // 4 for index, (old, new) in enumerate(zip(before, pixels)) if old != new]
        self.assertTrue(changed)
        allowed = set()
        for x, y, tile_width, tile_height in tiles:
            for row in range(tile_height):
                for column in range(tile_width):
                    allowed.add((y + row) * width + x + column)
        self.assertTrue(set(changed).issubset(allowed))

    def test_parse_frame_stats(self):
        stats = self.verify.parse_frame_stats(
            "event=desktop_frame_sent generation=1 frame_id=1 batches=2 tiles=10 "
            "bytes=100 pdus=2 encoding=planar\n"
            "event=desktop_frame_sent generation=1 frame_id=2 batches=4 tiles=20 "
            "bytes=200 pdus=4 encoding=planar\n")
        self.assertEqual(stats["frames"], 2)
        self.assertEqual(stats["mean_tiles_per_frame"], 15.0)
        self.assertEqual(stats["mean_pdus_per_frame"], 3.0)

    def test_parse_frame_stats_empty(self):
        stats = self.verify.parse_frame_stats("event=listening\n")
        self.assertEqual(stats["frames"], 0)
        self.assertIsNone(stats["mean_tiles_per_frame"])


class LiveAgentHelperTests(unittest.TestCase):
    """Helpers shared with scripts/benchmark-live-agent.py (no real capture needed)."""

    @classmethod
    def setUpClass(cls):
        cls.live = _load("benchmark_live_agent", "scripts/benchmark-live-agent.py")

    def test_parse_legacy_snapshot_timing(self):
        timings = self.live.parse_snapshot_timings(
            "event=snapshot_timing samples=30 width=2940 height=1912 capture_ms=41.1 "
            "conversion_ms=18.1 ipc_ms=8.1\n")
        self.assertEqual(len(timings), 1)
        record = timings[0]
        self.assertEqual((record["samples"], record["width"], record["height"]), (30, 2940, 1912))
        self.assertEqual((record["capture_ms"], record["conversion_ms"], record["ipc_ms"]),
                         (41.1, 18.1, 8.1))
        self.assertNotIn("target_fps", record)

    def test_parse_extended_snapshot_timing(self):
        line = ("event=snapshot_timing samples=30 width=1470 height=956 capture_ms=36.4 "
                "conversion_ms=16.4 ipc_ms=6.1 source=snapshot requested_width=1470 "
                "requested_height=956 image_width=1470 image_height=956 target_fps=30 "
                "loop_ms=62.3 overlap=1 convert=bit-exact\n")
        record = self.live.parse_snapshot_timings(line)[0]
        self.assertEqual(record["source"], "snapshot")
        self.assertEqual(record["target_fps"], 30)
        self.assertEqual(record["loop_ms"], 62.3)
        self.assertEqual(record["convert"], "bit-exact")

    def test_mean_field(self):
        records = [{"capture_ms": 10.0}, {"capture_ms": 20.0}, {}]
        self.assertEqual(self.live.mean_field(records, "capture_ms"), 15.0)
        self.assertIsNone(self.live.mean_field([], "capture_ms"))

    def test_agent_source_sizes(self):
        text = ("event=agent_frame_received generation=1 frame_id=1 width=2940 height=1912 bytes=1\n"
                "event=agent_frame_received generation=1 frame_id=2 width=2940 height=1912 bytes=1\n"
                "event=agent_frame_received generation=1 frame_id=3 width=1470 height=956 bytes=1\n")
        self.assertEqual(self.live.agent_source_sizes(text), ["2940x1912", "1470x956"])
        self.assertEqual(self.live.agent_source_sizes("event=listening\n"), [])

    def test_motion_seconds_for(self):
        self.assertEqual(self.live.motion_seconds_for(12), 24)
        self.assertEqual(self.live.motion_seconds_for(1), 15)

    def test_build_live_summary(self):
        probe = {"seconds": 10.0, "pdu_per_s": 5.0, "mbit_per_s": 50.0, "bitmap_updates": 50,
                 "bitmap_rectangles": 100, "bitmap_bytes": 1000,
                 "framebuffer_crc32": "0xdeadbeef"}
        frames = [{"generation": 1, "frame_id": 1, "batches": 2, "tiles": 10,
                   "bytes": 1000, "pdus": 2, "encoding": "planar"}]
        worker_text = ("event=agent_frame_received generation=1 frame_id=1 width=2940 "
                       "height=1912 bytes=1\n"
                       "event=agent_frame_received generation=1 frame_id=2 width=2940 "
                       "height=1912 bytes=1\n")
        agent_text = ("event=snapshot_timing samples=30 width=2940 height=1912 capture_ms=40.0 "
                      "conversion_ms=20.0 ipc_ms=10.0\n")
        summary = self.live.build_live_summary(probe, frames, worker_text, agent_text, 2940, 1912)
        self.assertEqual(summary["scenario"], "live-agent")
        self.assertEqual(summary["agent_frames_received"], 2)
        self.assertEqual(summary["agent_fps_produced"], 0.2)
        self.assertEqual(summary["worker_fps_delivered"], 0.1)
        self.assertEqual(summary["agent_capture_ms_mean"], 40.0)
        self.assertEqual(summary["agent_conversion_ms_mean"], 20.0)
        self.assertEqual(summary["agent_source_sizes"], ["2940x1912"])
        self.assertEqual(summary["client_framebuffer_crc32"], "0xdeadbeef")

    def test_live_environment_note(self):
        note = self.live.live_environment_note(True)
        self.assertIn("real-pipeline", note)
        self.assertIn("NOT Windows App", note)
        self.assertIn("live service capture agent", note)
        self.assertIn("no pre-existing live capture agent detected",
                      self.live.live_environment_note(False))

    def test_collect_warnings(self):
        result = {"agent_source_sizes": ["1470x956"], "agent_timing_lines": 0,
                  "sent_fps": 1.0, "agent_fps_produced": 10.0}
        warnings = self.live.collect_warnings(result, False, 2940, 1912, agent_timing_warm=False)
        joined = " | ".join(warnings)
        self.assertIn("motion window exited", joined)
        self.assertIn("rescaled", joined)
        self.assertIn("no event=snapshot_timing", joined)
        self.assertIn("timing did not flush", joined)


class LiveAgentEnvTests(unittest.TestCase):
    """--agent-env handling for scripts/benchmark-live-agent.py."""

    @classmethod
    def setUpClass(cls):
        cls.live = _load("benchmark_live_agent", "scripts/benchmark-live-agent.py")

    def test_defaults(self):
        env = self.live.parse_agent_env([])
        self.assertEqual(env["RDP_AGENT_NO_PERMISSION_REQUEST"], "1")
        self.assertEqual(env["RDP_AGENT_DELTA_FRAMES"], "1")

    def test_overrides(self):
        env = self.live.parse_agent_env(["RDP_AGENT_CAPTURE_STREAM=1",
                                         "RDP_AGENT_TARGET_FPS=60"])
        self.assertEqual(env["RDP_AGENT_CAPTURE_STREAM"], "1")
        self.assertEqual(env["RDP_AGENT_TARGET_FPS"], "60")

    def test_rejects_malformed(self):
        # The live module loads its own benchmark-fps instance, so use its exception class.
        with self.assertRaises(self.live.bench.HarnessError):
            self.live.parse_agent_env(["RDP_AGENT_TARGET_FPS"])
        with self.assertRaises(self.live.bench.HarnessError):
            self.live.parse_agent_env(["1BAD=1"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

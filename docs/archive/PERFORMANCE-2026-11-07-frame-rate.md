# RDP frame-rate investigation and optimization — 2026-11-07

> **历史记录（已被取代）** — 2026-11-07 性能记录；非当前基线。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Historical performance record (self-contained).

## Why this round exists

The Windows App connection now works, but the user reported extremely low frame rate. The previous
investigation suspected the debug transport dump; this round re-measured with a clean worker (no
`RDP_TRANSPORT_DUMP`) and found a real, reproducible bottleneck that has nothing to do with the dump.

## Measurement method (repeatable, no Windows App required)

macOS TCC blocks driving the Windows App GUI, so frame rate is measured on a loopback session:

- a test Worker (temp dir, self-signed cert, temp SAM, random `127.0.0.1` port, `test_pattern`
  false) — exactly like `scripts/test-protocol.py`;
- a real FreeRDP client (`bin/rdp-probe`) as the decode target, or the real capture agent when
  measuring the live pipeline;
- a scripted fake agent over the private Unix-socket IPC for deterministic "8 changed 64x64
  tiles/frame" and "whole screen changed" workloads;
- a synthetic 60 fps motion window (/tmp/motion) so ScreenCaptureKit actually sees changes.

`bin/rdp-probe -mode 9` is the benchmark client added for this round. It counts received bitmap
PDUs/rectangles/bytes for `RDP_PROBE_BENCH_SECONDS` seconds and prints
`bench seconds=… bitmap_updates=… bitmap_rectangles=… bitmap_bytes=… pdu_per_s=… mbit_per_s=… gdi=WxH framebuffer_crc32=0x…`.
The framebuffer CRC is over the three colour bytes per pixel and exists so incremental (dirty-rect)
delivery can be proven to converge to the same pixels as a full-frame refresh.

Worker frame lines now also carry `bytes=` and `pdus=`:
`event=desktop_frame_sent generation=… frame_id=… batches=… tiles=… bytes=… pdus=… encoding=planar`.

## Baseline measured 2026-11-07 16:45–17:00 (production code, no transport dump)

### Worker only (fake agent, production planar encoding)

| desktop | workload | target fps | achieved fps | tiles/frame | PDUs/frame | KB/frame | Mbit/s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1472x960 | 8 tiles changed/frame | 30 | **30.1** | 345 | 345 | 180 | 43 |
| 2944x1920 | 8 tiles changed/frame | 30 | **9.9** | 1380 | 1380 | 719 | 57 |
| 2944x1920 | whole screen changes | 10 | **8.0** | 1380 | 1380 | 719 | 46 |
| 3940x1888 (agent 约 2.9K) | 8 tiles changed/frame | 30 | **6.1** | 1860 | 1860 | 962 | 47 |

### Full pipeline (real capture agent + real client + motion on screen, 约 2.9K)

- Agent loop: capture 36.4 ms + conversion 16.4 ms + IPC 6.1 ms ≈ 59 ms → **17.1 agent frames/s**.
- Worker delivered **7.17 fps**; 1380 tiles / **1380 PDUs** / 7.68 MB per frame; **440 Mbit/s**.
- Client received 119,354 PDUs and 664 MB in 12 s (9,946 PDUs/s) and kept up, so the client was not
  the limit.

## Root causes

1. **Planar (the production encoder) never used the dirty-tile path.** `internal/worker/native.c`
   only compared 64x64 tiles against `ctx->last_desktop` for raw and NSCodec. Planar re-encoded and
   re-sent all 1380–1860 tiles of the full desktop for every agent frame, even when the agent had
   only changed a handful of tiles, and emitted one BitmapUpdate PDU per tile
   (`batch_rect_limit` 1 for planar vs 32 for raw). Measured client absorption is ~10k PDUs/s, so the
   PDU flood — TLS + one write per tile — is the worker ceiling, not the TCP bandwidth.
2. **Agent capture + CGImage conversion cost.** `SCScreenshotManager.captureImage` costs ~36 ms per
   frame at 约 2.9K, and `CapturePixelConverter.bgra` draws the CGImage into a
   `CGColorSpaceCreateDeviceRGB()` context, paying a full software colour conversion per frame
   (16 ms with a moving window, 60–97 ms with the normal desktop; it grew to 78–97 ms when the
   capture size was 3940x1888).
3. **Capture-size resync gap.** When the agent process restarts mid-session (worker restart, socket
   close), it comes back at the display's native size while the RDP peer still expects the client's
   requested size; the worker only sends the capture-size request at peer activate, so the mismatch
   persists and the worker then runs its scalar per-pixel nearest-neighbour scale loop every frame
   (measured 9.9 fps → 6.1 fps at 3940x1888).
4. **Per-frame copies.** The worker copies the full source frame under `frame_mutex`, then builds and
   saves a second full copy for the next diff; the agent allocates and zero-fills a 22 MB `Data` per
   frame and retains the previous frame. At 17–30 fps this is several hundred MB/s of avoidable
   memcpy/malloc churn.

## Targets for this round

- Interactive (a few changed tiles/frame) at 约 2.9K: worker must stop being the limit —
  a few tiles and one PDU per frame instead of 1380, so the pipeline runs at the agent's rate.
- Agent: remove the per-frame screenshot + colour-conversion cost (target ≤20 ms/iteration at
  约 2.9K) so the loop is no longer the frame-rate ceiling.
- Full-screen changes: keep planar but batch into a bounded number of PDUs (≈ceil(tiles/32)).
- No protocol/correctness regressions: incremental planar delivery must converge to exactly the same
  client pixels as a full refresh (checked with the probe framebuffer CRC).

## Implemented

### Worker (`internal/worker/native.c`)

1. **Planar joins the dirty-tile path.** Planar now compares the new desktop against
   `ctx->last_desktop` with the same 64x64 `rdp_tile_changed` diff raw/NSCodec already used, and
   keeps the reference desktop for the next frame. `force_full_frame` (client refresh, first frame
   after activation, resize/reconnect) still forces a full refresh. Test-pattern frames stay
   full-frame, so raw/NSCodec behaviour is unchanged.
2. **Batched planar PDUs.** `batch_rect_limit` for planar is now 32 like raw (was 1), so a full
   约 2.9K frame is 44 BitmapUpdates instead of 1380. The per-peer `BITMAP_DATA[]` and encode
   buffer are allocated once per negotiated desktop (planar RLE worst case
   `desktop_size + tile_count + 64`) and never reallocated while rectangles reference them - the
   2026-11-05 heap-use-after-free class is structurally impossible here; both are freed in
   `peer_context_cleanup`. A frame with zero changed tiles sends no update at all.
3. **Capture-size resync.** The negotiated desktop size is remembered and the Agent capture-size
   request (IPC type 9) is re-sent when a new Agent connection is accepted, so a restarted Agent no
   longer stays at the display's native size while the peer expects the client's size
   (`event=agent_capture_size_resynced`).
4. **Cheap mismatch scaling.** When the Agent capture size differs from the negotiated desktop, the
   per-pixel 64-bit division is replaced by a cached x-index table plus a row memcpy when widths
   match (identical pixels; 4.12 ms -> 1.20 ms per 约 2.9K->3940x1888 frame).
5. Probe benchmark mode (`-mode 9`, `RDP_PROBE_BENCH_SECONDS`, `RDP_PROBE_REFRESH_AT_MS`) and
   `bytes=`/`pdus=` on `event=desktop_frame_sent` for measurement.

### Agent (`native/macos`)

1. **Colour conversion removed from the hot path.** ScreenCaptureKit is asked for
   `colorSpaceName = sRGB`; the screenshot is then BGRA premultipliedFirst in sRGB and is copied row
   by row straight out of the CGImage data provider into a reusable buffer (no CGContext draw, no
   colour conversion, no zero-filled 22 MB `Data`). Non-sRGB/unsupported layouts fall back to the
   old DeviceRGB CGContext conversion, so colours stay correct. Conversion 16.2 ms -> 2-4 ms; colour
   proof: mean RGB difference 0.04 levels, max 10, zero samples > 32 versus the old path.
2. **Pipelined snapshot loop.** The next screenshot starts before the current frame is converted, so
   capture and conversion/IPC overlap; buffers are recycled (the delta encoder hands the previous
   frame's backing store back to the capture path). Agent RSS 744-787 MB -> ~98-128 MB.
3. **Continuous SCStream path (opt-in, `RDP_AGENT_CAPTURE_STREAM=1`).** Two real macOS 27 bugs were
   found and fixed: `capture-stream` left `SCStreamConfiguration.pixelFormat` at the OS default
   `420v` (the observer rejected every frame) and `queueDepth = 1` stalls delivery completely. With
   `32BGRA`, `queueDepth` 2-8 and sRGB, SCStream delivers ~30 fps with ~1 ms per-frame copy and no
   per-frame screenshot. It falls back to the screenshot loop on start failure, no frames within 2 s,
   or a resize not applied within 5 s.
4. `RDP_AGENT_TARGET_FPS` (default 30), `RDP_AGENT_STREAM_QUEUE_DEPTH`, `RDP_AGENT_SHOW_CURSOR`
   (default off - the RDP client draws the local cursor, so capturing it would double it),
   `capture-bench` diagnostics, capture-size observability, and honest per-stage timing
   (`capture_ms`/`conversion_ms`/`ipc_ms`/`await_ms` now add up to `loop_ms`).

### Measurement tooling (new)

- `scripts/benchmark-fps.py` - isolated test worker + scripted fake agent + `rdp-probe -mode 9`;
  scenarios `small`/`full`/`static`, JSON with fps/tiles/PDUs/bytes/Mbit/s plus loadavg and binary
  sha256 provenance.
- `scripts/verify-incremental-frames.py` - incremental-vs-full framebuffer CRC convergence gate.
- `scripts/benchmark-live-agent.py` + `scripts/motion-window.swift` - real pipeline benchmark
  (real capture agent + on-screen motion + real client), `--agent-env` for mode experiments.
- `scripts/test-benchmark-fps.py` - 41 unit tests for the harness.

## Results

### Worker only (loopback client, median of 3 interleaved runs)

| scenario | size | fps before -> after | tiles/frame | PDUs/frame | worker Mbit/s |
| --- | --- | --- | --- | --- | --- |
| small delta | 1470x956 | 29.70 -> **30.16** | 345 -> 9.1 | 345 -> 1.03 | 42.5 -> 1.1 |
| full change | 1470x956 | 27.60 -> **30.06** | 345 -> 345 | 345 -> 11.0 | 39.5 -> 43.0 |
| small delta | 约 2.9K | 8.20 -> **30.16** | 1380 -> 12.6 | 1380 -> 1.14 | 47.0 -> 1.6 |
| full change | 约 2.9K | 5.00 -> **12.70** | 1380 -> 1380 | 1380 -> 44.0 | 28.6 -> 72.7 |

### Real pipeline (real capture agent + motion on screen + real client, 约 2.9K, 12 s)

| agent mode | agent fps produced | worker fps delivered | tiles/frame | PDUs/frame | bytes/frame | worker Mbit/s |
| --- | --- | --- | --- | --- | --- | --- |
| before this change | 17.08 | **7.17** | 1380 | 1380 | 7.68 MB | 440 |
| snapshot (deployed default, 30 fps target) | 21.07 | **20.82** | 52 | 2.18 | 0.41 MB | 67.7 |
| `RDP_AGENT_CAPTURE_STREAM=1` (30 fps target) | 28.55 | **27.63** | 124 | 4.37 | 0.67 MB | 148.7 |
| stream + `RDP_AGENT_TARGET_FPS=60` | 49.08 | **39.25** | 51 | 2.28 | 0.12 MB | 37.9 |

Worker delivery is 2.9x (snapshot) to 5.5x (stream/60) faster, and interactive bandwidth at
约 2.9K dropped from ~440 Mbit/s to ~0.04-0.15 MB/frame because only dirty tiles are sent.

### Correctness gates

- `make build`, `go test ./...`, `go vet ./...`, `make check` - pass.
- `python3 scripts/test-protocol.py` - 18 tests, 17 pass + 1 AVC420 skip. New
  `test_13_planar_incremental_updates` (full first frame, suppressed identical frame, dirty-only
  update, Agent resync) and `test_14_planar_convergence_refresh_and_resize` (two-session
  framebuffer-CRC equality, refresh -> full -> incremental again, reconnect at a different size).
- `python3 scripts/verify-incremental-frames.py` - PASS, incremental CRC == full-frame CRC.
- ASAN+UBSAN cgo build of worker/probe: planar batched/incremental, size-mismatch and the old
  large-resize UAF repro - zero sanitizer reports.
- `make agent-check`, `make agent-build`, `python3 scripts/test-agent-ipc-wire.py` - pass.
- Colour fidelity: mean RGB difference 0.04 levels vs the pre-change path (max 10 of 255, no
  sample > 32).

## Honest limits and open items

- **Full-screen change at 约 2.9K is still worker planar-encode bound (~12.7 fps while the agent
  offers 22 fps).** Batching removed the PDU flood (1380 -> 44), not the RGB->YUV planar encode CPU
  cost. A true 60 fps full-screen experience needs the H.264/GFX route, which stays opt-in and
  unvalidated on a real client (see PERFORMANCE-AVC420-IMPLEMENTATION.md).
- **Interactive (dirty-tile) delivery is now source-rate limited**: 30 fps with the deployed
  snapshot loop, ~28 fps with the opt-in SCStream path, ~39 fps delivered with stream + 60 fps
  target. The snapshot loop is capture-bound (~36-40 ms per screenshot).
- **Unproven boundary: batched planar decoding by Microsoft Windows App.** 32 compressed rectangles
  per BitmapUpdate are validated against FreeRDP's client only. A Windows App visual check is the
  remaining acceptance step - look for partial/blocky frames while scrolling or dragging windows.
- Incremental delivery has no periodic server keyframe. If a client ever renders a stale region, a
  client refresh or reconnect recovers (a new peer always starts with a full frame).
- Stream mode is opt-in and not the deployed default because a mid-session ScreenCaptureKit stall has
  no runtime fallback (only start failure / 2 s no frames / 5 s resize fallback), whereas the
  screenshot loop always recovers.

## Follow-up (2026-11-07 ~17:40): continuous capture + 60 fps deployed

The first Windows App acceptance pass reported clear static text but visibly jerky/torn motion, which
matches the numbers above: the deployed default (snapshot loop, 30 fps target) delivered 27 fps at the
client's 3940x1888. The snapshot loop cannot go faster because every frame pays a ~35-45 ms
screen-capture call, so the opt-in continuous-capture mode was promoted to the deployment default in
`scripts/run-agent-stream.sh` (`RDP_AGENT_CAPTURE_STREAM=1`, `RDP_AGENT_TARGET_FPS=60`); only the
capture agent is restarted, an active RDP session survives it.

Measured with the committed live-pipeline benchmark at the client's resolution (3940x1888, 10 s
window, motion on, deployed worker `bin/rdp-worker`):

| agent config | agent fps produced | delivered fps | tiles/frame | PDUs/frame | KB/frame | Mbit/s |
| --- | --- | --- | --- | --- | --- | --- |
| snapshot, 30 fps target (previous default) | 27.6 | 27.1 | 61 | 2.44 | 221 | 48.9 |
| snapshot, 60 fps target | 27.4 | 26.8 | 61 | 2.44 | 221 | 48.4 |
| stream, 30 fps target | 29.9 | 29.2 | 116 | 4.15 | 321 | 76.8 |
| **stream, 60 fps target (now deployed)** | **58.3** | **57.1** | 46 | 2.17 | 77 | 36.0 |

At the smaller 2560x1440 client size the live agent reports `capture_ms=0.0 conversion_ms=1.4
ipc_ms=6.3 loop_ms=7.7` and produces ~58 fps, so 60 fps is comfortably reachable there.

Remaining motion limits:

- **Full-screen motion (whole-page scrolling, app switch) is still worker planar-encode bound**
  (measured 12.7 fps for 1380 changed tiles at 约 2.9K). Typical window dragging and partial
  motion are now at 57 fps because only the changed tiles are encoded.
- At 58 fps the worker is close to its per-frame budget (full-frame source copy + diff + reference
  copy of a 29.8 MB frame take ~10-15 ms); removing those copies (refcounted frame hand-off and
  double-buffered reference desktop) is the next cheap worker win if 60 fps needs headroom.
- The H.264/GFX route remains the only way to make full-screen motion smooth; it is still opt-in and
  unvalidated on a real client.

## Deployed state (2026-11-07 ~17:25 Asia/Shanghai；历史快照，PID/generation 以现场为准)

- Worker `bin/rdp-worker`（supervisor/child 进程 PID 现查）监听私有 LAN 地址 :3389，使用手工形态配置与
  Agent socket `.runtime/agent-compat.sock`。
- 可选 LaunchAgent `com.rdp-server.agent` 运行重新签名的 `bin/RDPAgent.app`（ad-hoc；屏幕录制/辅助功能
  TCC 授权在重签后保留），配置 `source=snapshot target_fps=30`，delta IPC。
- To try the faster agent modes, add env vars to `scripts/run-agent-stream.sh` and
  `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`:
  `RDP_AGENT_CAPTURE_STREAM=1` (~28 fps) and `RDP_AGENT_TARGET_FPS=60` (~39 fps delivered in the
  loopback benchmark); remove them to return to the deployed default.
- Rollback copies: `/tmp/rdp-rollback-2026-11-07/` (previous worker/probe and `RDPAgent.app`) and
  `/tmp/rdp-baseline/` (pre-optimization worker/probe used for the before numbers).

## Reproduce

~~~sh
python3 scripts/test-benchmark-fps.py
python3 scripts/benchmark-fps.py --scenario small --width 2940 --height 1912 --seconds 10
python3 scripts/benchmark-fps.py --scenario full  --width 2940 --height 1912 --seconds 10
python3 scripts/verify-incremental-frames.py
python3 scripts/benchmark-live-agent.py --seconds 12
python3 scripts/benchmark-live-agent.py --seconds 12 --agent-env RDP_AGENT_CAPTURE_STREAM=1
python3 scripts/benchmark-live-agent.py --seconds 12 --agent-env RDP_AGENT_CAPTURE_STREAM=1 --agent-env RDP_AGENT_TARGET_FPS=60
~~~
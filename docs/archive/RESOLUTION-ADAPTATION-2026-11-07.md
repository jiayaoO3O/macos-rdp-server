# Resolution adaptation + mid-session resize — implementation and evidence (2026-11-07)

> **历史记录（已被取代）** — 2026-11-07 分辨率自适应设计；黑边/分辨率部分已由虚拟 16:9 显示器方案取代，布局/鼠标契约仍有效。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Work item A（设计契约见下方 DESIGN 文档）。
Design/contract (binding integer formulas): [DESIGN-2026-11-07-resolution-adaptation.md](../DESIGN-2026-11-07-resolution-adaptation.md).
Branch: `feature/dynamic-resolution-and-connection-stability`.

## What changed

### Worker (C, `internal/worker/native.c`)

1. **Negotiated desktop size (never reject a sane request).** `peer_capabilities()`
   (FreeRDP calls it before every Demand Active) reads the client request and
   `peer_negotiate_size()` keeps it verbatim when it fits 16384/axis and
   16,777,216 pixels (64 MiB BGRA); otherwise it clamps proportionally, preserving
   the aspect ratio, to even dimensions (7680x4320 -> 5460x3072). The negotiated
   size is published in the Demand Active BITMAP capability set and logged as
   `event=peer_size_negotiated requested=WxH desktop=WxH policy=client|clamp`.
   `peer_activate()` no longer rejects oversized requests; it re-asserts the size,
   forces a full repaint and re-sends the capture-size IPC (type 9) to the Agent.
2. **Fit-with-bars composition (no distortion).** `draw_pattern()` now letterboxes
   the captured frame into the negotiated desktop with the contract formula
   (centre, black bars, nearest-neighbour; one memcpy per row in the 1:1 case).
   A capture that already equals the desktop keeps the previous zero-copy path.
   Layout changes are logged once per distinct tuple:
   `event=peer_frame_layout source=WxH desktop=WxH content=WxH offset=X,Y scaled=0|1`.
3. **Client-driven mid-session resize (MS-RDPEDISP).** Each peer creates a
   `disp_server_context`; it is opened after PostConnect once DRDYNVC is ready
   (`event=disp_channel_opened result=0|1`, `event=disp_caps_sent`). The DISP
   reader thread only records the monitor-layout bounding box and signals a
   per-peer event; the peer thread negotiates, sets the new settings, sets
   `ready=FALSE`, logs `event=peer_reactivate requested=.. desktop=..` and runs the
   Deactivation-Reactivation. `peer_activate()` then re-requests the capture size
   and repaints. A no-op resize logs `event=peer_resize_ignored reason=unchanged`.
   GFX/AVC420 mid-session resize is deliberately ignored
   (`reason=gfx_active`) until GFX surface reset is implemented.
4. **Probe (same file, test tool).** `PreConnect` installs the client
   `DesktopResize` callback before connect (gdi resize + `reactivated` line; the
   initial Demand Active clamp is reported from PostConnect when gdi != request).
   Mode 5 supports `RDP_PROBE_SAMPLE_POINTS="x:y,..."` -> `sample x= y= bgra=b,g,r,a`
   (XRGB32 byte-position order, i.e. b=pixel[3]). New **mode 10** emulates a client
   window resize: `RDP_PROBE_RESIZE_AT_MS/WIDTH/HEIGHT` sends a DISP monitor layout
   PDU and waits for the full frame at the new size (`resize_requested` /
   `reactivated` / `resize_frame_received`); a second sequential resize is driven by
   `RDP_PROBE_RESIZE2_*` (regression coverage). Existing mode stdout is
   byte-compatible (all previous tests unchanged).

### Fixes found during integration (independent verification)

* **WinPR manual-reset events (real worker bug).** WinPR on Unix does not implement
  auto-reset events: `CreateEvent(...,FALSE,...)` logs "auto-reset events not yet
  implemented" and `WaitForMultipleObjects` never drains the descriptor. After the
  first Agent frame the peer's frame event stayed readable forever and starved any
  later signal: a **second** client-driven resize was silently ignored by the peer
  thread (and the peer loop also busy-spun after the first frame). Both per-peer
  events are now manual-reset and `run_peer` drains the signaled one right after
  `WaitForMultipleObjects`. Regression test: `test_20` (two resizes in one
  session). Idle CPU after a session measured 0.00 s over 3 s (verifier).
* **Uniform-scale compose condition (real worker bug, ASAN).** The zero-copy
  pass-through must only be used when the capture is exactly the desktop size. A
  condition based on "content == desktop" missed a uniform upscale (content keeps
  the desktop size with zero offsets) and let a smaller source buffer be read as a
  larger desktop (heap over-read, SIGSEGV at 3200x1800+; the probe caught it as a
  transport drop). Compose now triggers whenever source dims != desktop dims or an
  offset is non-zero. Regression test: `test_18` case (iv) 1280x720 -> 2560x1440
  with pixel sampling.

### Agent (Swift, `native/macos`)

1. **`CaptureGeometry`/`CaptureGeometryState`** (new, MacAgentCore): capture size
   policy from (requested desktop box, native display pixels) — `exact` (box fits
   and aspect matches within 0.5% -> capture the box, Worker is 1:1),
   `native` (box >= display both axes -> capture native, never upscale the
   capture), `fit` (scale native into the box preserving aspect). Worker then
   letterboxes; the two formulas are bit-identical.
2. **IPC type 9 now means the negotiated desktop box.** The Agent recomputes the
   capture size, logs
   `event=capture_size_updated width=W height=H desktop=WxH native=NxH capture=WxH policy=...`
   and uses the computed capture size for the snapshot request, the SCStream
   configuration and the stream reconfigure path.
3. **Native display-size polling** (`DisplaySizeMonitor`, >=500 ms in both capture
   loops): a macOS resolution change recomputes the capture size and logs
   `event=display_size_changed native=.. desktop=.. capture=.. policy=..`; the
   stream pump reuses its existing reconfigure path.
4. **`DisplayLayout`** (new) + `DisplayCoordinateMapper.desktopPoint()`: desktop
   coordinates -> content box (bar clicks clamp to the nearest content edge) ->
   capture pixel -> macOS display points (existing linear mapping). Mouse input
   now goes through this path.
5. **Left/Right Windows keys** (scancodes 0x5B/0x5C, with or without the extended
   flag) map to the macOS Command keys — the field failure line
   `remote_input_rejected error=unsupported_RDP_scancode_0x5b` is gone.

### Tests / tooling

* `scripts/test-protocol.py`: 4 new loopback tests (+350 lines, 0 deletions) and
  pure-Python contract helpers (`negotiate_desktop_size`, `fit_layout`):
  - `test_16_size_matrix_negotiated_desktop` (10 sizes, gdi == desktop, full frame,
    no rejection, no clamp),
  - `test_17_oversized_request_is_clamped_and_told` (7680x4320 -> 5460x3072,
    client told, full frame at the clamped size),
  - `test_18_fit_with_bars_layout` (pixel-level letterbox verification for
    2214x1440->2560x1440, 800x520->800x600, 1470x956->1468x923),
  - `test_19_mid_session_client_resize_disp` (DISP resize 2560x1440 -> 1920x1080
    incl. both Agent type-9 payloads, a full 510-tile repaint after the
    reactivation, and the incremental follow-up when observable),
  - `test_20_two_client_resizes_in_one_session` (2560x1440 -> 1920x1080 ->
    5120x2880 in one connection: both reactivations, both type-9 requests, a full
    3600-tile repaint; regression for the WinPR event drain).
* `native/macos/Tests/MacAgentCoreTests/PermissionSnapshotTests.swift`: +286 lines
  of preconditions covering the capture policy, the layout formula and
  desktop->display mouse mapping for all representative sizes (corners + centre +
  bar clamping), Win-key mapping, geometry state transitions.
* `Makefile` agent-check compiles the two new MacAgentCore files.

## Policy summary (maintainer view)

| Client asks | Capture | Desktop | Result |
|---|---|---|---|
| 2560x1664 (aspect matches display) | 2560x1664 | 2560x1664 | 1:1, no bars |
| 2560x1440 (16:9) | 2214x1440 | 2560x1440 | 1:1 content + 173 px side bars, no distortion |
| 800x600 | 800x520 | 800x600 | 1:1 content + 40 px top/bottom bars |
| 4096x2304 | 约 2.9K (native) | 4096x2304 | upscaled content + bars (nearest-neighbour) |
| 7680x4320 (132 MB BGRA) | 5460x3072 | 5460x3072 | clamped, client told, full session |

## Verification evidence (loopback, isolated worker + fake/real agent; live port 3389 untouched)

| Check | Command | Result |
|---|---|---|
| Build | `make build` | OK |
| Build (AVC420 variant) | `make build-avc420-worker && go test -tags avc420 ./internal/worker` | OK |
| Go unit/race tests | `go test ./...`, `make check` (race, gfx-session, avc encoder, vet) | OK |
| Protocol suite | `python3 scripts/test-protocol.py` | **24 tests, OK, 1 AVC420 skip** (69 s), run twice consecutively green |
| Benchmark harness unit tests | `python3 scripts/test-benchmark-fps.py` | OK (41 tests) |
| Incremental convergence | `python3 scripts/verify-incremental-frames.py` | see VERIFICATION doc |
| Agent Swift checks | `make agent-check`, `make agent-build` | OK |
| Size matrix | test_16 | 800x600 .. 5120x2880 all accepted unchanged |
| Oversized fallback | test_17 | 7680x4320 -> 5460x3072, aspect preserved, no rejection |
| Fit-with-bars pixels | test_18 | bars black, content/markers at the mapped coordinates, `peer_frame_layout` exact |
| Mid-session DISP resize | test_19 | 2560x1440 -> 1920x1080 reactivation, new type-9, full 510-tile repaint, no rejection |
| Two resizes in one session | test_20 | 2560x1440 -> 1920x1080 -> 5120x2880, both reactivations + full 3600-tile repaint |
| Uniform upscale compose | test_18 (iv) | 1280x720 -> 2560x1440 pixel-sampled 2x upscale, no over-read |

Independent verification (adversarial edge cases, repeated resizes, RSS/thread
leaks, formula cross-checks): see
[VERIFICATION-2026-11-07-resolution-adaptation.md](VERIFICATION-2026-11-07-resolution-adaptation.md).
Verdict: PASS on the loopback product path; it found the two real worker bugs above
(second-resize signal starvation, uniform-scale over-read), both fixed and
re-verified, plus one test-harness log-read race that is fixed in
`scripts/test-protocol.py`.

## Not yet proven by automated tests (needs the real Windows client / maintainer)

* **Windows App live window resize.** The DISP path is implemented and verified
  with the FreeRDP probe (DISP client channel), but the real Windows App client
  must be observed once. Expect `event=disp_channel_opened result=0`,
  `event=disp_caps_sent result=0` at PostConnect, then
  `event=peer_reactivate requested=... desktop=...` when the window is resized.
  If the app does not use DISP, the channel stays idle and nothing changes.
* **One live mouse click check** at four corners + centre for a letterboxed size
  (the mapping math is unit-tested; a live click confirms the macOS display
  coordinate mapping end to end).
* **Live size matrix** (`scripts/benchmark-live-agent.py --width/--height` at
  RDP_AGENT_TARGET_FPS=60) — not run yet because the live service is carrying a
  user session and a second real capture agent adds load. Record fps per size
  there when convenient.
* **Deployment.** The live service still runs the pre-change binaries; see below.

## Deployment / rollback

* Agent and Worker must be deployed **together** (the new Agent captures the
  computed size; the new Worker letterboxes it). Rolling back either alone
  reintroduces a stretch (old Worker) or 1:1-without-bars (old Agent).
* Order that minimises disruption: restart the Worker first (drops the active RDP
  session), then `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`
  (Agent restart keeps a session if one is up; TCC grants survive rebuilds, but
  re-check `status`). The Worker drop is unavoidable (it owns the RDP listener).
* Rollback: `git switch` to the pre-change commit and rebuild, or restore
  binaries from a saved copy of `bin/`; nothing in `.runtime` changed format.
* Runbook after deploy: connect once, confirm
  `event=peer_size_negotiated requested=... policy=client`, check a mismatched
  aspect (e.g. 2560x1440) shows bars and a matching one (2560x1664) is 1:1, then
  resize the Windows App window and look for `peer_reactivate` +
  `disp_channel_opened`.

## Follow-ups

1. GFX/AVC420 mid-session resize: ResetGraphics + surface recreate (currently
   ignored to protect a mapped surface).
2. Upscale quality for clients much larger than the display (nearest-neighbour
   aliasing) — vImage/bilinear or capture-at-client-size policy revisit.
3. Live Windows App validation (DISP behaviour, initial-clamp behaviour when the
   client asks for 8K, bars/cursor feel).
4. Per-size live fps matrix and adaptive skip policy if upscaled 4K+ clients cap
   the Worker at 60 fps.
5. Why did the Windows client historically send 2560x1440 (16:9) against a
   约 2.9K display? After this change that session is letterboxed rather than
   stretched; if full-screen fill is preferred, pick 2560x1664.

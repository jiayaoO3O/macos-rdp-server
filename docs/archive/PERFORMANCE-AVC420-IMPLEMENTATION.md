# AVC420 implementation work log

> **历史记录（已被取代）** — AVC420 实验路径记录；未部署、非当前范围。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Date: 2026-11-05. This document is self-contained.

## Acceptance boundary

The next stage is an **explicitly enabled, hardware-encoded GFX AVC420 path with raw fallback**, not an assertion that raw/NSCodec now meets the high-refresh target. Completion requires capability negotiation, correct decoded synthetic frames, surface reset/refresh/reconnect and resize handling, bounded frame acknowledgement/backpressure, security regressions, and isolated ASAN coverage. Actual Windows App presentation quality/FPS remains a separate real-client acceptance step. AVC420 is lossy chroma-subsampled; it is not the eventual lossless-text/AVC444 claim.

No live service restart, LAN binding change, private configuration/credential read, or permission change was performed during this implementation pass. Existing worker/Agent PIDs and live lease state were **not re-verified**; re-check before deployment. Baseline test workers use temporary test credentials and loopback only. The workspace has no Git metadata (verified using git rev-parse); worktree isolation/rollback is unavailable.

## Baseline evidence

- make check: passed (Go race tests + vet); upstream FreeRDP deprecated declaration warnings remain.
- make test-protocol: 15/15 passed, including large delta resize and client bitmap decode.
- make agent-check: passed.
- python3 scripts/test-agent-ipc-wire.py: 3/3 passed.

## Implemented policy module

internal/worker/gfx_session.h, internal/worker/gfx_runtime.h and scripts/test-gfx-session.py:

- AVC420 requires explicit enablement, an available encoder and a compatible advertised capability. Version 8.0/unknown versions are rejected; 8.1 needs AVC420_ENABLED; understood 10.x versions reject AVC_DISABLED.
- Select the highest understood compatible version; construct server flags instead of echoing arbitrary client flags. Version 10.1 requires/returns its special 16-byte capability payload (others four bytes).
- At most three outstanding frames during normal acknowledgement pacing. Cumulative ACKs retire a bounded prefix; future, duplicate and stale normal ACKs cannot expand or corrupt the queue.
- uint32 frame ID wrap is supported without untrusted subtraction. ACK suspension keeps constant memory, can resume on the latest sent frame, and does not miscount unobserved frames as acknowledged.
- ACK latency is a protocol metric, **not client-rendered FPS**. A regressing clock cannot underflow latency. Accepted ACKs feed cumulative sample/average/maximum metrics and a rate-limited native summary; stale/duplicate ACKs are rejected before telemetry changes.
- A stalled-ACK deadline checks the oldest outstanding frame, moves forward after cumulative acknowledgement, and is disabled during negotiated ACK suspension (transport writes still need independent deadlines).
- Fourteen C-backed tests cover capability selection, ACK pacing/suspension/deadlines and metrics aggregation/report cadence, fail-closed channel/surface ordering, first-access-unit-before-map ordering, bounded AVC420 framing, and retry of the newest dropped frame after an ACK. Normal and ASAN+UBSAN runs pass.
- make check includes test-gfx-session. The lifecycle gate is now wired into the native peer path only for the `avc420` build and explicit `RDP_ENABLE_AVC420=1` opt-in; helper/compile tests still do not validate real client negotiation or playback.

## Native GFX lifecycle increment (2026-11-05)

The native peer keeps SupportGraphicsPipeline false by default and gates the server context on an avc420-tagged build, RDP_ENABLE_AVC420=1, and successful hardware-encoder preflight. On the peer thread it processes VCM/GFX event handles, runs WTSVirtualChannelManagerCheckFileDescriptor, and opens RDPGFX only after DRDYNVC is joined and ready. AVC420 capability selection and confirmation follow the existing policy helper. It sends ResetGraphics, CreateSurface, and MapSurfaceToOutput only after an Annex-B access unit is ready, then delivers that first frame; later frames use bounded ACK pacing, with the newest dropped update retried when capacity reopens. Each access unit is capped at 4 MiB and an ACK timeout closes stalled peers. Failures are raw-safe only before MapSurfaceToOutput is attempted; after any attempt the GFX session fails closed. GFX is torn down before the VCM.

Validation on 2026-11-06: make check and RDP_TEST_ASAN=1 python3 scripts/test-gfx-session.py passed (14 cases); make test-avc420-build passed. The tagged compile emits only existing FreeRDP deprecation warnings. No service restart, artifact deployment, GFX client probe, or Windows App test was performed.

The ACK callback records only accepted acknowledgements and emits a structured summary on the first ACK and every 60 thereafter: last/cumulative-average/maximum send-to-ACK latency, ACK queue depth, pending frames, and sample count. This telemetry does not establish decode time, rendered FPS, or visual quality.

The basic Reset/Create/Map and Annex-B command path is implemented, but GFX refresh/resize/reconnect handling, a GFX-aware headless client/decoder test, and real-client playback remain outstanding. The surface-map-attempt marker prevents raw fallback once MapSurfaceToOutput is attempted, because a failed write may still have reached the client; post-attempt failure closes the peer rather than attempting unsafe bitmap fallback.

## Codec findings and design constraints

The local FFmpeg 9.0.2 h264_videotoolbox encoder accepts NV12/YUV420P/hardware frames, **not BGRA directly**. It can be used independently alongside the baseline FreeRDP library. Do not replace .deps/install or load ABI-mismatched FreeRDP libraries into a running process.

Inspection of .deps/freerdp-3.32.2/libfreerdp/codec/h264_ffmpeg.c reveals a concrete hazard: its encoder sets three planar YUV420P data pointers/strides, then re-labels the frame NV12 for hardware upload without interleaving chroma. This is an independent reason to bypass the wrapper, **not proof of the sole root cause of the prior crash**. Its simplistic receive/EAGAIN handling must not be copied either.

The independent optional encoder now owns BGRA/NV12 staging, converts through swscale with actual per-plane strides, fails without the hardware VideoToolbox encoder (no silent software fallback), and verifies Annex B SPS/PPS/IDR in tests. The synthetic encode/decode run currently exercises 320×240; large non-multiple-of-16 desktop sizes are not yet validated through GFX. Odd dimensions are rejected and must use raw fallback until a tested padded/cropped GFX surface contract exists.

**Color acceptance is not settled by a standalone FFmpeg round trip.** FreeRDP's AVC420 client inverse in libfreerdp/primitives/prim_internal.h uses full-range BT.709-like coefficients, so a client that ignores range metadata may render limited-range output differently from a VUI-aware software decoder. The current sender explicitly converts full-range BGRA/RGB to limited-range BT.709 NV12; verify that choice against the actual FreeRDP GFX decoder and Windows App before claiming exact color or HDR management from DeviceRGB capture.

VideoToolbox advertises delayed output. The peer now requests a refresh when encode yields no access unit and retries the latest desktop frame, but this behavior still needs validation against input-acceptance/timestamp association and send-vs-receive EAGAIN semantics. No null-frame-per-capture flush: NULL signals encoder EOF. Recreate the encoder and send new SPS/PPS/IDR on resize/reset/refresh as needed; do not relabel an open encoder's dimensions.

## Encoder flush correction and validation (2026-11-05)

The standalone encoder now hardens the codec and bitstream-filter drain contract:

- Flush becomes irreversible before returning any already-queued access unit; callers cannot submit another frame after receiving a delayed packet from flush.
- `flush` reports EOF (`0`) only after codec and Annex B bitstream-filter EOF have both been observed. An incomplete drain is an error (`-1`), never a false successful EOF. The public header documents this contract.
- Deterministic white-box harnesses inject codec and BSF send-side `EAGAIN`, verify the same unconsumed input is retried exactly once, and cover queued-packet flush, post-flush encode rejection, and incomplete codec/filter EOF.

Validation on 2026-11-05 passed: `python3 scripts/test-avc-encoder.py --require-ffmpeg`, the same with `--asan`, `make test-gfx-session` (5 cases), `make test-avc420-build`, `make check`, `make test-protocol`, `make agent-check`, and `python3 scripts/test-agent-ipc-wire.py`. The FFmpeg encoder test produced and decoded synthetic VideoToolbox AVC420 frames; the ASAN variant passed. The full build emitted existing FreeRDP deprecated-declaration warnings.

`make test-avc420-build` verifies that the opt-in Go build tag compiles/links the optional encoder, and the tagged binary includes the guarded peer lifecycle. Runtime opt-in additionally requires RDP_ENABLE_AVC420=1; no standalone artifact has been packaged or deployed. The default stub path remains dependency-free and GFX-off.

### 2026-11-06 color conversion follow-up

The tighter FFmpeg decode assertion was first run against the old conversion and failed on the red patch (`[255,24,0]` versus `(255,0,0)`). The encoder now explicitly selects BT.709 coefficients and the full-range RGB to limited-range YUV conversion in `sws_setColorspaceDetails`; the strict decode test passes, including the existing `tv` range and BT.709 stream metadata checks. This demonstrates encoder/FFmpeg consistency only, not FreeRDP GFX client fidelity.

## Remaining integration work (goal remains active)

1. Encoder color conversion is now explicit: full-range BGRA/RGB is converted with the BT.709 matrix to limited-range NV12, matching the AVC metadata. A strict FFmpeg decode test checks primary/gray patches within 12 RGB levels. Remaining acceptance: verify the same colors through FreeRDP's actual GFX decoder and Windows App; FFmpeg round-trip is not client-color evidence. Keep default builds free of FFmpeg dependencies.
2. An isolated AVC420 Worker artifact is available via `make build-avc420-worker` (also run by `make test-avc420-build`) at `bin/rdp-worker-avc420`, separate from the default Worker binary. The artifact metadata confirms the `avc420` build tag. It has not been launched or deployed; runtime opt-in still requires `RDP_ENABLE_AVC420=1`, successful hardware-encoder preflight, and real-client testing.
3. The basic native surface lifecycle is implemented after the DRDYNVC-ready gate and CapsConfirm. Still needed: GFX refresh/resize/reconnect semantics and a verified recovery path for post-map failure; current behavior is deliberately fail-closed.
4. Annex-B routing through SurfaceFrameCommand with RDPGFX_AVC420_BITMAP_STREAM/cmd.extra, 4 MiB access-unit bound, three-frame ACK pacing, newest-frame retry, and 10-second stalled-ACK closure are implemented. Validate encoder send/receive EAGAIN semantics and encoded P-frame dependency behavior under a real GFX client.
5. Raw fallback is allowed only before a MapSurfaceToOutput attempt. Any failure after an attempt closes the peer; add/test delete-unmap-reset or reconnect handling before attempting post-map recovery. Never assume legacy bitmaps can overwrite a mapped GFX surface.
6. Extend the headless probe with a genuine GFX channel/decoder test (the existing probe is bitmap/NSCodec only). Test default-off fallback, explicit opt-in, unsupported client, reconnect, refresh, negotiated resize, large frame and stalled-reader deadline. Rerun protocol/security/Agent suites and sanitizers.
7. Only after successful automated validation, re-check real lease/service state before any authorized deployment. Measure capture/convert/encode/send/ACK separately; collect actual Windows App visual/FPS evidence before claiming the end-to-end target achieved.

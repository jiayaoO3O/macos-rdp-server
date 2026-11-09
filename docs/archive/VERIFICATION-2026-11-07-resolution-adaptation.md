# Verification — client-driven resolution adaptation (Work item A)

> **历史记录（已被取代）** — 2026-11-07 分辨率自适应验证；后续由虚拟 16:9 显示器方案取代（见 DESIGN-2026-11-08-virtual-display）。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Independent adversarial verification (read-only for source/tests).
Date: 2026-11-07 21:46–23:00 (Asia/Shanghai). Branch: `feature/dynamic-resolution-and-connection-stability`.
Base commit: `c971058` (no commit on top: `git log c971058..HEAD` is empty — the change set is uncommitted
working-tree state; `scripts/test-protocol.py` was additionally changed by the maintainer **during** this
verification to fix D1, and the final suite was re-run against that final state). Scope of the change set: `internal/worker/native.c`, `native/macos/**`,
`scripts/test-protocol.py`, `Makefile`, new `docs/DESIGN-2026-11-07-resolution-adaptation.md`,
`native/macos/Sources/MacAgentCore/CaptureGeometry.swift`, `DisplayLayout.swift`
(`git status --porcelain` = 8 modified, 4 new files; nothing else touched).

Never touched the live service: no access to port 3389, `.runtime/` state, `.runtime/config.json`,
`.runtime/sam`, credentials, `make agent-app` or the live worker/agent processes.

## Verdict

**PASS for the implemented loopback product path; no product defect found.**
All mandatory suites pass on the final working tree (protocol suite: 23 tests — 22 pass, 1 AVC420 skip, exit 0).
During verification the protocol suite initially failed `test_18` reproducibly (3/3 on this machine); the
root cause was the committed test's **log-file handling race**, not product code — the maintainer fixed it in
`scripts/test-protocol.py` (read the worker log through a fresh handle; write handle only for the child) while
this verification was in flight, and the re-run on the fixed tree is green. A second, **real worker bug** was
found by this verification (D2) and fixed by the maintainer during verification: WinPR's Unix auto-reset events are
unimplemented, so the per-peer frame event was never drained and starved the DISP resize event — a second
client-driven resize inside one connection was never handled. After the manual-reset/drain fix I re-verified
it on the rebuilt worker (final bin 校验和略, 23:30): two sequential DISP resizes in one connection now both
reactivate, renegotiate, re-request the Agent capture size and repaint. Two acceptance bullets are only
partially met because they need the live Windows App client (live mouse click, live size matrix), which this
verification was not allowed to drive. Details and evidence below.

## 1. Mandatory commands (exact, run sequentially against a stable `bin/`)

Environment note: the verifier's program sandbox starts child processes with an empty environment
(`HOME`/`PATH` unset), which makes `winpr_InitializeSSL` fail inside `bin/rdp-probe` (probe rc=10) and
`go` unfindable. All runs below therefore used a normal host environment explicitly
(`HOME=/Users/<user> PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`)
in a single long-lived sequential shell, with no concurrent builds/suites. The first run of the suite in a
different (empty-env) shell was discarded as invalid.

| # | Command | Result |
|---|---------|--------|
| 1 | `make build && go test ./... && go vet ./... && make check` | **rc=0**. build ok; `go test ./...` ok (agentipc/auth/config/worker); `go vet ./...` ok; `make check` ok: `go test -race ./...` ok, `test-gfx-session.py` 14 tests OK, `test-avc-encoder.py` 2 tests OK, vet ok. Note: Go reported `(cached)` for several packages; supplement: `go test -count=1 ./...` **ok** and `go test -race -count=1 ./internal/worker` **ok** (fresh, not cached). |
| 2 | `python3 scripts/test-protocol.py` | **First run (state reviewed at 21:46): FAILED — 23 tests, 21 passed, 2 failed (both `test_18` subtests), 1 AVC420 skip**; `test_18` alone failed 3/3 (22:56). Root cause was the test's worker-log read/write file-handle race, **not** product code (D1). **Re-run on the final working tree after the maintainer's `read_log()` fix: OK — `Ran 23 tests in 65.8s ... OK (skipped=1)`, exit 0**, all 22 non-skipped tests incl. `test_16`..`test_19` passed. The final `scripts/test-protocol.py` differs from the 21:46 state only by that test-only log-handle refactor (it also now routes the existing log assertions of `test_01`..`test_15` through `read_log()`). |
| 3 | `python3 scripts/test-benchmark-fps.py` | **ok — 41 tests, OK**. |
| 4 | `make agent-check && make agent-build` | **rc=0**. PermissionSnapshotTests (with the new CaptureGeometry/DisplayLayout/preconditions checks) compiled and ran clean; `swift build -c release` produced `bin/rdp-agent` (135/135 targets; only benign CommandLineTools ld search-path warnings). |
| 5 | `make build-avc420-worker && go test -tags avc420 ./internal/worker` | **rc=0**, `ok rdp-server/internal/worker`. |

## 2. Acceptance list (Work item A), item by item

| Acceptance bullet | Verdict | Evidence |
|---|---|---|
| Size matrix {800x600, 1024x768, 1468x923, 1920x1080, 2508x1220, 2560x1440, 约 2.9K, 3940x1888, 4096x2304, 5120x2880}: probe connects, gdi == negotiated, first frame full, later incremental, CRC convergence, no `peer_activate_rejected` | **PASS** | `test_16_size_matrix_negotiated_desktop` passed; independent /tmp matrix also passed 12 sizes incl. boundary cases (table §3a); full-frame tile counts equalled `((W+63)/64)*((H+63)/64)` for every size; incremental delivery/CRC convergence covered by `test_13`/`test_14` (passed in the same suite run) and by resize incremental evidence (§3c: 510→4 tiles). |
| Oversized request gets a documented working fallback and the client is told the real size | **PASS** | `test_17_oversized_request_is_clamped_and_told` passed (7680x4320 → 5460x3072, synthetic `reactivated`, full frame, aspect within one even step). Independent runs: 16384x16384 → 4096x4096; 16384x2048 → 11584x1448; 16384x1025 (64 MiB+4 B) → 16376x1024 (all probe rc=0, `desktop_size`=`gdi_size`=clamped, `policy=clamp`, `reactivated width=...`, no `peer_activate_rejected`). |
| Mouse mapping correct at four corners + centre for every accepted size (unit tests + one live click) | **PARTIAL — unit/loopback PASS, live click NOT RUN** | Swift `DisplayLayout.capturePoint`/`DisplayCoordinateMapper.desktopPoint` preconditions ran in `make agent-check` and cover corners/centre/bars for the 1:1, fit and scaled layouts. Independent cross-check of the compiled Swift formulas against the design contract: 71/71 cases match (11 layout, 15+25 capture-policy, 20 mouse-map; 0 mismatches). Worker rendering verified by pixel sampling for 4 layouts (corners+centre+bars, §3b). The live Windows-App click was **not** executed (live session protected by the task rules). |
| Fit-with-bars: no bleed, clicks map into content area | **PASS (loopback)** | Pixel sampling on the real worker: black bars exactly 0,0,0,0 and content pixels equal to the design-mapped source pixel at corners/centre/bar boundaries for 2214x1440→2560x1440, 800x520→800x600, 1470x956→1468x923, 2560x1664→2560x1664; `event=peer_frame_layout` matched the computed content/offset for every case. Bar-clamp mapping asserted in Swift preconditions and cross-checked. Live click: not run. |
| Suites stay green; size-matrix test added to `scripts/test-protocol.py`; live size matrix run recorded | **PARTIAL** | Size-matrix/resize tests **were added** (`test_16`..`test_19`); full suite is **green on the final working tree** (23 tests, 22 pass, 1 skip, exit 0) incl. `test_16/17/18/19`, after the maintainer's test-only log-handle fix (D1). **Live size matrix was not run** (`scripts/benchmark-live-agent.py` needs the live capture agent/service; forbidden by the task rules). |

**Overall: no acceptance failure attributable to the product code on the loopback path.** The two gaps are
(a) a committed test that is flaky because of how it reads the worker log (D1, test code, not product), and
(b) live-client-only checks and the live fps matrix (environment-protected, explicitly out of what this
verification could drive).

## 3. Adversarial checks (throwaway scripts in /tmp only; random loopback ports, isolated temp dirs)

Harness: `/tmp/vr3/harness.py` (same worker+fake-agent+probe pattern as `scripts/test-protocol.py`, but the
worker log is read through a **separate read-only fd** so tests do not race the writer; this is the exact
difference that makes D1 disappear). Throwaways: `/tmp/vr3/adv.py`, `adv2.py`, `final_resize.py`,
`crosscheck.py`, `probe2.c` → `/tmp/vr3/rdp-probe2` (a copy of the committed probe's mode-10 code with a
second sequential DISP resize, used only to test repeated resizes). Nothing was written to the repo.

### 3a. Size matrix and edge cases (test-pattern worker; probe mode 5)
| requested | expected negotiation | result |
|---|---|---|
| 200x10000 | 200x10000 client | rc=0, gdi 200x10000, full frame (628 tiles) |
| 1468x923 | client | rc=0, 345 tiles = full |
| 约 2.9K | client | rc=0, 1380 tiles = full |
| 4096x2304 | client | rc=0, 2304 tiles = full |
| 5120x2880 | client | rc=0, 3600 tiles = full |
| 16384x1024 (exactly 64 MiB) | client | rc=0, 4096 tiles = full |
| 16384x1023 | client | rc=0, full frame |
| 2560x1441 (odd) | client | rc=0, full frame |
| 7680x4320 | clamp 5460x3072 | rc=0, synthetic `reactivated 5460x3072`, 4128 tiles = full |
| 16384x16384 | clamp 4096x4096 | rc=0, 4096 tiles = full |
| 16384x2048 | clamp 11584x1448 | rc=0, 4163 tiles = full |
| 16384x1025 (budget+1 pixel row) | clamp 16376x1024 | rc=0, full frame, `reactivated` |
| 1x1, 2x2, 16x16, 16384x1 | impossible client geometry | **clean client-side rejection** (probe rc=11, stderr "Monitor configuration virtual desktop width/height must be 200 <= N <= 32766", no worker session, worker alive). Not a worker rejection: FreeRDP rejects such client core dimensions before the connection. |
| 200x32766 | clamp 100x16384 | not reachable through the probe: the probe CLI rejects height>16384 (rc=10). Worker formula verified only by the formula cross-check for this class; documented as not proven end-to-end. |

No crash, no hang, no `peer_activate_rejected`, and no worker exit in any accepted case; the single
non-rc=0 cases are the documented client-side geometry rejections above.

### 3b. Fit-with-bars and mouse-mapping math vs worker rendering
Four (capture, desktop) pairs, gradient frames (level = f(capture x,y)), probe `RDP_PROBE_SAMPLE_POINTS`
at corners, centre, bar boundaries and extra points; every sample equalled the design formula
`sx=floor((dx-offX)*cw/contentW)`, `sy=floor((dy-offY)*ch/contentH)`, bars exactly black, and every case
logged `event=peer_frame_layout source=... desktop=... content=... offset=...` with the Python-computed
values: **4/4 PASS, 0 bad samples** (2214x1440→2560x1440 content 2214x1440 offset 173,0;
800x520→800x600 content 800x520 offset 0,40; 1470x956→1468x923 content 1419x923 offset 24,0;
2560x1664→2560x1664 1:1). Frames were also sent sequentially on one fake-agent socket (frame_id 1..4) and
every one was accepted/logged — the same scenario D1 reports as "never received" when the committed test
reads the log.

### 3c. Mid-session client-driven resize (DISP)
Custom probe sends DISP monitor layouts and asserts the worker log, not just the client's first PDU:
- **Single resize with a live fake Agent**: 2560x1440 → 1920x1080. Worker log: `peer_reactivate requested=1920x1080 desktop=1920x1080 policy=client`, `peer_size_negotiated ...`, `rdp_desktop_size width=1920 height=1080`, `agent_capture_size_requested width=1920 height=1080`, no `peer_activate_rejected`; then the **first** `desktop_frame_sent` after reactivation had **tiles=510 = ((1920+63)/64)*((1080+63)/64) — full repaint**; a changed Agent frame produced the next frame with **tiles=4 — incremental resumes**. Probe rc=0. **PASS.**
- **Resize while client output is suppressed** (worker `RDP_TEST_SUPPRESS_OUTPUT_AT_MS=500`, `ALLOW=3500`, resize at 700 ms; real Agent frame): session survived, `peer_reactivate` logged, probe rc=0; the first frame after `event=client_output_suppressed allow=1` had **tiles=510 (full at the new size)**, followed by **tiles=4** incremental. **PASS.**
- **Resize while the fake Agent is disconnected** (type-9 send has no peer): session survived, reactivation completed, full repaint delivered from the cached frame, no crash; reconnecting the Agent produced `agent_capture_size_resynced width=2560 height=1440`. **PASS.**
- **Reconnect at a different size right after a mid-session resize**: after the 1920x1080 resize, a new connection at 2560x1440 connected rc=0 with gdi 2560x1440 and a full frame. **PASS.**
- **Two resizes in one connection** (2560x1440 → 1920x1080 → 5120x2880): **PASS after the D2 fix** (re-verified on the final worker sha256 `（校验和略）`, built 23:30). Worker log, in order: `disp_monitor_layout requested=1920x1080` → `peer_reactivate requested=1920x1080` → full frame `tiles=510` → incremental `tiles=4` (changed Agent frame) → `disp_monitor_layout requested=5120x2880` → `peer_reactivate requested=5120x2880 desktop=5120x2880 policy=client` → `peer_size_negotiated requested=5120x2880` → `rdp_desktop_size width=5120 height=2880` → `agent_capture_size_requested width=5120 height=2880` → `peer_activate_complete` → `peer_frame_layout source=约 2.9K desktop=5120x2880 content=4428x2880 offset=346,0`; probe printed `reactivated … count=2` and `resize2_frame_received width=5120 height=2880` and exited rc=0, no `peer_activate_rejected`, no `peer_resize_ignored`. (The *complete* 3600-tile send for the second frame is not captured because the custom probe deliberately stops pumping RDP events during the observation window; the worker's 5 s draw watchdog then cancels the blocked write — test artifact, first PDU at the new size already received.)

### 3d. Resource use (worker process, reused across sessions)
- 50 × 800x600 sessions: RSS 28.4 → 28.9 → 28.9 → 29.0 → 29.0 MB at sessions 10/20/30/40/50; thread count constant 7. **Plateau, PASS.**
- 20 × 4096x4096-clamped sessions: RSS 66.2 MB at sessions 5/10/15/20; thread count constant 7. **Plateau, PASS.**
- Earlier 14-session mixed run grew RSS 14 MB → 139 MB, but that sequence included two 64-MiB-frame sessions; the dedicated runs above show macOS malloc arena retention, not monotonic per-session growth. No leak found.

### 3e. Event / log hygiene
- Required audit names exist and are emitted: `peer_size_negotiated`, `peer_frame_layout`, `peer_reactivate`, `peer_resize_ignored`, `disp_channel_opened`, `disp_monitor_layout` (added by the maintainer with the D2 fix), `peer_activate_rejected` (worker, `internal/worker/native.c`); `capture_size_updated`, `display_size_changed` (Agent, `rdp-agent/main.swift`).
- The only event added in the per-frame path is `peer_frame_layout`, and it is emitted once per distinct (source,desktop,content,offset) tuple only (`peer_log_layout` memoises; `test_16` run: 0 layout lines for static test pattern; layout tests: 1 line per session). Existing `event=desktop_frame_sent` frequency is unchanged (one per drawn frame), no new per-frame line added.
- No secrets in worker logs: the test account password never appears (0 hits); logs contain only paths, sizes and event names; the Agent secret/SAM files are never logged (they are not even readable by this verification).
- `capture_size_updated` keeps its existing `width= height=` prefix and appends `desktop= native= capture= policy=` — parser-compatible as designed.

### 3f. Formula cross-checks (C and Swift against the contract)
- Swift: compiled `CaptureSizeRequest.swift + CaptureGeometry.swift + DisplayLayout.swift + DisplayCoordinateMapper.swift` from the working tree into a /tmp driver (`make agent-check` equivalent sources) and compared against an independent Python implementation of design §3/§4/§5: **71/71 matches, 0 mismatches** (fit layouts incl. 1x1/16384x1 degenerate, capture policy incl. the 0.5 % tolerance boundary and native/upscale cases, mouse clamp mapping incl. bars and out-of-range). The design's worked examples reproduce exactly (2214x1440, 800x520, 2560x1664 exact, 约 2.9K native, 2903x1888 fit).
- C: the worker's `peer_frame_layout` lines for all sampled pairs equal the same Python/design formula (§3b), and every accepted size's `device_size`/`gdi_size` equals the Python `negotiate_desktop_size` prediction (§3a), including the 8K/16K clamps. The Agent's final capture-safety clamp is not reachable for any valid negotiated desktop (proof: native branch requires display area <= desktop area <= 16 MiB pixels), so it is dead code for this contract and untested end-to-end — noted as low risk.

## 4. Defects found

### D1 — Found, root-caused and fixed during verification: `test_18_fit_with_bars_layout` was flaky because the test raced the worker log file (committed test code, **not a product defect**)
Reproduction (pre-fix state, on this machine):
```
python3 scripts/test-protocol.py ProtocolTest.test_18_fit_with_bars_layout   # fails
python3 scripts/test-protocol.py ProtocolTest.test_18_fit_with_bars_layout   # fails
python3 scripts/test-protocol.py ProtocolTest.test_18_fit_with_bars_layout   # fails
```
Observed: subcases 2/3 failed in `wait_log('event=agent_frame_received generation=1 frame_id=2|3')`; the
failure message's `log_since(mark)` was empty even though the worker did receive the frame. In the full-suite
run: `Ran 23 tests ... FAILED (failures=2, skipped=1)` (21 pass, 1 skip).
Why it was not a product bug: the same scenario driven by an independent harness that reads the worker log
through a **separate read-only fd** (`/tmp/vr3/adv.py`, `adv2.py`) sends four sequential frames on one
fake-Agent socket; the worker logs and accepts `agent_frame_received` for every one, and all pixel/layout
assertions pass. The committed test handed the same file object to `Popen(stdout=cls.log, stderr=cls.log)`
and also read it: child and parent share one file description, so the parent's `seek(0)`/reads move the
shared offset and worker writes can land where the reader has already been (observed as overwritten/garbled
log lines), making just-written events invisible to `log_since`.
Resolution during verification: the maintainer changed `scripts/test-protocol.py` to read the log through a fresh
read-only handle per poll (`read_log()`) while only the child keeps the write handle. Re-ran the final tree:
**`Ran 23 tests in 65.8s — OK (skipped=1)`, exit 0, `test_18` green.** (The fixed test also printed an
optional diagnostic in `test_19` — "session closed before an incremental frame after the resize repaint
could be observed" — because the probe disconnects right after the repaint; the incremental resume was
independently proven in §3c: tiles 510 → 4.) Severity/impact: was test reliability only; the feature was
never affected.

### D2 — Found and fixed during verification: a second client-driven DISP resize in one connection was never handled (real worker bug)
Reproduction (pre-fix worker): custom /tmp probe (copy of the committed mode-10 probe with two sequential resize
pairs; `/tmp/vr3/probe2.c`) on a loopback worker with a fake Agent: 2560x1440 connect, DISP monitor layout
1920x1080 at t≈400 ms, second DISP monitor layout 5120x2880 at t≈1600 ms.
Observed pre-fix: the first resize was fully handled (peer_reactivate, full `tiles=510` repaint, incremental
`tiles=4`); the client API accepted the second layout (`resize2_requested width=5120 height=2880`) but the
worker log had **no second `peer_reactivate`/`peer_resize_ignored`** and the probe hit its 20 s deadline
(rc=21). Session/worker stayed healthy — a silent, client-visible limitation of repeated resizes.
Root cause (diagnosed and fixed by the maintainer, confirmed independently here): **WinPR on Unix does not implement
auto-reset events** (`CreateEvent(NULL, FALSE, …)` logs "auto-reset events not yet implemented";
`WaitForMultipleObjects` never drains the eventfd). `frame_event` was created auto-reset and was still
readable after the first Agent frame, so the peer thread's wait always returned the lower-indexed
`frame_event` and never reached the `resize_event` branch — and the loop additionally busy-spun.
Fix in `internal/worker/native.c`: both per-peer events are created **manual-reset**
(`CreateEvent(NULL, TRUE, …)`), `run_peer` drains the signaled event with `ResetEvent` right after
`WaitForMultipleObjects` (before processing, so a signal arriving during the iteration remains pending for
the next wait), and a new audit line `event=disp_monitor_layout requested=WxH monitors=N` was added in
`peer_disp_monitor_layout` (the follow-up this verification suggested).
Re-verified after the rebuild (worker 校验和略, `internal/worker/native.c` 23:30 (the earlier 23:22 fix build also passed the same checks)): both resizes
handled, full ordered log evidence in §3c, probe rc=0; single-resize and output-suppressed resize checks still
PASS on the same binary; idle CPU over 3 s after a session = **0.00 s** (busy-spin gone at this sampling
resolution; measured on the fix build). D2 is therefore **FIXED, not an open defect**.

### D3 (observation, not a defect) — out-of-scope change in the same diff
`MacKeyMap.swift` maps Win keys 0x5B/0x5C to macOS Command. That is a useful follow-up from the earlier investigation
("Win key unsupported") but is not part of Work item A. It is small, unit-tested by the new preconditions,
and does not touch the resolution path; recorded so the maintainer can decide whether to split it.

## 5. Residual risks / follow-ups
1. **Live Windows 11 App validation still required** (not possible here): real window resize via DISP, the
   initial-clamp presentation (synthetic `reactivated` line is probe-only), and one live mouse click at
   corners/centre of a letterboxed size. The design's own follow-up list says the same.
2. **Repeated in-session resize** is proven on loopback after the D2 fix (twice in one connection); the
   committed `test_19` coverage for a second round was being added by the maintainer after this report — the live
   Windows client still needs to be watched for its DVC/re-activation behaviour.
3. **Live size/fps matrix** (`scripts/benchmark-live-agent.py --width/--height`, target 60 fps) not run;
   live service carries the user's session and was left untouched. Upscaled >native clients are
   nearest-neighbour and may alias (documented acceptance).
4. **GFX/AVC420 mid-session resize** is intentionally ignored (`peer_resize_ignored reason=gfx_active`); no
   loopback test exercised it because the AVC420 path requires `RDP_TEST_GFX=1` + the avc420 worker, which
   was not run in this verification. Accepted design gap/follow-up (GFX ResetGraphics).
5. **Desktop dimensions below 200 or above 32766 cannot be exercised** through the FreeRDP probe (client
   monitor validation rejects them before the worker); the worker contract for those inputs is only proven by
   formula, not end-to-end. 200x32766 (clamp) likewise not reachable (probe caps at 16384/axis).
6. **Real capture agent path untested**: the Agent capture policy/display polling was verified as compiled
   pure formulas (and `make agent-check`), not against a real SCStream/SCScreenshotManager session on the
   display; TCC/permissions/live capture were not exercised.
7. **Deployment/rollback** not performed: the live service runs the pre-change binaries; the new worker/agent
   are built but not deployed by this verification.
8. Long soak beyond 50 sessions / 20 large sessions not run; RSS/threads measured plateau only.

## 6. What this verification did NOT prove (explicit)
- Live Windows App / mstsc behaviour: DISP window resize, initial-clamp display, mouse clicks, deployment.
- GFX/AVC420 mid-session resize (documented as ignored), NSCodec/AVC420 specific paths.
- Live fps/size matrix and any performance claim.
- Real macOS capture agent (SCStream/SCScreenshotManager, display-size change polling, TCC).
- The complete full-frame send log for the *second* (very large) in-session resize: the reactivation,
  renegotiation, type-9 re-request and first PDU at the new size are proven, but the custom probe stops
  pumping events during the observation window, so the worker's 5 s draw watchdog cancels the remaining write
  (test artifact).
- Dimensions <200 or >32766 per axis, and the 200x32766 clamp through the probe.
- That the committed suite is deterministic across machines/load: it is green on the final tree (one full
  independent re-run plus the maintainer's runs), but the earlier flake (D1) shows the timing-sensitive areas need a
  few more repetitions in CI.

## 7. Artifacts / how to reproduce
- Mandatory runs: `/tmp/vr2/stage1..5.log` (timestamped, sequential); final-tree suite re-run:
  `/tmp/vr3/suite-fixed.log`.
- Test_18 flakiness + uncached Go tests: `/tmp/vr3/extra.log`.
- D2 pre-fix evidence: `/tmp/vr3/twice.py` (pre-fix log, second request ignored); post-fix evidence:
  `/tmp/vr3/d2.log`, `/tmp/vr3/d2final.log`, `/tmp/vr3/twice2.log`, and the final-bin re-check
  `/tmp/vr3/d2_final2.py` (prints the worker sha256 before/after; final bin `（校验和略）`:
  two reactivations, full 510 / incremental 4 / second resize frame 5120x2880, no rejects).
- Adversarial harness and results: `/tmp/vr3/harness.py`, `adv.py` → `adv.log`, `adv2.py` → `adv2.log`,
  `final_resize.py`, `crosscheck.py`, `probe2.c`/rdp-probe2 (all throwaway, /tmp only, never committed).
- Formula crosscheck: Swift driver over the working-tree `MacAgentCore` sources vs an independent Python
  implementation of design §3/§4/§5 → 71/71 match, 0 mismatch.
- All adversarial runs used random loopback ports and isolated temp dirs; the live 3389 service was not
  touched.
- Timeline caveat: this report was produced while the maintainer was still landing the D2 fix and the
  committed-`test_19` second-resize coverage. The mandatory runs in §1 and the 23:07 green suite were on the
  tree just before the D2 fix; the D2-affected scenarios plus single/suppressed resize regressions were then
  re-run and re-verified on the final worker (校验和略, built 23:30) — see §3c/§4. The maintainer is
  re-running the full committed suite on the final tree; no source file outside the documented change set was
  touched by this verification.

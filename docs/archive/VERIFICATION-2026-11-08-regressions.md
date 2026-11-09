# Verification — 2026-11-08 integrated regressions + deploy readiness (Issues 1-3)

> 注：本文是历史验证快照；文中的 PID/generation/提交/校验和均属当时状态，不代表当前运行态。

> **历史记录（已被取代）** — 2026-11-08 集成回归记录；测试基线数字已被 STATUS §4 取代（当前 35 例 loopback E2E，1 例 AVC420 skip）。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Independent adversarial verification (read-only for source/tests).
Date: 2026-11-08 09:27-10:00 (Asia/Shanghai). Branch: `feature/dynamic-resolution-and-connection-stability`.
Base before this change set: `07942eb` (mouse double-scaling commit). Final verified HEAD: **`2641480`**
(`eb04f35` worker file clipboard + DISP diagnostics, `05970c8` agent file clipboard, `0f3c925` tests/tooling,
`7000d12` DISP diagnosis doc, `5552268` clipboard state-machine/name fixes, `2641480` wheel direction +
agent-side name validation + committed regression tests). Final tree: clean except the other verifier's
untracked `docs/archive/VERIFICATION-2026-11-08-clipboard-files.md`.

Constraints respected: no source/test file was modified by this verification (only this note was created),
no git commit, no live worker/agent restart or kill by this verification, no `.runtime/sam`,
`.runtime/config.json` or credentials read; all experiments used isolated loopback workers, fake Agents,
`/tmp` binaries and `/tmp` directories. The live service was only read (logs/`ps`/`launchctl`) after the maintainer
deployed.

## Verdict

**PASS — no blocker, no product regression found.** All mandatory suites are green on the final HEAD;
the deploy artifacts are byte-identical to independently built HEAD binaries; the matched-pair deploy the
maintainer performed at 09:52 was done in the safe order and the post-deploy pair is healthy.

One **major deploy-process hazard** remains by design (worker and Agent are a hard matched pair for the file
clipboard; mixing versions can crash the Agent). It did not affect this deploy and is documented with the
required runbook rule in §5.1. Findings F2/F3 below (raised by the parallel file-clipboard verification and
fixed during this session) were independently re-verified. User GUI acceptance of the file clipboard, the
wheel direction/feel and the DISP client-log hop is still pending (see §2.8 / §4).

## 1. Verification states and artifacts

The tree moved four times while this verification ran; every result is bound to an exact state.

| State | Content | Independent binaries built from it |
|---|---|---|
| A `7000d12` | `eb04f35`/`05970c8`/`0f3c925`/`7000d12` (= the working-tree diff this verification started from; per-file diffs byte-identical) | `/tmp/vr-worker` sha256 `（校验和略）` (built while dirty at `07942eb`), `/tmp/vr-probe` sha256 `（校验和略）` |
| B `7000d12` clean | same tree rebuilt after the maintainer committed | `/tmp/vr-worker2` `（校验和略）`, `/tmp/vr-probe2` `（校验和略）` |
| C `5552268` | + zero-byte-first state-machine fix, C1/bidi name/path rejection (worker `clipboard_files.h` only) | `/tmp/vr-worker-h` `（校验和略）`, `/tmp/vr-probe-h` `（校验和略）` |
| D `2641480` (final) | + wheel direction fix, Agent-side C1/bidi validation, committed regression tests (Swift + scripts only; **no worker C change**) | worker/probe from C remain exact (Swift release build re-done in `/tmp/vr-agent-pkg2`, 27.4 s, OK) |

`/tmp/vr-worker` (dirty `07942eb`) and `/tmp/vr-worker2` (clean `7000d12`) differ only in Go
`vcs.modified`/`vcs.revision` build-info, not code. For state C/D the worker/probe binaries are
byte-identical to the deploy artifacts: `bin/rdp-worker` sha256 **`（校验和略）`**, `bin/rdp-probe`
sha256 **`（校验和略）`** — i.e. the workload the maintainer deployed is exactly what this verification tested.
The deployed Agent app executable was built at 09:51 after `2641480` (`bin/RDPAgent.app/.../rdp-agent`
sha256 `（校验和略）`) and contains the new `MacAgentCore.RDPWheel.macOSWheel1` symbol at the same address as
the independent HEAD build.

## 2. Mandatory suites (run by this verification, exact results)

All commands run in an interactive user shell on this Mac, sequentially, against the `/tmp` binaries above.

| # | Command | Result |
|---|---|---|
| 1 | `go build -o /tmp/vr-worker ./cmd/rdp-worker` + `go build -o /tmp/vr-probe ./cmd/rdp-probe` (states A-C, rebuilt per state) | OK, no warnings |
| 2 | `go test ./...` then `go test -count=1 ./...` | OK (agentipc/auth/config/worker); exit 0 |
| 3 | `go test -race -count=1 ./...` (states B and C) | OK 4/4 packages, exit 0 |
| 4 | `go vet ./...` | exit 0 (only pre-existing winpr deprecation warnings) |
| 5 | `make check` (states B and C: `go test -race` + `test-gfx-session` 14 tests + `test-avc-encoder` 2 tests + `go vet`) | exit 0; gfx-session "Ran 14 tests OK", avc-encoder "Ran 2 tests OK" |
| 6 | `make agent-check` (states B, C and final D) | exit 0, prints `clipboard_file_tests_ok` (now includes wheel-direction and C1/bidi preconditions) |
| 7 | `python3 scripts/test-clipboard-handshake.py` (final state D) | **6 tests OK**, exit 0 (includes fail-before/pass-after C checks for zero-byte-first advance and C1/bidi name+path rejection) |
| 8 | `python3 scripts/test-agent-ipc-wire.py` (final state D) | **5 tests OK**, exit 0 |
| 9 | `RDP_TEST_WORKER_BINARY=… RDP_TEST_PROBE_BINARY=… python3 scripts/test-protocol.py` ×5 (states A×2, B, C, D) | **33 tests OK (skipped=1)** every time; durations 89.4 s, 89.4 s, 90.6 s, 90.1 s, 91.0 s; **no flake** |
| 10 | isolated Agent release build: copy `native/macos/{Sources,Package.swift}` to `/tmp/vr-agent-pkg2`; `swift build -c release` | Build complete 27.4 s; executable produced (the real `make agent-build`/`make agent-app` was left to the maintainer's deploy step) |

Notes: the single skip in every protocol run is `test_12_gfx_avc420_client_probe` (needs `RDP_TEST_GFX=1` and
an AVC420-enabled worker/probe — unrelated to this change set). `test_19` prints one informational line
("session closed before an incremental frame after the resize repaint could be observed") in every run; it is
the test's tolerated branch, not a failure, and appears identically in pre-change runs. `make check`'s two
Python suites are standalone C/policy harnesses and do not spawn the worker binary; the worker/probe E2E
coverage comes from the protocol suite.

## 3. Regression review of existing behaviour (diff vs base `07942eb`)

### 3.1 Issue 2 — mouse (committed in `07942eb`, re-verified)
`send_mouse_event()` (`internal/worker/native.c`) forwards the client's desktop `x,y` **verbatim** into the
IPC type-3 payload, clamping only to the negotiated desktop (`dx>=ctx->width → width-1`); the pre-fix
`x*frame_width/ctx->width` scaling is gone. Loopback tests `test_21` (uniform 1280x720→2560x1440 and
1254x610→2508x1220) and `test_21b` (letterboxed 2214x1440→2560x1440 and 1876x1220→2508x1220, where the bug
sent 86/74 instead of 100) assert the fake Agent receives `mouse(100,100)`; both are green in all five
protocol runs. The diff does not touch `send_key_event`/unicode/release-all input paths or input coalescing.
The probe-only hook `RDP_PROBE_INPUT_AFTER_FIRST_BITMAP` is default-off; mode-0 stdout is unchanged unless
the hook is set (the extra `input_sent_after_first_bitmap` line is printed only on the hook path).

### 3.2 Issue 1 — DISP diagnostics only (no behaviour change)
- `configure_peer()` adds `ctx->disp->ChannelIdAssigned = peer_disp_channel_id_assigned`; the callback only
  logs and returns `TRUE` (a `FALSE` would fail `Open()`).
- `run_peer()` refactor keeps the identical open conditions (`peer->connected && joined && dvc ready`),
  the identical single-attempt/single-failure paths, and only adds the opt-in `RDP_DISP_DEBUG=1` state line.
- Existing DISP event names and their first fields are preserved; new fields are appended
  (`ts_ms=`, `max_monitors=`, `area_a/b=`, per-monitor fields). Substring parsers keep working: `test_22`
  asserts the old substrings (`disp_channel_opened result=0|1`, `disp_channel_closed opened=0`) and
  `scripts/disp-diagnose.py`'s regexes still match (checked by inspection and by the green DISP tests).
- `peer_context_cleanup()` now emits one `event=disp_channel_closed opened=0|1 ts_ms=` line per peer.
- `test_19`, `test_20` (one and two client-driven resizes) and the new negative `test_22` (client without
  DISP support) are green in all five runs.
- Production log (read-only) evidence: `disp_channel_opened` 16 / `disp_caps_sent` 16 /
  `disp_monitor_layout` 0 / `peer_reactivate` 0. The documented diagnostics fields appear in the
  independent evidence artifacts (`/tmp/disp-diag-evidence/*`, `/tmp/rdp-worker-disp` sha256 matches the
  diagnosis doc: `（校验和略）`).

### 3.3 Text clipboard path (type 8) unchanged
Wire format is untouched: Agent→worker `type=8, payload=[1]+UTF-8`; worker→Agent
`type=8, payload=[2]+UTF-16LE`. `ClipboardMonitor.poll()` still returns the same `[1]+UTF-8` payload, the
same `< 65536` limit, and the same empty-payload revocation for an empty/non-text clipboard. The format-list
selection now prefers files over text and is unit-tested by `scripts/test-clipboard-handshake.py`
(`test_acknowledges_formats_then_requests_unicode_from_client`); `test_26` proves a text clipboard still
works next to the file path. Stale text is dropped when a file offer becomes the clipboard and a file
advertisement is revoked when text/empty arrives (worker `clipboard_publish_local`; Agent
`sendLocalClipboardUpdate`). See F4 for the one coverage gap.

### 3.4 Frame delivery / session lifecycle / output suppression / lease
The diff's only peer-lifecycle additions are: the cliprdr-init publishing block in `peer_post_connect`,
one teardown log line, the cliprdr stream abort in `peer_context_cleanup` **after `cliprdr->Stop()`** (no
callback races), and a lock-free stall flag in the peer loop (sets `clip_file_cancel_requested` only).
`test_01`-`test_22` cover reconnect, single-connection lease, half-open/TLS stall timeouts, blocked frame
writes, refresh timeout, output suppression echo, planar/NSCodec/delta frames, size matrix and fit-with-bars;
all green in all runs, and the two protocol runs at the same state were reproducible (no flake).

### 3.5 Connect-time cliprdr initialization ordering (changed on purpose)
`ctx->cliprdr->autoInitializationSequence=FALSE`; the **peer thread** sends `CB_CLIP_CAPS` then
`CB_MONITOR_READY`, and only afterwards the first local `CB_FORMAT_LIST` (`cliprdr_send_initialization` +
`clipboard_publish_peer`). Independently measured on a loopback session (probe mode 11, fresh worker):
exactly **1** `caps_received general_flags=0x00000006`, exactly **1** `event=cliprdr_initialized
general_flags=0x00000006`, 1 `event=cliprdr_start result=0`, zero `cliprdr_*_failed` lines → no double
initialization. `0x6 = CB_USE_LONG_FORMAT_NAMES (0x2) | CB_STREAM_FILECLIP_ENABLED (0x4)` per
`.deps/install/include/freerdp3/freerdp/channels/cliprdr.h` (matches the contract's caps intent;
`fileClipNoFilePaths=FALSE`, `hasHugeFileSupport=FALSE`).
Clients that do not redirect the clipboard: with `clipboard=true`, probe mode 5 (no cliprdr channel) gives
`event=cliprdr_start result=1359` (pre-existing FreeRDP "channel not open"), **no** init PDUs are sent
(`cliprdr_initialized` is false and every publish path checks it) and the session is normal (probe rc=0,
bitmap update received). The pre-change `bin/rdp-worker` baseline produced the identical `result=1359`,
so this is not a regression.

### 3.6 Unknown IPC type tolerance (both sides)
- Worker: fake Agent sent `type=99` and then a valid type-2/7 frame to a fresh worker → log
  `event=agent_ipc_ignored type=99` (once), **no** `agent_ipc_rejected`, the frame was received
  (`event=agent_frame_received`), session continues. Types ≤6/8/9/13+ are also tolerated (bitmap-deduped
  logging).
- Agent: `scripts/test-agent-ipc-wire.py` sends unknown type 99 to the real Swift `AgentUnixSocket`
  receiver → exactly one `event=ipc_message_ignored type=99`, later known messages still flow; the old
  throw/exit path is gone.

### 3.7 Swift Agent changes (final state D)
- `receiveMessages` uses `decodeTolerant` and per-type dedupe; malformed magic/version/length still throw
  (unrecoverable errors still exit → launchd restart, as before).
- `ClipboardMonitor.poll()` preserves text payload/limit/empty semantics; a file URL list becomes a
  direction-2 offer, and files win over text for the same change; pasteboard writes performed by the Agent
  are folded into `lastChangeCount` so they do not echo back.
- File assembly runs on `DispatchQueue("rdp-agent.clipboard-files")`; `submit()` from the input receiver only
  enqueues bounded messages (never writes files on the input thread), and a 64 MiB pending cap aborts with
  `ipc_backpressure` (see F5 for its observable edge).
- Both live code paths (`stream-snapshot` snapshot loop, `stream-snapshot` SCStream loop) and the legacy
  `stream` command call `sendLocalClipboardUpdate` and route file messages to the receiver; the diagnostics
  `capture-stream` path has no clipboard IPC and is unaffected.
- Remote→local files: assembler validates begin/entry/chunk/end per contract (count/total/name/size,
  in-order contiguous chunks, exact sizes), writes `NSTemporaryDirectory()/rdp-clipboard/<uuid>/` with dirs
  0700, files `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW` 0600, keeps at most current+previous directories and
  deletes the offer directory on cancel/fail. Agent-side C1/bidi name/path rejection (F3) is now present and
  unit-tested.
- `make agent-check` compiles the complete `Sources/MacAgentCore` file list (19 sources incl. new
  `ClipboardFileTransfer.swift`) plus both test files; the isolated `swift build -c release` compiles
  `main.swift` including the wheel change.

### 3.8 Wheel direction change in `2641480` (new since the original diff, reviewed)
`RDPWheel.macOSWheel1()` replaces posting the raw RDP rotation in `.line` units: it inverts the sign
(field report: macOS scrolled opposite to Windows) and converts ±120 rotation to ±1 line per notch
(sub-notch rotations clamp to ±1, zero rotation returns nil). Call site unchanged (same CGEvent post path).
Unit preconditions cover +120/-120/±240/sub-notch/zero. Physical direction/feel cannot be verified without
the user's GUI (Windows' default is 3 lines/notch; the fix posts 1 line/notch — see §2.8 acceptance).

## 4. Findings (severity, evidence, repro)

**F1 — major (deploy-process hazard, not a code defect): worker and Agent are a hard matched pair; mixed
versions can crash the Agent.** The file-clipboard IPC types 13-16 are not understood by the pre-change
builds, and neither side negotiated a version.
* new-worker + old-Agent: the new worker sends type 13/16/14/15 only when an RDP client pastes files
  (remote→local: `cliprdr_client_formats` sees `FileGroupDescriptorW` → `cliprdr_client_data_response` →
  `cliprdr_stream_start`). The old Agent's `AgentIPCCodec.decode` throws `.unknownMessageType`, which
  escapes `receiveMessages` into `startInputReceiver`'s outer catch → `exit(1)` (verified in
  `07942eb:native/macos/Sources/rdp-agent/main.swift`). launchd `KeepAlive{SuccessfulExit:false}` +
  `ThrottleInterval 10` restarts it (~10 s cadence).
* new-Agent + old-worker is the worst direction: the new Agent's first clipboard poll sees a file list
  already on `NSPasteboard` (`lastChangeCount` starts at -1) and sends 13/16/15; the old worker logs
  `event=agent_ipc_rejected reason=invalid_frame_message` and **closes the IPC socket** → the Agent's next
  send/frame throws → exit(1) → launchd restart → re-reads the same file list → ~10 s crash loop until the
  clipboard changes.
* Repro of the old-worker half (executed by this verification against the then-live-old `bin/rdp-worker`
  before the deploy overwrote it): open a fake-Agent socket, send `RDPA`+type 13+16-byte begin; observe
  `event=agent_ipc_rejected reason=invalid_frame_message` and `BrokenPipeError` on the next write.
* Mitigation (followed by the 09:52 deploy, must also be used for rollback): replace both binaries first,
  then start the new worker (`kill -TERM supervisor` → `rm -f .runtime/agent-compat.sock` → start), then
  `launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent`. Never restart the new Agent while the old
  worker is still running; never roll back only one side. Because worker restart drops all RDP sessions,
  the new-worker+old-Agent window has no client traffic, so worker-first is safe in practice.

**F2 — minor, FIXED at `5552268` (re-verified): zero-byte FIRST file aborted multi-file paste.** The chunk
state machine inferred "no file started" from `total_bytes==0 && file_index==0 && offset==0`; a leading
0-byte file left exactly that state, so advancing to file 1 failed with `bad_state` and the paste timed out.
`5552268` adds an explicit `file_started` flag and commits regression tests (`scripts/test-protocol.py`
test_23 cases 0,128 / 0,0,1024 / 512,0,64 with byte-exact IPC assertions; C-harness cases). Independent
re-verification at state C/D: custom loopback runs with probe mode 11 for offers `[0,1024]`, `[0,0,128]`,
`[64,0,0]` → probe rc=0, `file_paste_ok`, IPC begin/entry/end exact, chunks only for non-empty files and
byte-exact; C state-machine checks pass. Repro:
`RDP_TEST_WORKER_BINARY=<pre-5552268 worker> …` + the test_23 zero-first cases fail with
`reason=bad_state`; on HEAD they pass.

**F3 — minor, FIXED at `5552268` (worker) and `2641480` (Agent), re-verified: C1/bidi control characters
accepted in names/paths.** Names containing U+0080..U+009F, U+200E/F, U+202A..E, U+2066..69 were accepted;
they can spoof/corrupt log lines and local file names. The worker's `clipboard_files.h` now rejects them in
names and paths (C harness has fail-before/pass-after checks); the Agent's `AgentClipboardFileValidation`
mirrors it (Swift preconditions). Independent check: a compiled C program against HEAD rejects those code
points for names and paths and still accepts NBSP/U+202F/Chinese/emoji/en-dash names.

**F4 — minor: remote→local text clipboard (Windows copy → macOS paste) has no end-to-end loopback test.**
The worker callback that forwards client text to the Agent was rewritten in this change
(`cliprdr_client_text_response` → `cliprdr_client_data_response`, now gated on the pending requested
format). Behaviour is equivalent on review, the C harness covers format-list selection and `test_26` covers
text next to the file path, but no probe mode sends a client text clipboard, so the forward path
(`send_agent_clipboard_utf16`) is only code-reviewed. The deployed pair did exercise it live on
2026-11-08 09:55 (`selected=13` → `clipboard_client_text_forwarded result=1`), so the path works with the
real client; the gap is automated regression coverage only. Suggested repro/coverage: add a probe mode or
fake cliprdr client that advertises format 13, answers `CB_FORMAT_DATA_REQUEST` with UTF-16LE text and
asserts a type-8 payload `[2]+utf16le` arrives at the fake Agent.

**F5 — minor: Agent buffer backpressure can silently drop a completed paste while the worker reports
success.** If file writes fall behind by >64 MiB (`ClipboardFileReceiver.maxPendingBytes`), the Agent logs
`clipboard_file_rejected reason=ipc_backpressure` and discards the rest of the offer; there is no back-channel
for that in direction 1, so the worker still sends IPC 15 complete and logs
`clipboard_file_complete result=0`. Memory stays bounded (as designed) but the worker's `result=0` is not a
paste guarantee in that edge case. Repro: only reachable with a deliberately slow `FileSystem` (Swift unit
injection) or extreme disk stalls; not reproducible on loopback.

**F6 — minor: temp-directory rotation can delete files still referenced by the pasted clipboard.** Per
contract the Agent keeps only current+previous offer directories; when a new remote→local offer begins it
deletes the older one. If the clipboard still points at that directory (e.g. two consecutive offers since
the paste) a Finder paste of the old items can fail while the new transfer is running. Contract-compliant,
low user impact.

**F7 — nit: `options->clipboard_utf8` is not freed when a file offer replaces text**
(`clipboard_agent_offer_begin` sets `clipboard_utf8_length=0` without freeing). Bounded: the buffer is freed
on the next text change and at process exit; no growth per offer.

**F8 — nit: direction-2 entry validation does `open()/fstat()` while holding `options->clipboard_mutex`**
(`clipboard_validate_local_file` inside `clipboard_agent_offer_entry`). Not the `agent_mutex`/`frame_mutex`
the contract forbids and syscalls are short, but it can briefly delay cliprdr callbacks that need the
clipboard lock. Contention only; no deadlock observed or found by lock-order review.

**F9 — minor, pre-existing (not introduced here): machine-specific temp directories in the test scripts.**
`scripts/test-protocol.py` (`agent_socket_dir`) and `scripts/test-agent-ipc-wire.py` (3 tests) hardcode
`$TMPDIR/opencode`（本机 /private/var/folders/... 形式）。They were already present at `07942eb`;
on any other machine/CI the suites fail with `FileNotFoundError`. Deploy on this machine is unaffected.

**F10 — minor (docs): the DISP diagnosis is honest but now stale in places; the historical internal notes are not maintained in this repository.**
`docs/DIAGNOSIS-2026-11-08-disp-window-resize.md` correctly states the status ("client-side state/setting is
the leading conclusion; the exact failing client flag is still unproven"), the unproven hop (§6.4) and the
acceptance block (§9) — this matches the code/log evidence reviewed here. Stale items: it says
"HEAD `07942eb` + uncommitted working-tree changes" (now committed through `2641480`), and its production
counts "7 DISP opens/caps" (the live log now has 16 opens / 16 caps / 0 layouts / 0 reactivations — same
conclusion). The doc's Windows-App log strings were cross-checked in the installed binary (`Received Display
Control Caps`, `Received monitor layout change with {} monitors`, `SendMonitorLayoutPdu returned: {}`,
`Unexpected Caps PDU length {}`) and its artifacts/sha256 were verified. Not re-derived independently: the
opcode-level static analysis in §4.2/4.3 and the bookmark CLI matrix; not re-run: `disp-diagnose.py
--self-test` (it mutates the user's Windows App bookmark list; script syntax and isolation design were
inspected instead). The current conclusion is tracked in `docs/STATUS-2026-11-08.md`.

**F11 — nit: a client `CB_FORMAT_DATA_REQUEST(13)` while the local text is empty/unadvertised now gets no
`CB_FORMAT_DATA_RESPONSE`** (old code answered with an empty UTF-16 string). A conforming client only requests
advertised formats, so this needs a misbehaving client; session stays up. If strict MS-RDPECLIP behaviour is
wanted, answer `CB_RESPONSE_FAIL`.

**F12 — nit: new `event=disp_channel_closed opened=0|1 ts_ms=` line per peer session** (also for clients that
never opened DISP). Substring-based log tools are unaffected; only exact whole-line matchers would need an
update (none found in this repo).

## 5. Docs accuracy and deploy readiness

### 5.1 Deploy performed (post-deploy read-only check)
The maintainer deployed the matched pair at 09:52:18-09:52:37 in the safe order (old worker stopped first, new
worker started, then Agent kickstart), after rebuilding the Agent from `2641480` at 09:51:
worker supervisor **70928** → child **70932**（`bin/rdp-worker` 与独立验证的 HEAD 构建一致），
Agent PID **71088**，generation **695**（`bin/RDPAgent.app/.../rdp-agent`，contains the
`macOSWheel1` symbol). TCC screen_recording/accessibility granted (maintainer), worker log shows `clipboard=true`.
Post-deploy read-only spot check (09:54-10:00): worker `event=listening`; Agent connected and streaming
约 2.9K (first full frame 1380 tiles / 22,485,120 bytes, then 7-27 changed tiles per frame); worker IPC
clean (no `agent_ipc_rejected`, `ipc_message_ignored`, `agent_ipc_write_*`, `peer_configure_failed`); one
`event=clipboard_local_changed` handled (new pair IPC works); Agent log shows continuous 60 fps
`snapshot_timing` with no `input_receiver_stopped` and no crash loop. Two real Windows App sessions then
connected and exercised the new code live:
- 09:55:37 (1600x1200): `cliprdr_start result=0`, **`cliprdr_initialized general_flags=0x00000006` exactly
  once** (new init ordering accepted by the real client), new DISP audit lines with `ts_ms`,
  `clipboard_client_formats result=0 selected=13` → **`clipboard_client_text_forwarded result=1`**
  (remote→local text works live), and
  `clipboard_file_entry/offer/complete direction=local_to_remote count=1 bytes=6065780 result=0`
  (macOS→Windows file offer works live: a 6,065,780-byte file with a 30-byte name was advertised).
- Same session later: `clipboard_client_formats result=0 selected=49155` (0xC003) immediately followed by
  `clipboard_file_rejected direction=remote_to_local reason=client_failed` — the **real client answered the
  file-descriptor data request with FAIL/empty**, so that Windows→macOS paste did not proceed (the session
  stayed healthy; lease released normally; a reconnect at 09:58:13 re-ran the init sequence once with
  `general_flags=0x6`). This is a client-side refusal path, not a worker crash, but Windows→macOS file paste
  still needs a user retry and client-side evidence before it can be called accepted (see §5.4).
- The maintainer's `scripts/disp-diagnose.py --duration 300` manual test (Issue 1 client-log hop) finished with exit 0
  at 09:58; interpreting its client-log evidence is the maintainer's/Issue-1 owner's task and is not re-verified here.

### 5.2 Runbook applicability（运维须知现见 `AGENTS.md` §6；下面引用内容保留为历史证据）
Still applies unchanged: worker restart drops RDP sessions (user consent required); restart via
`kill -TERM <supervisor>` → `rm -f .runtime/agent-compat.sock` → `nohup ./bin/rdp-worker -config
.runtime/config.json -agent-socket .runtime/agent-compat.sock >> .runtime/worker-live.log 2>&1 &`;
`launchctl kickstart -k gui/$(id -u)/com.rdp-server.agent` restarts the Agent without dropping the session;
post-deploy `rdp-agent status` TCC check. Verified live topology matches the documented deployment model (supervisor PPID 1 →
child; launchd label/bundle id; agent generation file/argument).
No config format change: the `clipboard` config key already existed before this change set (default false;
production has it true and text clipboard worked before). No new environment variables are required
(`RDP_DISP_DEBUG`, `RDP_TEST_*` are diagnostic/test only). Nothing new needs a launchd/supervisor change.

### 5.3 New operational surface (small)
- Worker/Agent temp files: Agent writes only under `NSTemporaryDirectory()/rdp-clipboard/<uuid>/`
  (0700 dirs / 0600 files, O_EXCL/O_NOFOLLOW), keeps at most current+previous offer dirs and deletes failed
  offers; they live under the per-user `/var/folders/.../T` and are system-cleaned. No ops action; leftover
  dirs after a rollback are harmless.
- Logs: new grep-able events (`cliprdr_initialized general_flags=0x6`, `clipboard_file_*`,
  `clipboard_local_changed`, `disp_channel_closed`, `agent_ipc_ignored`, `ipc_message_ignored`,
  `clipboard_file_rejected reason=…`); per-session volume is negligible next to frames. Worker log appends
  (~242 MB before deploy) — unchanged policy.
- TCC: no new required permission for text/file clipboard in the default paths. Caveat: local→remote file
  copies read user files from the worker/Agent process context; files in TCC-protected locations
  (Desktop/Documents/Downloads) may be denied by macOS privacy (symptom: `clipboard_file_rejected
  direction=local_to_remote reason=unreadable|not_regular`) unless the Agent/worker has Files & Folders /
  Full Disk Access. Not testable without the user GUI; include it in acceptance.
- Rollback: `bin/` was overwritten by the deploy; this verification found no saved pre-change binaries in
  `bin/`（旧 worker 构建为 `6dec2ac`，Agent 为旧版）。Rebuild from
  `6dec2ac` (e.g. `git worktree add /tmp/rollback 6dec2ac` then `make build agent-build agent-app`, copy
  binaries back) and roll back **both** sides in one window (worker stop/start first, then Agent kickstart).
  No config/SAM format change, so rollback is binary-only.

### 5.4 User acceptance still required (not verifiable headlessly)
File clipboard: Windows→macOS paste of one/multiple files, Chinese name, ~10 MiB, 0-byte, and a list whose
**first** file is 0 bytes; macOS→Windows the same; Finder/Explorer paste, content equality; text↔files
switching both ways; cancellation/oversize leaves session alive and no stuck temp dirs. macOS→Windows file
offers already worked live; the one live Windows→macOS attempt aborted with `reason=client_failed` (client
answered our descriptor request with FAIL/empty, §5.1) — retry with Explorer copy → Finder paste and, if it
fails again, capture: Windows App version/clipboard-redirection setting, the exact copied item type
(file/folder/zip/cloud placeholder), the worker log lines around `selected=49155` and the App unified log
(`log stream --info --predicate 'process == "Windows App"'`). Do not change server code before that
evidence exists; `client_failed` means the client refused and the worker aborted gracefully.
Wheel: direction matches Windows and 1 line/notch feels right (unit mapping only). DISP: one user GUI session
with `scripts/disp-diagnose.py` to capture the client unified-log hop (the diagnosis doc's §6.3) — the maintainer's
300 s run was in progress at the final check. TCC-protected folder copy as in §5.3.

### 5.5 Maintainer follow-ups for historical internal records (historical notes; not in this repository)
1. Deploy record: final pair PIDs/shas/generation, deploy time, matched-pair rule + the F1 mixed-version
   crash-loop hazard and safe order (and the same rule for rollback). New worker SHA `（校验和略）`, Agent app
   `（校验和略）`.
2. Issue status: Issue 2 mouse fixed (`07942eb`) + wheel direction fix (`2641480`); Issue 1 = diagnostics +
   client-side diagnosis, user GUI hop still open; Issue 3 file clipboard implemented (worker C + Agent Swift
   + probe modes 11/12 + tests) and deployed.
3. Maintainer notes: IPC types 13-16 wire format; server `CB_CLIP_CAPS` general_flags `0x6`; cliprdr
   `autoInitializationSequence=FALSE` with peer-thread `CB_CLIP_CAPS`+`CB_MONITOR_READY` then first
   `CB_FORMAT_LIST` (order matters — `test_26` flake); `clipboard` config key now enables text+file
   clipboard; Agent temp-dir policy/limits.
4. Test baseline update: protocol suite **33 tests (32 pass + 1 AVC420 skip)**, new
   test_21/21b/22/23/24/25/25b/25c/26; `test-clipboard-handshake.py` 6, `test-agent-ipc-wire.py` 5,
   `make agent-check` now runs wheel/validation/clipboard Swift tests; log strings to watch.
5. Pending acceptance items from §5.4 and the docs-accuracy fixes from F10 (DIAGNOSIS HEAD/counts).

## 6. Not verified / limitations
- User GUI acceptance not driven (per instructions): physical mouse/wheel direction, Finder/Explorer file
  paste, TCC prompts, Windows App window-resize client log hop. Field behaviour is covered by loopback only.
- The live worker/Agent were never restarted by this verification; post-deploy checks are read-only logs/`ps`.
- `disp-diagnose.py --self-test` was not re-run (mutates the user's Windows App bookmarks); static-analysis
  claims in the diagnosis doc were spot-checked with `strings`, not re-derived.
- Remote→local text clipboard has no E2E loopback test (F4); F5/F6 edge cases are code-inspection findings.
- The other verifier's `docs/archive/VERIFICATION-2026-11-08-clipboard-files.md` was present as an untracked file and
  was neither used as evidence nor modified by this verification.

## 7. Key repro commands (this verification)
```sh
# fresh binaries from the verified tree (never make build / bin/ during verification)
go build -o /tmp/vr-worker-h ./cmd/rdp-worker
go build -o /tmp/vr-probe-h ./cmd/rdp-probe
go test -count=1 ./...; go test -race -count=1 ./...; go vet ./...
make check; make agent-check
python3 scripts/test-clipboard-handshake.py
python3 scripts/test-agent-ipc-wire.py
for i in 1 2; do RDP_TEST_WORKER_BINARY=/tmp/vr-worker-h \
  RDP_TEST_PROBE_BINARY=/tmp/vr-probe-h python3 scripts/test-protocol.py; done
# isolated Agent release build (does not touch bin/)
cp -R native/macos/Sources native/macos/Package.swift /tmp/vr-agent-pkg2/ && swift build -c release --package-path /tmp/vr-agent-pkg2
# init-ordering / unknown-type / zero-byte-first experiments: python3 harness snippets importing
# scripts/test-protocol.py ProtocolTest (see §3.5/§3.6/F2), and a C program over clipboard_files.h for F3.
```
Environment: macOS (arm64), Go 1.27.3, FreeRDP 3.32.2 installed under `.deps/install`, Swift 6.x
(`swiftc` from the active Xcode/CLT toolchain). Runtime state at final check: worker supervisor 70928 →
child 70932, Agent 71088 (generation 695), both deployed from HEAD `2641480`; live pair healthy.

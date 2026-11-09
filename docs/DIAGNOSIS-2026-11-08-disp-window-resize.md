# DISP window-resize diagnosis — why Windows App never sends monitor layout (2026-11-08)

> **历史记录（已被取代）** — 2026-11-08 DISP 诊断；其中“黑边/自动分辨率”部分已由虚拟 16:9 显示器方案取代，**DISP 会话中窗口缩放的客户端限制结论仍有效**。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](STATUS-2026-11-08.md) 为准。


Work item: Issue 1（历史交接文档已移除）
("窗口缩放时自动分辨率切换没有生效").
Related design/implementation: [DESIGN-2026-11-07-resolution-adaptation.md](DESIGN-2026-11-07-resolution-adaptation.md),
[RESOLUTION-ADAPTATION-2026-11-07.md](archive/RESOLUTION-ADAPTATION-2026-11-07.md),
[VERIFICATION-2026-11-07-resolution-adaptation.md](archive/VERIFICATION-2026-11-07-resolution-adaptation.md).

Branch `feature/dynamic-resolution-and-connection-stability`, HEAD `07942eb` + uncommitted working-tree
changes (this diagnosis adds DISP audit logging to `internal/worker/native.c` and
`scripts/disp-diagnose.py`; the tree also contains unrelated clipboard/mouse work by other owners).

Status: **client-side state/setting is the leading conclusion; the exact failing client flag is still
unproven** because no Windows App unified log has been captured for a session against our worker yet.
Section 6 lists exactly which extra evidence the user GUI test must produce, and
`scripts/disp-diagnose.py` is ready to collect it.

---

## 1. TL;DR

* The server DISP implementation is correct and observable: a FreeRDP client (`bin/rdp-probe -mode 10`)
  completes a client-driven resize against the patched test worker (layout received -> reactivation ->
  new desktop size). Server-side evidence in section 3.
* The real Microsoft Windows App **11.4.4 (3132)** connected to production 7 times today; the worker
  opened the `Microsoft::Windows::RDS::DisplayControl` DVC and wrote `DisplayControlCaps` successfully in
  all 7 sessions, and the client sent a monitor-layout PDU **0 times**. Section 2.
* Static analysis of the Windows App binary shows the client's caps handler **accepts exactly the caps we
  send** (MaxNumMonitors=1, MaxMonitorAreaFactorA/B=8192), so "caps value rejected / MaxNumMonitors must
  be > 1" is disproven. Section 4.2.
* The client sends DISP layout from its window-resize path only when a set of client-side flags all pass;
  if any flag is false the resize handler is a **silent no-op** (no log at the wire level, no PDU). The
  most probable failing flag is `dynamicResolutionSupported` (set by a caps callback) or
  `dynamicResolutionEnabled` (bookmark setting) at resize time. Section 4.3/4.4.
* "Smart sizing takes precedence over dynamic resolution" is **not** supported by the binary: smart
  sizing (`scalingEnabled`) is a *required positive gate* for the dynamic-resolution branch, not a
  blocker. Section 4.5.
* Recommended product behaviour: keep reconnect-adaptation as the guaranteed path, do not change the
  server DISP caps, document the Windows App settings/user steps, and use the isolated diagnostic script
  to pin the failing client flag. Section 5/6.

## 2. Live evidence (read-only, worker on the private LAN)

The live worker/agent were **not** restarted or reconfigured for this diagnosis; only the existing log
was read (`.runtime/worker-live.log`, no debug level was enabled, no transport dump against 3389). The
deployed live worker binary predates the new DISP audit fields of section 7, so the counts below
use the pre-existing `event=disp_*` lines only; the new fields are available on the
`/tmp/rdp-worker-disp` test build (and on any future controlled deploy).

```
$ grep -c "event=disp_channel_opened" .runtime/worker-live.log   # 7
$ grep -c "event=disp_caps_sent"     .runtime/worker-live.log   # 7
$ grep -c "event=disp_monitor_layout" .runtime/worker-live.log  # 0
$ grep -c "event=peer_reactivate"    .runtime/worker-live.log   # 0
```

Latest session in that log (2026-11-08 01:22, the session the user was using while this diagnosis was
written):

```
01:22:39 event=authorized backend=authorized-session
         event=peer_size_negotiated requested=2508x1220 desktop=2508x1220 policy=client
         event=agent_capture_size_requested width=2508 height=1220
         event=peer_activate_complete width=2508 height=1220
         event=disp_channel_opened result=0
         event=disp_caps_sent result=0
         ... (frames continue; no disp_monitor_layout / peer_reactivate for the rest of the session)
```

Consequences that are already proven:

1. The client requests/opens the DISP DVC (`disp_channel_opened result=0` — the server-side
   `WTSVirtualChannelOpenEx` for `Microsoft::Windows::RDS::DisplayControl` succeeded), so the client DISP
   plugin is active and dynamic resolution is at least partially enabled for the bookmark.
2. The server wrote `DisplayControlCaps` successfully in all 7 sessions (`disp_caps_sent result=0`).
   This is a server write success; whether the client's caps handler actually ran is the unproven hop
   (section 6). The client binary does have the corresponding parser and log line (section 4.2).
3. The client never sends `DISPLAY_CONTROL_PDU_TYPE_MONITOR_LAYOUT` for window resizes, so the server
   never reactivates. This is the user-visible issue and it is **not** a server reactivation bug: the
   server code path is never entered.

Note on session ordering: the DISP channel opens shortly after `peer_activate_complete`, i.e. early in
the session, before the user resizes the window. A "caps arrive too late / after the resize" race is
therefore unlikely, but the client-side log timestamps from the test in section 6 are the proof.

## 3. Loopback evidence that the server DISP path is correct

Reproduced with the patched test worker (never production 3389) on an isolated port:

```
# test worker: /tmp/rdp-worker-disp, temp config/SAM/cert in /tmp, test_pattern backend, 127.0.0.1
RDP_DISP_DEBUG=1 WLOG_LEVEL=ERROR /tmp/rdp-worker-disp -config <tmp>/config.json -agent-socket <tmp>/s

# client without DISP support (negative control), mode 5 does not enable FreeRDP_SupportDisplayControl
printf '<pw>\n' | bin/rdp-probe -port <p> -mode 5 -width 800 -height 600
# worker DISP lines:
event=disp_debug_state joined=0 dvc_ready=0 connected=1 ts_ms=45802880   # RDP_DISP_DEBUG=1 only
event=disp_channel_closed opened=0 ts_ms=45802885
# -> no disp_channel_opened / disp_caps_sent / disp_monitor_layout: a client that does not open the
#    DisplayControl DVC is unaffected (this is the contract for the new negative regression test).

# conformant DISP client (mode 10) drives one resize 800x600 -> 1024x768
RDP_PROBE_RESIZE_AT_MS=700 RDP_PROBE_RESIZE_WIDTH=1024 RDP_PROBE_RESIZE_HEIGHT=768 \
  bin/rdp-probe -port <p> -mode 10 -width 800 -height 600
# worker DISP lines:
event=disp_channel_id_assigned id=1 ts_ms=45804501
event=disp_channel_opened result=0 ts_ms=45804501
event=disp_caps_sent result=0 max_monitors=1 area_a=8192 area_b=8192 ts_ms=45804501
event=disp_monitor_layout requested=1024x768 monitors=1 ts_ms=45805230 \
      left=0 top=0 width=1024 height=768 flags=0x00000001 dscale=100 devscale=100
event=peer_reactivate requested=1024x768 desktop=1024x768 policy=client
event=disp_channel_closed opened=1 ts_ms=45805249
# probe rc=0; full frame at the new size was delivered (test_19/test_20 already cover two sequential resizes)
```

Artifacts kept for review: `/tmp/disp-diag-evidence/worker-mode5-no-disp.log`,
`/tmp/disp-diag-evidence/worker-mode10-disp-resize.log`, `probe-mode5.out`, `probe-mode10.out`.
Conclusion: with a client that actually sends the PDU, the server does everything MS-RDPEDISP requires
(Deactivation-Reactivation, new desktop size, repaint). The missing piece is entirely on the client side.

## 4. Windows App 11.4.4 static analysis (main binary, arm64 slice)

Environment: macOS, `/Applications/Windows App.app/Contents/MacOS/Windows App` (universal x86_64+arm64,
129 MB). `otool`/`objdump --start-address` ignore address ranges on Mach-O, so the arm64 slice was
extracted with `lipo -thin arm64 /tmp/wa-arm64` and disassembled with LLDB
(`lldb --batch -o "target create --arch arm64 /tmp/wa-arm64" -o "disassemble --start-address A --end-address B"`)
and a one-time full `objdump -d /tmp/wa-arm64 > /tmp/wa-arm64-full.disasm` for cross-reference searches.

### 4.1 The relevant client code paths

* `RdpDisplayControlPlugin` / `RdpDisplayControlChannel` (C++ classes in the binary, symbols
  `__ZN23RdpDisplayControlPlugin*`, `__ZN24RdpDisplayControlChannel*`) implement MS-RDPEDISP client:
  `OnDataReceived` (0x10135ac00), `SendMonitorLayoutPdu` (0x10135c53c), `WriteMonitorLayoutPdu`,
  `ValidateDisplayControlMonitorLayout`.
* Window resize: `-[SessionWindowController windowDidEndLiveResize:]` (0x1003b6220) and
  `windowWillResize:toSize:` / `windowDidResize:` (0x1003c09bc / 0x1003c0d50).
  `windowDidEndLiveResize:` always tail-calls `updateScreenThrottled()` (0x1003c001c), which debounces
  via `DispatchQueue.asyncAfter` (~0.5 s) and then runs `updateScreen` (inlined into
  `updateScreenThrottled`'s closure body at 0x1003c5af8).
* `updateScreen` builds `RDCScreen` objects and calls the session delegate:
  `RDCSessionConnection.setScreenLayout(_:)` (0x10021f66c) bridges `[RDCScreen]` to `NSArray` and calls
  `[RDCConnection setScreenLayout:]`; the C++ side then runs
  `RDC::ConnectionDelegate::SetMonitorLayout` -> `RdCore::Graphics::A3::RdpGraphicsAdaptor::SetMonitorList`
  (0x1010b5388) -> interface vtable call to `RdpDisplayControlChannel::SendMonitorLayoutPdu`
  (indirect call at `SetMonitorList+0x5284`, logs `"SendMonitorLayoutPdu returned: {}"`).
* `RdpGraphicsAdaptor::SetDisplayControlChannel` (0x1010bd3f0) also fires the connection diagnostics
  checkpoint `OnServerSupportsDynamicResolution` when the DISP channel is attached.

### 4.2 The client accepts our caps (ruled out as root cause)

`RdpDisplayControlChannel::OnDataReceived` caps branch (arm64, addresses from the binary):

```
1003b3e8: cmp   w8, #0x13          ; caps PDU length field must be > 19 -> ours is 20 (8 header + 12 caps)
1003b3f0: ldr   w8, [x22, #0x8]    ; MaxNumMonitors
1003b3f4: cbz   w8, <error path>   ; must be != 0                 -> ours is 1
1003b3f8: ldr   w8, [x22, #0xc]    ; MaxMonitorAreaFactorA
1003b3fc: cmp   w8, #0xc7          ; must be > 199 (0xc7)
1003b410: cmp   w8, #0x2000        ; must be <= 8192 (0x2000)      -> ours is 8192 (boundary accepted)
1003b41c: cmp   w9, #0x2000        ; same for MaxMonitorAreaFactorB -> ours is 8192 (boundary accepted)
...
           str   d0, [x23, #0x5c]  ; store caps into the channel object
           str   w8, [x22, #0x64]
           stur  w8, [x22, #-0xc]  ; mark "server supports dynamic resolution"
           <callback / trace event>
```

The corresponding log string is
`"Received Display Control Caps with number of monitors: {}, max monitor width {}, max monitor height {}"`
(found at 0x101cb11e1 / referenced at 0x10135b52c). Rejections would log
`"Unexpected Caps PDU length {}"` / `"0 max number of monitors in caps {}"` instead.

=> A client requiring `MaxNumMonitors > 1`, or a specific value other than what we send, is **disproven**
for this version. Our 1 / 8192 / 8192 caps pass every client-side validation check. The client then marks
DISP caps as supported; `SendMonitorLayoutPdu` refuses to run if that flag is not set
(`ldr w8,[x0,#0x58]; cbz -> error`).

### 4.3 The client-side gates before it sends a monitor layout

`updateScreen` selects the dynamic-resolution branch only when **all** of the following hold (else it is a
silent no-op — it returns without calling `setScreenLayout`, which exactly matches the production logs):

```
1003c5bdc: (SessionViewController.scalingEnabled captured on the main thread by closure #1 at
          0x1003c6158) == 1                         ; smart sizing setting must be ON
1003c5be8: layouts.count == 1                        ; single screen layout for the session window
                                                       (vector at field offset 0xcf8)
1003c5c10: dynamicResolutionEnabled == 1             ; SessionWindowController field offset 0xd00
1003c5c20: dynamicResolutionSupported == 1           ; SessionWindowController field offset 0xd08
1003c5c2c: isMultipleMonitors == 0                   ; field offset 0xd90 must be false
1003c5c3c: railMode == 0                             ; field offset 0x1021a2750 must be false
```

When the gates pass it builds `RDCScreen`(s) from the window content size, applies the retina scale flag
and calls the session delegate; the log strings `"Received monitor layout change with {} monitors: {}"`
(in `SetMonitorList`) and `"SendMonitorLayoutPdu returned: {}"` (in the DISP channel) then appear in the
client's unified log — those two lines are the fastest discriminator for the user test.

### 4.4 Where `dynamicResolutionSupported` comes from

`SessionWindowManager.onDynamicResolutionSupported()` (0x1001cfb3c) sets its own flag and writes
`dynamicResolutionSupported = true` into every registered `SessionWindowController` (field offset 0xd08).
It is reached through `RDCSessionConnection.onDynamicResolutionSupported()` (0x100221534), which forwards
via a weak delegate, i.e. from the RDP core callback that the DISP caps handler fires. If that callback is
lost/not applied at resize time, the gate in 4.3 rejects and the client silently does nothing — no error,
no log, no PDU. `dynamicResolutionEnabled` is a per-window copy of the bookmark/session setting, updated
through `SessionWindowManager.dynamicResolutionEnabled` setter (0x1001cfaf4).

### 4.5 Smart sizing does not "take precedence"

Two independent observations:

1. The static gate list in 4.3 requires `scalingEnabled == 1`; it does not reject when smart sizing is on.
   So "smart sizing blocks dynamic resolution" is not supported by the client binary.
2. The Windows App scripting CLI normalises the bookmark fields: with `--dynamicdisplay true` the stored
   RDP properties always become `dynamic resolution:i:1` **and** `smart sizing:i:1`, even with
   `--scaling false`; with `--dynamicdisplay false` the two fields are independent
   (`--scaling false` -> `smart sizing:i:0`, fixed `desktopwidth/desktopheight` from `--resolution`).
   The user's production bookmarks already have both `=1`, which is the same normalised state.

## 5. Root cause conclusion and recommended product behaviour

### 5.1 What is proven

1. The server DISP implementation works with a conformant client (loopback mode 10; test_19/test_20 and
   the new negative case).
2. Our caps are valid for Windows App 11.4.4 and are accepted by the client's caps parser.
3. The real Windows App never sends a monitor layout for window resizes against our worker (7/7 sessions
   today); the server therefore cannot react. No server-side reactivation bug is involved.
4. The client only sends a layout when its own gates pass; a failing gate is silent. There is no server
   PDU that can force a layout request.

### 5.2 Leading hypothesis (not yet proven)

At resize time the Windows App evaluates `dynamicResolutionSupported` (most likely) or
`dynamicResolutionEnabled` as false, so `updateScreen` returns without asking the server to resize. The
caps are delivered (worker writes succeed and the client parser accepts them), so the weak link is the
client-side callback/state propagation `OnServerSupportsDynamicResolution` -> `dynamicResolutionSupported`,
or the bookmark/session setting not being reflected in `dynamicResolutionEnabled`.
`scalingEnabled`, `isMultipleMonitors` and `railMode` are the other gates; the user session is single
window/non-rail so they are unlikely to be the blocker.

### 5.3 Decision tree (per earlier investigation)

* **If the user test shows caps received but no `Received monitor layout change` after resize** -> the
  client-side gate is closed before the RDP layer. This is a client setting/limitation. Product action:
  keep reconnect-adaptation (works today), document the client-side requirement and workaround; do not
  change the server caps (the client accepts them).
* **If the user test shows `Received monitor layout change` but no `SendMonitorLayoutPdu returned`** ->
  the DISP channel was not attached/valid at that moment (caps state lost) -> still client-side; collect
  the two adjacent log timestamps and document.
* **If the user test shows `SendMonitorLayoutPdu returned: 0` but the worker logs no
  `disp_monitor_layout`** -> channel/transport issue (server-side investigation warranted; we already log
  channel closed/opened with timestamps for this).
* **Server-side fixes to consider only if evidence points there:** check `WTSVirtualChannelReady` before
  sending caps / re-send caps once after the first layout attempt; do not change caps values.
* Do not adopt "force a reconnect after resize": the worker cannot see a local window resize without a
  client signal; reconnect-adaptation stays the fallback the user already uses.

### 5.4 Recommended product behaviour now

1. Keep the current resolution-adaptation contract: reconnect with a new window size adapts automatically;
   mid-session adaptation works for conformant clients (FreeRDP, and Windows clients that send DISP).
2. Do not change the DISP caps (MaxNumMonitors=1, AreaFactorA/B=8192); the client accepts them.
3. Document Windows App requirements/steps (section 6.2) and state that if the client still does not send
   layout, reconnecting to the desired resolution is the supported workaround.
4. Keep the DISP audit lines (section 7) in the worker: they are the fastest way to classify future
   client-update regressions (opened/caps/id assigned/monitor layout/closed with millisecond timestamps).

## 6. What was tested and what remains unproven

### 6.1 Tested (reproducible)

| Item | Result |
| --- | --- |
| Worker DISP diagnostics: `go build -o /tmp/rdp-worker-disp ./cmd/rdp-worker` | build OK; binary 构建成功（校验和略） |
| Loopback, client without DISP (`bin/rdp-probe -mode 5`) | rc=0, full frame, no `disp_channel_opened`/`caps_sent`/`monitor_layout`; one `disp_channel_closed opened=0` (diagnostic line only) |
| Loopback, DISP client (`bin/rdp-probe -mode 10`, 800x600 -> 1024x768) | rc=0; `disp_channel_id_assigned` -> `disp_channel_opened result=0` -> `disp_caps_sent ...` -> `disp_monitor_layout requested=1024x768` -> `peer_reactivate requested=1024x768` -> `disp_channel_closed opened=1` |
| `scripts/disp-diagnose.py --self-test` (isolated LAN worker + live `log stream` + bookmark lifecycle) | PASS, bookmark created/export-verified/deleted, temp credentials removed |
| Windows App CLI bookmark matrix (`--dynamicdisplay`, `--scaling`, `--fullscreen`, `--resolution`) | dynamic display forces `dynamic resolution:i:1` + `smart sizing:i:1`; with dynamic off the two fields are independent; resolution only materialises when dynamic resolution is off |
| Windows App binary static analysis (caps handler, resize gate list, callback chain, SendMonitorLayoutPdu call site) | see section 4 |
| Production live log (read-only) | 7 DISP channel opens + caps, 0 monitor layouts, 0 reactivations |

### 6.2 User test: exact steps to enable/verify auto-resolution

For the product bookmark (Windows App 11.4.4 on macOS), the settings that matter are the RDP properties
`dynamic resolution:i:1` and `smart sizing:i:1` plus windowed single monitor. Verify with the app's own CLI:

```sh
APP="/Applications/Windows App.app/Contents/MacOS/Windows App"
"$APP" --script bookmark list
"$APP" --script bookmark export <bookmark-id> | grep -E \
  "dynamic resolution|smart sizing|full address|screen mode id|use multimon|username"
# expected for auto-resolution: dynamic resolution:i:1 and smart sizing:i:1, screen mode id:i:1
```

To create/repair a bookmark with the correct properties:

```sh
"$APP" --script bookmark write <new-or-existing-id> \
  --hostname 192.0.2.10:3389 --friendlyname "rdp-live-diagnostic" \
  --username 'MACRDP\<account>' --password '<your test password>' \
  --dynamicdisplay true --scaling false --fullscreen false --resolution "1280 720"
# export then shows dynamic resolution:i:1 + smart sizing:i:1 (CLI normalisation), windowed mode
```

Steps to verify on a test deployment:

1. Open Windows App -> right-click the bookmark -> Edit -> Display: enable **Dynamic resolution**
   (the client stores `dynamic resolution:i:1`); leave **Scaling/smart sizing** enabled
   (`smart sizing:i:1` requires `scalingEnabled == 1`, see 4.3); keep the session **windowed**
   (not full screen) and **single monitor**.
2. Connect, wait for the desktop, then drag the window corner/edge to a clearly different size, release,
   wait 1-2 s.
3. Expected when working: the remote image re-renders sharply at the new size (no scaling blur), and the
   worker log shows `disp_monitor_layout` -> `peer_reactivate` -> `peer_size_negotiated` ->
   `agent_capture_size_requested` -> full repaint.
4. If it does not change: the documented workaround is to disconnect and reconnect (the worker adapts on
   reconnect), or collect evidence with the isolated diagnostic below.

### 6.3 Isolated diagnostic for the client-side log hop (needs one user GUI session)

`scripts/disp-diagnose.py` does this without touching the production worker:

```sh
cd <repo> && python3 scripts/disp-diagnose.py --duration 180
# optional: --transport-dump (isolated worker only), --worker-binary /tmp/rdp-worker-disp
```

It starts a throw-away test-pattern worker on a private-LAN address (e.g. 192.0.2.10):<random port> with temp config/SAM/self-signed
cert in /tmp, captures `log stream --info --predicate 'process == "Windows App"'`, creates a temporary
bookmark "rdp-disp-test" (deleted at the end), prints the one-time temporary password and the exact user
steps (click bookmark, accept the self-signed certificate warning, resize 2-3 times, disconnect), then
prints the worker DISP sequence, the DISP-relevant client log lines and a verdict.

The lines that decide the open question (client unified log, info level):

* `Received Display Control Caps with number of monitors: 1, max monitor width: 8192, max monitor height: 8192`
  -> caps reached the client parser (expected; already strongly implied by 4.2).
* `Received monitor layout change with 1 monitors: ...` (after the resize) -> the app passed its gates and
  asked the RDP layer for a new layout; if missing, the failing gate is above the RDP layer.
* `SendMonitorLayoutPdu returned: 0` -> the channel actually wrote the PDU; if the worker then logs no
  `disp_monitor_layout`, the remaining suspects are transport/channel state (server-side investigation).

### 6.4 Remains unproven

* Whether a real Windows App window resize produces the caps log and/or the layout-change log against our
  worker (no client unified log captured yet; `log show` only keeps recent info entries, so it must be
  streamed live during the test - the script does that).
* Which exact client gate is false (supported / enabled / scaling / multi-monitor / rail), and whether a
  UI setting toggle can make the client send the layout.
* Whether a product-side server change can improve the situation (only the evidence above can decide).

## 7. Diagnostics added to the worker (this work item)

`internal/worker/native.c`, DISP regions only (no behaviour change, no new allocations, no blocking calls;
existing event name and first fields are preserved so existing log parsers keep working):

* `ConfigurePeer` now installs `DispServerContext.ChannelIdAssigned = peer_disp_channel_id_assigned`.
* New/changed audit lines (all DISP lines now carry monotonic `ts_ms` from `GetTickCount64()`):

```
event=disp_channel_id_assigned id=%u ts_ms=%llu
event=disp_channel_opened result=0|1 ts_ms=%llu
event=disp_caps_sent result=%u max_monitors=%u area_a=%u area_b=%u ts_ms=%llu
event=disp_monitor_layout requested=%ux%u monitors=%u ts_ms=%llu left=%d top=%d width=%u height=%u flags=0x%08x dscale=%u devscale=%u
event=disp_channel_closed opened=0|1 ts_ms=%llu          # in peer_context_cleanup, i.e. peer ended
# RDP_DISP_DEBUG=1 only (off by default):
event=disp_debug_state joined=%u dvc_ready=%u connected=%u ts_ms=%llu   # once per state change
event=disp_debug_monitor index=%u left=%d top=%d width=%u height=%u flags=0x%08x dscale=%u devscale=%u
```

`peer_disp_monitor_layout()` also logs the first monitor's full fields (the values the client sent) before
recording the resize request. For test runs use `WLOG_FILTER=<logger>:LEVEL` (a bare logger tag makes
WinPR abort); e.g. `WLOG_FILTER=com.freerdp.channels.rdpedisp.server:DEBUG`.

## 8. Reproduction commands (summary)

```sh
# build the diagnostics worker (never `make build` for experiments)
go build -o /tmp/rdp-worker-disp ./cmd/rdp-worker

# loopback negative case (client without DISP) and positive case (FreeRDP DISP client)
#   see section 3; artifacts in /tmp/disp-diag-evidence/
# interactive Windows App client-log test (isolated worker, one user GUI session)
python3 scripts/disp-diagnose.py --self-test   # harness check, no GUI
python3 scripts/disp-diagnose.py --duration 180

# client static-analysis helpers used above
lipo -thin arm64 "/Applications/Windows App.app/Contents/MacOS/Windows App" -output /tmp/wa-arm64
lldb --batch -o "target create --arch arm64 /tmp/wa-arm64" \
  -o "disassemble --start-address 0x10135ac00 --end-address 0x10135c094"
objdump -d /tmp/wa-arm64 > /tmp/wa-arm64-full.disasm   # once, for xref searches
```

## 9. Acceptance status for Issue 1

* Worker-side diagnostics: done (section 7).
* Server DISP correctness under a conformant client: proven (section 3; test_19/test_20 remain green).
* Negative regression "client that does not send DISP is unaffected": implemented by `protocol-tests`
  (test_22) against the same binary; contract documented in section 7 / sent to that owner.
* Real-Windows-App end-to-end: **blocked on one user GUI session** (section 6.3); the report will be
  updated with the client-log evidence and a final server/client verdict once that evidence exists.
  Until then the evidence in sections 2-4 supports "client-side state/setting", not a server bug.

# Design — client-driven resolution adaptation (2026-11-07, Work item A)

Status: implementation contract. Every implementer (worker C, agent Swift, protocol
tests) must follow the exact integer formulas here so the three sides agree
bit-for-bit. Work item A baseline is this document.

Branch: feature/dynamic-resolution-and-connection-stability. Do not switch branches,
do not restart the live service (it carries the user's Windows session), and never
read .runtime/sam, credentials or .runtime/config.json.

## 1. Requirement

A client may select any resolution. The server must adapt correctly:

* no rejection for any sane requested size (including > display native and > 64 MiB BGRA),
* no distortion: content keeps the capture aspect ratio (letterbox with black bars
  when the client desktop aspect differs from the display aspect),
* correct mouse mapping under that layout,
* stable frames, incremental delivery after the first full frame, no crashes.

Policy summary:

* Desktop size = what the client asked for, after clamping only when the request
  cannot be represented (see 2). The client is told the negotiated size in the
  initial Demand Active (or later Reactivate) so its window matches.
* Capture size is chosen by the Agent from (requested desktop box, native display
  size) — see 4. The Agent never upscales the capture. Client boxes smaller than
  the display capture smaller (bandwidth win); boxes larger than the display
  capture native and the Worker upscales.
* Worker composes the captured frame into the desktop with "fit" (letterbox,
  centred, black bars), never a non-uniform stretch.
* Mouse coordinates travel to the Agent as desktop coordinates; the Agent inverts
  the same layout, maps into the capture, then maps capture pixels onto the macOS
  display (existing DisplayCoordinateMapper linear mapping).

Scale quality note: Worker composition is nearest-neighbour (existing behaviour).
Upscaling from native for very large clients aliases slightly; that is accepted for
this item (documented, follow-up: vImage/bilinear). The common case (client box
smaller than display) is nearly 1:1 because the Agent downscales first.

## 2. Worker size negotiation (C, peer_negotiate_size)

Constants:
* MAX_DESKTOP_DIM = 16384 (per axis)
* DESKTOP_PIXEL_BUDGET = MAX_FRAME_BYTES / 4 = 64 MiB / 4 = 16777216 pixels

function peer_negotiate_size(reqW, reqH, *outW, *outH):
    if reqW == 0 or reqH == 0: -> invalid (connection cannot proceed; FreeRDP already
       rejects zero client core data, so no new rejection path for real clients)
    if reqW <= MAX_DESKTOP_DIM and reqH <= MAX_DESKTOP_DIM and reqW*reqH <= DESKTOP_PIXEL_BUDGET:
        out = req; policy = "client"
    else:
        scale by a single factor so the aspect ratio is preserved:
        factor = min( sqrt(DESKTOP_PIXEL_BUDGET / (reqW*reqH)),
                      16384.0/reqW, 16384.0/reqH )
        outW = max(2, floor(reqW*factor)); outH = max(2, floor(reqH*factor))
        clear the low bit (outW &= ~1u; outH &= ~1u) so both dimensions are even
        (Windows clients size their window from these values);
        if outW < 2: outW = 2; if outH < 2: outH = 2
        while (UINT64)outW*outH > DESKTOP_PIXEL_BUDGET: outW -= 2 (or outH if outW<=outH)
        policy = "clamp"
    return out

Implementation points (worker):

1. Add peer->Capabilities = peer_capabilities. FreeRDP calls it in
   rdp_peer_handle_state_demand_active BEFORE rdp_send_demand_active, on the initial
   connection and on every reactivation. At that point settings->DesktopWidth/Height
   already contain the client's request (client core data on first connect; the
   server-set size on reactivation). The callback negotiates, writes the negotiated
   values back into the settings (FreeRDP_DesktopWidth/Height), sets ctx->width/height
   to the negotiated size, and logs:
     event=peer_size_negotiated requested=WxH desktop=WxH policy=client|clamp
   It never fails for non-zero requests. This makes the *initial* Demand Active carry
   the negotiated size: the size reaches the client in the Demand Active BITMAP
   capability set (desktopWidth/desktopHeight/desktopResizeFlag), and FreeRDP clients
   apply it to their settings when DesktopResize is enabled (verified in
   libfreerdp/core/capabilities.c rdp_apply_bitmap_capability_set). Keep
   settings->DesktopResize TRUE so clients accept server-chosen sizes. The client is
   NOT guaranteed to fire its DesktopResize callback for the initial connection
   (that callback is mainly the deactivate/reactivate path), so the probe must take
   its reported desktop size from the gdi/settings state in PostConnect.
2. peer_activate() keeps its validation (it now sees negotiated values); remove the
   old rejection for oversized requests — only width/height == 0 remains impossible
   in practice. Keep the "not_leased"/"no_frame" rejections.
3. peer_activate() must set ctx->force_full_frame = TRUE and ctx->drawn = FALSE on
   every activation (including reactivation) so the client is repainted after a size
   change even when the source screen is static, and must send IPC type 9 with the
   negotiated desktop size (existing code, unchanged wire format).
4. Add an audit event when the frame layout (capture dims vs desktop) changes for a
   peer: event=peer_frame_layout source=WxH desktop=WxH content=WxH offset=X,Y scaled=0|1
   Log it once per distinct tuple (store last logged tuple in peer_context).
5. Mid-session resize (DISP, section 6) reuses the same negotiation function.
6. **Compose condition (important):** the source buffer may be passed through
   zero-copy ONLY when source_width==desktop_width, source_height==desktop_height
   and both offsets are zero. Uniform scaling keeps content==desktop with zero
   offsets, so a condition based on content-vs-desktop is NOT sufficient - it
   silently treats a smaller source buffer as a larger desktop (heap over-read).
   Compose whenever source dims != desktop dims OR any offset is non-zero.
7. **Event wakeups on Unix:** WinPR does not implement auto-reset events
   (CreateEvent(bManualReset=FALSE) logs "auto-reset events not yet implemented"
   and WaitForMultipleObjects never drains the eventfd). Create the per-peer
   frame/resize events as MANUAL reset and ResetEvent() the signaled one in
   run_peer immediately after WaitForMultipleObjects, before processing. Without
   the drain, the first frame signal stays readable forever and starves any
   later signal (this made a second client-driven resize invisible, and also
   caused a busy-spin after the first frame).

## 3. Fit-with-bars layout (C and Swift and tests — identical integer math)

Given capture cw x ch (source pixel size from the Agent) and negotiated desktop W x H:

    // use UINT64 for products
    if (UINT64)cw*H <= (UINT64)W*ch:          // capture relatively wider or equal: fit height
        contentH = H
        contentW = max(1, (cw*H + ch/2) / ch)  // round to nearest
    else:                                      // fit width
        contentW = W
        contentH = max(1, (ch*W + cw/2) / cw)
    offX = (W - contentW) / 2                  // integer division (floor)
    offY = (H - contentH) / 2
    scaled = (cw != contentW || ch != contentH)

Invariants: contentW <= W, contentH <= H (aspect preserved, no distortion).
Desktop pixel (dx,dy) shows:
    if dx outside [offX, offX+contentW) or dy outside [offY, offY+contentH): black
    else sx = (UINT32)((UINT64)(dx-offX) * cw / contentW)   // floor
         sy = (UINT32)((UINT64)(dy-offY) * ch / contentH)   // floor
         pixel = capture[sy][sx]

C implementation in draw_pattern(): when source dims differ from the desktop (or the
layout is not exactly 1:1 at zero offset), allocate the composed desktop buffer, memset
it to 0 (black), then for each content row copy the mapped source row:
  * if contentW == cw (horizontal 1:1) use one memcpy per row into the row at offX;
  * otherwise use the cached scale_x table (peer_ensure_scale_x keyed by content width
    and source width) and copy 4-byte pixels.
Vertical mapping sy per row is computed directly with the formula above. A 1:1 case
(cw==contentW && ch==contentH) still needs the offset copy (bars on the other axis).
When the capture is already exactly the desktop (cw==W && ch==H && offX==offY==0) keep
the existing zero-copy path. The composed desktop buffer is what gets diffed against
ctx->last_desktop and planar/raw encoded, so incremental delivery keeps working.
Test-pattern frames (no Agent source) stay full-desktop pattern, unchanged.

Worker mouse(): keeps sending raw desktop coordinates (no change to the wire format).

## 4. Agent capture policy (Swift)

Inputs: requested desktop box W x H (IPC type 9 = capture-size message; the payload
still carries the negotiated desktop size), native display pixel size nw x nh
(display mode pixel width/height). All values are Int, products UInt64.

    match = |W*nh - H*nw| * 200 <= H*nw        // <= 0.5% relative aspect difference
    if match && W <= nw && H <= nh:
        cw = W; ch = H; policy = "exact"        // 1:1 in the Worker, no bars
    else if W >= nw && H >= nh:
        cw = nw; ch = nh; policy = "native"     // never upscale the capture
    else if (UInt64)W*nh <= (UInt64)H*nw:       // width is the limiting axis
        cw = W; ch = max(1, (nh*W + nw/2) / nw); policy = "fit"
    else:                                       // height is the limiting axis
        ch = H; cw = max(1, (nw*H + nh/2) / nh); policy = "fit"
    if cw > nw: cw = nw
    if ch > nh: ch = nh
    // final safety: CaptureSizeRequest limits (1..16384 per axis, area*4 <= 64 MiB)

Rounding/edge rules: the box is the negotiated desktop, so it already satisfies the
64 MiB budget; capture is <= native. Never emit a capture larger than the native
display or zero.

Rationale examples (display 2940x1912, production):
  2560x1440 box -> "fit", capture 2214x1440 (Worker 1:1 content, bars 173 px left/right)
  2560x1664 box -> "exact" (aspect within 0.5%), capture 2560x1664
  800x600 box   -> "fit", capture 800x520 (bars 40 px top/bottom)
  4096x2304 box -> "native", capture 2940x1912 (Worker upscales ~1.2x, bars)
  3940x1888 box -> "fit", capture 2903x1888

State: replace/next to CaptureSizeState with a thread-safe geometry state holding
requested desktop, native display size and the computed capture. updateRequested()
and updateNative() recompute; callers log:
  event=capture_size_updated desktop=WxH native=NxH capture=WxH policy=exact|fit|native
  event=display_size_changed native=NxH desktop=WxH capture=WxH policy=...
The capture configuration (snapshot SCStreamConfiguration / SCScreenshotManager
request and StreamFramePump.updateConfiguration) uses the computed capture size.

Native display size detection: poll CGDisplayMode/CGDisplayBounds for the captured
display at least every 500 ms from the capture loops (and once before configuring).
On change, recompute the capture size; the snapshot loop picks it up per iteration,
the stream pump reconfigure path already exists (requestReconfigure). 0x0/absent mode
falls back to the last known native size.

## 5. Mouse mapping (Agent, Swift)

Input: desktop coordinates (dx,dy) from the Worker; state: requested desktop W x H,
capture cw x ch, display bounds (CGDisplayBounds = points).
1. Compute contentW/H, offX/offY with the section 3 formula.
2. Desktop -> capture pixel, with clamping into the content area (a click in a bar
   maps to the nearest content edge; never outside the capture):
     if dx < offX:            sx = 0
     else if dx >= offX+contentW: sx = cw-1
     else:                    sx = (dx-offX)*cw / contentW
     same for dy -> sy
3. Existing DisplayCoordinateMapper.point(x: sx, y: sy, captureWidth: cw,
   captureHeight: ch, display: bounds) -> macOS point.

Add pure helpers in MacAgentCore so tests can cover them:
  DisplayLayout.fit(captureWidth:captureHeight:desktopWidth:desktopHeight)
  DisplayCoordinateMapper.desktopPoint(x:y:desktop:cature:display:)  (exact names up to
  the implementer, keep them pure and documented)
Keep the old capture->display mapping for compatibility.

## 6. Mid-session resize (client window resize, DISP channel)

Mechanism: the Windows client reports a live window resize as an MS-RDPEDISP
DISPLAY_CONTROL_PDU_TYPE_MONITOR_LAYOUT PDU on the dynamic channel
"Microsoft::Windows::RDS::DisplayControl". The server replies with the standard
Deactivation-Reactivation sequence carrying a new Demand Active desktop size.

Worker implementation:
1. configure_peer(): create ctx->disp = disp_server_context_new(ctx->vcm) (include
   <freerdp/server/disp.h>; symbols are in libfreerdp-server3). Set
   disp->custom = ctx, disp->DispMonitorLayout = peer_disp_monitor_layout,
   disp->MaxNumMonitors = 1, MaxMonitorAreaFactorA/B = 8192. Create a per-peer
   auto-reset resize_event for the peer thread.
2. Start/open the channel only after PostConnect and when drdynvc is READY, exactly
   like the existing rdpgfx open branch in run_peer(): disp->Open(disp), then if that
   succeeded disp->DisplayControlCaps(disp); log
     event=disp_channel_opened result=0|1
   Failures are logged and ignored (client without DISP support keeps working).
3. peer_disp_monitor_layout() runs on the DISP channel thread. It must NOT touch the
   transport: store the requested size under job->options->mutex and SetEvent the
   peer's resize_event. Requested size = bounding box of the received monitors
   (left/top/width/height union), ignoring empty layouts.
4. run_peer(): add ctx->resize_event to the wait set. When signalled and the peer is
   ready:
       - take the pending requested size,
       - if it equals the current negotiated desktop, log event=peer_resize_ignored
         reason=unchanged and do nothing,
       - negotiate with peer_negotiate_size (section 2),
       - set FreeRDP_DesktopWidth/Height to the negotiated size,
       - ctx->ready = FALSE (no bitmap updates during the handshake),
       - log event=peer_reactivate requested=WxH desktop=WxH
       - call peer->context->update->DesktopResize(peer->context); on failure end the
         peer loop as for other fatal errors.
   The reactivation path calls Capabilities (negotiation, already settled) -> Demand
   Active -> Confirm Active -> finalization -> peer_activate, which re-sends IPC type 9
   with the new desktop size and forces a full frame. Agent frames then carry the new
   capture size and the Worker letterboxes them per section 3.
5. No change is needed to the Agent IPC wire format. The existing Agent resync on
   reconnect keeps working.

Compatibility/fallbacks: if the client never opens DISP or never sends monitor layout,
nothing changes (a reconnect at a new size already works). GFX/AVC420 mid-session
resize is out of scope (GFX surface reset is a follow-up); the production path is
planar. Document that.

## 7. rdp-probe additions (C, same native.c; core for tests)

Probe is the deterministic client for loopback tests. Add:

1. PreConnect callback that installs update->DesktopResize = probe_desktop_resize
   BEFORE connect (the default client struct points at the server sender; a
   resolution change during the connection sequence must not send a Deactivate-All).
   probe_desktop_resize(width,height): update ctx->width/height from the new settings
   or gdi, call gdi_resize(gdi,...) when gdi exists; print
     "reactivated width=.. height=.." (stdout, one line per call)
   In probe_connect (PostConnect) initialize gdi from the *settings* size and keep the
   existing update hooks; probe_paint's dimension check must use the current ctx size.
2. mode 5 pixel sampling: env RDP_PROBE_SAMPLE_POINTS="x:y,x:y,..." (max 32 points).
   After the FULL first desktop frame is received (all tiles, not the first batched
   PDU), print one line per point:
     "sample x=<x> y=<y> bgra=<b>,<g>,<r>,<a>"
   The gdi buffer uses PIXEL_FORMAT_XRGB32 whose naming is byte-position based,
   so memory order is [X/alpha, R, G, B]: extract b=pixel[3], g=pixel[2],
   r=pixel[1], a=pixel[0]. Out-of-range points print bgra=0,0,0,0. Filenames
   are not a contract, but the greyscale assertions in the tests stay valid for
   either extraction order; still print the semantic b,g,r,a.
3. mode 10 "client-driven resize": connect at -width/-height, wait for the first
   bitmap frame, then emulate a window resize and verify the server adapts.
   Env: RDP_PROBE_RESIZE_AT_MS (delay after first frame, default 500),
        RDP_PROBE_RESIZE_WIDTH, RDP_PROBE_RESIZE_HEIGHT.
   Needs the DISP client channel: in PreConnect register the addin provider and set
   LoadChannels = freerdp_client_load_channels (like mode 8 does); subscribe to
   ChannelConnected on instance->context->pubSub in PostConnect and store the
   DispClientContext when the channel name is DISP_DVC_CHANNEL_NAME
   (include <freerdp/client/disp.h>, <freerdp/channels/disp.h>, <freerdp/client/channels.h>).
   When the disp context is available and the deadline passes, call
   disp->SendMonitorLayout(disp, 1, layout) with layout = { Flags = MONITOR_PRIMARY,
   Left=0, Top=0, Width, Height, PhysicalWidth=0, PhysicalHeight=0, Orientation=0,
   DesktopScaleFactor=100, DeviceScaleFactor=100 } and print
     "resize_requested width=.. height=..".
   Wait for probe_desktop_resize and then for the FULL desktop frame at the new
   size (rectangle count baseline is taken in the DesktopResize callback, so late
   pre-resize PDUs cannot fake it; the expected rectangle count is the tile count
   of the new desktop); print "resize_frame_received width=.. height=..".
   A second sequential resize in the same session is supported through
   RDP_PROBE_RESIZE2_AT_MS / RDP_PROBE_RESIZE2_WIDTH / RDP_PROBE_RESIZE2_HEIGHT and
   prints resize2_requested / resize2_frame_received (regression for the event
   drain in section 2 point 7). Deadline: 20 s (30 s with a second resize); print
   "resize_timeout ..." and exit non-zero otherwise.
4. Keep every existing mode's stdout byte-compatible (existing tests parse it).

## 8. Events / audit lines (grep-able, no secrets)

Worker: peer_size_negotiated, peer_frame_layout, peer_reactivate,
peer_resize_ignored, peer_activate_started/complete (existing), rdp_desktop_size
(existing), agent_capture_size_requested/resynced (existing), disp_channel_opened.
Agent: capture_size_updated (extended with desktop/native/capture/policy, keep the
existing key=value ordering prefix so any parsers still match: it currently prints
"event=capture_size_updated width=W height=H"; append desktop/native/policy fields
after the existing ones), display_size_changed.

## 9. Required test coverage (scripts/test-protocol.py unless noted)

All tests use the existing harness (fake Agent socket, random loopback port, isolated
temp SAM). Keep every existing test green (test_01..test_15). Add:

A. test_16_size_matrix_negotiated_desktop — test_pattern=True (no Agent needed).
   For each size in {800x600, 1024x768, 1468x923, 1920x1080, 2508x1220, 2560x1440,
   2940x1912, 3940x1888, 4096x2304, 5120x2880}: bin/rdp-probe -mode 5 connects,
   returncode 0, prints desktop_size and gdi_size equal to the requested size, a
   full frame was delivered, worker log has peer_activate_complete with that size and
   no peer_activate_rejected or peer_size_negotiated reason=clamp. Sizes above the
   display native are expected to work (Worker upscales the test pattern? NOTE: test
   pattern is generated at desktop size, so this covers negotiation/buffers/frames).
B. test_17_oversized_request_is_clamped_and_told — probe -mode 5 at 7680x4320
   (132 MB BGRA > 64 MiB). Expect returncode 0, "reactivated" line (the client-side
   resolution change from the initial Demand Active), desktop_size and gdi_size equal
   to the clamped size printed by the worker (parse it from
   "event=peer_size_negotiated requested=7680x4320 desktop=WxH policy=clamp"),
   WxH == 5460x3072 for this input, no peer_activate_rejected, and a bitmap frame at
   the clamped size. Also assert the aspect ratio stayed 16:9 (W*9 == H*16).
C. test_18_fit_with_bars_layout — fake Agent + planar worker (test_pattern=False).
   For two honest pairs, send a capture frame that is a solid colour with four
   distinctive 8x8 corner markers, then probe -mode 5 with RDP_PROBE_SAMPLE_POINTS:
     (i) capture 2214x1440 -> desktop 2560x1440 (1:1 content, bars 173 px left/right)
         samples: (0,720) black bar, (172,720) black or edge, (173,720) content,
         (1279,720) centre marker colour, (2559,720) black bar, (2560-173-1, 0)
         top-right marker.
     (ii) capture 800x520 -> desktop 800x600 (1:1 content, bars 40 top/bottom)
         samples: (400,39) black, (400,40) content top marker, (400,559) content
         bottom row, (400,560) black.
     (iii) capture 1470x956 -> desktop 1468x923 (scaled 0.966, bars 24/25 px):
         only assert bar colour at (0,461) and content colour at the centre; no exact
         marker byte comparison across the scale.
     (iv) capture 1280x720 -> desktop 2560x1440 (uniform 2x upscale, content fills
         the desktop, zero offsets): regression for the compose condition in
         section 2 point 6 (a content==desktop comparison alone would pass the
         smaller source buffer through as a larger desktop).
   Also assert the worker logged event=peer_frame_layout with matching
   source/desktop/content/offset.
D. test_19_mid_session_client_resize_disp — test_pattern=True. Probe -mode 10
   -width 2560 -height 1440, RDP_PROBE_RESIZE_WIDTH=1920 RDP_PROBE_RESIZE_HEIGHT=1080.
   Expect: resize_requested, reactivated (1920x1080), resize_frame_received; worker
   log has event=peer_reactivate requested=1920x1080 desktop=1920x1080,
   peer_size_negotiated ..., a second agent_capture_size_requested width=1920
   height=1080, rdp_desktop_size width=1920 height=1080, no peer_activate_rejected,
   and the first desktop_frame_sent after the reactivation is the FULL 510-tile
   repaint.
D2. test_20_two_client_resizes_in_one_session — a second sequential resize in the
   same connection (2560x1440 -> 1920x1080 -> 5120x2880 via RDP_PROBE_RESIZE2_*):
   both peer_reactivate lines, both type-9 capture-size requests, a full 3600-tile
   repaint after the second reactivation, no peer_activate_rejected. This is the
   regression test for the WinPR manual-reset event drain (design section 2 point 7)
   and would have failed before that fix.
E. Mouse mapping: include the new pure-layout assertions in the Swift preconditions
   test (make agent-check); a live corner/centre click is a manual acceptance step
   recorded in the docs (the user's Windows client). The Python side additionally
   asserts the Worker layout geometry that the mapping inverts.
F. Tests stay independent: each configures the worker it needs via the existing
   configure() helper; no test may depend on live .runtime state or port 3389.
G. Existing suites: python3 scripts/test-protocol.py (all green, 1 AVC420 skip),
   python3 scripts/test-benchmark-fps.py, go test ./..., make agent-check.
H. Optional manual/live matrix: scripts/benchmark-live-agent.py --width/--height for
   three sizes at RDP_AGENT_TARGET_FPS=60; record fps in the docs. Never run against
   the live service/port 3389.

## 10. Acceptance mapping (Work item A)

* Size matrix connects, gdi == negotiated size, first full, incremental later, CRC
  convergence holds, no peer_activate_rejected -> tests A + existing test_14.
* Oversized request gets documented fallback and the client is told the real size ->
  test B + docs.
* Mouse mapping at four corners + centre for every accepted size (unit tests + one
  live click) -> Swift preconditions (all sizes, corners/centre) + docs manual click.
* Fit-with-bars: no bleed, clicks map into content -> tests C + Swift mapping tests.
* Suites stay green; size-matrix test added; live matrix run recorded -> tests A-H.

Corrections agreed after implementation (2026-11-07):
* The "W*9 == H*16" wording in section 9 B is unsatisfiable once each dimension is
  rounded down to an even number: 5460*9 = 49140 vs 3072*16 = 49152. The accepted
  expectation is the literal clamped size from section 2 (5460x3072) plus aspect
  equality within one even-pixel step (|W*9 - H*16| <= max(W,H)).
* Section 7.2's "B,G,R,X memory order" was wrong; see the corrected semantic
  sampling text in 7.2 (XRGB32 is byte-position named: [X,R,G,B]).
* Initial oversized clamping is delivered through the Demand Active BITMAP
  capability set, not a Reactivate. The probe prints a synthetic
  "reactivated width=.. height=.." line from PostConnect when the gdi size differs
  from the requested size, so the test can assert the client was told.
* Mid-session resize while the opt-in GFX/AVC420 path is active is ignored on
  purpose (event=peer_resize_ignored reason=gfx_active): the GFX surface needs a
  ResetGraphics/recreate that is a documented follow-up; production is planar/raw.

## 11. Risks and follow-ups

* Windows client window-resize support is client-dependent; if it does not use DISP,
  the channel stays idle and behaviour is unchanged. Validate against the real client
  on the next real connection (log disp_channel_opened, then resize the window).
* GFX/AVC420 + mid-session resize needs GFX ResetGraphics handling: follow-up.
* Nearest-neighbour upscale quality for clients much larger than the display:
  follow-up (vImage / bilinear).
* 8192 cap in the FreeRDP client DISP sender: probe-driven resizes cannot test
  >8192 axes via DISP; the initial-connect clamp path covers 8K.

## 12. Addendum 2026-11-09: input display target (virtual display active)

The mouse mapping in section 5 assumed the `CGDisplayBounds` passed to `point(...)` describes the
same space as the capture frame. That holds when the captured display is the physical panel. With the
custom 1x virtual display active the capture frame is the virtual display's framebuffer, so the input
must be expressed in the virtual display's bounds:

1. If the virtual display is active, `CGDisplayIsActive` is true, its bounds are non-degenerate, and
   round(bounds.size) == capture size -> inject on the virtual display id with its bounds.
2. Otherwise (no virtual display, fit-with-bars capture, mirror transition while the geometry still
   matches the physical fit, stale/dead virtual id) -> keep the startup physical display bounds.

This is required because macOS 26.5.1 keeps the mirrored physical panel's native HiDPI point bounds
while the capture is the virtual framebuffer at the negotiated desktop pixel size (e.g. 3840x2160
capture with 2560x1440 physical points), so using the physical bounds scaled every injected point by
points/pixels (top-left aligned, error growing towards the bottom-right). macOS 27.2 forces the
mirrored panel to the virtual 1x mode, which is why the defect was latent there.

Implementation: `InputDisplayTargetResolver` in `MacAgentCore/DisplayCoordinateMapper.swift`, wired in
`rdp-agent/main.swift` via `VirtualDisplayController.activeDisplayID`; diagnostics
`event=input_target` / `event=input_target_fallback`; unit tests in `VirtualDisplayTests.swift`.
Root cause and verification: `docs/DIAGNOSIS-2026-11-09-mouse-offset-virtual-display-bounds.md`
(commit `e13c9d3`, verified on macOS 26.x).

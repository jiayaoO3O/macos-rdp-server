# P0 FreeRDP adapter

The cgo adapter lives in `internal/worker/native.c` so Go compiles it into the
isolated `rdp-worker` executable. It links the official, unmodified FreeRDP
3.32.2 / WinPR libraries built into `.deps/install`.

Ownership and execution:

- The main Go goroutine locks its OS thread for the listener lifetime.
- A maximum of four native peer pthreads each own their FreeRDP peer, context,
  settings, callback state and event loop. Native code never retains Go pointers.
- C strings passed to the listener remain allocated until it exits. The CLI
  terminates on a fatal listener error; the adapter is not a restartable in-process
  library. Detached peers terminate with that process.
- Each peer records the NTLM identity inside `SspiNtlmHashCallback`, asks WinPR's
  SAM API for the NT hash and WinPR's `NTOWFv2FromHashA` for the response hash.
  WinPR verifies the NTLM proof, MIC and CredSSP exchange. Only the subsequent
  authenticated Logon callback may acquire the Go authorization lease.
- Do not substitute delegated `TSCredentials` or the RDP client-info username for
  the authenticated principal. FreeRDP 3.32.2's NLA parser stores delegated
  fields in settings; the Logon identity observed here had empty user/domain.
- HYBRID NLA is required. RDP security, TLS-only, RDSTLS, AAD and HYBRID_EX are
  disabled. In local tests HYBRID_EX reached Logon with `automatic=FALSE`; it
  therefore failed closed. Revisit against upstream before enabling it.
- The peer owns its lease until cleanup. Native settings/context are freed before
  removing its socket from the watchdog, and the final peer close happens outside
  our mutex. No other connection can take over an active lease.
- Each accepted peer keeps a duplicated cancellation descriptor. A separate
  listener watchdog uses `shutdown()` on that duplicate to interrupt the
  FreeRDP-owned socket after a 15-second TLS/NLA handshake deadline or a 5-second
  frame send deadline. Both the event-loop send and `RefreshRect` callback use
  the same deadline wrapper. Peer-thread-only checks are insufficient because
  `CheckFileDescriptor()` can block inside TLS or a callback. These deadlines
  are resource bounds, not a complete account lockout/rate-limiting policy.
- The 800x600 test screen has two states: initial and keyboard-plus-mouse received.
  Input callbacks update state; the event loop sends only changed frames. Pixel
  buffers remain on the C stack and are consumed synchronously by FreeRDP.
- No input reaches macOS and no desktop is captured. This adapter does not yet
  implement a UID/GeneratedUID desktop authorization boundary or frame generation.

The development probe initializes FreeRDP GDI, records every received bitmap
update, and checks first/last pixels for the test-pattern states. Protocol tests
assert rejected credentials receive no bitmap updates. Modes 3 and 4 stop reading
after input / a refresh request to exercise both frame-send deadline paths; tests
require the client to observe server transport closure and a subsequent connection
to acquire the released lease. It ignores the certificate only for its hard-coded
loopback test destination. Do not use it as a general RDP client.

FreeRDP / WinPR are Apache-2.0. The official 3.32.2 archive ships a top-level
`LICENSE` (Apache License 2.0), but **no archive-level `NOTICE`**: the only
`NOTICE` in the archive is the AOSP-derived cpufeatures notice at
`winpr/libwinpr/sysinfo/cpufeatures/NOTICE` (that NOTICE carries Apache-2.0
text while the cpufeatures sources carry their own BSD-3-Clause AOSP headers;
the component is Android-only and is not compiled on macOS). Other component
attributions are inline in the source headers. Preserve the required notices if
redistributing the linked libraries. This project itself is Apache-2.0: see the
repository `LICENSE`, `NOTICE` and `THIRD-PARTY-NOTICES.md`.

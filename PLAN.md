# Project scope and roadmap notes

> **Historical planning document.** This is not an implementation specification or a
> current task list. Early P0/P1/P2/P3 proposals below were superseded as the prototype
> evolved; some proposed components and milestones were never implemented and are no
> longer planned. For supported behavior, limitations, and test evidence, use the
> [current status document](docs/STATUS-2026-11-08.md) and the code.

## Product boundary

The project's agreed initial boundary is intentionally narrow: a Mac user signs in
locally, then uses an RDP client to control that same user's desktop. Remote login,
lock-screen/FileVault unlock, cross-user access, concurrent sessions, public-internet
exposure, audio redirection, and drive redirection are outside this scope.

The implementation uses a Go/FreeRDP worker and a per-user Swift agent for macOS screen
capture, input, and clipboard integration. The menu bar app supervises those processes.
This summary is descriptive only; consult source and the current status document before
making implementation decisions.

## Historical proposals

The original staged plan explored system services, privileged helpers, login-window
bridging, FileVault recovery, multiple backend states, and a future signed/notarized
product. Those proposals were exploratory, not commitments or evidence of support.
Login-window bridging and privileged/system-level integration conflict with the current
scope and system-security boundaries. The release remains an ad-hoc-signed prototype;
see [known limitations](docs/STATUS-2026-11-08.md).

Older stage-by-stage acceptance records remain under [`docs/validation/`](docs/validation/)
for historical traceability. Read each record as evidence from its own date, not as the
current project state. See the [documentation index](docs/README.md) for authoritative
design and verification references.

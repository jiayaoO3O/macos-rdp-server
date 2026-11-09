# VERIFICATION — bidirectional file clipboard (Issue 3), 2026-11-08

> **历史记录（已被取代）** — 2026-11-08 文件剪贴板独立验证；最终真机验收见 VERIFICATION-2026-11-08-field-acceptance.md。
> 当前状态/可用范围/测试基线/部署运行态以 [docs/STATUS-2026-11-08.md](../STATUS-2026-11-08.md) 为准。


Independent adversarial verification by `verifier-clipboard`. Binding contract:
[DESIGN-2026-11-08-clipboard-files.md](../DESIGN-2026-11-08-clipboard-files.md) §1–§6 (Issue 3).

Branch: `feature/dynamic-resolution-and-connection-stability`.
Verified state: `7000d12` (feature) + `5552268` (fix for findings 1–2 below). During
verification the working tree also carried uncommitted test-script changes
(`scripts/test-protocol.py`, `scripts/test-clipboard-handshake.py`, regression cases for
both findings) and, at the very end, unrelated mouse-wheel changes by another contributor
(`AgentInputAudit.swift`, `rdp-agent/main.swift`); neither touches the clipboard paths
verified here.
All experiments used isolated `/tmp` workers, random loopback ports, temp dirs and a fake
Agent; the live worker (59846) / live agent (59961) were never touched and
`.runtime/sam`, `.runtime/config.json` and credentials were never read.

## Verdict

**PASS (as of `5552268`).** No security blocker, no remaining major finding.
Two findings were found by this verification — 1 major (functional) and 1 minor
(contract) — both were fixed by the owning contributor in `5552268` and independently re-verified
against a freshly built worker/probe from the current tree. Three non-blocking
observations remain (F3–F5, minor/nit; none is a deploy blocker). Independent
experiments, existing suites and mutation spot-checks all pass except where stated.

## Findings

### F1 — MAJOR (found, fixed in 5552268, re-verified): remote→local multi-file copy aborts when the first file(s) are 0 bytes

A Windows→macOS file copy whose first advertised file is 0 bytes aborted the whole
offer: worker logged
`event=clipboard_file_rejected direction=remote_to_local reason=bad_state`, sent
`IPC 15 direction=1 status=2`, the client never received a contents request for the
following file and the paste timed out. The RDP session stayed up (recoverable error,
no crash/leak), but the user gets nothing.

Root cause: `rdp_clipboard_chunk_start_file()` in `internal/worker/clipboard_files.h`
inferred "no file started yet" from `total_bytes==0 && file_index==0 && offset==0`.
After a zero-byte first file that exact state persists, so advancing to file 1 was
rejected as out-of-order (`RDP_CLIPBOARD_ERR_STATE`). Unit proof before fix:

```
begin(2)=0
start_file(0,0)=0
file_complete(0)=1
start_file(1,128)=12   # 12 = RDP_CLIPBOARD_ERR_STATE, expected 0
```

End-to-end repro (isolated worker + fake Agent + FreeRDP probe mode 11):

```sh
go build -o /tmp/ver-worker ./cmd/rdp-worker
go build -o /tmp/ver-probe ./cmd/rdp-probe
RDP_TEST_WORKER_BINARY=/tmp/ver-worker RDP_TEST_PROBE_BINARY=/tmp/ver-probe \
  RDP_PROBE_FILE_COUNT=2 RDP_PROBE_FILE_SIZE=0 RDP_PROBE_FILE_SIZE2=128 \
  python3 /tmp/ver_adversarial.py zero_byte_order      # see artifacts
```

Before fix: `rc=22`, IPC messages `begin(1,0,2,128,0) entry(0,0) entry(1,128) end(1,2,0,2)`,
worker log `reason=bad_state`. Also reproduced with `[0,0,128]`; `[128,0]` passed
(confirms the bug is specifically the leading-zero case).

Fix (`5552268`): explicit `BOOL file_started` in `rdp_clipboard_chunk_state`.
**Re-verified** with `/tmp/ver-worker2` built from `5552268`: `[0,128]`, `[0,0,128]`,
`[128,0]` all complete with `rc=0`, IPC `end(1,0,0,N)`, chunk requested for the first
non-empty file, no `clipboard_file_rejected`; updated `test_23` regression cases pass.

### F2 — MINOR (found, fixed in 5552268, re-verified): remote file names with C1 controls / bidi overrides accepted

Contract §5 requires rejecting "control chars" in untrusted remote names. The worker
accepted C1 controls and bidi formatting characters (byte-level check only rejected
`<0x20`/`0x7F`), forwarded them over IPC 16 and the Agent would create such names:

* `a\u0085b.bin` → IPC 16 name bytes `61 c2 85 62 2e 62 69 6e`, transfer completed (`rc=0`).
* `evil\u202Etxt.exe` (RLO) → IPC 16 name bytes `… e2 80 ae …`, transfer completed.

No traversal impact (separators are rejected separately); impact is log spoofing /
invisible or extension-disguising filenames. Repro: probe mode 11 with
`RDP_PROBE_FILE_NAME="a<U+0085>b.bin"` (same harness, `unicode_control_names`).

Fix (`5552268`): `rdp_clipboard_has_unsafe_format_chars()` rejects U+0080–U+009F,
U+200E/F, U+202A–U+202E, U+2066–U+2069 in names and local paths; ordinary non-ASCII
(Chinese, NBSP, U+202F) still valid.
**Re-verified**: both names now rejected `reason=bad_name`, no IPC 16 entry forwarded,
probe fails cleanly; Chinese names still pass in `test_23`.

### F3 — MINOR (open, non-blocking, follow-up recommended): Agent-side validation does not mirror the F2 fix

The Swift Agent's `AgentClipboardFileValidation.isValidName` /
`isValidAbsolutePath` (`AgentIPCMessage.swift`) still only reject `<0x20`/`0x7F`, so
they accept C1/bidi. Today the Worker rejects these before IPC 16, so there is no
end-to-end exposure, but contract §5 says "Limits (both sides enforce independently)".
A rolling deploy / future IPC producer could reintroduce the names. Recommendation:
mirror `rdp_clipboard_has_unsafe_format_chars` in Swift and add a unit case.

### F4 — MINOR (open, not covered by contract): duplicate basenames in one remote offer abort the whole paste

The Agent writes each remote file with `O_CREAT|O_EXCL`; two entries with the same
name (possible when a Windows client copies same-named files from different folders)
make the second `open()` fail `EEXIST`, which fails the entire offer and deletes the
temp dir (all files lost). Verified with an independent Swift harness using the real
`PosixClipboardFileAssemblyFileSystem`:

```
duplicate-name events: [.offerFailed(.fileSystem("systemCall(\"open\", 17)"))]
```

The worker/Agent do not de-duplicate names. Non-blocking (graceful failure, session
stays up), but a "rename to name (2)" or per-entry rejection would be friendlier.
Repro artifact: `/tmp/ver-swift/main.swift` (compiled against
`AgentIPCMessage.swift` + `ClipboardFileTransfer.swift`).

### F5 — NIT (open, documentation): "clamp to the file size" vs "reject crossing EOF"

Contract §5 says "never read past EOF; clamp to the file size", while §2.2 step 4 says
"validate offset + cbRequested <= size … Any error … answers CB_RESPONSE_FAIL". The
implementation (`rdp_clipboard_validate_range`) rejects a range crossing EOF and does
not clamp. That matches §2.2 and is safe; only the §5 wording is inconsistent.
Recommend aligning the doc (or clamping if the intent was §5).

## What was independently verified as correct

Security (remote→local untrusted names, via probe mode 11 + fake Agent):

* Rejected with `reason=bad_name`, no bytes requested, session usable afterwards:
  `../evil.bin`, `..\evil.bin`, `/tmp/evil.bin`, `C:evil.bin`, `..`, `.`,
  `a\x01b.bin`, empty name, 256-byte name (integration; >255 also unit-tested).
* Count 101 → `too_many_files`; total >4 GiB → `too_large`; per-file ≥2 GiB, zero
  files, directory attribute and malformed packed lists → rejected by the C helper
  harness (`scripts/test-clipboard-handshake.py`).
* Chunk-state rules (gap/overlap/overflow/out-of-order/cancel, zero-byte files) are
  enforced by `rdp_clipboard_chunk_*`; the Agent assembler independently enforces the
  same rules (`ClipboardFileTransferTests`, plus my Swift harness).
* Malformed Agent→Worker IPC: truncated begin, wrong direction for types 13/15/16,
  count 101, total >4 GiB, `nameLen`/`pathLen`-payload mismatch, nameLen 0, status 3,
  type 14 from the Agent, unknown types 17/99 and type 3 from the Agent are all
  logged (`clipboard_file_rejected`/`agent_ipc_ignored`) and **never close the IPC
  connection**; a following type-8 text message still works and a new RDP session is
  served normally.
* Agent temp tree: dir 0700, files 0600, `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`;
  traversal names (`../x`, `/etc/passwd`, `a/b`, `a\b`, `C:x`, `.`, `..`, NUL) rejected
  before `open(2)`; pre-created symlink with the offered name is not followed and its
  target is not overwritten; offer dirs are removed on failure/cancel.
* Local→remote TOCTOU: file truncated after advertisement → each range is revalidated,
  `CB_RESPONSE_FAIL` + `reason=size_mismatch`; file replaced by a same-size symlink
  after advertisement → `reason=not_regular`, target content never served.
* Log leakage: worker logs contain no file contents and no local paths (basename
  length only: `name_len=`, `offset=`, `bytes=`, `reason=`); Agent logs count/bytes
  only. No credentials or `.runtime` content touched.

Correctness vs contract:

* Format IDs: server advertises `0xC003` + `0xC004`; client descriptor request for
  `0xC003` is served from the cached packed list; `FILECONTENTS_SIZE` answer is exactly
  8 bytes little-endian; `FILECONTENTS_RANGE` chunking is 65524 bytes max and matches
  the client request; `CB_RESPONSE_FAIL` with no data on any range error.
* Caps/init ordering: `event=cliprdr_initialized general_flags=0x00000006` (long format
  names + stream file clip) exactly once per connection; the probe receives
  `CB_CLIP_CAPS` once and `CB_MONITOR_READY` before `CB_FORMAT_LIST` (no double init);
  text-only and file-only format lists are each one PDU per clipboard change.
* files→text revocation: after a file offer is pasted, a local text change makes a new
  client receive a text-only `CB_FORMAT_LIST` (client DEBUG: `id=0x0000000d`, no
  `0xC003`), i.e. the old file advertisement is revoked.
* Peer frame thread not blocked: during a 10 MiB remote→local transfer the worker sent
  `event=desktop_frame_sent` for 8 concurrently uploaded Agent frames while the
  transfer completed (`rc=0`, IPC end status=0). File I/O is on the cliprdr channel
  thread / Agent clipboard queue, never on the peer frame thread; IPC sends are bounded
  by the 500 ms socket timeout.
* Bounded resources: 10 sequential 1 MiB remote→local transfers on one worker:
  RSS 22.6→23.2 MB (plateau, warm-up growth only), fd count constant at 18, no leaked
  temp files (worker creates none).
* Direction-2 limit boundary: 100-file offer accepted, all 100 entries validated and
  the 100-entry packed descriptor served (probe parsed it; its own limit is 16); 101
  rejected `too_many_files`.
* Text clipboard non-regression: `test_26`, `test_01`-style mode 0/5 sessions and text
  after files/file after text all work.

## Test quality (spot-checked, not trusted)

* Baseline with `/tmp/ver-worker` + `/tmp/ver-probe` from the tree: `test_23`, `test_24`,
  `test_25`, `test_25b`, `test_25c`, `test_26` → all OK; `test-clipboard-handshake.py`
  (C helper harness) → 6 tests OK; `make agent-check` → `clipboard_file_tests_ok`;
  `test-agent-ipc-wire.py` → 5 tests OK.
* Mutation A (`/tmp` copy of the repo, never the working tree): force
  `rdp_clipboard_name_valid` to always return TRUE → `test_25` **FAILED** with 4
  subtest failures (traversal/absolute names no longer rejected). The security test is
  real, not tautological.
* Mutation B: force `rdp_clipboard_select_format` to always request text → `test_23`
  **FAILED** (3 subtest failures; no file offer, probe times out). The file-offer path
  is really asserted.
* Coverage gap found by this verification: the original `test_23` had only a
  *single*-file zero-byte case, which cannot reach the F1 state-machine branch;
  `[0,128]`/`[0,0,128]` were missing. The owning contributor added regression cases to
  `test_23` and the C harness after the fix (present in the working tree). Fail-before/
  pass-after proven: updated `test_23` against the pre-fix worker fails exactly the two
  new cases (`multi-zero-first-2`, `multi-zero-zero-1024`, rc 22 vs 0) and passes
  against the fixed worker (`/tmp/ver-worker2`, OK in 4.5 s).
* Assertions reviewed and found meaningful: IPC begin/entry/chunk/end sequence and byte
  reconstruction, caps flags 0x6, rejection reasons, no chunk after client failure,
  session-stays-usable checks, Agent O_EXCL/O_NOFOLLOW/mode tests.

## Repro artifacts (all under /tmp, no repo/source modification)

* `/tmp/ver_adversarial.py` — independent loopback scenarios (zero-byte ordering,
  malformed IPC, TOCTOU, unsafe names, 100 files, repeated transfers, frames during
  transfer, files→text revocation). Reuses `scripts/test-protocol.py` helpers.
* `/tmp/ver-swift/main.swift` — independent Agent assembler harness (real POSIX temp
  dir; duplicate names, C1/bidi, traversal, symlink race, modes, 100 zero-byte files).
* `/tmp/mutant-worker-A`, `/tmp/mutant-worker-B` — mutation builds from a `/tmp` repo
  copy (working tree untouched).
* `/tmp/ver-worker`, `/tmp/ver-probe` (pre-fix `7000d12`) and `/tmp/ver-worker2`,
  `/tmp/ver-probe2` (post-fix `5552268`).

## Not verified (out of scope / needs hardware)

* Real Windows App / mstsc manual acceptance (copy 1/N files, Chinese name, ~10 MiB,
  0-byte, both directions, text switching) — loopback only here.
* End-to-end >2 GiB per file / >4 GiB total (limits are enforced by the C helpers and
  the Agent codec; the FreeRDP probe cannot generate them).
* Drag & drop with a real Windows client (same cliprdr formats; no separate channel).
* Agent-side C1/bidi parity (F3) and duplicate-basename UX (F4) — recommended follow-ups.

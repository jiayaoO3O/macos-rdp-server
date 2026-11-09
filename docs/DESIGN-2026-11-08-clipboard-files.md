# Design / binding contract — bidirectional file clipboard (2026-11-08, Issue 3)

Status: implementation contract. Worker C, Agent Swift, probe and protocol tests must
follow this document. It is the third follow-up (Issue 3).

Branch: `feature/dynamic-resolution-and-connection-stability`. Never restart the live
worker/agent without explicit user consent; never read `.runtime/sam`,
`.runtime/config.json` or credentials. All experiments use isolated workers, random
loopback ports and `/tmp` directories.

## 1. Scope

Phase A only: **file copy/paste both directions** through the RDP clipboard virtual
channel (`cliprdr`), plus the worker↔agent IPC extension needed to carry file data.
Drag & drop is **not** a separate protocol: it uses the same cliprdr file formats on the
wire, so it is "free" if the Windows client offers it. Do not invent a new drag channel.

* Windows → macOS: Windows Explorer "Copy" of files → macOS Finder "Paste" creates the
  files on the local disk.
* macOS → Windows: Finder "Copy" of files → Windows Explorer "Paste" writes the files.
* Text clipboard (CF_UNICODETEXT, format 13) must not regress.
* File transfers must not block the peer frame thread: the worker streams clipboard
  bytes through the existing agent IPC socket; the agent writes files on its own
  clipboard thread/queue. The peer thread only forwards bounded chunks.

## 2. Wire protocol (MS-RDPECLIP), reference points

Clipboard format IDs on the wire:

| Format | ID | Direction of data flow |
|---|---|---|
| CF_UNICODETEXT | 13 | both (existing) |
| FileGroupDescriptorW | 0xC003 (49155) | both |
| FileContents | 0xC004 (49156) | both |

PDU types already exposed by FreeRDP 3.32.2 (`include/freerdp/channels/cliprdr.h`):
`CB_FORMAT_LIST`, `CB_FORMAT_LIST_RESPONSE`, `CB_FORMAT_DATA_REQUEST`,
`CB_FORMAT_DATA_RESPONSE`, `CB_FILECONTENTS_REQUEST` (0x0008),
`CB_FILECONTENTS_RESPONSE` (0x0009). Flags `FILECONTENTS_SIZE` (0x1) and
`FILECONTENTS_RANGE` (0x2) are mutually exclusive.

Reusable exported FreeRDP helpers (`#include <freerdp/utils/cliprdr_utils.h>`, linked
into the worker already; use them, do not re-implement the packed file list):

* `cliprdr_parse_file_list(const BYTE *data, UINT32 len, FILEDESCRIPTORW **array, UINT32 *count)`
  — parses `cItems + cItems * FILEDESCRIPTORW` (592 bytes each). Rejects `..` path
  components; still validate names yourself (section 5).
* `cliprdr_serialize_file_list(const FILEDESCRIPTORW *array, UINT32 count, BYTE **data, UINT32 *len)`
  — serializes the same wire format; fails for files >= 2 GiB unless the
  `CB_HUGE_FILE_SUPPORT_ENABLED` flag is passed through `_ex` (we advertise
  `hasHugeFileSupport = FALSE` and cap at 2 GiB).
* `cliprdr_read_filedescriptor` / `cliprdr_write_filedescriptor` if a single entry is
  needed.
* `FILEDESCRIPTORW` is defined in `<winpr/shell.h>` (592-byte layout: `dwFlags`, `clsid`,
  `sizel`, `pointl`, attributes, three FILETIMEs, size high/low, `cFileName[260]`).

### 2.1 Windows → macOS (remote copy → local paste)

1. Windows client sends `CB_FORMAT_LIST` advertising `FileGroupDescriptorW` (+
   `FileContents`; sometimes `CF_HDROP`).
2. Worker: reply `CB_FORMAT_LIST_RESPONSE` OK, then send `CB_FORMAT_DATA_REQUEST` for
   format 0xC003. (Match the format by `formatId == 0xC003` **or** `formatName ==
   "FileGroupDescriptorW"`; Windows App advertises both.)
3. Windows replies `CB_FORMAT_DATA_RESPONSE` containing the packed file list.
4. Worker: parse + validate the list (section 5). Start an IPC offer to the Agent
   (section 3, direction 1), then request file contents one chunk at a time:
   `CB_FILECONTENTS_REQUEST{ streamId = 1, listIndex = fileIndex, dwFlags = FILECONTENTS_RANGE,
   nPositionLow/High = offset, cbRequested = chunk }`. `chunk` = 65524 bytes max
   (fits one IPC payload); 64 KiB is the recommended value. No `FILECONTENTS_SIZE`
   request is needed because the descriptor carries the size; verify received total
   against it and fail the offer on mismatch.
5. For each `CB_FILECONTENTS_RESPONSE` with `streamId` matching, forward the bytes as an
   IPC file chunk, then request the next chunk. A response with `CB_RESPONSE_FAIL` or
   a short/oversized chunk aborts the offer with an error end message.
6. When all files are complete: send IPC offer-end status=complete. The Agent sets the
   macOS pasteboard to the local file URLs (Finder paste works).

### 2.2 macOS → Windows (local copy → remote paste)

1. Agent observes file URLs on `NSPasteboard.general` (`.fileURL` objects). It sends an
   IPC offer (section 3, direction 2) with absolute paths + sizes + names.
2. Worker validates (absolute, `lstat` regular file, no symlink, readable, count/size
   limits, size matches) and advertises to the client
   `CB_FORMAT_LIST{ FileGroupDescriptorW(0xC003), FileContents(0xC004) }` (no
   `formatName` needed for these IDs; adding the name is harmless).
3. Client sends `CB_FORMAT_DATA_REQUEST{0xC003}`; worker answers with the serialized
   packed file list built from the Agent metadata.
4. Client sends `CB_FILECONTENTS_REQUEST`:
   * `dwFlags & FILECONTENTS_SIZE`: answer with `CB_FILECONTENTS_RESPONSE` whose data is
     the 8-byte little-endian file size (`cbRequested == 8`).
   * `dwFlags & FILECONTENTS_RANGE`: validate `offset + cbRequested <= size`, read the
     range from the path, answer with the bytes. Any error (bad index, bad range,
     read failure) answers `CB_RESPONSE_FAIL` with no data and logs the reason.
5. On a new local clipboard (text or another file list) the Agent sends a new IPC
   offer/type-8 message; the worker revokes the old file advertisement by sending a new
   `CB_FORMAT_LIST` (text-only, or empty list when the clipboard is empty).

## 3. Worker ↔ Agent IPC extension (binding wire format)

Transport unchanged: `RDPA` magic, version 1, `u16 type`, `u32 payload length`
(big-endian), max payload 65536, Unix stream socket. Existing types 1..12 unchanged.
**All new fields are big-endian.**

New message types:

| Type | Name | Direction | Payload |
|---|---|---|---|
| 13 | `clipboardFileOfferBegin` | worker→agent (dir 1), agent→worker (dir 2) | `u8 direction, u8 reserved=0, u16 fileCount, u64 totalBytes, u32 flags=0` = 16 bytes |
| 14 | `clipboardFileChunk` | worker→agent only | `u32 fileIndex, u64 offset, then data` (data <= 65524) |
| 15 | `clipboardFileOfferEnd` | both | `u8 direction, u8 status, u16 errorCode, u32 fileCount` = 8 bytes |
| 16 | `clipboardFileEntry` | both | `u8 direction, u8 reserved=0, u16 nameLen, u32 fileIndex, u64 size, u16 pathLen, nameUtf8[nameLen], pathUtf8[pathLen]` (18-byte header) |

* `direction`: `1` = remote (Windows) → local (macOS); `2` = local (macOS) → remote
  (Windows). The direction byte must equal the offer's direction on every message of the
  offer.
* `status`: `0` = complete (all data delivered / list complete), `1` = cancelled
  (superseded), `2` = error. For direction 2 the begin/entry/end sequence only carries
  metadata; `status=0` end means "advertise this list to the client".
* `pathLen` is `0` for direction 1; direction 2 requires an absolute path.
* Chunks for direction 1 are sent in `fileIndex` order, each file starting at offset 0,
  strictly increasing offsets with no gaps or overlaps. The Agent enforces this.
* A begin message implicitly cancels any offer still in progress in the same direction.
* Text clipboard stays on type 8: `payload[0] == 1` local→remote, `== 2` remote→local.
  When the local clipboard holds files the Agent sends a file offer (dir 2) instead of
  type 8; when it holds text it sends type 8. Empty clipboard = type 8 with empty text.

Limits (both sides enforce independently):

* `MAX_CLIPBOARD_FILES` = 100
* `MAX_CLIPBOARD_FILE_BYTES` = 2 GiB per file
* `MAX_CLIPBOARD_TOTAL_BYTES` = 4 GiB per offer
* file name <= 255 UTF-8 bytes, path <= 1023 UTF-8 bytes, name must be a single path
  component (no `/`, `\`, `:`, NUL, control chars, `.`/`..`, leading `-` is allowed)
* the Agent's local temp directory is `NSTemporaryDirectory()/rdp-clipboard/<uuid>/`,
  mode 0700, files 0600, created with O_EXCL; stale offer directories from previous
  offers are deleted when a new offer starts (keep at most the current + previous one).

Compatibility: the Agent must **ignore unknown IPC message types** (log
`event=ipc_message_ignored type=N` once per type) instead of throwing; a throw currently
kills the input receiver and exits the agent. The Worker must ignore unknown types from
the Agent with `event=agent_ipc_ignored type=N` instead of closing the IPC connection
(forward compatibility for rolling deploys). Deploy worker and agent together anyway.

## 4. Worker C implementation map

Files: `internal/worker/native.c`, `internal/worker/clipboard_handshake.h`, new
`internal/worker/clipboard_files.h` for pure helpers (parse/validate/serialize
descriptors, limits, range checks) so a C harness can unit-test them.

New per-peer state (in `peer_context`) and server state (in `server_options`):

* worker-side remote→local offer state: file descriptors, current file index, offset,
  requested chunk, temp/offer id (worker does not need temp files: it streams to the
  Agent directly).
* worker-side local→remote offer state: file paths + sizes + names + timestamps from the
  Agent, current advertisement generation.
* clipboard format state: what the worker last advertised (text / files / none), so a
  change sends exactly one new `CB_FORMAT_LIST`.

Rules:

* Never perform file I/O while holding `agent_mutex` / `frame_mutex`; the cliprdr
  callbacks run on the channel thread. Sending IPC is bounded by the existing socket
  send timeout. Read local files with `pread` in <= 64 KiB blocks per request.
* All clipboard-file callbacks must return `CHANNEL_RC_OK` on recoverable errors (log
  + abort the offer) so a bad client cannot kill the session.
* Keep the existing text path working; a format list that has both text and files
  prefers files (Windows Explorer copy), otherwise text.
* Logging (stderr, grep-able, no file contents, paths allowed only for local→remote and
  only as basename + length, never credentials):
  `event=clipboard_file_offer direction=remote_to_local|local_to_remote count=N bytes=M`
  `event=clipboard_file_entry direction=... index=i size=N name_len=N`
  `event=clipboard_file_request direction=... index=i offset=O length=L`
  `event=clipboard_file_complete direction=... files=N bytes=M result=0|1`
  `event=clipboard_file_rejected direction=... reason=too_many_files|too_large|bad_name|bad_range|not_regular|unreadable|size_mismatch|ipc_failed|client_failed`
* Set `ctx->cliprdr->useLongFormatNames = TRUE`, `streamFileClipEnabled = TRUE`,
  `fileClipNoFilePaths = FALSE`, `hasHugeFileSupport = FALSE` before `Start()`.

## 5. Security requirements (must be unit-tested)

Remote→local (untrusted names from the Windows client):

* reject non-single-component names (`/`, `\`, `..`, absolute paths, drive letters,
  control chars, empty, > 255 bytes after UTF-8 conversion, reserved `.`/`..`),
* reject count > 100, per-file size > 2 GiB, total > 4 GiB, zero files,
* Agent: only the sanitized last path component is used; file created inside the
  offer's temp dir with `O_CREAT|O_EXCL|O_WRONLY` 0600; never follow symlinks
  (`O_NOFOLLOW`); chunk offsets must be contiguous and total must equal the advertised
  size; on any error delete the whole offer dir and log; never write outside the dir.

Local→remote (paths from the Agent, which runs as the same user):

* require absolute path, `lstat` regular file, reject symlinks and directories,
  reject unreadable, size from `stat` must match the advertised size, count/size limits,
* each `CB_FILECONTENTS_REQUEST` range is re-validated against the file size before
  `pread`; never read past EOF; clamp to the file size.

## 6. Tests required

1. C unit harness (`scripts/test-clipboard-handshake.py`, extend): compiled against the
   installed FreeRDP headers, covering `clipboard_files.h` pure helpers:
   file-list parse/serialize round-trip (ASCII, Chinese names, 1/2/100 files, size 0,
   > 2 GiB rejection, > 100 files rejection), name sanitization matrix, range checks,
   chunk state machine (in-order, gap, overlap, overflow, cancel), limits.
2. Loopback protocol tests (`scripts/test-protocol.py`), isolated worker + fake Agent:
   * remote→local: probe (client) advertises `FileGroupDescriptorW`, answers descriptor
     and contents requests; fake Agent asserts the IPC begin/entry/chunk/end sequence and
     reconstructs exact bytes (single file, multiple files, Chinese name, ~10 MiB file
     in chunks).
   * local→remote: fake Agent sends offer with real temp files; probe requests the
     descriptor + contents and asserts the bytes/sizes (FILECONTENTS_SIZE + RANGE).
   * error paths: bad name / too many files / size mismatch / failed contents request →
     worker logs `clipboard_file_rejected`, session stays up, text clipboard still works.
3. Agent Swift tests (`make agent-check`): IPC codec for types 13..16 (round-trip,
   bounds, truncation), offer assembly state machine (in-order/gap/overflow/cancel,
   path sanitization), pasteboard file URL list conversion (pure helpers).
4. `scripts/test-agent-ipc-wire.py`: a real socket test where the worker-side peer sends
   the new messages to a Swift sender/receiver and the Agent ignores an unknown type.
5. Full suites stay green: `make build`, `go test ./...`, `go vet ./...`, `make check`,
   `make agent-check`, `python3 scripts/test-protocol.py` (24 existing + new, 1 AVC420
   skip), `python3 scripts/test-clipboard-handshake.py`, `make test-agent-ipc-wire`.

## 7. Manual acceptance (user)

* Windows → macOS: copy one file, multiple files, a file with a Chinese name, a ~10 MiB
  file, a 0-byte file; paste in Finder; contents equal.
* macOS → Windows: copy files in Finder, paste in Explorer; contents equal.
* text clipboard still works both ways; copying text after files (and files after text)
  switches formats correctly.
* oversize / cancelled copy does not hang the session or leak temp files.

## 8. File ownership (avoid conflicting writes)

| Owner | Files |
|---|---|
| worker-core | `internal/worker/native.c` (cliprdr + IPC loop + struct regions), `internal/worker/clipboard_handshake.h`, new `internal/worker/clipboard_files.h` |
| agent-clipboard | `native/macos/Sources/MacAgentCore/*` (new clipboard file codec + tests), `native/macos/Sources/rdp-agent/main.swift`, `native/macos/Tests/MacAgentCoreTests/*`, `Makefile` agent-check file list |
| probe-cliprdr | `internal/worker/native.c` (probe section only, from the `rdp-probe` marker to EOF) |
| protocol-tests | `scripts/test-protocol.py`, `scripts/test-clipboard-handshake.py`, `scripts/test-agent-ipc-wire.py` |
| disp-diagnosis | `internal/worker/native.c` (DISP regions only), `docs/DIAGNOSIS-2026-11-08-disp-window-resize.md`, `scripts/disp-*.py` |
| maintainer | mouse fix in `internal/worker/native.c`, docs, git, integration, deployment |

Everyone uses the `edit` tool on exact literals inside `native.c`; never rewrite the
whole file. If the edit tool reports a stale version, re-read and rebase. Do not run
`git commit`, `git switch`, `make build` (use `go build -o /tmp/...` and the
`RDP_TEST_WORKER_BINARY`/`RDP_TEST_PROBE_BINARY` env overrides for focused tests), and
never restart the live worker/agent.

## 9. Addendum — TCC / Full Disk Access: staging of local files (2026-11-08)

macOS TCC protects `~/Desktop`, `~/Documents`, iCloud Drive and other folders per
*process*. The Worker process cannot rely on opening those files even though it runs as
the same user (field evidence: `clipboard_file_rejected direction=local_to_remote
reason=unreadable`; the shell process also gets EPERM on `~/Desktop`). Only the
RDPAgent.app can practically be granted Full Disk Access.

Direction 2 (macOS → Windows) therefore stages every copied file instead of advertising
the original path:

* When building a direction-2 offer, the Agent validates the contract limits
  (100 files / < 2 GiB per file / ≤ 4 GiB total, name/path rules) first, then
  **stream-copies** each file (64 KiB chunks, never the whole file in memory) to
  `NSTemporaryDirectory()/rdp-clipboard-out/<offer-uuid>/<index>-<sanitized-name>`
  (directories 0700, files 0600, `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`; sources opened
  `O_RDONLY|O_NOFOLLOW|O_CLOEXEC` and `fstat`-checked to be regular files).
* IPC type-16 entries keep the original **name** but carry the absolute **staged path**;
  the advertised size is the copied byte count, verified to equal the source size
  (a file that changes during the copy aborts the offer with `size_mismatch`). The
  Worker therefore never needs access to the original (possibly TCC-protected) path.
* If the Agent itself cannot read the source (no Full Disk Access / TCC denial), it
  rejects the whole list, logs
  `event=clipboard_file_rejected direction=local_to_remote reason=unreadable
  name=<sanitized basename> errno=<n>` (never a full path) and sends the empty type-8
  reset so the Worker revokes the previous file advertisement.
* Staging life cycle: on success the newest directory becomes `current`, the previous
  one becomes `previous`; the older directory is deleted when the next offer is staged.
  A staging error deletes its partial directory. The directories are also removed when
  the Agent process exits, so a cancelled/failed copy does not leak temp files. A
  paste of an already-revoked advertisement can hit `ENOENT`; the Worker answers
  `CB_RESPONSE_FAIL` and the session stays up.
* File contents/paths beyond the sanitized basename never appear in logs.

Operational requirement: grant **Full Disk Access** to `RDPAgent.app`
(System Settings → Privacy & Security → Full Disk Access) for copies from
`~/Desktop`, `~/Documents`, iCloud Drive and similar protected locations. Without it,
text clipboard and non-protected folders keep working; protected-folder copies are
rejected with the audit log line above. The Worker needs no TCC permission.

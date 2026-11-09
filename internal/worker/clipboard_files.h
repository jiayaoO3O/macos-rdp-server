#ifndef RDP_CLIPBOARD_FILES_H
#define RDP_CLIPBOARD_FILES_H

/* File clipboard helpers (Issue 3, 2026-11-08).
 *
 * BINDING CONTRACT: docs/DESIGN-2026-11-08-clipboard-files.md.
 *
 * This header is header-only and side-effect free: every helper is a pure
 * function over buffers/structs, so the worker and the C unit harness
 * (scripts/test-clipboard-handshake.py) compile exactly the same code. The only
 * external calls are the documented FreeRDP/WinPR helpers:
 *   - cliprdr_parse_file_list() / cliprdr_serialize_file_list() (packed
 *     FileGroupDescriptorW list; linked from libfreerdp3),
 *   - ConvertWCharNToUtf8() / ConvertUtf8ToWChar() (WinPR unicode, libwinpr3).
 * A harness that calls parse/build/fill_descriptor must therefore link
 *   -L .deps/install/lib -lfreerdp3 -lwinpr3 -Wl,-rpath,<same dir>
 * Pure name/limits/chunk/IPC helpers do not reference those symbols.
 *
 * API overview (all limits below are enforced by both worker and Agent):
 *   Part A  constants, direction/status/format ids, status -> log reason
 *   Part B  UTF-8/name/path validation and name sanitization
 *   Part C  offer limits, FILECONTENTS range validation + EOF clamping
 *   Part D  packed FileGroupDescriptorW parse/build + FILEDESCRIPTORW fill
 *   Part E  chunk assembly state machine (in-order / gap / overlap / overflow)
 *   Part F  IPC message type 13/14/15/16 big-endian codecs
 *
 * `rdp_clipboard_status` values map 1:1 to the `reason=` tokens of the
 * grep-able `event=clipboard_file_rejected` log line in contract section 4:
 *   RDP_CLIPBOARD_ERR_TOO_MANY_FILES -> too_many_files
 *   RDP_CLIPBOARD_ERR_TOO_LARGE      -> too_large
 *   RDP_CLIPBOARD_ERR_BAD_NAME       -> bad_name
 *   RDP_CLIPBOARD_ERR_NOT_REGULAR    -> not_regular
 *   RDP_CLIPBOARD_ERR_UNREADABLE     -> unreadable
 *   RDP_CLIPBOARD_ERR_SIZE_MISMATCH  -> size_mismatch
 *   RDP_CLIPBOARD_ERR_BAD_RANGE      -> bad_range
 *   RDP_CLIPBOARD_ERR_IPC            -> ipc_failed
 *   RDP_CLIPBOARD_ERR_CLIENT         -> client_failed
 * The remaining codes (EMPTY/BAD_FORMAT/STATE/UNSUPPORTED) are internal and
 * never logged as a rejected reason on their own by the worker.
 *
 * No helper here performs file I/O, allocates unbounded memory, logs or blocks.
 */

#include <freerdp/channels/cliprdr.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/file.h>
#include <winpr/shell.h>
#include <winpr/string.h>

#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Part A: constants, wire ids, status/reason mapping                        */
/* ------------------------------------------------------------------------- */

#define RDP_CLIPBOARD_FORMAT_TEXT 13u /* CF_UNICODETEXT */
#define RDP_CLIPBOARD_FORMAT_FILE_GROUP_DESCRIPTOR 0xC003u /* FileGroupDescriptorW */
#define RDP_CLIPBOARD_FORMAT_FILE_CONTENTS 0xC004u         /* FileContents */

#define RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL 1u /* Windows -> macOS */
#define RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE 2u /* macOS -> Windows */

#define RDP_CLIPBOARD_OFFER_STATUS_COMPLETE 0u
#define RDP_CLIPBOARD_OFFER_STATUS_CANCELLED 1u
#define RDP_CLIPBOARD_OFFER_STATUS_ERROR 2u

#define RDP_CLIPBOARD_MAX_FILES 100u
#define RDP_CLIPBOARD_MAX_FILE_BYTES (2ULL * 1024ULL * 1024ULL * 1024ULL)
#define RDP_CLIPBOARD_MAX_TOTAL_BYTES (4ULL * 1024ULL * 1024ULL * 1024ULL)
#define RDP_CLIPBOARD_MAX_NAME_BYTES 255u
#define RDP_CLIPBOARD_MAX_PATH_BYTES 1023u
/* One CB_FILECONTENTS_RANGE request per IPC chunk: 12-byte chunk header plus
 * this many data bytes is exactly the 65536-byte IPC payload maximum. */
#define RDP_CLIPBOARD_CHUNK_BYTES 65524u
/* Defensive bound for a single served FILECONTENTS_RANGE response; Windows
 * clients request at most 64 KiB per range, anything wildly larger is failed. */
#define RDP_CLIPBOARD_MAX_RESPONSE_BYTES (4u * 1024u * 1024u)

/* Size of one FILEDESCRIPTORW on the wire ([MS-RDPECLIP] 2.2.5.1). */
#define RDP_CLIPBOARD_DESCRIPTOR_BYTES 592u

typedef enum {
	RDP_CLIPBOARD_OK = 0,
	RDP_CLIPBOARD_ERR_EMPTY,           /* zero files advertised */
	RDP_CLIPBOARD_ERR_TOO_MANY_FILES,  /* count > MAX_FILES */
	RDP_CLIPBOARD_ERR_TOO_LARGE,       /* per-file or total byte limit */
	RDP_CLIPBOARD_ERR_BAD_NAME,        /* not a single safe path component */
	RDP_CLIPBOARD_ERR_NOT_REGULAR,     /* directory or non-regular file */
	RDP_CLIPBOARD_ERR_UNREADABLE,      /* open/stat/read failed */
	RDP_CLIPBOARD_ERR_SIZE_MISMATCH,   /* data vs advertised descriptor size */
	RDP_CLIPBOARD_ERR_BAD_RANGE,       /* FILECONTENTS range/flag violation */
	RDP_CLIPBOARD_ERR_BAD_FORMAT,      /* malformed packed list / IPC payload */
	RDP_CLIPBOARD_ERR_IPC,             /* worker <-> agent transport failed */
	RDP_CLIPBOARD_ERR_CLIENT,          /* RDP client failed/cancelled */
	RDP_CLIPBOARD_ERR_STATE,           /* operation not valid in this state */
	RDP_CLIPBOARD_ERR_UNSUPPORTED      /* format id we do not serve */
} rdp_clipboard_status;

/* Log token for a rejected offer (contract section 4). */
static inline const char *rdp_clipboard_status_reason(rdp_clipboard_status status)
{
	switch (status)
	{
		case RDP_CLIPBOARD_OK:
			return "ok";
		case RDP_CLIPBOARD_ERR_EMPTY:
			return "empty";
		case RDP_CLIPBOARD_ERR_TOO_MANY_FILES:
			return "too_many_files";
		case RDP_CLIPBOARD_ERR_TOO_LARGE:
			return "too_large";
		case RDP_CLIPBOARD_ERR_BAD_NAME:
			return "bad_name";
		case RDP_CLIPBOARD_ERR_NOT_REGULAR:
			return "not_regular";
		case RDP_CLIPBOARD_ERR_UNREADABLE:
			return "unreadable";
		case RDP_CLIPBOARD_ERR_SIZE_MISMATCH:
			return "size_mismatch";
		case RDP_CLIPBOARD_ERR_BAD_RANGE:
			return "bad_range";
		case RDP_CLIPBOARD_ERR_BAD_FORMAT:
			return "bad_format";
		case RDP_CLIPBOARD_ERR_IPC:
			return "ipc_failed";
		case RDP_CLIPBOARD_ERR_CLIENT:
			return "client_failed";
		case RDP_CLIPBOARD_ERR_STATE:
			return "bad_state";
		case RDP_CLIPBOARD_ERR_UNSUPPORTED:
			return "unsupported";
		default:
			return "unknown";
	}
}

static inline UINT16 rdp_clipboard_read_be16(const BYTE *p)
{
	return (UINT16)(((UINT16)p[0] << 8) | (UINT16)p[1]);
}

static inline UINT32 rdp_clipboard_read_be32(const BYTE *p)
{
	return ((UINT32)p[0] << 24) | ((UINT32)p[1] << 16) | ((UINT32)p[2] << 8) | (UINT32)p[3];
}

static inline UINT64 rdp_clipboard_read_be64(const BYTE *p)
{
	return ((UINT64)rdp_clipboard_read_be32(p) << 32) | rdp_clipboard_read_be32(p + 4);
}

/* The packed FileGroupDescriptorW list is a serialized Windows structure and
 * therefore little-endian (FreeRDP serializes it with wStream's LE primitives);
 * the worker<->Agent IPC messages 13..16 are big-endian per the contract. */
static inline UINT32 rdp_clipboard_read_le32(const BYTE *p)
{
	return ((UINT32)p[3] << 24) | ((UINT32)p[2] << 16) | ((UINT32)p[1] << 8) | (UINT32)p[0];
}

static inline void rdp_clipboard_write_be16(BYTE *p, UINT16 value)
{
	p[0] = (BYTE)(value >> 8);
	p[1] = (BYTE)value;
}

static inline void rdp_clipboard_write_be32(BYTE *p, UINT32 value)
{
	p[0] = (BYTE)(value >> 24);
	p[1] = (BYTE)(value >> 16);
	p[2] = (BYTE)(value >> 8);
	p[3] = (BYTE)value;
}

static inline void rdp_clipboard_write_be64(BYTE *p, UINT64 value)
{
	rdp_clipboard_write_be32(p, (UINT32)(value >> 32));
	rdp_clipboard_write_be32(p + 4, (UINT32)value);
}

/* ------------------------------------------------------------------------- */
/* Part B: UTF-8 / name / path validation and sanitization                   */
/* ------------------------------------------------------------------------- */

/* Strict UTF-8 (RFC 3629): rejects truncated, overlong, surrogate and >U+10FFFF
 * sequences, and embedded NUL bytes. */
static inline BOOL rdp_clipboard_utf8_valid(const char *text, size_t length)
{
	const BYTE *s = (const BYTE *)text;
	size_t i = 0;

	if (!s && length)
		return FALSE;
	while (i < length)
	{
		const BYTE c = s[i];
		size_t extra = 0;
		UINT32 minimum = 0;
		UINT32 value = 0;

		if (c == 0x00)
			return FALSE;
		if (c < 0x80)
		{
			i++;
			continue;
		}
		else if ((c & 0xE0) == 0xC0)
		{
			extra = 1;
			minimum = 0x80;
			value = c & 0x1F;
		}
		else if ((c & 0xF0) == 0xE0)
		{
			extra = 2;
			minimum = 0x800;
			value = c & 0x0F;
		}
		else if ((c & 0xF8) == 0xF0)
		{
			extra = 3;
			minimum = 0x10000;
			value = c & 0x07;
		}
		else
			return FALSE;
		if (length - i <= extra)
			return FALSE;
		for (size_t k = 1; k <= extra; k++)
		{
			const BYTE cont = s[i + k];
			if ((cont & 0xC0) != 0x80)
				return FALSE;
			value = (value << 6) | (cont & 0x3F);
		}
		if (value < minimum)
			return FALSE; /* overlong encoding */
		if (value >= 0xD800 && value <= 0xDFFF)
			return FALSE; /* UTF-16 surrogate half */
		if (value > 0x10FFFF)
			return FALSE;
		i += extra + 1;
	}
	return TRUE;
}

/* Unsafe non-ASCII control/formatting code points that must never reach a log
 * line or a local file name (contract section 5 "control chars"):
 *   U+0080..U+009F  C1 controls (encoded C2 80..9F)
 *   U+200E/U+200F   LRM/RLM direction marks (E2 80 8E/8F)
 *   U+202A..U+202E  bidi embedding/override (E2 80 AA..AE)
 *   U+2066..U+2069  bidi isolates (E2 81 A6..A9)
 * The input is already known to be valid UTF-8; this is a byte-level scan of
 * the canonical encodings of exactly those code points. */
static inline BOOL rdp_clipboard_has_unsafe_format_chars(const char *text, size_t length)
{
	const unsigned char *s = (const unsigned char *)text;

	if (!s)
		return FALSE;
	for (size_t i = 0; i < length; i++)
	{
		if (s[i] == 0xC2 && i + 1 < length && s[i + 1] >= 0x80 && s[i + 1] <= 0x9F)
			return TRUE;
		if (s[i] == 0xE2 && i + 2 < length && s[i + 1] == 0x80)
		{
			const unsigned char third = s[i + 2];
			if (third == 0x8E || third == 0x8F || (third >= 0xAA && third <= 0xAE))
				return TRUE;
		}
		if (s[i] == 0xE2 && i + 2 < length && s[i + 1] == 0x81 && s[i + 2] >= 0xA6 &&
		    s[i + 2] <= 0xA9)
			return TRUE;
	}
	return FALSE;
}

/* A safe file name: one path component, <= 255 UTF-8 bytes. Rejects empty,
 * ".", "..", separators, drive-letter colon, NUL/control bytes, C1/bidi
 * formatting characters and invalid UTF-8 (contract section 5, remote->local
 * untrusted names). */
static inline BOOL rdp_clipboard_name_valid(const char *name, size_t length)
{
	if (!name || length == 0 || length > RDP_CLIPBOARD_MAX_NAME_BYTES)
		return FALSE;
	if ((length == 1 && name[0] == '.') || (length == 2 && name[0] == '.' && name[1] == '.'))
		return FALSE;
	for (size_t i = 0; i < length; i++)
	{
		const unsigned char c = (unsigned char)name[i];
		if (c < 0x20 || c == 0x7F)
			return FALSE;
		if (c == '/' || c == '\\' || c == ':')
			return FALSE;
		if (c == 0x00)
			return FALSE;
	}
	if (!rdp_clipboard_utf8_valid(name, length))
		return FALSE;
	return !rdp_clipboard_has_unsafe_format_chars(name, length);
}

/* A safe worker->Agent local file path (contract section 5, local->remote):
 * absolute, <= 1023 UTF-8 bytes, no NUL/control bytes, valid UTF-8. The file
 * type itself (regular, not a symlink) is checked with lstat by the worker. */
static inline BOOL rdp_clipboard_path_valid(const char *path, size_t length)
{
	if (!path || length == 0 || length > RDP_CLIPBOARD_MAX_PATH_BYTES)
		return FALSE;
	if (path[0] != '/')
		return FALSE;
	for (size_t i = 0; i < length; i++)
	{
		const unsigned char c = (unsigned char)path[i];
		if (c == 0x00 || c < 0x20 || c == 0x7F)
			return FALSE;
	}
	if (!rdp_clipboard_utf8_valid(path, length))
		return FALSE;
	return !rdp_clipboard_has_unsafe_format_chars(path, length);
}

/* Length of the UTF-8 sequence that starts with `lead`, or 0 when `lead` is a
 * continuation byte / invalid lead. */
static inline size_t rdp_clipboard_utf8_sequence_length(unsigned char lead)
{
	if (lead < 0x80)
		return 1;
	if ((lead & 0xE0) == 0xC0)
		return 2;
	if ((lead & 0xF0) == 0xE0)
		return 3;
	if ((lead & 0xF8) == 0xF0)
		return 4;
	return 0;
}

/* Defense-in-depth helper: derive the last safe path component from untrusted
 * input. The worker REJECTS invalid names (see rdp_clipboard_name_valid);
 * this mirrors what the Agent is additionally required to do before creating a
 * file (contract section 5, "only the sanitized last path component is used").
 *
 * Rules: take the substring after the last '/' or '\\'; drop a leading "X:"
 * drive prefix; replace bytes < 0x20, 0x7F, ':' and '\' with '_' (a UTF-8
 * multi-byte sequence is copied through byte-wise); map empty, "." and ".."
 * to "file"; truncate to RDP_CLIPBOARD_MAX_NAME_BYTES at a UTF-8 boundary.
 * Always NUL-terminates when out_size > 0. Returns the output length (<= 255). */
static inline size_t rdp_clipboard_sanitize_name(const char *input, size_t input_length, char *out,
                                                 size_t out_size)
{
	size_t start = 0, length = 0;

	if (!out || out_size == 0)
		return 0;
	out[0] = '\0';
	if (!input || input_length == 0)
	{
		if (out_size > 4)
		{
			memcpy(out, "file", 5);
			return 4;
		}
		return 0;
	}
	for (size_t i = 0; i < input_length; i++)
		if (input[i] == '/' || input[i] == '\\')
			start = i + 1;
	length = input_length - start;
	/* Drop a Windows drive prefix ("C:name"). */
	if (length >= 2 && input[start + 1] == ':' &&
	    ((input[start] >= 'A' && input[start] <= 'Z') ||
	     (input[start] >= 'a' && input[start] <= 'z')))
	{
		start += 2;
		length -= 2;
	}
	size_t written = 0;
	for (size_t i = 0; i < length && written + 1 < out_size; i++)
	{
		unsigned char c = (unsigned char)input[start + i];
		if (c < 0x20 || c == 0x7F || c == ':' || c == '\\')
			c = '_';
		out[written++] = (char)c;
		if (written >= RDP_CLIPBOARD_MAX_NAME_BYTES)
			break;
	}
	/* Truncation may have cut a multi-byte sequence: keep only complete
	 * sequences so the returned name is always valid UTF-8. */
	{
		size_t valid = 0;
		while (valid < written)
		{
			const size_t sequence =
			    rdp_clipboard_utf8_sequence_length((unsigned char)out[valid]);
			if (sequence == 0 || valid + sequence > written)
				break;
			valid += sequence;
		}
		written = valid;
	}
	out[written] = '\0';
	if (written == 0 || strcmp(out, ".") == 0 || strcmp(out, "..") == 0)
	{
		if (out_size > 4)
		{
			memcpy(out, "file", 5);
			return 4;
		}
		return 0;
	}
	return written;
}

/* ------------------------------------------------------------------------- */
/* Part C: offer limits and FILECONTENTS range validation                    */
/* ------------------------------------------------------------------------- */

/* Common count/total limits for both directions (contract section 3). */
static inline rdp_clipboard_status rdp_clipboard_check_limits(UINT32 file_count,
                                                              UINT64 total_bytes)
{
	if (file_count == 0)
		return RDP_CLIPBOARD_ERR_EMPTY;
	if (file_count > RDP_CLIPBOARD_MAX_FILES)
		return RDP_CLIPBOARD_ERR_TOO_MANY_FILES;
	if (total_bytes > RDP_CLIPBOARD_MAX_TOTAL_BYTES)
		return RDP_CLIPBOARD_ERR_TOO_LARGE;
	return RDP_CLIPBOARD_OK;
}

/* Exactly one of FILECONTENTS_SIZE / FILECONTENTS_RANGE (contract section 2). */
static inline BOOL rdp_clipboard_file_request_flags_valid(UINT32 flags)
{
	return (flags & (FILECONTENTS_SIZE | FILECONTENTS_RANGE)) != 0 &&
	       (flags & (FILECONTENTS_SIZE | FILECONTENTS_RANGE)) !=
	           (FILECONTENTS_SIZE | FILECONTENTS_RANGE);
}

/* Strict FILECONTENTS_RANGE validation (no request may cross EOF). Kept for
 * unit tests and callers that want to reject rather than clamp; the RDP
 * serving path uses rdp_clipboard_clamp_range() below because Windows clients
 * request full chunks without clamping the last one. Never reads past EOF. */
static inline rdp_clipboard_status rdp_clipboard_validate_range(UINT64 file_size, UINT64 offset,
                                                                UINT32 requested,
                                                                UINT32 max_response,
                                                                UINT32 *length_out)
{
	if (length_out)
		*length_out = 0;
	if (requested == 0 || requested > max_response)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (offset > file_size)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if ((UINT64)requested > file_size - offset)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (length_out)
		*length_out = requested;
	return RDP_CLIPBOARD_OK;
}

/* Clamp a FILECONTENTS_RANGE request at EOF, exactly like a Windows server
 * ([MS-RDPECLIP] 2.2.5.3): clients such as mstsc request FULL chunks and do not
 * clamp the last request (e.g. size 1048087: requests 262144 at offset 786432),
 * expecting a SHORT response. Returns OK with the byte count to serve:
 *   - requested == 0                 -> BAD_RANGE
 *   - offset > file_size             -> BAD_RANGE
 *   - offset == file_size            -> OK with *length_out = 0 (an empty OK
 *     response signals EOF; clients may probe offset==size for exact multiples)
 *   - offset + requested > file_size -> OK with *length_out = file_size - offset
 *   - clamped length > max_response  -> BAD_RANGE (defensive allocation bound)
 * The clamped length is <= file_size - offset, so a caller can never read past
 * EOF. */
static inline rdp_clipboard_status rdp_clipboard_clamp_range(UINT64 file_size, UINT64 offset,
                                                             UINT32 requested,
                                                             UINT32 max_response,
                                                             UINT32 *length_out)
{
	UINT64 remaining = 0;
	UINT64 length = 0;

	if (length_out)
		*length_out = 0;
	if (requested == 0)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (offset > file_size)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	remaining = file_size - offset;
	length = (UINT64)requested < remaining ? (UINT64)requested : remaining;
	if (length > max_response)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (length_out)
		*length_out = (UINT32)length;
	return RDP_CLIPBOARD_OK;
}

/* Validate one Agent-supplied local file entry before it is advertised
 * (contract section 5): absolute path, safe single-component name, size limits.
 * The worker additionally lstat()s the path (regular file, not a symlink,
 * readable, advertised size == st_size). */
static inline rdp_clipboard_status rdp_clipboard_validate_local_entry(
    const char *name, UINT32 name_length, const char *path, UINT32 path_length, UINT64 size)
{
	if (!rdp_clipboard_name_valid(name, name_length) ||
	    !rdp_clipboard_path_valid(path, path_length))
		return RDP_CLIPBOARD_ERR_BAD_NAME;
	if (size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
		return RDP_CLIPBOARD_ERR_TOO_LARGE;
	return RDP_CLIPBOARD_OK;
}

/* ------------------------------------------------------------------------- */
/* Part D: packed FileGroupDescriptorW list parse/build                      */
/* ------------------------------------------------------------------------- */

typedef struct
{
	char name[RDP_CLIPBOARD_MAX_NAME_BYTES + 1]; /* NUL-terminated UTF-8 component */
	UINT32 name_length;
	UINT64 size;
	UINT32 attributes; /* FILE_ATTRIBUTE_* from the descriptor */
} rdp_clipboard_descriptor;

/* Convert one FILEDESCRIPTORW.cFileName (UTF-16, fixed 260 WCHAR field) into a
 * validated UTF-8 single-component name. */
static inline rdp_clipboard_status rdp_clipboard_descriptor_name(const WCHAR *cFileName,
                                                                  char *out, size_t out_size,
                                                                  UINT32 *out_length)
{
	char buffer[4 * 260 + 4];
	size_t wlen = 0;

	if (out_length)
		*out_length = 0;
	if (!cFileName || !out || out_size == 0)
		return RDP_CLIPBOARD_ERR_BAD_NAME;
	while (wlen < 260 && cFileName[wlen] != 0)
		wlen++;
	if (wlen == 0 || wlen >= 260)
		return RDP_CLIPBOARD_ERR_BAD_NAME; /* empty or unterminated field */
	const SSIZE_T converted = ConvertWCharNToUtf8(cFileName, 260, buffer, sizeof(buffer));
	if (converted < 0)
		return RDP_CLIPBOARD_ERR_BAD_NAME;
	const size_t length = (size_t)converted;
	if (!rdp_clipboard_name_valid(buffer, length))
		return RDP_CLIPBOARD_ERR_BAD_NAME;
	if (length + 1 > out_size)
		return RDP_CLIPBOARD_ERR_BAD_NAME;
	memcpy(out, buffer, length);
	out[length] = '\0';
	if (out_length)
		*out_length = (UINT32)length;
	return RDP_CLIPBOARD_OK;
}

/* Parse and fully validate a packed FileGroupDescriptorW list received from the
 * RDP client (remote->local). `files` must hold capacity descriptors; on
 * success *file_count is set, on failure it is 0. Enforces the exact
 * cItems + cItems * 592 wire length (FreeRDP's parser silently stops early on
 * a bad descriptor, so the length check is what makes a malformed list fail
 * deterministically), count/size limits, regular-file attributes and the name
 * rules. */
static inline rdp_clipboard_status rdp_clipboard_parse_file_list(
    const BYTE *data, UINT32 data_length, rdp_clipboard_descriptor *files, UINT32 capacity,
    UINT32 *file_count)
{
	if (file_count)
		*file_count = 0;
	if (!data || data_length < 4 || !files || !file_count)
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;
	const UINT32 count = rdp_clipboard_read_le32(data);
	if (count == 0)
		return RDP_CLIPBOARD_ERR_EMPTY;
	if (count > RDP_CLIPBOARD_MAX_FILES)
		return RDP_CLIPBOARD_ERR_TOO_MANY_FILES;
	if (capacity < count)
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;
	if ((UINT64)data_length != 4ULL + (UINT64)count * RDP_CLIPBOARD_DESCRIPTOR_BYTES)
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;

	FILEDESCRIPTORW *parsed = NULL;
	UINT32 parsed_count = 0;
	const UINT rc = cliprdr_parse_file_list(data, data_length, &parsed, &parsed_count);
	rdp_clipboard_status status = RDP_CLIPBOARD_OK;
	UINT64 total = 0;

	if (rc != 0 || !parsed || parsed_count != count)
	{
		free(parsed);
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;
	}
	for (UINT32 i = 0; i < count; i++)
	{
		const UINT64 size =
		    ((UINT64)parsed[i].nFileSizeHigh << 32) | (UINT64)parsed[i].nFileSizeLow;
		if (parsed[i].dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
		{
			status = RDP_CLIPBOARD_ERR_NOT_REGULAR;
			break;
		}
		if (size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
		{
			status = RDP_CLIPBOARD_ERR_TOO_LARGE;
			break;
		}
		total += size;
		if (total > RDP_CLIPBOARD_MAX_TOTAL_BYTES)
		{
			status = RDP_CLIPBOARD_ERR_TOO_LARGE;
			break;
		}
		files[i].size = size;
		files[i].attributes = parsed[i].dwFileAttributes;
		status = rdp_clipboard_descriptor_name(parsed[i].cFileName, files[i].name,
		                                       sizeof(files[i].name), &files[i].name_length);
		if (status != RDP_CLIPBOARD_OK)
			break;
	}
	free(parsed);
	if (status != RDP_CLIPBOARD_OK)
	{
		*file_count = 0;
		return status;
	}
	*file_count = count;
	return RDP_CLIPBOARD_OK;
}

/* Fill one FILEDESCRIPTORW for the local->remote FileGroupDescriptorW list. */
static inline BOOL rdp_clipboard_fill_descriptor(FILEDESCRIPTORW *descriptor, const char *name,
                                                  size_t name_length, UINT64 size)
{
	char copy[RDP_CLIPBOARD_MAX_NAME_BYTES + 1];

	if (!descriptor || !rdp_clipboard_name_valid(name, name_length))
		return FALSE;
	if (size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
		return FALSE;
	memset(descriptor, 0, sizeof(*descriptor));
	descriptor->dwFlags = FD_ATTRIBUTES | FD_FILESIZE;
	descriptor->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
	descriptor->nFileSizeHigh = (UINT32)(size >> 32);
	descriptor->nFileSizeLow = (UINT32)size;
	memcpy(copy, name, name_length);
	copy[name_length] = '\0';
	const SSIZE_T wlen = ConvertUtf8ToWChar(copy, descriptor->cFileName, 260);
	if (wlen < 0)
		return FALSE;
	descriptor->cFileName[wlen] = 0;
	return TRUE;
}

/* Serialize a validated descriptor array into the packed wire format using the
 * exported FreeRDP helper (which also enforces the 2 GiB per-file rule because
 * hasHugeFileSupport is FALSE). On success `*data` is malloc-owned. */
static inline rdp_clipboard_status rdp_clipboard_build_file_list(
    const rdp_clipboard_descriptor *files, UINT32 count, BYTE **data, UINT32 *data_length)
{
	FILEDESCRIPTORW *descriptors = NULL;
	rdp_clipboard_status status = RDP_CLIPBOARD_OK;
	UINT64 total = 0;

	if (data)
		*data = NULL;
	if (data_length)
		*data_length = 0;
	if (!files || !data || !data_length)
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;
	for (UINT32 i = 0; i < count; i++)
	{
		if (files[i].size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
			return RDP_CLIPBOARD_ERR_TOO_LARGE;
		total += files[i].size;
	}
	status = rdp_clipboard_check_limits(count, total);
	if (status != RDP_CLIPBOARD_OK)
		return status;
	descriptors = (FILEDESCRIPTORW *)calloc(count ? count : 1, sizeof(FILEDESCRIPTORW));
	if (!descriptors)
		return RDP_CLIPBOARD_ERR_BAD_FORMAT;
	for (UINT32 i = 0; i < count; i++)
	{
		if (!rdp_clipboard_fill_descriptor(&descriptors[i], files[i].name, files[i].name_length,
		                                    files[i].size))
		{
			status = RDP_CLIPBOARD_ERR_BAD_NAME;
			break;
		}
	}
	if (status == RDP_CLIPBOARD_OK)
	{
		const UINT rc = cliprdr_serialize_file_list(descriptors, count, data, data_length);
		if (rc != 0 || !*data || *data_length < 4)
			status = RDP_CLIPBOARD_ERR_BAD_FORMAT;
	}
	free(descriptors);
	return status;
}

/* ------------------------------------------------------------------------- */
/* Part E: chunk assembly state machine                                      */
/* ------------------------------------------------------------------------- */

/* Receiver-side assembly state for an offer's file chunks. It enforces the
 * contract rules: chunks arrive for files in fileIndex order, each file starts
 * at offset 0, offsets strictly increase with no gaps/overlaps, and no chunk
 * crosses the advertised file size. The Agent uses the same rules; the worker
 * unit harness exercises this state machine directly. */
typedef struct
{
	UINT32 file_count;
	UINT32 file_index;
	UINT64 offset;      /* next expected offset in the current file */
	UINT64 file_size;   /* advertised size of the current file */
	UINT64 total_bytes; /* bytes accepted across all files */
	BOOL active;
	/* Explicit "a file has been started" flag. Deriving this from
	 * (total_bytes==0 && file_index==0 && offset==0) is wrong: a zero-byte
	 * FIRST file leaves exactly that state, so advancing to file 1 used to be
	 * rejected as an out-of-order file (remote->local multi-file paste with a
	 * leading 0-byte file aborted with reason=bad_state; verifier finding
	 * 2026-11-08). */
	BOOL file_started;
} rdp_clipboard_chunk_state;

static inline void rdp_clipboard_chunk_reset(rdp_clipboard_chunk_state *state)
{
	if (state)
		memset(state, 0, sizeof(*state));
}

static inline rdp_clipboard_status rdp_clipboard_chunk_begin(rdp_clipboard_chunk_state *state,
                                                              UINT32 file_count)
{
	if (!state)
		return RDP_CLIPBOARD_ERR_STATE;
	memset(state, 0, sizeof(*state));
	if (file_count == 0 || file_count > RDP_CLIPBOARD_MAX_FILES)
		return file_count == 0 ? RDP_CLIPBOARD_ERR_EMPTY : RDP_CLIPBOARD_ERR_TOO_MANY_FILES;
	state->file_count = file_count;
	state->active = TRUE;
	return RDP_CLIPBOARD_OK;
}

/* Begin (or advance to) one file of the offer. The first call must pass
 * file_index 0; later calls must pass the current file_index + 1. */
static inline rdp_clipboard_status rdp_clipboard_chunk_start_file(
    rdp_clipboard_chunk_state *state, UINT32 file_index, UINT64 file_size)
{
	if (!state || !state->active)
		return RDP_CLIPBOARD_ERR_STATE;
	if (file_index >= state->file_count)
		return RDP_CLIPBOARD_ERR_STATE;
	if (!state->file_started)
	{
		if (file_index != 0)
			return RDP_CLIPBOARD_ERR_STATE;
	}
	else if (file_index != state->file_index + 1)
		return RDP_CLIPBOARD_ERR_STATE;
	if (file_size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
		return RDP_CLIPBOARD_ERR_TOO_LARGE;
	if (state->total_bytes + file_size > RDP_CLIPBOARD_MAX_TOTAL_BYTES)
		return RDP_CLIPBOARD_ERR_TOO_LARGE;
	state->file_index = file_index;
	state->file_size = file_size;
	state->offset = 0;
	state->file_started = TRUE;
	return RDP_CLIPBOARD_OK;
}

/* Accept one chunk. Rejects out-of-order file indexes, gaps, overlaps, zero
 * length chunks and any chunk crossing the advertised file size. */
static inline rdp_clipboard_status rdp_clipboard_chunk_accept(rdp_clipboard_chunk_state *state,
                                                               UINT32 file_index, UINT64 offset,
                                                               UINT32 length)
{
	if (!state || !state->active)
		return RDP_CLIPBOARD_ERR_STATE;
	if (file_index != state->file_index)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (length == 0)
		return RDP_CLIPBOARD_ERR_BAD_RANGE;
	if (offset != state->offset)
		return RDP_CLIPBOARD_ERR_BAD_RANGE; /* gap or overlap */
	if ((UINT64)length > state->file_size - state->offset)
		return RDP_CLIPBOARD_ERR_BAD_RANGE; /* overflow past advertised size */
	state->offset += length;
	state->total_bytes += length;
	return RDP_CLIPBOARD_OK;
}

static inline BOOL rdp_clipboard_chunk_file_complete(const rdp_clipboard_chunk_state *state)
{
	return state && state->active && state->offset == state->file_size;
}

static inline BOOL rdp_clipboard_chunk_complete(const rdp_clipboard_chunk_state *state)
{
	return rdp_clipboard_chunk_file_complete(state) &&
	       state->file_index + 1 == state->file_count;
}

/* Sender-side helper for remote->local streaming: the length of the next
 * FILECONTENTS_RANGE request for the current file (0 when the file is done),
 * with *offset_out set to the request offset. */
static inline UINT32 rdp_clipboard_chunk_next_request(const rdp_clipboard_chunk_state *state,
                                                       UINT32 chunk_size, UINT64 *offset_out)
{
	UINT64 remaining = 0;

	if (offset_out)
		*offset_out = 0;
	if (!state || !state->active || chunk_size == 0)
		return 0;
	if (state->offset >= state->file_size)
		return 0;
	remaining = state->file_size - state->offset;
	if (offset_out)
		*offset_out = state->offset;
	return remaining < (UINT64)chunk_size ? (UINT32)remaining : chunk_size;
}

/* ------------------------------------------------------------------------- */
/* Part F: IPC message type 13/14/15/16 codecs (all fields big-endian)       */
/* ------------------------------------------------------------------------- */

#define RDP_CLIPBOARD_IPC_TYPE_OFFER_BEGIN 13u
#define RDP_CLIPBOARD_IPC_TYPE_CHUNK 14u
#define RDP_CLIPBOARD_IPC_TYPE_OFFER_END 15u
#define RDP_CLIPBOARD_IPC_TYPE_ENTRY 16u

#define RDP_CLIPBOARD_IPC_BEGIN_BYTES 16u
#define RDP_CLIPBOARD_IPC_END_BYTES 8u
#define RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES 18u
#define RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES 12u
#define RDP_CLIPBOARD_IPC_MAX_CHUNK_BYTES RDP_CLIPBOARD_CHUNK_BYTES

typedef struct
{
	UINT8 direction;
	UINT16 file_count;
	UINT64 total_bytes;
	UINT32 flags;
} rdp_clipboard_offer_begin;

typedef struct
{
	UINT8 direction;
	UINT8 status;
	UINT16 error_code;
	UINT32 file_count;
} rdp_clipboard_offer_end;

typedef struct
{
	UINT8 direction;
	UINT32 file_index;
	UINT64 size;
	const char *name; /* UTF-8, not NUL-terminated in the wire payload */
	UINT32 name_length;
	const char *path; /* UTF-8; empty for remote->local */
	UINT32 path_length;
} rdp_clipboard_entry;

typedef struct
{
	UINT32 file_index;
	UINT64 offset;
	const BYTE *data;
	UINT32 data_length;
} rdp_clipboard_chunk;

static inline BOOL rdp_clipboard_offer_direction_valid(UINT32 direction)
{
	return direction == RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL ||
	       direction == RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE;
}

static inline BOOL rdp_clipboard_parse_offer_begin(const BYTE *payload, UINT32 length,
                                                    rdp_clipboard_offer_begin *out)
{
	if (!payload || !out || length != RDP_CLIPBOARD_IPC_BEGIN_BYTES)
		return FALSE;
	memset(out, 0, sizeof(*out));
	out->direction = payload[0];
	if (!rdp_clipboard_offer_direction_valid(out->direction) || payload[1] != 0)
		return FALSE;
	out->file_count = rdp_clipboard_read_be16(payload + 2);
	out->total_bytes = rdp_clipboard_read_be64(payload + 4);
	out->flags = rdp_clipboard_read_be32(payload + 12);
	if (rdp_clipboard_check_limits(out->file_count, out->total_bytes) != RDP_CLIPBOARD_OK)
		return FALSE;
	return TRUE;
}

static inline void rdp_clipboard_write_offer_begin(BYTE payload[RDP_CLIPBOARD_IPC_BEGIN_BYTES],
                                                    const rdp_clipboard_offer_begin *begin)
{
	if (!payload || !begin)
		return;
	memset(payload, 0, RDP_CLIPBOARD_IPC_BEGIN_BYTES);
	payload[0] = begin->direction;
	payload[1] = 0; /* reserved */
	rdp_clipboard_write_be16(payload + 2, begin->file_count);
	rdp_clipboard_write_be64(payload + 4, begin->total_bytes);
	rdp_clipboard_write_be32(payload + 12, begin->flags);
}

static inline BOOL rdp_clipboard_parse_offer_end(const BYTE *payload, UINT32 length,
                                                  rdp_clipboard_offer_end *out)
{
	if (!payload || !out || length != RDP_CLIPBOARD_IPC_END_BYTES)
		return FALSE;
	memset(out, 0, sizeof(*out));
	out->direction = payload[0];
	if (!rdp_clipboard_offer_direction_valid(out->direction))
		return FALSE;
	out->status = payload[1];
	if (out->status > RDP_CLIPBOARD_OFFER_STATUS_ERROR)
		return FALSE;
	out->error_code = rdp_clipboard_read_be16(payload + 2);
	out->file_count = rdp_clipboard_read_be32(payload + 4);
	return TRUE;
}

static inline void rdp_clipboard_write_offer_end(BYTE payload[RDP_CLIPBOARD_IPC_END_BYTES],
                                                  const rdp_clipboard_offer_end *end)
{
	if (!payload || !end)
		return;
	memset(payload, 0, RDP_CLIPBOARD_IPC_END_BYTES);
	payload[0] = end->direction;
	payload[1] = end->status;
	rdp_clipboard_write_be16(payload + 2, end->error_code);
	rdp_clipboard_write_be32(payload + 4, end->file_count);
}

static inline UINT32 rdp_clipboard_entry_wire_length(UINT32 name_length, UINT32 path_length)
{
	return RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES + name_length + path_length;
}

/* Parse a type-16 entry payload and validate the direction, lengths and content
 * rules (single-component name; direction 2 requires an absolute path;
 * direction 1 requires an empty path). */
static inline BOOL rdp_clipboard_parse_entry(const BYTE *payload, UINT32 length,
                                              rdp_clipboard_entry *out)
{
	UINT16 name_length = 0, path_length = 0;

	if (!payload || !out || length < RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES)
		return FALSE;
	memset(out, 0, sizeof(*out));
	out->direction = payload[0];
	if (!rdp_clipboard_offer_direction_valid(out->direction) || payload[1] != 0)
		return FALSE;
	name_length = rdp_clipboard_read_be16(payload + 2);
	out->file_index = rdp_clipboard_read_be32(payload + 4);
	out->size = rdp_clipboard_read_be64(payload + 8);
	path_length = rdp_clipboard_read_be16(payload + 16);
	if (name_length == 0 || name_length > RDP_CLIPBOARD_MAX_NAME_BYTES)
		return FALSE;
	if (path_length > RDP_CLIPBOARD_MAX_PATH_BYTES)
		return FALSE;
	if (out->direction == RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL && path_length != 0)
		return FALSE;
	if (out->direction == RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE && path_length == 0)
		return FALSE;
	if (length != rdp_clipboard_entry_wire_length(name_length, path_length))
		return FALSE;
	if (out->size >= RDP_CLIPBOARD_MAX_FILE_BYTES)
		return FALSE;
	out->name = (const char *)(payload + RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES);
	out->name_length = name_length;
	out->path = out->name + name_length;
	out->path_length = path_length;
	if (out->direction == RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE)
		return rdp_clipboard_validate_local_entry(out->name, out->name_length, out->path,
		                                          out->path_length, out->size) ==
		       RDP_CLIPBOARD_OK;
	return rdp_clipboard_name_valid(out->name, name_length);
}

static inline void rdp_clipboard_write_entry(BYTE *payload, UINT32 length,
                                              const rdp_clipboard_entry *entry)
{
	if (!payload || !entry || !entry->name || length < rdp_clipboard_entry_wire_length(
	                                            entry->name_length, entry->path_length))
		return;
	memset(payload, 0, rdp_clipboard_entry_wire_length(entry->name_length, entry->path_length));
	payload[0] = entry->direction;
	payload[1] = 0; /* reserved */
	rdp_clipboard_write_be16(payload + 2, (UINT16)entry->name_length);
	rdp_clipboard_write_be32(payload + 4, entry->file_index);
	rdp_clipboard_write_be64(payload + 8, entry->size);
	rdp_clipboard_write_be16(payload + 16, (UINT16)entry->path_length);
	memcpy(payload + RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES, entry->name, entry->name_length);
	if (entry->path_length)
		memcpy(payload + RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES + entry->name_length, entry->path,
		       entry->path_length);
}

static inline BOOL rdp_clipboard_parse_chunk(const BYTE *payload, UINT32 length,
                                              rdp_clipboard_chunk *out)
{
	UINT32 data_length = 0;

	if (!payload || !out || length < RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES)
		return FALSE;
	memset(out, 0, sizeof(*out));
	out->file_index = rdp_clipboard_read_be32(payload);
	out->offset = rdp_clipboard_read_be64(payload + 4);
	data_length = length - RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES;
	if (data_length == 0 || data_length > RDP_CLIPBOARD_IPC_MAX_CHUNK_BYTES)
		return FALSE;
	out->data = payload + RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES;
	out->data_length = data_length;
	return TRUE;
}

static inline void rdp_clipboard_write_chunk(BYTE *payload, UINT32 length,
                                              const rdp_clipboard_chunk *chunk)
{
	UINT32 data_length = 0;

	if (!payload || !chunk || !chunk->data)
		return;
	data_length = chunk->data_length;
	if (data_length == 0 || data_length > RDP_CLIPBOARD_IPC_MAX_CHUNK_BYTES)
		return;
	if (length < RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES + data_length)
		return;
	rdp_clipboard_write_be32(payload, chunk->file_index);
	rdp_clipboard_write_be64(payload + 4, chunk->offset);
	memcpy(payload + RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES, chunk->data, data_length);
}

#endif /* RDP_CLIPBOARD_FILES_H */

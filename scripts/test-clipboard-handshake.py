#!/usr/bin/env python3
"""C unit harness for the worker's clipboard helpers.

Compiles small C programs against the installed FreeRDP/WinPR headers and the
worker's header-only helpers, runs them and requires exit code 0. Every C check
prints the failing expression and makes the program exit 1, so a failure is
visible in the unittest output.

Coverage:
  * clipboard_handshake.h text-clipboard callback wiring (existing path),
  * clipboard_files.h pure helpers (Issue 3 file clipboard):
    - packed FileGroupDescriptorW parse/serialize round-trip (ASCII, Chinese,
      1/2/100 files, zero-byte) and malformed-list/limit rejection (>100 files,
      >= 2 GiB, 4 GiB total, directory entry, traversal name),
    - name sanitization matrix (traversal/absolute/empty/control/long),
    - FILECONTENTS request-flag and range validation,
    - chunk assembly state machine (in-order/gap/overlap/overflow/cancel),
    - IPC message type 13/14/15/16 big-endian codecs (round-trip + malformed).
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FREERDP_INCLUDES = (
    "-I", str(ROOT / "internal/worker"),
    "-I", str(ROOT / ".deps/install/include/freerdp3"),
    "-I", str(ROOT / ".deps/install/include/winpr3"),
)
FREERDP_LIBRARIES = (
    "-L", str(ROOT / ".deps/install/lib"),
    "-lfreerdp3", "-lwinpr3",
    "-Wl,-rpath," + str(ROOT / ".deps/install/lib"),
)
PROGRAM_HEADER = r'''
#include "clipboard_files.h"
#include <stdint.h>
#include <stdio.h>
static int failures;
#define CHECK(condition) do { \
    if (!(condition)) { \
        printf("FAIL line %d: %s\n", __LINE__, #condition); \
        failures++; \
    } \
} while (0)
'''
PROGRAM_FOOTER = r'''
    if (failures) { printf("%d check(s) failed\n", failures); return 1; }
    printf("ok\n");
    return 0;
}
'''


class ClipboardHandshakeTest(unittest.TestCase):
    def compile_and_run(self, source, link=False):
        with tempfile.TemporaryDirectory(prefix="rdp-clip-c-") as directory:
            executable = Path(directory) / "case"
            command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                       "-Wno-deprecated-declarations", *FREERDP_INCLUDES]
            if link:
                command += list(FREERDP_LIBRARIES)
            result = subprocess.run(command + ["-x", "c", "-", "-o", str(executable)],
                                    input=source, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, "C compile failed:\n" + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0,
                             "C checks failed:\n" + result.stdout + result.stderr)

    def run_clipboard_program(self, body, link=False):
        self.compile_and_run(PROGRAM_HEADER + "int main(void) {\n" + body + PROGRAM_FOOTER,
                             link=link)

    def test_acknowledges_formats_then_requests_unicode_from_client(self):
        source = r'''
#include "clipboard_handshake.h"
static int state;
static UINT ack(CliprdrServerContext *c, const CLIPRDR_FORMAT_LIST_RESPONSE *r) {
  (void)c; if (state != 0 || !(r->common.msgFlags & CB_RESPONSE_OK)) return 1;
  state = 1; return CHANNEL_RC_OK;
}
static UINT request(CliprdrServerContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *r) {
  (void)c; if (state != 1 || r->requestedFormatId != 13) return 2;
  state = 2; return CHANNEL_RC_OK;
}
static UINT ready(CliprdrServerContext *c, const CLIPRDR_MONITOR_READY *r) {
  (void)c; (void)r; return CHANNEL_RC_OK;
}
static UINT incoming(CliprdrServerContext *c, const CLIPRDR_FORMAT_DATA_REQUEST *r) {
  (void)c; (void)r; return CHANNEL_RC_OK;
}
int main(void) {
  CliprdrServerContext c = {0};
  c.ServerFormatListResponse = ack;
  c.ServerFormatDataRequest = request;
  c.MonitorReady = ready;
  rdp_clipboard_set_callbacks(&c, incoming);
  if (c.MonitorReady != ready || c.ServerFormatDataRequest != request ||
      c.ClientFormatDataRequest != incoming) return 3;
  CLIPRDR_FORMAT format = {0}; format.formatId = 13;
  CLIPRDR_FORMAT_LIST list = {0}; list.numFormats = 1; list.formats = &format;
  if (rdp_clipboard_client_formats(&c, &list) != CHANNEL_RC_OK || state != 2) return 1;
  state = 0; list.numFormats = 0; list.formats = 0;
  if (rdp_clipboard_client_formats(&c, &list) != CHANNEL_RC_OK || state != 1) return 2;
  return 0;
}
'''
        self.compile_and_run(source)

    def test_name_validation_and_sanitization_matrix(self):
        self.run_clipboard_program(r'''
    /* --- name validation: one safe path component ------------------------ */
    CHECK(rdp_clipboard_name_valid("a.txt", 5));
    CHECK(rdp_clipboard_name_valid("\xe4\xb8\xad\xe6\x96\x87.txt", 10)); /* 中文.txt */
    CHECK(rdp_clipboard_name_valid("-leading-dash", 13)); /* leading '-' allowed */
    CHECK(rdp_clipboard_name_valid("a b (1).txt", 11));
    CHECK(!rdp_clipboard_name_valid("", 0));
    CHECK(!rdp_clipboard_name_valid(".", 1));
    CHECK(!rdp_clipboard_name_valid("..", 2));
    CHECK(!rdp_clipboard_name_valid("../x", 4));
    CHECK(!rdp_clipboard_name_valid("/absolute", 9));
    CHECK(!rdp_clipboard_name_valid("a/b", 3));
    CHECK(!rdp_clipboard_name_valid("a\x5c" "b", 3));   /* backslash */
    CHECK(!rdp_clipboard_name_valid("C:\x5c" "x", 4));  /* drive prefix */
    CHECK(!rdp_clipboard_name_valid("a:b", 3));         /* drive/ADS colon */
    CHECK(!rdp_clipboard_name_valid("a\nb", 3));        /* control byte */
    CHECK(!rdp_clipboard_name_valid("\x01", 1));
    CHECK(!rdp_clipboard_name_valid("\x7f", 1));
    /* invalid UTF-8: stray continuation, truncated, overlong, surrogate, >U+10FFFF */
    CHECK(!rdp_clipboard_name_valid("\x80", 1));
    CHECK(!rdp_clipboard_name_valid("\xe4\xb8", 2));
    CHECK(!rdp_clipboard_name_valid("\xc0\xaf", 2));
    CHECK(!rdp_clipboard_name_valid("\xed\xa0\x80", 3));
    CHECK(!rdp_clipboard_name_valid("\xf4\x90\x80\x80", 4));
    CHECK(!rdp_clipboard_name_valid("a\x00" "b", 3));
    /* 255 UTF-8 bytes allowed, 256 rejected */
    char long_name[257];
    memset(long_name, 'a', sizeof(long_name));
    CHECK(rdp_clipboard_name_valid(long_name, 255));
    CHECK(!rdp_clipboard_name_valid(long_name, 256));
    /* unsafe non-ASCII formatting/control code points (Issue 3 verifier fix):
     * C1 controls U+0080..U+009F, LRM/RLM, bidi embeddings/overrides/isolates */
    CHECK(!rdp_clipboard_name_valid("\xc2\x85", 2));            /* U+0085 NEL */
    CHECK(!rdp_clipboard_name_valid("a\xc2\x85" "b", 4));
    CHECK(!rdp_clipboard_name_valid("\xc2\x80", 2));            /* U+0080 C1 start */
    CHECK(!rdp_clipboard_name_valid("\xc2\x9f", 2));            /* U+009F C1 end */
    CHECK(!rdp_clipboard_name_valid("\xe2\x80\x8e", 3));       /* U+200E LRM */
    CHECK(!rdp_clipboard_name_valid("\xe2\x80\x8f", 3));       /* U+200F RLM */
    CHECK(!rdp_clipboard_name_valid("\xe2\x80\xaa", 3));       /* U+202A LRE */
    CHECK(!rdp_clipboard_name_valid("\xe2\x80\xae", 3));       /* U+202E RLO */
    CHECK(!rdp_clipboard_name_valid("x\xe2\x80\xae" "y", 5));
    CHECK(!rdp_clipboard_name_valid("\xe2\x81\xa6", 3));       /* U+2066 LRI */
    CHECK(!rdp_clipboard_name_valid("\xe2\x81\xa9", 3));       /* U+2069 PDI */
    /* ordinary non-ASCII text stays valid: U+00A0, U+202F, Chinese */
    CHECK(rdp_clipboard_name_valid("\xc2\xa0", 2));             /* NBSP */
    CHECK(rdp_clipboard_name_valid("\xe2\x80\xaf", 3));        /* U+202F */
    CHECK(rdp_clipboard_name_valid("\xe4\xb8\xad\xe6\x96\x87.txt", 10));
    /* --- path validation (local->remote Agent paths) -------------------- */
    CHECK(rdp_clipboard_path_valid("/tmp/f.txt", 10));
    CHECK(rdp_clipboard_path_valid("/tmp/\xe4\xb8\xad\xe6\x96\x87.txt", 15));
    CHECK(!rdp_clipboard_path_valid("relative/f.txt", 14));
    CHECK(!rdp_clipboard_path_valid("", 0));
    CHECK(!rdp_clipboard_path_valid("/tmp/a\nb", 8));
    CHECK(!rdp_clipboard_path_valid("/tmp/\xc2\x85" "x", 8));   /* C1 in path */
    CHECK(!rdp_clipboard_path_valid("/tmp/\xe2\x80\xae" "f", 9)); /* bidi in path */
    CHECK(rdp_clipboard_path_valid("/tmp/\xe2\x80\xaf" "f", 9));  /* U+202F ok */
    /* --- sanitization: untrusted remote name -> safe component ----------- */
    char out[256];
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("../../etc/passwd", 16, out, sizeof(out)) == 6);
    CHECK(strcmp(out, "passwd") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("/absolute/path/x.txt", 20, out, sizeof(out)) == 5);
    CHECK(strcmp(out, "x.txt") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("C:\x5c" "Users\x5c" "me\x5c" "evil.txt", 20,
                                      out, sizeof(out)) == 8);
    CHECK(strcmp(out, "evil.txt") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("C:evil.txt", 10, out, sizeof(out)) == 8);
    CHECK(strcmp(out, "evil.txt") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("", 0, out, sizeof(out)) == 4);
    CHECK(strcmp(out, "file") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name(".", 1, out, sizeof(out)) == 4);
    CHECK(strcmp(out, "file") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("..", 2, out, sizeof(out)) == 4);
    CHECK(strcmp(out, "file") == 0);
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name("a\tb", 3, out, sizeof(out)) == 3);
    CHECK(strcmp(out, "a_b") == 0);
    CHECK(rdp_clipboard_sanitize_name("file:name", 9, out, sizeof(out)) == 9);
    CHECK(strcmp(out, "file_name") == 0);
    CHECK(rdp_clipboard_sanitize_name("\xe4\xb8\xad\xe6\x96\x87.txt", 10, out,
                                      sizeof(out)) == 10);
    CHECK(strcmp(out, "\xe4\xb8\xad\xe6\x96\x87.txt") == 0);
    /* long input truncates to <= 255 bytes without splitting a UTF-8 sequence;
     * the result must not depend on the caller's output buffer contents. */
    char long_input[300];
    memset(long_input, 'x', sizeof(long_input));
    memset(out, 0x5A, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name(long_input, 300, out, sizeof(out)) == 255);
    CHECK(rdp_clipboard_utf8_valid(out, 255));
    memset(out, 0x80, sizeof(out)); /* continuation-byte garbage must not matter */
    CHECK(rdp_clipboard_sanitize_name(long_input, 300, out, sizeof(out)) == 255);
    CHECK(rdp_clipboard_utf8_valid(out, 255));
    /* truncation landing in the middle of 4-byte sequences backs off to the
     * last complete character: 100 x U+1F600 (400 bytes) -> 252 bytes. */
    char emoji_input[400];
    for (int i = 0; i < 100; i++)
        memcpy(emoji_input + (size_t)i * 4, "\xF0\x9F\x98\x80", 4);
    memset(out, 0x80, sizeof(out));
    CHECK(rdp_clipboard_sanitize_name(emoji_input, 400, out, sizeof(out)) == 252);
    CHECK(rdp_clipboard_utf8_valid(out, 252));
    /* small output buffer is always NUL-terminated */
    char small[5];
    memset(small, 0x5A, sizeof(small));
    CHECK(rdp_clipboard_sanitize_name("abcdefgh", 8, small, sizeof(small)) == 4);
    CHECK(strcmp(small, "abcd") == 0);
    CHECK(rdp_clipboard_sanitize_name("x", 1, small, 1) == 0);
    CHECK(small[0] == '\0');
''')

    def test_filcontents_range_and_limits(self):
        self.run_clipboard_program(r'''
    UINT32 length = 0;
    CHECK(rdp_clipboard_validate_range(100, 0, 100, 65536, &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 100);
    CHECK(rdp_clipboard_validate_range(100, 50, 50, 65536, &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 50);
    CHECK(rdp_clipboard_validate_range(10, 5, 5, 65536, &length) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_validate_range(100, 50, 51, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100, 100, 1, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100, 101, 1, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100, 0, 0, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100, 0, 65537, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100, 0, 100, 0, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(0, 0, 1, 65536, &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(UINT64_MAX, UINT64_MAX - 4, 4, 65536, &length) ==
          RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_validate_range(UINT64_MAX, UINT64_MAX - 3, 4, 65536, &length) ==
          RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(100000, 0, 65536, 65536, &length) ==
          RDP_CLIPBOARD_OK);
    CHECK(length == 65536);
    /* FILECONTENTS request flags: exactly one of SIZE / RANGE */
    CHECK(rdp_clipboard_file_request_flags_valid(FILECONTENTS_SIZE));
    CHECK(rdp_clipboard_file_request_flags_valid(FILECONTENTS_RANGE));
    CHECK(!rdp_clipboard_file_request_flags_valid(FILECONTENTS_SIZE | FILECONTENTS_RANGE));
    CHECK(!rdp_clipboard_file_request_flags_valid(0));
    CHECK(!rdp_clipboard_file_request_flags_valid(0x00000004));
    /* offer limits: 100 files, 4 GiB total, 2 GiB per file (== rejected) */
    CHECK(rdp_clipboard_check_limits(1, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_check_limits(100, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_check_limits(100, RDP_CLIPBOARD_MAX_TOTAL_BYTES) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_check_limits(0, 0) == RDP_CLIPBOARD_ERR_EMPTY);
    CHECK(rdp_clipboard_check_limits(101, 0) == RDP_CLIPBOARD_ERR_TOO_MANY_FILES);
    CHECK(rdp_clipboard_check_limits(1, RDP_CLIPBOARD_MAX_TOTAL_BYTES + 1) ==
          RDP_CLIPBOARD_ERR_TOO_LARGE);
    /* local->remote Agent entries */
    CHECK(rdp_clipboard_validate_local_entry("f.txt", 5, "/tmp/f.txt", 10, 3) ==
          RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_validate_local_entry("f.txt", 5, "relative/f.txt", 14, 3) ==
          RDP_CLIPBOARD_ERR_BAD_NAME);
    CHECK(rdp_clipboard_validate_local_entry("../f", 4, "/tmp/f", 6, 3) ==
          RDP_CLIPBOARD_ERR_BAD_NAME);
    CHECK(rdp_clipboard_validate_local_entry("f.txt", 5, "/tmp/f.txt", 10,
                                             RDP_CLIPBOARD_MAX_FILE_BYTES) ==
          RDP_CLIPBOARD_ERR_TOO_LARGE);
    CHECK(rdp_clipboard_validate_local_entry("f.txt", 5, "/tmp/f.txt", 10,
                                             RDP_CLIPBOARD_MAX_FILE_BYTES - 1) ==
          RDP_CLIPBOARD_OK);
    /* log-token mapping used by event=clipboard_file_rejected reason=... */
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_TOO_MANY_FILES),
                 "too_many_files") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_TOO_LARGE), "too_large") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_BAD_NAME), "bad_name") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_NOT_REGULAR), "not_regular") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_UNREADABLE), "unreadable") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_SIZE_MISMATCH),
                 "size_mismatch") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_BAD_RANGE), "bad_range") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_IPC), "ipc_failed") == 0);
    CHECK(strcmp(rdp_clipboard_status_reason(RDP_CLIPBOARD_ERR_CLIENT), "client_failed") == 0);
    /* Windows/mstsc EOF clamp (field regression 2026-11-08): a client requests
     * a FULL chunk even when it runs past EOF; the serve path must clamp to the
     * remaining bytes and return a short response instead of bad_range. The
     * strict rdp_clipboard_validate_range above stays unchanged for clients
     * that require exact responses. */
    CHECK(rdp_clipboard_clamp_range(1048087, 0, 262144, 4u * 1024u * 1024u, &length) ==
          RDP_CLIPBOARD_OK);
    CHECK(length == 262144);
    CHECK(rdp_clipboard_clamp_range(1048087, 786432, 262144, 4u * 1024u * 1024u,
                                    &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 261655); /* short tail: 1048087 - 786432 */
    CHECK(rdp_clipboard_clamp_range(1048576, 786432, 262144, 4u * 1024u * 1024u,
                                    &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 262144); /* exact multiple: nothing to clamp */
    CHECK(rdp_clipboard_clamp_range(100, 100, 262144, 65536u, &length) ==
          RDP_CLIPBOARD_OK);
    CHECK(length == 0); /* offset==size: empty OK response (EOF) */
    CHECK(rdp_clipboard_clamp_range(100, 101, 1, 65536u, &length) ==
          RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_clamp_range(100, 0, 0, 65536u, &length) ==
          RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_clamp_range(0, 0, 0, 65536u, &length) ==
          RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_validate_range(1048087, 786432, 262144, 4u * 1024u * 1024u,
                                       &length) == RDP_CLIPBOARD_ERR_BAD_RANGE);
''')

    def test_file_list_parse_serialize_round_trip(self):
        self.run_clipboard_program(r'''
    rdp_clipboard_descriptor files[101];
    rdp_clipboard_descriptor parsed[100];
    UINT32 count = 0;
    BYTE *data = NULL;
    UINT32 length = 0;

    /* one ASCII file */
    memset(files, 0, sizeof(files));
    strcpy(files[0].name, "hello.txt");
    files[0].name_length = (UINT32)strlen(files[0].name);
    files[0].size = 3;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(data != NULL && length == 4 + RDP_CLIPBOARD_DESCRIPTOR_BYTES);
    CHECK(data[0] == 1 && data[1] == 0 && data[2] == 0 && data[3] == 0); /* cItems LE */
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(count == 1);
    CHECK(strcmp(parsed[0].name, "hello.txt") == 0);
    CHECK(parsed[0].name_length == 9 && parsed[0].size == 3);
    free(data);

    /* zero-byte file */
    files[0].size = 0;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(count == 1 && parsed[0].size == 0);
    CHECK(strcmp(parsed[0].name, "hello.txt") == 0);
    free(data);

    /* Chinese file name */
    memset(files, 0, sizeof(files));
    strcpy(files[0].name, "\xe4\xb8\xad\xe6\x96\x87.txt"); /* 中文.txt */
    files[0].name_length = (UINT32)strlen(files[0].name);
    files[0].size = 123;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(count == 1 && parsed[0].size == 123);
    CHECK(strcmp(parsed[0].name, files[0].name) == 0);
    free(data);

    /* two files */
    memset(files, 0, sizeof(files));
    strcpy(files[0].name, "a.bin");
    files[0].name_length = (UINT32)strlen(files[0].name);
    files[0].size = 0;
    strcpy(files[1].name, "space name.txt");
    files[1].name_length = (UINT32)strlen(files[1].name);
    files[1].size = 123456789;
    CHECK(rdp_clipboard_build_file_list(files, 2, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 4 + 2 * RDP_CLIPBOARD_DESCRIPTOR_BYTES);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(count == 2);
    CHECK(strcmp(parsed[0].name, "a.bin") == 0 && parsed[0].size == 0);
    CHECK(strcmp(parsed[1].name, "space name.txt") == 0 && parsed[1].size == 123456789);
    free(data);

    /* 100 files */
    memset(files, 0, sizeof(files));
    for (UINT32 i = 0; i < 100; i++) {
        snprintf(files[i].name, sizeof(files[i].name), "file%03u.bin", i);
        files[i].name_length = (UINT32)strlen(files[i].name);
        files[i].size = (UINT64)i * 1000;
    }
    CHECK(rdp_clipboard_build_file_list(files, 100, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(length == 4U + 100U * RDP_CLIPBOARD_DESCRIPTOR_BYTES);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(count == 100);
    for (UINT32 i = 0; i < 100; i++) {
        char expected[32];
        snprintf(expected, sizeof(expected), "file%03u.bin", i);
        CHECK(strcmp(parsed[i].name, expected) == 0);
        CHECK(parsed[i].size == (UINT64)i * 1000);
    }
    free(data);
    data = NULL;

    /* build-side limits (101 entries must be rejected before any fill) */
    memset(files, 0, sizeof(files));
    CHECK(rdp_clipboard_build_file_list(files, 101, &data, &length) ==
          RDP_CLIPBOARD_ERR_TOO_MANY_FILES);
    CHECK(rdp_clipboard_build_file_list(files, 0, &data, &length) ==
          RDP_CLIPBOARD_ERR_EMPTY);
    strcpy(files[0].name, "limit.bin");
    files[0].name_length = (UINT32)strlen(files[0].name);
    files[0].size = RDP_CLIPBOARD_MAX_FILE_BYTES;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) ==
          RDP_CLIPBOARD_ERR_TOO_LARGE);
    files[0].size = 0;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) == RDP_CLIPBOARD_OK);
    free(data);
    data = NULL;

    /* FILEDESCRIPTORW fill */
    FILEDESCRIPTORW descriptor;
    CHECK(rdp_clipboard_fill_descriptor(&descriptor, "ok.txt", 6, 42));
    CHECK(descriptor.nFileSizeLow == 42 && descriptor.nFileSizeHigh == 0);
    CHECK((descriptor.dwFlags & (FD_ATTRIBUTES | FD_FILESIZE)) ==
          (FD_ATTRIBUTES | FD_FILESIZE));
    CHECK(!rdp_clipboard_fill_descriptor(&descriptor, "a/b", 3, 0));
    CHECK(!rdp_clipboard_fill_descriptor(&descriptor, "ok.txt", 6,
                                         RDP_CLIPBOARD_MAX_FILE_BYTES));

    /* malformed packed lists */
    BYTE empty_list[4] = {0, 0, 0, 0};
    CHECK(rdp_clipboard_parse_file_list(empty_list, 4, parsed, 100, &count) ==
          RDP_CLIPBOARD_ERR_EMPTY);
    BYTE too_many_list[4] = {101, 0, 0, 0}; /* little-endian cItems = 101 */
    CHECK(rdp_clipboard_parse_file_list(too_many_list, 4, parsed, 100, &count) ==
          RDP_CLIPBOARD_ERR_TOO_MANY_FILES);
    CHECK(rdp_clipboard_parse_file_list(NULL, 0, parsed, 100, &count) ==
          RDP_CLIPBOARD_ERR_BAD_FORMAT);
    CHECK(rdp_clipboard_parse_file_list(empty_list, 2, parsed, 100, &count) ==
          RDP_CLIPBOARD_ERR_BAD_FORMAT);
    CHECK(rdp_clipboard_parse_file_list(too_many_list, 4, parsed, 0, &count) ==
          RDP_CLIPBOARD_ERR_TOO_MANY_FILES);

    /* valid single-file list: exact wire length is enforced */
    memset(files, 0, sizeof(files));
    strcpy(files[0].name, "mutate.txt");
    files[0].name_length = (UINT32)strlen(files[0].name);
    files[0].size = 5;
    CHECK(rdp_clipboard_build_file_list(files, 1, &data, &length) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 100, &count) ==
          RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_parse_file_list(data, length - 1, parsed, 100, &count) ==
          RDP_CLIPBOARD_ERR_BAD_FORMAT);
    CHECK(rdp_clipboard_parse_file_list(data, length, parsed, 0, &count) ==
          RDP_CLIPBOARD_ERR_BAD_FORMAT);
    BYTE *copy = (BYTE *)malloc(length);
    CHECK(copy != NULL);
    if (copy) {
        /* directory attribute -> NOT_REGULAR (dwFileAttributes at descriptor+36) */
        memcpy(copy, data, length);
        copy[4 + 36] = 0x10; /* FILE_ATTRIBUTE_DIRECTORY */
        CHECK(rdp_clipboard_parse_file_list(copy, length, parsed, 100, &count) ==
              RDP_CLIPBOARD_ERR_NOT_REGULAR);
        /* >= 2 GiB -> TOO_LARGE (nFileSizeLow at descriptor+68, little-endian) */
        memcpy(copy, data, length);
        copy[4 + 68] = 0x00;
        copy[4 + 69] = 0x00;
        copy[4 + 70] = 0x00;
        copy[4 + 71] = 0x80;
        CHECK(rdp_clipboard_parse_file_list(copy, length, parsed, 100, &count) ==
              RDP_CLIPBOARD_ERR_TOO_LARGE);
        /* traversal name -> BAD_NAME (cFileName at descriptor+72, UTF-16LE) */
        memcpy(copy, data, length);
        static const UINT16 bad_name[] = {'.', '.', '/', 'x', 0};
        memcpy(copy + 4 + 72, bad_name, sizeof(bad_name));
        CHECK(rdp_clipboard_parse_file_list(copy, length, parsed, 100, &count) ==
              RDP_CLIPBOARD_ERR_BAD_NAME);
        free(copy);
    }
    free(data);
''', link=True)

    def test_chunk_assembly_state_machine(self):
        self.run_clipboard_program(r'''
    rdp_clipboard_chunk_state state;
    memset(&state, 0, sizeof(state));
    CHECK(!state.active);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 10) == RDP_CLIPBOARD_ERR_STATE);
    CHECK(rdp_clipboard_chunk_begin(&state, 2) == RDP_CLIPBOARD_OK);
    CHECK(state.active && state.file_count == 2);
    CHECK(rdp_clipboard_chunk_begin(&state, 0) == RDP_CLIPBOARD_ERR_EMPTY);
    CHECK(!state.active);
    CHECK(rdp_clipboard_chunk_begin(&state, 101) == RDP_CLIPBOARD_ERR_TOO_MANY_FILES);
    CHECK(!state.active);
    CHECK(rdp_clipboard_chunk_begin(&state, 2) == RDP_CLIPBOARD_OK);

    /* first file must be index 0, then in-order */
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 10) == RDP_CLIPBOARD_ERR_STATE);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 10) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 4) == RDP_CLIPBOARD_OK);
    CHECK(!rdp_clipboard_chunk_file_complete(&state));
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 4, 6) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_file_complete(&state));
    CHECK(!rdp_clipboard_chunk_complete(&state));

    /* second file: gap/overlap/zero/overflow/wrong index are rejected */
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 5) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 1) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 1, 1) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 0, 0) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 0, 6) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 0, 3) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 3, 2) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_complete(&state));

    /* skipping a file index is rejected */
    CHECK(rdp_clipboard_chunk_begin(&state, 3) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 2, 1) == RDP_CLIPBOARD_ERR_STATE);

    /* per-file limit: >= 2 GiB is rejected at start_file */
    CHECK(rdp_clipboard_chunk_begin(&state, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, RDP_CLIPBOARD_MAX_FILE_BYTES) ==
          RDP_CLIPBOARD_ERR_TOO_LARGE);
    /* total limit: accept two ~2 GiB files (4 GiB - 2 bytes), then a third file
     * pushes the advertised offer total past 4 GiB and must be rejected. */
    CHECK(rdp_clipboard_chunk_begin(&state, 3) == RDP_CLIPBOARD_OK);
    for (UINT32 file = 0; file < 2; file++) {
        CHECK(rdp_clipboard_chunk_start_file(&state, file,
                                             RDP_CLIPBOARD_MAX_FILE_BYTES - 1) ==
              RDP_CLIPBOARD_OK);
        UINT64 remaining = RDP_CLIPBOARD_MAX_FILE_BYTES - 1;
        UINT64 offset = 0;
        while (remaining) {
            UINT32 step = remaining < 65524 ? (UINT32)remaining : 65524;
            if (rdp_clipboard_chunk_accept(&state, file, offset, step) != RDP_CLIPBOARD_OK)
                break;
            offset += step;
            remaining -= step;
        }
        CHECK(rdp_clipboard_chunk_file_complete(&state));
    }
    CHECK(rdp_clipboard_chunk_start_file(&state, 2, 3) == RDP_CLIPBOARD_ERR_TOO_LARGE);
    /* cancel: a new begin implicitly supersedes an in-progress offer */
    CHECK(rdp_clipboard_chunk_begin(&state, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 7) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_begin(&state, 1) == RDP_CLIPBOARD_OK);
    CHECK(state.offset == 0 && state.file_index == 0 && state.total_bytes == 0);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 5, 1) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 7) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_file_complete(&state) == FALSE);

    /* sender-side next-request helper */
    CHECK(rdp_clipboard_chunk_begin(&state, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 100000) == RDP_CLIPBOARD_OK);
    UINT64 offset = 999;
    CHECK(rdp_clipboard_chunk_next_request(&state, 65524, &offset) == 65524);
    CHECK(offset == 0);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 65524) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_next_request(&state, 65524, &offset) == 34476);
    CHECK(offset == 65524);
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 65524, 34476) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_next_request(&state, 65524, &offset) == 0);
    CHECK(offset == 0);
    CHECK(rdp_clipboard_chunk_next_request(NULL, 65524, &offset) == 0);
    /* zero-byte FIRST file: start_file(0,0) leaves offset==0/total_bytes==0,
     * which used to be mistaken for "no file started" and rejected the advance
     * to file 1 as out-of-order (multi-file paste with a leading empty file). */
    CHECK(rdp_clipboard_chunk_begin(&state, 2) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_file_complete(&state));
    CHECK(!rdp_clipboard_chunk_complete(&state));
    CHECK(rdp_clipboard_chunk_accept(&state, 0, 0, 1) == RDP_CLIPBOARD_ERR_BAD_RANGE);
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 128) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 1, 0, 128) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_complete(&state));

    /* two leading zero-byte files, then a 1024-byte file */
    CHECK(rdp_clipboard_chunk_begin(&state, 3) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_file_complete(&state));
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_file_complete(&state));
    CHECK(!rdp_clipboard_chunk_complete(&state));
    CHECK(rdp_clipboard_chunk_start_file(&state, 2, 1024) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_accept(&state, 2, 0, 1024) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_complete(&state));

    /* out-of-order advance is still rejected with the explicit started flag */
    CHECK(rdp_clipboard_chunk_begin(&state, 3) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 0, 0) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 2, 1) == RDP_CLIPBOARD_ERR_STATE);
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 1) == RDP_CLIPBOARD_OK);
    CHECK(rdp_clipboard_chunk_start_file(&state, 1, 2) == RDP_CLIPBOARD_ERR_STATE);
''')

    def test_ipc_file_clipboard_codecs(self):
        self.run_clipboard_program(r'''
    BYTE payload[65536];
    BYTE malformed[16];

    /* --- type 13: offer begin (16 bytes, big-endian) --------------------- */
    rdp_clipboard_offer_begin begin = {RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL, 2, 12345, 0};
    rdp_clipboard_offer_begin parsed_begin;
    rdp_clipboard_write_offer_begin(payload, &begin);
    CHECK(payload[0] == 1 && payload[1] == 0);
    CHECK(payload[2] == 0 && payload[3] == 2);        /* fileCount BE */
    CHECK(payload[12] == 0 && payload[13] == 0 && payload[14] == 0 && payload[15] == 0);
    CHECK(rdp_clipboard_parse_offer_begin(payload, RDP_CLIPBOARD_IPC_BEGIN_BYTES,
                                          &parsed_begin));
    CHECK(parsed_begin.direction == 1 && parsed_begin.file_count == 2);
    CHECK(parsed_begin.total_bytes == 12345 && parsed_begin.flags == 0);
    memcpy(malformed, payload, 16);
    malformed[1] = 1; /* reserved must be 0 */
    CHECK(!rdp_clipboard_parse_offer_begin(malformed, 16, &parsed_begin));
    memcpy(malformed, payload, 16);
    malformed[0] = 3; /* invalid direction */
    CHECK(!rdp_clipboard_parse_offer_begin(malformed, 16, &parsed_begin));
    memcpy(malformed, payload, 16);
    malformed[0] = 0;
    CHECK(!rdp_clipboard_parse_offer_begin(malformed, 16, &parsed_begin));
    CHECK(!rdp_clipboard_parse_offer_begin(payload, 12, &parsed_begin));
    CHECK(!rdp_clipboard_parse_offer_begin(NULL, 16, &parsed_begin));
    begin.file_count = 0;
    rdp_clipboard_write_offer_begin(payload, &begin);
    CHECK(!rdp_clipboard_parse_offer_begin(payload, 16, &parsed_begin));
    begin.file_count = 101;
    rdp_clipboard_write_offer_begin(payload, &begin);
    CHECK(!rdp_clipboard_parse_offer_begin(payload, 16, &parsed_begin));
    begin.file_count = 1;
    begin.total_bytes = RDP_CLIPBOARD_MAX_TOTAL_BYTES + 1;
    rdp_clipboard_write_offer_begin(payload, &begin);
    CHECK(!rdp_clipboard_parse_offer_begin(payload, 16, &parsed_begin));

    /* --- type 15: offer end (8 bytes, big-endian) ----------------------- */
    rdp_clipboard_offer_end end = {RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE,
                                   RDP_CLIPBOARD_OFFER_STATUS_COMPLETE, 0, 3};
    rdp_clipboard_offer_end parsed_end;
    rdp_clipboard_write_offer_end(payload, &end);
    CHECK(rdp_clipboard_parse_offer_end(payload, RDP_CLIPBOARD_IPC_END_BYTES, &parsed_end));
    CHECK(parsed_end.direction == 2 && parsed_end.status == 0);
    CHECK(parsed_end.error_code == 0 && parsed_end.file_count == 3);
    memcpy(malformed, payload, 8);
    malformed[1] = 3; /* invalid status */
    CHECK(!rdp_clipboard_parse_offer_end(malformed, 8, &parsed_end));
    memcpy(malformed, payload, 8);
    malformed[0] = 0; /* invalid direction */
    CHECK(!rdp_clipboard_parse_offer_end(malformed, 8, &parsed_end));
    CHECK(!rdp_clipboard_parse_offer_end(payload, 7, &parsed_end));
    CHECK(!rdp_clipboard_parse_offer_end(NULL, 8, &parsed_end));

    /* --- type 16: file entry (18-byte header + name + path) ------------- */
    const char *name_cn = "\xe4\xb8\xad\xe6\x96\x87.txt"; /* 中文.txt, 10 bytes */
    const UINT32 name_length = 10;
    rdp_clipboard_entry entry = {RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL, 0, 3,
                                 name_cn, name_length, "", 0};
    rdp_clipboard_entry parsed_entry;
    UINT32 wire = rdp_clipboard_entry_wire_length(name_length, 0);
    CHECK(wire == RDP_CLIPBOARD_IPC_ENTRY_HEADER_BYTES + 10);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    CHECK(parsed_entry.direction == 1 && parsed_entry.file_index == 0);
    CHECK(parsed_entry.size == 3 && parsed_entry.name_length == name_length);
    CHECK(memcmp(parsed_entry.name, name_cn, name_length) == 0);
    CHECK(parsed_entry.path_length == 0);
    /* direction 2 must carry an absolute path */
    const char *path_cn = "/tmp/\xe4\xb8\xad\xe6\x96\x87.txt";
    const UINT32 path_length = 15;
    entry.direction = RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE;
    entry.path = path_cn;
    entry.path_length = path_length;
    wire = rdp_clipboard_entry_wire_length(name_length, path_length);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    CHECK(parsed_entry.direction == 2 && parsed_entry.path_length == path_length);
    CHECK(memcmp(parsed_entry.path, path_cn, path_length) == 0);
    /* invalid entries: direction 1 with a path, direction 2 without one,
     * traversal name, relative path, oversized file, truncated payload */
    entry.direction = RDP_CLIPBOARD_DIRECTION_REMOTE_TO_LOCAL;
    entry.path = path_cn;
    entry.path_length = path_length;
    wire = rdp_clipboard_entry_wire_length(name_length, path_length);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(!rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    entry.direction = RDP_CLIPBOARD_DIRECTION_LOCAL_TO_REMOTE;
    entry.path = "";
    entry.path_length = 0;
    wire = rdp_clipboard_entry_wire_length(name_length, 0);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(!rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    entry.path = "relative/x";
    entry.path_length = 10;
    wire = rdp_clipboard_entry_wire_length(name_length, 10);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(!rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    entry.path = "/tmp/x";
    entry.path_length = 6;
    entry.name = "../x";
    entry.name_length = 4;
    wire = rdp_clipboard_entry_wire_length(4, 6);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(!rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    entry.name = name_cn;
    entry.name_length = name_length;
    entry.size = RDP_CLIPBOARD_MAX_FILE_BYTES;
    wire = rdp_clipboard_entry_wire_length(name_length, 6);
    rdp_clipboard_write_entry(payload, wire, &entry);
    CHECK(!rdp_clipboard_parse_entry(payload, wire, &parsed_entry));
    CHECK(!rdp_clipboard_parse_entry(payload, wire - 1, &parsed_entry));

    /* --- type 14: file chunk (12-byte header + data, <= 65524) ---------- */
    BYTE chunk_data[RDP_CLIPBOARD_CHUNK_BYTES];
    for (size_t i = 0; i < sizeof(chunk_data); i++)
        chunk_data[i] = (BYTE)((i * 37u + 7) & 0xFFu);
    rdp_clipboard_chunk chunk = {3, 123456789, chunk_data, sizeof(chunk_data)};
    rdp_clipboard_chunk parsed_chunk;
    UINT32 chunk_wire = RDP_CLIPBOARD_IPC_CHUNK_HEADER_BYTES + sizeof(chunk_data);
    rdp_clipboard_write_chunk(payload, chunk_wire, &chunk);
    CHECK(payload[0] == 0 && payload[3] == 3); /* fileIndex BE */
    CHECK(rdp_clipboard_parse_chunk(payload, chunk_wire, &parsed_chunk));
    CHECK(parsed_chunk.file_index == 3 && parsed_chunk.offset == 123456789);
    CHECK(parsed_chunk.data_length == sizeof(chunk_data));
    CHECK(memcmp(parsed_chunk.data, chunk_data, sizeof(chunk_data)) == 0);
    CHECK(!rdp_clipboard_parse_chunk(payload, 12, &parsed_chunk));  /* no data */
    CHECK(!rdp_clipboard_parse_chunk(payload, 11, &parsed_chunk));
    CHECK(!rdp_clipboard_parse_chunk(NULL, chunk_wire, &parsed_chunk));
    static BYTE oversized[12 + RDP_CLIPBOARD_CHUNK_BYTES + 1];
    CHECK(!rdp_clipboard_parse_chunk(oversized, sizeof(oversized), &parsed_chunk));
''')


if __name__ == "__main__":
    unittest.main()

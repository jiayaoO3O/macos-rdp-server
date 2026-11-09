#!/usr/bin/env python3
"""Offline decoder for FreeRDP transport (stream) dump files.

The record container is produced by FreeRDP's built-in stream dump:

    .deps/freerdp-3.32.2/libfreerdp/core/streamdump.c

and is enabled on the server with the FreeRDP settings
FreeRDP_TransportDump=TRUE + FreeRDP_TransportDumpFile=<path>
(our worker exposes this as the RDP_TRANSPORT_DUMP=<path> environment
variable, see internal/worker/native.c).

Record layout, confirmed from stream_dump_write_line()/read_line():

    offset  size  field
    0       8     UINT64 timestamp (GetTickCount64 ms, native-endian; LE on arm64/x86_64)
    8       1     BYTE received = !!(flags & STREAM_MSG_SRV_RX)
    9       4     UINT32 crc32 of the payload (streamdump.c crc32b())
    13      8     UINT64 payload size
    21      N     payload bytes

The "received" byte semantics (include/freerdp/streamdump.h):

    STREAM_MSG_SRV_RX = 1  -> the *server* received the PDU  => client -> server
    STREAM_MSG_SRV_TX = 2  -> the *server* sent the PDU      => server -> client

stream_dump_write_line() stores (flags & STREAM_MSG_SRV_RX), so 1 == RX
(client->server) and 0 == TX (server->client).

crc32b() in streamdump.c is the reflected CRC-32 with init 0xFFFFFFFF,
polynomial 0xEDB88320 and final xor 0xFFFFFFFF, i.e. bit-for-bit the same
algorithm as zlib.crc32(). crc32b() below is a literal port of the C code;
the unit test asserts it equals zlib.crc32() on a spread of inputs.

The file is opened with "ab" (O_APPEND), so records are a clean, chronological
sequence (TX and RX interleaved); two independent per-direction file offsets
are kept in memory but O_APPEND makes the file append-only.

Decoding is best-effort: every record length and CRC is validated and every
payload is decoded as far as possible (TPKT / X.224 / MCS / TS_SECURITY_HEADER /
share control / share data / license / fast-path).  Corrupt records are
reported, never fatal.  Encrypted or compressed bodies are reported as such.

Security: the decoder never prints credential, SAM, clipboard or password
material.  Client Info strings, redirection strings and channel payload bytes
are not printed (only their structural lengths/flags).  --hex is an explicit
opt-in that dumps the first 64 raw bytes of a record and may therefore reveal
user data.

Usage:
    python3 scripts/decode-transport-dump.py <dumpfile> [--summary|--hex]
                                            [--limit N] [--from-record K]
                                            [--direction both|tx|rx]

Exit codes: 0 = decoded, no corruption; 2 = corruption found (still decoded);
1 = file/usage error.
"""

from __future__ import annotations

import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# Record container
# ---------------------------------------------------------------------------

RECORD_LE = struct.Struct("<QBIQ")  # tick_ms, received, crc32, size
RECORD_BE = struct.Struct(">QBIQ")  # only relevant on a big-endian host
RECORD_HEADER_SIZE = RECORD_LE.size  # 21

TX = "TX"  # server -> client  (received flag == 0)
RX = "RX"  # client -> server  (received flag == 1)


def crc32b(data: bytes) -> int:
    """Literal port of crc32b() from libfreerdp/core/streamdump.c."""
    crc = 0xFFFFFFFF
    for d in data:
        crc ^= d & 0xFF
        for _ in range(8):
            mask = 0xEDB88320 if (crc & 1) else 0
            crc = (crc >> 1) ^ mask
    return (~crc) & 0xFFFFFFFF


class Record:
    __slots__ = ("index", "offset", "ts", "received", "crc", "size", "payload", "error")

    def __init__(self, index, offset, ts, received, crc, size, payload, error=None):
        self.index = index
        self.offset = offset
        self.ts = ts
        self.received = received
        self.crc = crc
        self.size = size
        self.payload = payload
        self.error = error

    @property
    def direction(self):
        return RX if self.received & 1 else TX


def _endian_name(struct_obj) -> str:
    return "little-endian" if struct_obj is RECORD_LE else "big-endian"


def _parse_with(data: bytes, record_struct: struct.Struct):
    """Parse all records; return (records, structural_errors)."""
    records = []
    errors = []
    off = 0
    index = 0
    while off < len(data):
        if len(data) - off < RECORD_HEADER_SIZE:
            errors.append(
                "record #%d at file offset %d: truncated record header "
                "(%d bytes available, need %d)" % (index, off, len(data) - off, RECORD_HEADER_SIZE)
            )
            records.append(Record(index, off, 0, 0, 0, len(data) - off, None, "truncated header"))
            break
        ts, received, crc, size = record_struct.unpack_from(data, off)
        payload_off = off + RECORD_HEADER_SIZE
        if size > len(data) - payload_off:
            errors.append(
                "record #%d at file offset %d: payload size %d exceeds remaining file bytes %d"
                % (index, off, size, len(data) - payload_off)
            )
            records.append(Record(index, off, ts, received, crc, size, None, "truncated payload"))
            break
        payload = data[payload_off:payload_off + size]
        rec = Record(index, off, ts, received, crc, size, payload)
        if crc32b(payload) != crc:
            rec.error = "crc mismatch (header 0x%08x, computed 0x%08x)" % (crc, crc32b(payload))
            errors.append("record #%d at file offset %d: %s" % (index, off, rec.error))
        records.append(rec)
        off = payload_off + size
        index += 1
    return records, errors


def parse_dump(data: bytes):
    """Parse a whole dump file, auto-detecting host endianness.

    Returns (records, errors, endian_description).
    """
    records, errors = _parse_with(data, RECORD_LE)
    if _first_record_trustworthy(records):
        return records, errors, "little-endian"
    records_be, errors_be = _parse_with(data, RECORD_BE)
    if _first_record_trustworthy(records_be):
        return records_be, errors_be, "big-endian"
    return records, errors, "little-endian"


def _first_record_trustworthy(records):
    if not records:
        return True
    first = records[0]
    return first.payload is not None and not first.error


# ---------------------------------------------------------------------------
# Protocol constants (verified against the FreeRDP 3.32.2 tree)
# ---------------------------------------------------------------------------

# libfreerdp/core/tpdu.h: enum X224_TPDU_TYPE
X224_TPDU = {
    0xE0: "CONNECTION_REQUEST",
    0xD0: "CONNECTION_CONFIRM",
    0x80: "DISCONNECT_REQUEST",
    0xF0: "DATA",
    0x70: "ERROR",
}

# libfreerdp/core/mcs.h: enum DomainMCSPDU (choice = (value << 2) | options)
DOMAIN_MCSPDU = {
    0: "PlumbDomainIndication",
    1: "ErectDomainRequest",
    2: "MergeChannelsRequest",
    3: "MergeChannelsConfirm",
    4: "PurgeChannelsIndication",
    5: "MergeTokensRequest",
    6: "MergeTokensConfirm",
    7: "PurgeTokensIndication",
    8: "DisconnectProviderUltimatum",
    9: "RejectMCSPDUUltimatum",
    10: "AttachUserRequest",
    11: "AttachUserConfirm",
    12: "DetachUserRequest",
    13: "DetachUserIndication",
    14: "ChannelJoinRequest",
    15: "ChannelJoinConfirm",
    16: "ChannelLeaveRequest",
    17: "ChannelConveneRequest",
    18: "ChannelConveneConfirm",
    19: "ChannelDisbandRequest",
    20: "ChannelDisbandIndication",
    21: "ChannelAdmitRequest",
    22: "ChannelAdmitIndication",
    23: "ChannelExpelRequest",
    24: "ChannelExpelIndication",
    25: "SendDataRequest",
    26: "SendDataIndication",
    27: "UniformSendDataRequest",
    28: "UniformSendDataIndication",
    29: "TokenGrabRequest",
    30: "TokenGrabConfirm",
    31: "TokenInhibitRequest",
    32: "TokenInhibitConfirm",
    33: "TokenGiveRequest",
    34: "TokenGiveIndication",
    35: "TokenGiveResponse",
    36: "TokenGiveConfirm",
    37: "TokenPleaseRequest",
    38: "TokenPleaseConfirm",
    39: "TokenReleaseRequest",
    40: "TokenReleaseConfirm",
    41: "TokenTestRequest",
    42: "TokenTestConfirm",
}

MCS_SEND_DATA = {25, 26, 27, 28}
MCS_BASE_CHANNEL_ID = 1001
MCS_GLOBAL_CHANNEL_ID = 1003

# include/freerdp/streamdump.h
STREAM_MSG_SRV_RX = 1
STREAM_MSG_SRV_TX = 2

# libfreerdp/core/rdp.h: security header flags
SEC_EXCHANGE_PKT = 0x0001
SEC_TRANSPORT_REQ = 0x0002
SEC_TRANSPORT_RSP = 0x0004
SEC_ENCRYPT = 0x0008
SEC_RESET_SEQNO = 0x0010
SEC_IGNORE_SEQNO = 0x0020
SEC_INFO_PKT = 0x0040
SEC_LICENSE_PKT = 0x0080
SEC_LICENSE_ENCRYPT_CS = 0x0200
SEC_REDIRECTION_PKT = 0x0400
SEC_SECURE_CHECKSUM = 0x0800
SEC_AUTODETECT_REQ = 0x1000
SEC_AUTODETECT_RSP = 0x2000
SEC_HEARTBEAT = 0x4000
SEC_FLAGSHI_VALID = 0x8000

SEC_FLAG_NAMES = (
    (SEC_EXCHANGE_PKT, "EXCHANGE_PKT"),
    (SEC_TRANSPORT_REQ, "TRANSPORT_REQ"),
    (SEC_TRANSPORT_RSP, "TRANSPORT_RSP"),
    (SEC_ENCRYPT, "ENCRYPT"),
    (SEC_RESET_SEQNO, "RESET_SEQNO"),
    (SEC_IGNORE_SEQNO, "IGNORE_SEQNO"),
    (SEC_INFO_PKT, "INFO_PKT"),
    (SEC_LICENSE_PKT, "LICENSE_PKT"),
    (SEC_LICENSE_ENCRYPT_CS, "LICENSE_ENCRYPT_CS"),
    (SEC_REDIRECTION_PKT, "REDIRECTION_PKT"),
    (SEC_SECURE_CHECKSUM, "SECURE_CHECKSUM"),
    (SEC_AUTODETECT_REQ, "AUTODETECT_REQ"),
    (SEC_AUTODETECT_RSP, "AUTODETECT_RSP"),
    (SEC_HEARTBEAT, "HEARTBEAT"),
    (SEC_FLAGSHI_VALID, "FLAGSHI_VALID"),
)

# libfreerdp/core/rdp.h: slow-path share control PDU types (low 4 bits of pduType)
SHARE_CONTROL_PDU = {
    0x1: "DEMAND_ACTIVE",
    0x3: "CONFIRM_ACTIVE",
    0x6: "DEACTIVATE_ALL",
    0x7: "DATA",
    0xA: "SERVER_REDIRECTION",   # FreeRDP PDU_TYPE_SERVER_REDIRECTION
    0xB: "SERVER_REDIRECTION",   # [MS-RDPBCGR] SERVER_REDIRECTION_PDU value
}
SHARE_CONTROL_KNOWN = set(SHARE_CONTROL_PDU)

# libfreerdp/core/rdp.c: PDU_TYPE_FLOW_*
FLOW_PDU = {
    0x41: "FLOW_TEST",
    0x42: "FLOW_RESPONSE",
    0x43: "FLOW_STOP",
}

# libfreerdp/core/rdp.h: enum rdpPduType (share data header pduType2)
DATA_PDU_TYPE = {
    0x02: "UPDATE",
    0x14: "CONTROL",
    0x1B: "POINTER",
    0x1C: "INPUT",
    0x1F: "SYNCHRONIZE",
    0x21: "REFRESH_RECT",
    0x22: "PLAY_SOUND",
    0x23: "SUPPRESS_OUTPUT",
    0x24: "SHUTDOWN_REQUEST",
    0x25: "SHUTDOWN_DENIED",
    0x26: "SAVE_SESSION_INFO",
    0x27: "FONT_LIST",
    0x28: "FONT_MAP",
    0x29: "SET_KEYBOARD_INDICATORS",
    0x2B: "BITMAP_CACHE_PERSISTENT_LIST",
    0x2C: "BITMAP_CACHE_ERROR",
    0x2D: "SET_KEYBOARD_IME_STATUS",
    0x2E: "OFFSCREEN_CACHE_ERROR",
    0x2F: "SET_ERROR_INFO",
    0x30: "DRAW_NINEGRID_ERROR",
    0x31: "DRAW_GDIPLUS_ERROR",
    0x32: "ARC_STATUS",
    0x36: "STATUS_INFO",
    0x37: "MONITOR_LAYOUT",
    0x38: "FRAME_ACKNOWLEDGE",
}

# libfreerdp/core/capabilities.h: capabilitySetType values
CAPSET_TYPE = {
    0x0001: "GENERAL",
    0x0002: "BITMAP",
    0x0003: "ORDER",
    0x0004: "BITMAP_CACHE",
    0x0005: "CONTROL",
    0x0006: "BITMAP_CACHE_V3_CODEC_ID",
    0x0007: "ACTIVATION",
    0x0008: "POINTER",
    0x0009: "SHARE",
    0x000A: "COLOR_CACHE",
    0x000C: "SOUND",
    0x000D: "INPUT",
    0x000E: "FONT",
    0x000F: "BRUSH",
    0x0010: "GLYPH_CACHE",
    0x0011: "OFFSCREEN_CACHE",
    0x0012: "BITMAP_CACHE_HOST_SUPPORT",
    0x0013: "BITMAP_CACHE_V2",
    0x0014: "VIRTUAL_CHANNEL",
    0x0015: "DRAW_NINE_GRID_CACHE",
    0x0016: "DRAW_GDI_PLUS",
    0x0017: "RAIL",
    0x0018: "WINDOW",
    0x0019: "COMP_DESK",
    0x001A: "MULTI_FRAGMENT_UPDATE",
    0x001B: "LARGE_POINTER",
    0x001C: "SURFACE_COMMANDS",
    0x001D: "BITMAP_CODECS",
    0x001E: "FRAME_ACKNOWLEDGE",
}

# libfreerdp/core/license.c: enum LicenseRequestType
LICENSE_MSG = {
    0x01: "LICENSE_REQUEST",
    0x02: "PLATFORM_CHALLENGE",
    0x03: "NEW_LICENSE",
    0x04: "UPGRADE_LICENSE",
    0x12: "LICENSE_INFO",
    0x13: "NEW_LICENSE_REQUEST",
    0x15: "PLATFORM_CHALLENGE_RESPONSE",
    0xFF: "ERROR_ALERT",
}
PREAMBLE_VERSION_3_0 = 0x03
EXTENDED_ERROR_MSG_SUPPORTED = 0x80

LICENSE_ERROR_CODE = {
    0x00000001: "ERR_INVALID_SERVER_CERTIFICATE",
    0x00000002: "ERR_NO_LICENSE",
    0x00000003: "ERR_INVALID_MAC",
    0x00000004: "ERR_INVALID_SCOPE",
    0x00000006: "ERR_NO_LICENSE_SERVER",
    0x00000007: "STATUS_VALID_CLIENT",
    0x00000008: "ERR_INVALID_CLIENT",
    0x0000000B: "ERR_INVALID_PRODUCT_ID",
    0x0000000C: "ERR_INVALID_MESSAGE_LENGTH",
}
LICENSE_STATE_TRANSITION = {
    0x00000001: "ST_TOTAL_ABORT",
    0x00000002: "ST_NO_TRANSITION",
    0x00000003: "ST_RESET_PHASE_TO_START",
    0x00000004: "ST_RESEND_LAST_MESSAGE",
}

# include/freerdp/error.h: Error Info PDU codes (0x00010000 variants are
# FreeRDP's internal "extended" representation used in its own logs).
ERRINFO = {
    0x00000001: "ERRINFO_RPC_INITIATED_DISCONNECT",
    0x00000002: "ERRINFO_RPC_INITIATED_LOGOFF",
    0x00000003: "ERRINFO_IDLE_TIMEOUT",
    0x00000004: "ERRINFO_LOGON_TIMEOUT",
    0x00000005: "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION",
    0x00000006: "ERRINFO_OUT_OF_MEMORY",
    0x00000007: "ERRINFO_SERVER_DENIED_CONNECTION",
    0x00000009: "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES",
    0x0000000A: "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED",
    0x0000000B: "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER",
    0x0000000C: "ERRINFO_LOGOFF_BY_USER",
    0x0001000C: "ERRINFO_LOGOFF_BY_USER",
    0x0000000F: "ERRINFO_CLOSE_STACK_ON_DRIVER_NOT_READY",
    0x00000010: "ERRINFO_SERVER_DWM_CRASH",
    0x00000011: "ERRINFO_CLOSE_STACK_ON_DRIVER_FAILURE",
    0x00000012: "ERRINFO_CLOSE_STACK_ON_DRIVER_IFACE_FAILURE",
    0x00000017: "ERRINFO_SERVER_WINLOGON_CRASH",
    0x00000018: "ERRINFO_SERVER_CSRSS_CRASH",
    0x00000100: "ERRINFO_LICENSE_INTERNAL",
    0x00000101: "ERRINFO_LICENSE_NO_LICENSE_SERVER",
    0x00000102: "ERRINFO_LICENSE_NO_LICENSE",
    0x00000103: "ERRINFO_LICENSE_BAD_CLIENT_MSG",
    0x00000104: "ERRINFO_LICENSE_HWID_DOESNT_MATCH_LICENSE",
    0x00000105: "ERRINFO_LICENSE_BAD_CLIENT_LICENSE",
    0x00000106: "ERRINFO_LICENSE_CANT_FINISH_PROTOCOL",
    0x00000107: "ERRINFO_LICENSE_CLIENT_ENDED_PROTOCOL",
    0x00000108: "ERRINFO_LICENSE_BAD_CLIENT_ENCRYPTION",
    0x00000109: "ERRINFO_LICENSE_CANT_UPGRADE_LICENSE",
    0x0000010A: "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS",
    0x000010C9: "ERRINFO_UNKNOWN_DATA_PDU_TYPE",
    0x000010CA: "ERRINFO_UNKNOWN_PDU_TYPE",
    0x000010D4: "ERRINFO_CONFIRM_ACTIVE_HAS_WRONG_SHAREID",
    0x000010D5: "ERRINFO_CONFIRM_ACTIVE_HAS_WRONG_ORIGINATOR",
    0x000010E5: "ERRINFO_CONFIRM_ACTIVE_PDU_TOO_SHORT",
    0x000010EA: "ERRINFO_BAD_CAPABILITIES",
}

# libfreerdp/core/control.h: TS_CONTROL_PDU action values
CONTROL_ACTION = {0x01: "REQUEST_CONTROL", 0x02: "GRANTED_CONTROL", 0x03: "DETACH", 0x04: "COOPERATE"}
SYNCHRONIZE_MESSAGE = {0x01: "SYNC1", 0x02: "SYNC2"}

# libfreerdp/core/nego.h: RDP Negotiation
RDP_NEG_TYPE = {0x01: "RDP_NEG_REQ", 0x02: "RDP_NEG_RSP", 0x03: "RDP_NEG_FAILURE"}
PROTOCOL_FLAGS = (
    (0x00000001, "SSL"),
    (0x00000002, "HYBRID"),
    (0x00000004, "RDSTLS"),
    (0x00000008, "HYBRID_EX"),
    (0x00000010, "RDSAAD"),
)
NEG_FAILURE = {
    0x01: "SSL_REQUIRED_BY_SERVER",
    0x02: "SSL_NOT_ALLOWED_BY_SERVER",
    0x03: "SSL_CERT_NOT_ON_SERVER",
    0x04: "INCONSISTENT_FLAGS",
    0x05: "HYBRID_REQUIRED_BY_SERVER",
    0x06: "SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER",
}

# libfreerdp/core/autodetect.c
AUTODETECT_HEADER_TYPE = {0x00: "REQUEST", 0x01: "RESPONSE"}
AUTODETECT_REQUEST_TYPE = {
    0x0001: "RTT_REQUEST_CONTINUOUS",
    0x1001: "RTT_REQUEST_CONNECTTIME",
    0x0014: "BW_START_REQUEST_CONTINUOUS",
    0x0114: "BW_START_REQUEST_TUNNEL",
    0x1014: "BW_START_REQUEST_CONNECTTIME",
    0x0002: "BW_PAYLOAD_REQUEST",
    0x002B: "BW_STOP_REQUEST_CONNECTTIME",
    0x0429: "BW_STOP_REQUEST_CONTINUOUS",
    0x0629: "BW_STOP_REQUEST_TUNNEL",
}
AUTODETECT_RESPONSE_TYPE = {
    0x0000: "RTT_RESPONSE",
    0x0018: "NETCHAR_SYNC_RESPONSE",
    0x0840: "NETCHAR_RESULTS_0x0840",
    0x0880: "NETCHAR_RESULTS_0x0880",
    0x08C0: "NETCHAR_RESULTS_0x08C0",
}

# libfreerdp/core/multitransport.c
MULTITRANSPORT_PROTOCOL = {0x0001: "UDPFECR", 0x0002: "UDPFECL", 0x0003: "UDP_2"}
HRESULT_NAMES = {
    0x00000000: "S_OK",
    0x80004004: "E_ABORT",
    0x80004005: "E_FAIL",
    0x80070005: "E_ACCESSDENIED",
}

# libfreerdp/core/license.c: enum BinaryBlobType
LICENSE_BLOB_TYPE = {
    0x0000: "BB_ANY_BLOB",
    0x0001: "BB_DATA_BLOB",
    0x0002: "BB_RANDOM_BLOB",
    0x0003: "BB_CERTIFICATE_BLOB",
    0x0004: "BB_ERROR_BLOB",
    0x0009: "BB_ENCRYPTED_DATA_BLOB",
    0x000D: "BB_KEY_EXCHG_ALG_BLOB",
    0x000E: "BB_SCOPE_BLOB",
    0x000F: "BB_CLIENT_USER_NAME_BLOB",
    0x0010: "BB_CLIENT_MACHINE_NAME_BLOB",
}

# CredSSP TSRequest context-specific fields (libfreerdp/core/nla.c)
TSREQUEST_FIELDS = {
    0xA0: "version",
    0xA1: "negoTokens",
    0xA2: "authInfo",
    0xA3: "pubKeyAuth",
    0xA4: "errorCode",
    0xA5: "clientNonce",
}
TSREQUEST_VERSION = {2: "CredSSP v2", 3: "CredSSP v3", 4: "CredSSP v4", 5: "CredSSP v5", 6: "CredSSP v6"}

# libfreerdp/core/fastpath.h
FASTPATH_UPDATE_TYPE = {
    0x0: "ORDERS",
    0x1: "BITMAP",
    0x2: "PALETTE",
    0x3: "SYNCHRONIZE",
    0x4: "SURFCMDS",
    0x5: "PTR_NULL",
    0x6: "PTR_DEFAULT",
    0x8: "PTR_POSITION",
    0x9: "COLOR",
    0xA: "CACHED",
    0xB: "POINTER",
    0xC: "LARGE_POINTER",
}
FASTPATH_FRAGMENT = {0x0: "SINGLE", 0x1: "LAST", 0x2: "FIRST", 0x3: "NEXT"}
FASTPATH_INPUT_EVENT = {0x0: "SCANCODE", 0x1: "MOUSE", 0x2: "MOUSEX", 0x3: "SYNC", 0x4: "UNICODE"}
FASTPATH_OUTPUT_SECURE_CHECKSUM = 0x1
FASTPATH_OUTPUT_ENCRYPTED = 0x2

# Virtual channel data PDU flags (libfreerdp/core/channels.h / MS-RDPBCGR)
CHANNEL_FLAG = (
    (0x00000001, "FIRST"),
    (0x00000002, "LAST"),
    (0x00000010, "SHOW_PROTOCOL"),
    (0x00000020, "SUSPEND"),
    (0x00000040, "RESUME"),
    (0x00000080, "SHADOW_PERSISTENT"),
    (0x00200000, "COMPRESSED"),
    (0x00400000, "AT_FRONT"),
    (0x00800000, "FLUSHED"),
)

# GCC user-data block identifiers (include/freerdp/settings_types.h)
GCC_BLOCK = {
    0xC001: "CS_CORE",
    0xC002: "CS_SECURITY",
    0xC003: "CS_NET",
    0xC004: "CS_CLUSTER",
    0xC005: "CS_MONITOR",
    0xC006: "CS_MCS_MSGCHANNEL",
    0xC008: "CS_MONITOR_EX",
    0xC00A: "CS_MULTITRANSPORT",
    0xC00C: "CS_UNUSED1",
    0x0C01: "SC_CORE",
    0x0C02: "SC_SECURITY",
    0x0C03: "SC_NET",
    0x0C04: "SC_MCS_MSGCHANNEL",
    0x0C08: "SC_MULTITRANSPORT",
}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def _u8(d, o):
    return d[o]


def _u16le(d, o):
    return d[o] | (d[o + 1] << 8)


def _u16be(d, o):
    return (d[o] << 8) | d[o + 1]


def _u32le(d, o):
    return d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)


def _u32be(d, o):
    return (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]


def _hex(d, limit=64):
    out = " ".join("%02x" % b for b in d[:limit])
    if len(d) > limit:
        out += " ... (%d bytes total)" % len(d)
    return out


def _symbolic(value, table):
    name = table.get(value)
    if name:
        return name
    return "0x%x" % value


def _flag_names(flags, table):
    names = [name for bit, name in table if flags & bit]
    return "|".join(names) if names else "none"


def _per_read_length(d, o):
    """PER length as implemented by libfreerdp/crypto/per.c per_read_length()."""
    if o >= len(d):
        raise ValueError("PER length past end")
    b = d[o]
    o += 1
    if b & 0x80:
        if o >= len(d):
            raise ValueError("PER length byte 2 past end")
        return ((b & 0x7F) << 8) | d[o], o + 1
    return b, o


def _per_read_integer16(d, o, minimum=0):
    """PER INTEGER16 (2-byte big-endian, value + minimum) per per_read_integer16()."""
    if o + 2 > len(d):
        raise ValueError("PER uint16 past end")
    return _u16be(d, o) + minimum, o + 2


def _ber_length(d, o):
    if o >= len(d):
        raise ValueError("BER length past end")
    b = d[o]
    o += 1
    if b & 0x80:
        n = b & 0x7F
        if n == 0 or o + n > len(d):
            raise ValueError("bad BER long-form length")
        return int.from_bytes(d[o:o + n], "big"), o + n
    return b, o


def _der_read_tlv(d, o):
    """Read one BER/DER TLV.

    Returns (tag, value_offset, value_length, next_offset).  Handles the
    high-tag-number form used by T.125 Connect-Initial/Response
    (0x7f 0x65 / 0x7f 0x66).
    """
    if o >= len(d):
        raise ValueError("DER tag past end")
    tag = d[o]
    o += 1
    if tag & 0x1F == 0x1F:
        if o >= len(d):
            raise ValueError("DER high tag past end")
        tag = (tag << 8) | d[o]
        o += 1
    length, o = _ber_length(d, o)
    return tag, o, length, o + length


class Decoded:
    """Decoding result for one record payload."""

    __slots__ = ("parts", "kinds", "notes")

    def __init__(self):
        self.parts = []
        self.kinds = []
        self.notes = []

    def text(self):
        return " | ".join(self.parts) if self.parts else "<empty>"


# ---------------------------------------------------------------------------
# RDP Negotiation (X.224 CR/CC payload)
# ---------------------------------------------------------------------------


def _decode_rdp_neg(d, out):
    if len(d) < 4:
        out.parts.append("RDP_NEG? short(%dB)" % len(d))
        out.kinds.append("RDP_NEG")
        return
    ntype = d[0]
    flags = d[1]
    length = _u16le(d, 2)
    name = RDP_NEG_TYPE.get(ntype, "RDP_NEG_0x%02x" % ntype)
    out.kinds.append(name)
    txt = "%s flags=0x%02x len=%d" % (name, flags, length)
    if ntype == 0x01 and len(d) >= 8:
        proto = _u32le(d, 4)
        txt += " requested=0x%08x[%s]" % (proto, _flag_names(proto, PROTOCOL_FLAGS))
    elif ntype == 0x02 and len(d) >= 8:
        proto = _u32le(d, 4)
        txt += " selected=0x%08x[%s]" % (proto, _flag_names(proto, PROTOCOL_FLAGS))
    elif ntype == 0x03 and len(d) >= 8:
        failure = _u32le(d, 4)
        txt += " failure=0x%08x[%s]" % (failure, NEG_FAILURE.get(failure, "?"))
    out.parts.append(txt)


# ---------------------------------------------------------------------------
# NLA / CredSSP TSRequest (DER) - structure only, never token bytes
# ---------------------------------------------------------------------------


def _tsrequest_extent(d):
    """If d is exactly one DER SEQUENCE, return its content (offset, length)."""
    try:
        tag, vstart, vlen, nxt = _der_read_tlv(d, 0)
    except ValueError:
        return None
    if tag != 0x30 or nxt != len(d):
        return None
    return vstart, vlen


def _decode_tsrequest(d, out):
    """Decode a CredSSP TSRequest envelope; token contents are not printed."""
    ext = _tsrequest_extent(d)
    if ext is None:
        return False
    vstart, vlen = ext
    version = None
    fields = []
    ntlmssp = False
    o = vstart
    end = vstart + vlen
    try:
        while o < end:
            tag, fstart, flen, nxt = _der_read_tlv(d, o)
            if nxt > len(d):
                return False
            payload = d[fstart:fstart + flen]
            name = TSREQUEST_FIELDS.get(tag, "tag0x%02x" % tag)
            if tag == 0xA0 and len(payload) >= 3 and payload[0] == 0x02:
                version = payload[2]
            if tag in (0xA1, 0xA2) and b"NTLMSSP\x00" in payload[:16]:
                ntlmssp = True
            fields.append("%s=%dB" % (name, flen))
            o = nxt
    except ValueError:
        return False
    out.kinds.append("NLA:TSRequest")
    txt = "NLA/CredSSP TSRequest %s version=%s fields=[%s]" % (
        TSREQUEST_VERSION.get(version, "unknown"),
        version,
        ",".join(fields),
    )
    if ntlmssp:
        txt += " token=NTLMSSP"
    txt += " (token bytes not printed)"
    out.parts.append(txt)
    out.notes.append("NLA/CredSSP authentication token payload intentionally not printed")
    return True


# ---------------------------------------------------------------------------
# GCC user data blocks (MCS Connect Initial / Response)
# ---------------------------------------------------------------------------


def _parse_gcc_blocks(region, out):
    """Best-effort parse of a GCC user-data block sequence.

    The PER encoding that precedes the blocks is fiddly to peel exactly, so
    this scans for a block identifier that starts a consistent chain of
    (type, length) block headers and decodes whatever it finds.
    """
    best = None
    for start in range(0, max(0, len(region) - 4)):
        btype = _u16le(region, start)
        if btype not in GCC_BLOCK:
            continue
        off = start
        blocks = []
        ok = True
        while off + 4 <= len(region):
            btype = _u16le(region, off)
            blen = _u16le(region, off + 2)
            plausible = btype in GCC_BLOCK or (btype >> 8) in (0xC0, 0x0C)
            if not plausible or blen < 4 or off + blen > len(region):
                ok = False
                break
            blocks.append((btype, blen, off))
            off += blen
            if off == len(region):
                break
        if ok and blocks:
            if best is None or len(blocks) > len(best[1]):
                best = (start, blocks)
    if best is None:
        return False
    start, blocks = best
    if start:
        out.notes.append("GCC blocks located at +%d in user data" % start)
    for btype, blen, _ in blocks:
        out.parts.append("GCC %s(len=%d)" % (_symbolic(btype, GCC_BLOCK), blen))
    out.kinds.append("GCC blocks")
    return True


def _mcs_connect_gcc_userdata(region):
    """Return the last top-level OCTET STRING (T.125 userData = GCC data)."""
    o = 0
    last = None
    try:
        while o < len(region):
            tag, vstart, vlen, nxt = _der_read_tlv(region, o)
            if nxt > len(region):
                return None
            if tag == 0x04:
                last = region[vstart:vstart + vlen]
            o = nxt
    except ValueError:
        return None
    return last


def _decode_mcs_connect(d, out):
    tag = d[0]
    if tag == 0x7F and len(d) >= 2 and d[1] in (0x65, 0x66):
        kind = d[1]
        tag_end = 2
    elif tag in (0x65, 0x66):
        kind = tag
        tag_end = 1
    else:
        out.parts.append("MCS connect? tag=0x%02x" % tag)
        return
    name = "MCS Connect Initial (0x65)" if kind == 0x65 else "MCS Connect Response (0x66)"
    out.kinds.append("MCS Connect Initial" if kind == 0x65 else "MCS Connect Response")
    try:
        blen, p = _ber_length(d, tag_end)
    except ValueError as exc:
        out.parts.append("%s berLength=<%s>" % (name, exc))
        return
    out.parts.append("%s berLen=%d" % (name, blen))
    region = d[p:p + blen]
    gcc = _mcs_connect_gcc_userdata(region)
    if gcc is not None:
        out.notes.append("T.125 userData (GCC ConnectData) = %d bytes" % len(gcc))
        if not _parse_gcc_blocks(gcc, out):
            out.notes.append("could not locate GCC user-data blocks")
    elif region:
        _parse_gcc_blocks(region, out)


# ---------------------------------------------------------------------------
# License PDUs
# ---------------------------------------------------------------------------


def _decode_license(d, out):
    if len(d) < 4:
        out.parts.append("LICENSE? short(%dB)" % len(d))
        out.kinds.append("License")
        return
    msg = d[0]
    lflags = d[1]
    msgsize = _u16le(d, 2)
    name = LICENSE_MSG.get(msg, "License_0x%02x" % msg)
    out.kinds.append("License:" + name)
    txt = "License %s flags=0x%02x(msgSize=%d version=0x%x%s)" % (
        name,
        lflags,
        msgsize,
        lflags & 0x0F,
        ",EXTENDED_ERROR" if lflags & EXTENDED_ERROR_MSG_SUPPORTED else "",
    )
    if msg == 0xFF and len(d) >= 12:  # ERROR_ALERT
        err = _u32le(d, 4)
        transition = _u32le(d, 8)
        txt += " errorCode=0x%08x[%s] stateTransition=0x%08x[%s]" % (
            err,
            LICENSE_ERROR_CODE.get(err, "?"),
            transition,
            LICENSE_STATE_TRANSITION.get(transition, "?"),
        )
        if len(d) >= 16:
            btype = _u16le(d, 12)
            blen = _u16le(d, 14)
            txt += " binaryBlob(type=%s len=%d)" % (_symbolic(btype, LICENSE_BLOB_TYPE), blen)
    out.parts.append(txt)


# ---------------------------------------------------------------------------
# Client Info PDU (TS_INFO_PACKET) - structural fields only, never strings
# ---------------------------------------------------------------------------

INFO_FLAG_NAMES = (
    (0x00000001, "UNICODE"),
    (0x00000002, "COMPRESSION"),
    (0x00000004, "LOGONNOTIFY"),
    (0x00000008, "MOUSE"),
    (0x00000010, "MOUSE_HAS_WHEEL"),
    (0x00000020, "DISABLECTRLALTDEL"),
    (0x00000040, "MAXIMIZESHELL"),
    (0x00000080, "REMOTECONSOLEAUDIO"),
    (0x00000100, "FORCE_ENCRYPTED_CS_PDU"),
    (0x00000200, "LOGONERRORS"),
    (0x00000400, "ENABLEWINDOWSKEY"),
    (0x00000800, "CANNOT_SEND_ALTERNATE_SHELL"),
    (0x00001000, "CANNOT_SEND_WORKING_DIR"),
)


def _decode_client_info(d, out):
    if len(d) < 18:
        out.parts.append("ClientInfo? short(%dB)" % len(d))
        out.kinds.append("ClientInfo")
        return
    codepage = _u32le(d, 0)
    iflags = _u32le(d, 4)
    cb_user = _u16le(d, 8)
    cb_pass = _u16le(d, 10)
    cb_shell = _u16le(d, 12)
    cb_dir = _u16le(d, 14)
    out.kinds.append("ClientInfo")
    # Deliberately do not print the strings (they can carry user/domain data).
    out.parts.append(
        "ClientInfo codepage=0x%08x flags=0x%08x[%s] cbUser=%d cbPassword=%d "
        "cbAlternateShell=%d cbWorkingDir=%d"
        % (codepage, iflags, _flag_names(iflags, INFO_FLAG_NAMES), cb_user, cb_pass, cb_shell, cb_dir)
    )
    out.notes.append("ClientInfo string payload intentionally not printed")


# ---------------------------------------------------------------------------
# Auto-detect / heartbeat
# ---------------------------------------------------------------------------


def _decode_autodetect(d, out, is_request):
    name = "AUTODETECT_REQ" if is_request else "AUTODETECT_RSP"
    out.kinds.append(name)
    if len(d) < 6:
        out.parts.append("%s short(%dB)" % (name, len(d)))
        return
    header_len = d[0]
    header_type = d[1]
    seq = _u16le(d, 2)
    field = _u16le(d, 4)
    txt = "%s headerLength=%d headerTypeId=%s(0x%02x) sequenceNumber=%d" % (
        name,
        header_len,
        AUTODETECT_HEADER_TYPE.get(header_type, "?"),
        header_type,
        seq,
    )
    if is_request:
        txt += " requestType=0x%04x[%s]" % (
            field,
            AUTODETECT_REQUEST_TYPE.get(field, "?"),
        )
    else:
        txt += " responseType=0x%04x[%s]" % (
            field,
            AUTODETECT_RESPONSE_TYPE.get(field, "?"),
        )
    extra = len(d) - 6
    if extra > 0:
        txt += " extra=%dB" % extra
    out.parts.append(txt)


def _decode_heartbeat(d, out):
    out.kinds.append("HEARTBEAT")
    if len(d) < 3:
        out.parts.append("HEARTBEAT short(%dB)" % len(d))
        return
    out.parts.append("HEARTBEAT headerType=%d sequenceNumber=%d" % (d[0], _u16le(d, 1)))


# ---------------------------------------------------------------------------
# Redirection PDUs
# ---------------------------------------------------------------------------


def _decode_redirection_body(d, out, nested):
    """Decode TS_REDIRECTION_PACKET (optionally preceded by 2 pad bytes)."""
    out.kinds.append("REDIRECTION")
    if nested:
        if len(d) < 2:
            out.parts.append("Redirection body short(%dB)" % len(d))
            return
        d = d[2:]
    if len(d) < 4:
        out.parts.append("Redirection? short(%dB)" % len(d))
        return
    flags = _u16le(d, 0)
    length = _u16le(d, 2)
    txt = "Redirection flags=0x%04x[%s] length=%d" % (
        flags,
        _flag_names(flags, ((SEC_REDIRECTION_PKT, "SEC_REDIRECTION_PKT"),)),
        length,
    )
    if len(d) >= 12:
        session_id = _u32le(d, 4)
        redir_flags = _u32le(d, 8)
        txt += " sessionID=0x%08x redirFlags=0x%08x" % (session_id, redir_flags)
    out.parts.append(txt)
    out.notes.append("redirection optional fields not decoded (may contain credential material)")


# ---------------------------------------------------------------------------
# Share data header payloads
# ---------------------------------------------------------------------------


def _decode_capability_sets(d, out):
    caps = []
    off = 0
    while off + 4 <= len(d):
        ctype = _u16le(d, off)
        clen = _u16le(d, off + 2)
        if clen < 4 or off + clen > len(d):
            out.notes.append("capability set %d at +%d has bad length %d" % (ctype, off, clen))
            break
        caps.append("%s(%d)" % (_symbolic(ctype, CAPSET_TYPE), clen))
        off += clen
    out.parts.append("caps=%d [%s]" % (len(caps), ",".join(caps)))


def _decode_demand_active(body, out, confirm):
    if len(body) < 8:
        out.parts.append("DemandActive? short(%dB)" % len(body))
        return
    share_id = _u32le(body, 0)
    if confirm:
        if len(body) < 10:
            out.parts.append("ConfirmActive? short(%dB)" % len(body))
            return
        originator = _u16le(body, 4)
        lsd = _u16le(body, 6)
        lcc = _u16le(body, 8)
        p = 10
        txt = "ConfirmActive shareId=0x%08x originatorId=%d" % (share_id, originator)
    else:
        lsd = _u16le(body, 4)
        lcc = _u16le(body, 6)
        p = 8
        txt = "DemandActive shareId=0x%08x" % share_id
    if p + lsd + 4 > len(body):
        out.parts.append(txt + " (truncated sourceDescriptor)")
        return
    source = body[p:p + lsd]
    p += lsd
    ncap = _u16le(body, p)
    p += 2
    p += 2  # pad2Octets
    txt += " sourceDescriptor=%r lengthSourceDescriptor=%d lengthCombinedCapabilities=%d numberCapabilities=%d" % (
        bytes(source).decode("ascii", "backslashreplace"),
        lsd,
        lcc,
        ncap,
    )
    out.parts.append(txt)
    caps_len = lcc - 4
    if caps_len > 0:
        caps = body[p:p + caps_len]
        if len(caps) < caps_len:
            out.notes.append("capability region shorter than lengthCombinedCapabilities")
        _decode_capability_sets(caps, out)


def _decode_share_data(d, out):
    if len(d) < 12:
        out.parts.append("ShareData? short(%dB)" % len(d))
        return
    share_id = _u32le(d, 0)
    stream_id = d[5]
    uncompressed_length = _u16le(d, 6)
    pdu_type2 = d[8]
    compressed_type = d[9]
    compressed_length = _u16le(d, 10)
    body = d[12:]
    name = DATA_PDU_TYPE.get(pdu_type2, "Data_0x%02x" % pdu_type2)
    out.kinds.append("Data:" + name)
    txt = "ShareData share=0x%08x streamId=%d pduType2=%s(0x%02x)" % (
        share_id,
        stream_id,
        name,
        pdu_type2,
    )
    if compressed_type:
        txt += " compressedType=0x%02x compressedLength=%d" % (compressed_type, compressed_length)
    elif uncompressed_length != len(body):
        out.notes.append(
            "share data uncompressedLength=%d != actual body %d" % (uncompressed_length, len(body))
        )
    if body:
        txt += " | " + _decode_data_pdu_body(pdu_type2, body)
    out.parts.append(txt)


def _decode_data_pdu_body(pdu_type2, b):
    try:
        if pdu_type2 == 0x14:  # CONTROL
            action = _u16le(b, 0) & 0x0FFF
            return "controlAction=%s(0x%04x)" % (CONTROL_ACTION.get(action, "?"), action)
        if pdu_type2 == 0x1F:  # SYNCHRONIZE
            msg = _u16le(b, 0)
            return "syncMessage=%s(0x%04x)" % (SYNCHRONIZE_MESSAGE.get(msg, "?"), msg)
        if pdu_type2 == 0x2F:  # SET_ERROR_INFO
            err = _u32le(b, 0)
            return "errorInfo=0x%08x[%s]" % (err, ERRINFO.get(err, "?"))
        if pdu_type2 == 0x27:  # FONT_LIST
            return "numberFonts=%d" % _u16le(b, 0)
        if pdu_type2 == 0x28:  # FONT_MAP
            n = _u16le(b, 0)
            entries = []
            o = 2
            for _ in range(min(n, 32)):
                if o + 4 > len(b):
                    break
                entries.append((_u16le(b, o), _u16le(b, o + 2)))
                o += 4
            return "numberEntries=%d %s" % (n, entries if entries else "")
        if pdu_type2 == 0x21:  # REFRESH_RECT
            n = _u16le(b, 0)
            rects = []
            o = 2
            for _ in range(min(n, 16)):
                if o + 8 > len(b):
                    break
                rects.append(
                    "(%d,%d)-(%d,%d)" % (_u16le(b, o), _u16le(b, o + 2), _u16le(b, o + 4), _u16le(b, o + 6))
                )
                o += 8
            return "numberRectangles=%d %s" % (n, " ".join(rects))
        if pdu_type2 == 0x38:  # FRAME_ACKNOWLEDGE
            return "frameId=%d" % _u32le(b, 0)
        if pdu_type2 == 0x37:  # MONITOR_LAYOUT
            if len(b) < 8:
                return "monitorLayout short(%dB)" % len(b)
            count = _u32le(b, 4)
            return "monitorCount=%d" % count
        if pdu_type2 == 0x02:  # UPDATE
            if len(b) < 4:
                return "update short(%dB)" % len(b)
            update_type = _u16le(b, 0)
            if update_type == 0x0001:  # BITMAP
                n = _u16le(b, 2)
                txt = "update=BITMAP numberRectangles=%d" % n
                if len(b) >= 4 + 18:
                    w = _u16le(b, 4 + 8)
                    h = _u16le(b, 4 + 10)
                    bpp = _u16le(b, 4 + 12)
                    txt += " firstRect=%dx%d bpp=%d" % (w, h, bpp)
                return txt
            return "updateType=0x%04x" % update_type
        if pdu_type2 == 0x1B:  # POINTER
            return "pointerUpdateType=%s" % {0: "SYSTEM", 1: "POSITION", 2: "COLOR", 3: "CACHED"}.get(
                _u16le(b, 0), "?"
            )
        if pdu_type2 == 0x26:  # SAVE_SESSION_INFO
            if len(b) < 8:
                return "saveSessionInfo short(%dB)" % len(b)
            return "infoType=0x%08x length=%d (payload not printed)" % (_u32le(b, 0), _u32le(b, 4))
        if pdu_type2 == 0x24:  # SHUTDOWN_REQUEST
            return "shutdownRequest"
        return "body=%dB" % len(b)
    except Exception as exc:  # noqa: BLE001 - best effort decoder
        return "decode error: %s" % exc


# ---------------------------------------------------------------------------
# Security header + slow path share control
# ---------------------------------------------------------------------------


SPECIAL_SEC_MASK = (
    SEC_INFO_PKT
    | SEC_LICENSE_PKT
    | SEC_REDIRECTION_PKT
    | SEC_AUTODETECT_REQ
    | SEC_AUTODETECT_RSP
    | SEC_HEARTBEAT
    | SEC_EXCHANGE_PKT
    | SEC_TRANSPORT_REQ
    | SEC_TRANSPORT_RSP
)


def _share_control_valid(d, off):
    """Does d[off:] look like a complete slow-path share control PDU?"""
    if len(d) - off < 6:
        return False
    total = _u16le(d, off)
    if total == 0x8000:
        return len(d) - off == 8
    if total < 6:
        return False
    raw = _u16le(d, off + 2)
    ptype = raw & 0x0F
    if ptype not in SHARE_CONTROL_KNOWN:
        return False
    return total == len(d) - off


def _has_security_header(d):
    """Decide whether a slow-path user data blob starts with TS_SECURITY_HEADER."""
    if len(d) < 6:
        return False
    flags = _u16le(d, 0)
    flags_hi = _u16le(d, 2)
    if flags == 0:
        return False
    if flags_hi != 0 and not (flags & SEC_FLAGSHI_VALID):
        # A real no-security share control PDU has its pduType in bytes 2..3,
        # and FreeRDP writes pduType | 0x10, so flags_hi is never 0 there.
        return False
    if flags & (SEC_ENCRYPT | SPECIAL_SEC_MASK):
        return True
    return False


def _decode_share_control(d, out, offset=0):
    total = _u16le(d, offset)
    if total == 0x8000:
        _decode_flow_control(d, out, offset)
        return
    raw = _u16le(d, offset + 2)
    ptype = raw & 0x0F
    source = _u16le(d, offset + 4)
    name = SHARE_CONTROL_PDU.get(ptype, "ShareCtrl_0x%x" % ptype)
    out.kinds.append(name)
    remaining = len(d) - offset
    out.parts.append(
        "ShareCtrl totalLength=%d(%s) pduType=%s(0x%02x,raw=0x%04x) pduSource=%d"
        % (total, "ok" if total == remaining else "MISMATCH %dB" % remaining, name, ptype, raw, source)
    )
    if total != remaining:
        out.notes.append("share control totalLength=%d but %d bytes remain" % (total, remaining))
    body = d[offset + 6:]
    if ptype in (0xA, 0xB):
        _decode_redirection_body(body, out, nested=True)
        out.notes.append("SERVER_REDIRECTION PDU present in the stream")
        return
    if ptype == 0x1:
        _decode_demand_active(body, out, confirm=False)
    elif ptype == 0x3:
        _decode_demand_active(body, out, confirm=True)
    elif ptype == 0x6:
        if len(body) >= 6:
            lsd = _u16le(body, 4)
            out.parts.append(
                "DeactivateAll shareId=0x%08x lengthSourceDescriptor=%d sourceDescriptor=%r"
                % (_u32le(body, 0), lsd, bytes(body[6:6 + lsd]).decode("ascii", "backslashreplace"))
            )
    elif ptype == 0x7:
        _decode_share_data(body, out)
    else:
        out.parts.append("body=%dB" % len(body))


def _decode_flow_control(d, out, offset):
    flow_type = d[offset + 2]
    flow_id = d[offset + 4]
    flow_num = d[offset + 5]
    source = _u16le(d, offset + 6)
    out.kinds.append("FlowControl")
    out.parts.append(
        "FlowControl totalLength=0x8000 type=%s(0x%02x) flowIdentifier=%d flowNumber=%d pduSource=%d"
        % (_symbolic(flow_type, FLOW_PDU), flow_type, flow_id, flow_num, source)
    )
    out.notes.append("flow control PDU (T.128 FlowPDU) - no RDP payload")


def _decode_multitransport(body, out, request):
    out.kinds.append("MULTITRANSPORT_REQ" if request else "MULTITRANSPORT_RSP")
    if len(body) < 8:
        out.parts.append(
            "Multitransport %s short(%dB)" % ("Request" if request else "Response", len(body))
        )
        return
    req_id = _u32le(body, 0)
    if request:
        proto = _u16le(body, 4)
        cookie_len = max(0, len(body) - 8)
        out.parts.append(
            "Multitransport Request requestId=%d requestedProtocol=%s(0x%04x) "
            "securityCookie=%dB (not printed)"
            % (req_id, MULTITRANSPORT_PROTOCOL.get(proto, "?"), proto, cookie_len)
        )
        out.notes.append("multitransport security cookie intentionally not printed")
    else:
        hr = _u32le(body, 4)
        out.parts.append(
            "Multitransport Response requestId=%d hr=0x%08x[%s]"
            % (req_id, hr, HRESULT_NAMES.get(hr, "?"))
        )


def _decode_channel_data(d, out, channel_id):
    """Virtual channel data PDU (rdp_write_channel_pdu): totalLength(4) flags(4)."""
    out.kinds.append("ChannelData")
    if len(d) < 8:
        out.parts.append("ChannelData ch=%d short(%dB)" % (channel_id, len(d)))
        return
    total = _u32le(d, 0)
    flags = _u32le(d, 4)
    out.parts.append(
        "ChannelData ch=%d totalLength=%d flags=0x%08x[%s] payload=%dB"
        % (channel_id, total, flags, _flag_names(flags, CHANNEL_FLAG), max(0, len(d) - 8))
    )
    out.notes.append("virtual channel payload not printed")


def _looks_like_rdp_user_data(d):
    """Is this MCS SendData userData an RDP core PDU rather than channel data?"""
    if _share_control_valid(d, 0):
        return True
    if not _has_security_header(d):
        return False
    flags = _u16le(d, 0)
    if flags & SPECIAL_SEC_MASK:
        return True
    return _share_control_valid(d, 4)


def _looks_like_channel_data(d):
    """Virtual channel data PDU: totalLength(4) flags(4) payload."""
    if len(d) < 8:
        return False
    total = _u32le(d, 0)
    flags = _u32le(d, 4)
    if total != len(d):
        return False
    # CHANNEL_FLAG_FIRST/LAST/SHOW_PROTOCOL/SUSPEND/RESUME/SHADOW_PERSISTENT
    # plus COMPRESSED/AT_FRONT/FLUSHED.
    return (flags & ~0x00F000FF) == 0


def _decode_rdp_user_data(d, out, channel_id):
    """Decode the userData of an MCS SendData PDU."""
    if channel_id != MCS_GLOBAL_CHANNEL_ID and (
        _looks_like_channel_data(d) or not _looks_like_rdp_user_data(d)
    ):
        _decode_channel_data(d, out, channel_id)
        return
    if _has_security_header(d):
        flags = _u16le(d, 0)
        flags_hi = _u16le(d, 2)
        full = flags
        if flags & SEC_FLAGSHI_VALID:
            full = flags | (flags_hi << 16)
        out.parts.append(
            "SEC flags=0x%04x%s[%s] flagsHi=0x%04x"
            % (
                flags,
                (" (0x%08x)" % full) if full != flags else "",
                _flag_names(full & 0xFFFF, SEC_FLAG_NAMES),
                flags_hi,
            )
        )
        body = d[4:]
        if flags & SEC_ENCRYPT:
            out.parts.append("encrypted body (8-byte MAC + RC4 ciphertext, not decodable)")
            out.kinds.append("SEC:ENCRYPTED")
            out.notes.append("encrypted security header - payload body cannot be decoded")
            return
        if flags & SEC_LICENSE_PKT:
            _decode_license(body, out)
            return
        if flags & SEC_INFO_PKT:
            _decode_client_info(body, out)
            return
        if flags & SEC_REDIRECTION_PKT:
            _decode_redirection_body(body, out, nested=False)
            return
        if flags & SEC_AUTODETECT_REQ:
            _decode_autodetect(body, out, is_request=True)
            return
        if flags & SEC_AUTODETECT_RSP:
            _decode_autodetect(body, out, is_request=False)
            return
        if flags & SEC_HEARTBEAT:
            _decode_heartbeat(body, out)
            return
        if flags & SEC_TRANSPORT_REQ:
            _decode_multitransport(body, out, request=True)
            return
        if flags & SEC_TRANSPORT_RSP:
            _decode_multitransport(body, out, request=False)
            return
        if flags & SEC_EXCHANGE_PKT:
            out.parts.append("Security Exchange PDU body=%dB (not decoded)" % len(body))
            out.kinds.append("SEC:EXCHANGE")
            return
        out.parts.append("SEC body=%dB" % len(body))
        out.kinds.append("SEC:flagonly")
        return
    _decode_share_control(d, out)


# ---------------------------------------------------------------------------
# MCS + X.224 + TPKT
# ---------------------------------------------------------------------------


def _decode_mcs(d, out):
    if not d:
        out.parts.append("MCS <empty>")
        return
    choice = d[0]
    if choice in (0x65, 0x66) or (
        choice == 0x7F and len(d) >= 2 and d[1] in (0x65, 0x66)
    ):
        _decode_mcs_connect(d, out)
        return
    domain = choice >> 2
    options = choice & 0x03
    name = DOMAIN_MCSPDU.get(domain, "MCS_0x%02x" % choice)
    out.kinds.append("MCS:" + name)
    if domain not in MCS_SEND_DATA:
        out.parts.append(
            "MCS %s(choice=0x%02x options=%d) body=%dB" % (name, choice, options, max(0, len(d) - 1))
        )
        body = d[1:]
        try:
            if domain == 10:  # AttachUserRequest: no fields
                return
            if domain == 11 and len(body) >= 3:  # AttachUserConfirm
                # mcs_send_attach_user_confirm: result then initiator (UserId)
                result = body[0]
                user = _u16be(body, 1) + MCS_BASE_CHANNEL_ID
                out.parts.append("result=%d userId=%d" % (result, user))
                return
            if domain == 14 and len(body) >= 4:  # ChannelJoinRequest
                user = _u16be(body, 0) + MCS_BASE_CHANNEL_ID
                out.parts.append("userId=%d channelId=%d" % (user, _u16be(body, 2)))
                return
            if domain == 15 and len(body) >= 7:  # ChannelJoinConfirm
                # mcs_send_channel_join_confirm: result, initiator, requested, channelId
                result = body[0]
                user = _u16be(body, 1) + MCS_BASE_CHANNEL_ID
                requested = _u16be(body, 3)
                channel = _u16be(body, 5)
                out.parts.append(
                    "result=%d userId=%d requested=%d channelId=%d"
                    % (result, user, requested, channel)
                )
                return
            if domain == 8 and body:  # DisconnectProviderUltimatum
                out.parts.append("reason=%d" % body[0])
                return
            if domain == 1 and len(body) >= 8:  # ErectDomainRequest
                out.parts.append("subHeight=%d subInterval=%d" % (_u32be(body, 0), _u32be(body, 4)))
                return
        except Exception as exc:  # noqa: BLE001
            out.notes.append("MCS %s decode error: %s" % (name, exc))
        return
    # DomainMCSPDU_SendData{Request,Indication} / UniformSendData*
    if len(d) < 8:
        out.parts.append("MCS %s short(%dB)" % (name, len(d)))
        return
    initiator = _u16be(d, 1) + MCS_BASE_CHANNEL_ID
    channel_id = _u16be(d, 3)
    priority = d[5]
    user_data_length = _u16be(d, 6) & 0x7FFF
    user_data = d[8:8 + user_data_length]
    out.parts.append(
        "MCS %s userId=%d channelId=%d priority=0x%02x userDataLen=%d"
        % (name, initiator, channel_id, priority, user_data_length)
    )
    if len(user_data) != user_data_length:
        out.notes.append(
            "MCS userData length %d exceeds record payload (have %d)"
            % (user_data_length, len(user_data))
        )
    if user_data:
        _decode_rdp_user_data(user_data, out, channel_id)


def _decode_x224(d, out):
    if len(d) < 2:
        out.parts.append("X224? short(%dB)" % len(d))
        return
    li = d[0]
    code = d[1]
    name = X224_TPDU.get(code, "X224_0x%02x" % code)
    out.parts.append("X224 %s(li=%d)" % (name, li))
    if code == 0xF0:  # DATA: li, code, EOT(0x80)
        if len(d) < 3:
            return
        _decode_mcs(d[3:], out)
        return
    if code in (0xE0, 0xD0):
        # X.224 header: li, code, dst-ref(2), src-ref(2), class(1).  Remaining
        # bytes are an optional "Cookie: mstshash=..." string (Connection
        # Request only) followed by the RDP Negotiation Request/Response.
        out.kinds.append("X224:" + name)
        if len(d) < 7:
            return
        out.parts.append("class=0x%02x" % d[6])
        rest = d[7:]
        neg = None
        if len(rest) >= 8:
            tail = rest[-8:]
            if tail[0] in (0x01, 0x02, 0x03) and _u16le(tail, 2) == 8:
                neg = tail
                rest = rest[:-8]
        if rest:
            # Cookie content is user-identifying; print the length only.
            out.parts.append("cookie=%dB (not printed)" % len(rest))
            out.kinds.append("cookie")
        if neg is not None:
            _decode_rdp_neg(neg, out)
        return
    out.kinds.append("X224:" + name)


def _decode_tpkt(d, out):
    if len(d) < 4:
        out.parts.append("TPKT? short(%dB)" % len(d))
        out.kinds.append("TPKT:short")
        return len(d)
    version = d[0]
    tpkt_len = _u16be(d, 2)
    out.kinds.append("TPKT")
    out.parts.append("TPKT version=%d length=%d" % (version, tpkt_len))
    if tpkt_len < 4:
        out.notes.append("invalid TPKT length %d" % tpkt_len)
        return len(d)
    used = min(tpkt_len, len(d))
    if tpkt_len > len(d):
        out.notes.append("TPKT length %d exceeds record payload %d" % (tpkt_len, len(d)))
    body = d[4:used]
    if body:
        _decode_x224(body, out)
    return used


# ---------------------------------------------------------------------------
# Fast path
# ---------------------------------------------------------------------------


def _decode_fastpath(d, out, direction=TX):
    if len(d) < 3:
        out.parts.append("FastPath? short(%dB)" % len(d))
        out.kinds.append("FastPath:short")
        return len(d)
    header = d[0]
    action = header & 0x03
    try:
        length, p = _per_read_length(d, 1)
    except ValueError as exc:
        out.parts.append("FastPath header=%s length=<%s>" % (_hex(d, 1), exc))
        return len(d)
    used = min(length, len(d))
    if direction == RX:
        # Fast-Path Input Event PDU: fpInputHeader(1) length(1-2) [sig8] events
        number_events = (header >> 2) & 0x0F
        enc_flags = (header >> 6) & 0x03
        if enc_flags & FASTPATH_OUTPUT_ENCRYPTED:
            out.parts.append(
                "FastPath input length=%d action=%d encrypted secFlags=0x%02x (not decodable)"
                % (length, action, enc_flags)
            )
            out.kinds.append("FastPath:encrypted")
            return used
        txt = "FastPath input length=%d action=%d numberEvents=%d" % (
            length,
            action,
            number_events,
        )
        if p < used:
            eh = d[p]
            txt += " firstEvent=%s(0x%x) eventFlags=0x%02x" % (
                FASTPATH_INPUT_EVENT.get(eh >> 5, "?"),
                eh >> 5,
                eh & 0x1F,
            )
        out.parts.append(txt)
        out.kinds.append("FastPath:INPUT")
        return used
    if action == 0x3:
        # Action X224: a plain X.224 PDU is embedded after the fast-path header.
        out.kinds.append("FastPath:X224")
        out.parts.append("FastPath action=X224 length=%d" % length)
        if p < used:
            _decode_x224(d[p:used], out)
        return used
    if header & 0xC0:
        # Output side: bit6 = secure checksum, bit7 = encrypted.  Input side:
        # bits 2..5 carry numberEvents; bits 6..7 carry encryption flags.
        sec_out = (header >> 6) & 0x03
        number_events = (header >> 2) & 0x0F
        if sec_out & FASTPATH_OUTPUT_ENCRYPTED:
            out.parts.append(
                "FastPath encrypted length=%d secFlags=0x%02x (data signed/encrypted, not decodable)"
                % (length, sec_out)
            )
            out.kinds.append("FastPath:encrypted")
            return used
        out.parts.append(
            "FastPath length=%d action=%d numberEvents=%d" % (length, action, number_events)
        )
        out.kinds.append("FastPath")
        return used
    # Plain (unencrypted) fast-path output update PDU:
    #   fpOutputHeader(1) length1/2(2) [signature(8)] fpUpdateHeader(3..4) size(2) data
    if p >= used:
        out.parts.append("FastPath update length=%d (no update header)" % length)
        return used
    update_header = d[p]
    update_code = update_header & 0x0F
    fragmentation = (update_header >> 4) & 0x03
    compression = (update_header >> 6) & 0x03
    p += 1
    compression_flags = 0
    if compression:
        if p >= used:
            out.parts.append("FastPath update compressed (truncated header)")
            return used
        compression_flags = d[p]
        p += 1
    if p + 2 > used:
        out.parts.append("FastPath update (truncated size)")
        return used
    size = _u16le(d, p)
    p += 2
    data = d[p:p + size]
    name = FASTPATH_UPDATE_TYPE.get(update_code, "0x%x" % update_code)
    out.kinds.append("FastPath:" + name)
    txt = "FastPath update=%s(0x%x) frag=%s compression=%d size=%d pduLength=%d" % (
        name,
        update_code,
        FASTPATH_FRAGMENT.get(fragmentation, "?"),
        compression,
        size,
        length,
    )
    if compression:
        txt += " compressionFlags=0x%02x (compressed data, not decoded)" % compression_flags
        if update_code == 0x1:
            out.kinds.append("FastPath:BITMAP(compressed)")
    elif update_code == 0x1 and len(data) >= 2:
        # Fast-path BITMAP: numberRectangles(2) then TS_BITMAP_DATA rectangles.
        n = _u16le(data, 0)
        txt += " numberRectangles=%d" % n
        if len(data) >= 2 + 18:
            w = _u16le(data, 2 + 8)
            h = _u16le(data, 2 + 10)
            bpp = _u16le(data, 2 + 12)
            txt += " firstRect=%dx%d bpp=%d" % (w, h, bpp)
    out.parts.append(txt)
    return used


# ---------------------------------------------------------------------------
# Record payload dispatch
# ---------------------------------------------------------------------------


def decode_payload(payload, direction):
    """Decode one dump record payload into a Decoded result."""
    out = Decoded()
    if not payload:
        out.parts.append("<empty payload>")
        out.kinds.append("empty")
        return out
    offset = 0
    segments = 0
    while offset < len(payload):
        chunk = payload[offset:]
        if chunk[0] == 0x30 and _decode_tsrequest(chunk, out):
            # NLA/CredSSP TSRequest is a self-contained DER blob.
            offset = len(payload)
            segments += 1
            break
        if chunk[0] & 0x03 != 0x03:
            used = _decode_fastpath(chunk, out, direction)
        else:
            used = _decode_tpkt(chunk, out)
        if not used or used <= 0:
            out.notes.append("stopped at payload offset %d" % offset)
            break
        offset += used
        segments += 1
        if segments >= 16:
            if offset < len(payload):
                out.parts.append("... %d trailing bytes not decoded" % (len(payload) - offset))
            break
    return out


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_header(path, data, records, errors, endian_name):
    lines = []
    lines.append("# FreeRDP transport dump: %s" % path)
    lines.append(
        "# record format: [u64 tick_ms][u8 received][u32 crc32b][u64 size][payload] "
        "(%s, %d-byte header)" % (endian_name, RECORD_HEADER_SIZE)
    )
    lines.append(
        "# direction: TX = server -> client (received=0), RX = client -> server (received=1)"
    )
    lines.append("# %d records, %d bytes, %d corrupt" % (len(records), len(data), len(errors)))
    return lines


def _fmt_time(ts, first_ts):
    if first_ts is None:
        return "     ?     "
    return "%+9.3fs" % ((ts - first_ts) / 1000.0)


FIRST_TS = [None]


def render_record(rec, show_hex):
    if rec.error and rec.payload is None:
        return "[%04d] @%d %s CORRUPT: %s" % (rec.index, rec.offset, rec.direction, rec.error)
    dec = decode_payload(rec.payload, rec.direction)
    line = "[%04d] %s %s len=%5d  %s" % (
        rec.index,
        _fmt_time(rec.ts, FIRST_TS[0]),
        rec.direction,
        rec.size,
        dec.text(),
    )
    if rec.error:
        line += "  !CRC %s" % rec.error
    for note in dec.notes:
        line += "\n        note: " + note
    if show_hex:
        line += "\n        hex: " + _hex(rec.payload, 64)
    return line


def _histogram(records):
    """Return (tx_counts, rx_counts) of decoded kind labels."""
    tx = {}
    rx = {}
    for rec in records:
        if rec.payload is None:
            continue
        dec = decode_payload(rec.payload, rec.direction)
        kind = dec.kinds[-1] if dec.kinds else "unknown"
        target = tx if rec.direction == TX else rx
        target[kind] = target.get(kind, 0) + 1
    return tx, rx


def render_summary(path, data, records, errors, endian_name):
    lines = render_header(path, data, records, errors, endian_name)
    first_ts = next((r.ts for r in records if r.payload is not None), None)
    if first_ts is not None:
        last_ts = records[-1].ts
        lines.append("# time span: +0.000s .. %+.3fs" % ((last_ts - first_ts) / 1000.0))
    tx_records = [r for r in records if r.direction == TX]
    rx_records = [r for r in records if r.direction == RX]
    lines.append("# TX (server->client): %d records" % len(tx_records))
    lines.append("# RX (client->server): %d records" % len(rx_records))
    tx_hist, rx_hist = _histogram(records)
    if tx_records:
        lines.append("# TX decoded kinds:")
        for kind, count in sorted(tx_hist.items(), key=lambda kv: (-kv[1], kv[0])):
            lines.append("#   %5d  %s" % (count, kind))
    if rx_records:
        lines.append("# RX decoded kinds:")
        for kind, count in sorted(rx_hist.items(), key=lambda kv: (-kv[1], kv[0])):
            lines.append("#   %5d  %s" % (count, kind))
    # Session boundaries: an X.224 Connection Request starts a new connection.
    starts = []
    for rec in records:
        if rec.payload and rec.direction == RX and len(rec.payload) > 6 and rec.payload[0] == 0x03:
            body = rec.payload[4:]
            if len(body) >= 2 and body[1] == 0xE0:
                starts.append(rec.index)
    if starts:
        lines.append(
            "# X.224 CONNECTION_REQUEST (new connection) at records: %s"
            % ", ".join(str(s) for s in starts)
        )
    # Server TX stream that immediately follows each Client Info PDU.
    saved_ts = FIRST_TS[0]
    if first_ts is not None:
        FIRST_TS[0] = first_ts
    for rec in records:
        if rec.payload is None or rec.direction != RX:
            continue
        dec = decode_payload(rec.payload, rec.direction)
        if "ClientInfo" not in dec.kinds:
            continue
        lines.append("")
        lines.append(
            "# Client Info PDU received at record #%d; following server TX stream:" % rec.index
        )
        follow = 0
        for later in records[rec.index + 1:]:
            if later.direction != TX:
                continue
            lines.append("  " + render_record(later, False).replace("\n", "\n  "))
            follow += 1
            if follow >= 12:
                break
        if follow == 0:
            lines.append("  (no server TX record after this Client Info)")
    FIRST_TS[0] = saved_ts
    if errors:
        lines.append("")
        lines.append("# corruption:")
        for err in errors:
            lines.append("#   " + err)
    return lines


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_arg_parser():
    p = argparse.ArgumentParser(
        prog="decode-transport-dump.py",
        description="Decode a FreeRDP transport dump (RDP_TRANSPORT_DUMP) offline.",
        epilog=(
            "Exit codes: 0 = clean, 2 = corruption found (records still decoded), "
            "1 = usage/file error."
        ),
    )
    p.add_argument("dumpfile", help="dump file produced by FreeRDP_TransportDumpFile")
    p.add_argument(
        "--summary",
        action="store_true",
        help="print an aggregate summary (counts, kind histograms, session starts, and the "
        "server TX stream after each Client Info PDU) instead of per-record lines",
    )
    p.add_argument(
        "--hex",
        action="store_true",
        help="also print the first 64 raw bytes of each record (may reveal user data)",
    )
    p.add_argument("--limit", type=int, default=None, metavar="N", help="decode at most N records")
    p.add_argument(
        "--from-record",
        type=int,
        default=0,
        metavar="K",
        dest="from_record",
        help="start at record index K (0-based)",
    )
    p.add_argument(
        "--direction",
        choices=("both", "tx", "rx"),
        default="both",
        help="only show TX (server->client) or RX (client->server) records",
    )
    return p


def load_dump(path):
    with open(path, "rb") as fp:
        data = fp.read()
    records, errors, endian_name = parse_dump(data)
    return data, records, errors, endian_name


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    try:
        data, records, errors, endian_name = load_dump(args.dumpfile)
    except OSError as exc:
        print("error: cannot read %s: %s" % (args.dumpfile, exc), file=sys.stderr)
        return 1

    if args.summary:
        print("\n".join(render_summary(args.dumpfile, data, records, errors, endian_name)))
        return 2 if errors else 0

    FIRST_TS[0] = next((r.ts for r in records if r.payload is not None), 0)
    print("\n".join(render_header(args.dumpfile, data, records, errors, endian_name)))

    shown = 0
    for rec in records:
        if rec.index < args.from_record:
            continue
        if args.direction == "tx" and rec.direction != TX:
            continue
        if args.direction == "rx" and rec.direction != RX:
            continue
        print(render_record(rec, args.hex))
        shown += 1
        if args.limit is not None and shown >= args.limit:
            break
    if shown == 0:
        print("# (no records matched)")
    if errors:
        print("# corruption details:")
        for err in errors:
            print("#   " + err)
        print("# %d corrupt record(s); records were still decoded" % len(errors))
    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

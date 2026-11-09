#!/usr/bin/env python3
"""Unit tests for scripts/decode-transport-dump.py.

The tests fabricate FreeRDP transport-dump records (streamdump.c format) in
memory, so they run standalone with no network, no server and no fixture
files left behind.  Run with:

    python3 scripts/test-decode-transport-dump.py

or as part of a standard unittest discovery run.
"""

import importlib.util
import io
import struct
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DECODER_PATH = ROOT / "scripts" / "decode-transport-dump.py"


def load_decoder():
    spec = importlib.util.spec_from_file_location("decode_transport_dump", DECODER_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise RuntimeError("cannot load decoder from %s" % DECODER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


D = load_decoder()

# Record header: UINT64 tick, BYTE received, UINT32 crc32, UINT64 size (LE host).
RECORD = struct.Struct("<QBIQ")
HEADER_SIZE = RECORD.size


def ref_crc32b(data):
    """Independent literal port of crc32b() from libfreerdp/core/streamdump.c."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


def record(payload, direction, ts=0, corrupt_crc=False):
    received = 1 if direction == "RX" else 0
    crc = ref_crc32b(payload)
    if corrupt_crc:
        crc ^= 0xDEADBEEF
    return RECORD.pack(ts, received, crc, len(payload)) + payload


# ---------------------------------------------------------------------------
# PDU builders (wire layouts verified against the FreeRDP 3.32.2 sources)
# ---------------------------------------------------------------------------


def tpkt(x224_payload):
    return struct.pack(">BBH", 3, 0, 4 + len(x224_payload)) + x224_payload


def x224_data(mcs_payload):
    """X.224 Data TPDU: LI=2, code=0xF0, EOT=0x80."""
    return bytes([2, 0xF0, 0x80]) + mcs_payload


def mcs_send_data(user_data, channel_id=1003, user_id=1002, domain=26):
    """MCS SendData (26 = Indication for server TX, 25 = Request for client TX)."""
    choice = domain << 2
    header = bytes([choice])
    header += struct.pack(">HH", user_id - 1001, channel_id)
    header += bytes([0x70])
    header += struct.pack(">H", 0x8000 | len(user_data))
    return header + user_data


def slow_pdu(user_data, channel_id=1003, user_id=1002, direction="TX"):
    domain = 26 if direction == "TX" else 25
    return tpkt(x224_data(mcs_send_data(user_data, channel_id, user_id, domain)))


def sec_header(flags):
    return struct.pack("<HH", flags, 0)


def share_control(ptype, body, source=1002, total_override=None):
    raw = 0x10 | ptype
    total = 6 + len(body) if total_override is None else total_override
    return struct.pack("<HHH", total, raw, source) + body


def capability_sets(caps):
    blob = b""
    for ctype, data in caps:
        blob += struct.pack("<HH", ctype, 4 + len(data)) + data
    return blob


def demand_active_body(share_id=0x13EA, source=b"RDP", caps=None):
    if caps is None:
        caps = [(0x0001, b"\x01\x00\x00\x00" + b"\x00" * 16), (0x0002, b"\x00" * 24)]
    blob = capability_sets(caps)
    length_combined = 4 + len(blob)  # numberCapabilities + pad2Octets + caps
    body = struct.pack("<IHH", share_id, len(source), length_combined)
    body += source
    body += struct.pack("<HH", len(caps), 0)
    body += blob
    return body


def demand_active_pdu():
    return slow_pdu(share_control(0x1, demand_active_body()), direction="TX")


def confirm_active_body(share_id=0x13EA, originator=0x03EA):
    caps = [(0x0001, b"\x00" * 16)]
    blob = capability_sets(caps)
    length_combined = 4 + len(blob)
    body = struct.pack("<IHHH", share_id, originator, 4, length_combined)
    body += b"RDP"
    body += struct.pack("<HH", len(caps), 0)
    body += blob
    return body


def confirm_active_pdu():
    return slow_pdu(share_control(0x3, confirm_active_body()), direction="RX")


def license_error_alert(error_code=0x00000007, state_transition=0x00000002, msg_type=0xFF):
    payload = struct.pack("<BBH", msg_type, 0x03, 8)  # preamble version 3.0
    payload += struct.pack("<II", error_code, state_transition)
    return slow_pdu(sec_header(0x0080) + payload, direction="TX")


def client_info_pdu(user=b"alice\x00", domain=b"MACRDP\x00"):
    flags = 0x00000001 | 0x00000008 | 0x00000010  # UNICODE|MOUSE|MOUSE_HAS_WHEEL
    body = struct.pack("<IIHHHH", 0x00000409, flags, len(user), 2, 2, 2)
    body += domain + user + b"\x00\x00" + b"\x00\x00" + b"\x00\x00"
    return slow_pdu(sec_header(0x0040) + body, direction="RX")


def data_pdu_set_error_info(error_info=0x0001000C):
    body = struct.pack("<I", error_info)
    share_data = struct.pack("<IBBHBBH", 0x13EA, 0, 1, len(body), 0x2F, 0, 0)
    return slow_pdu(share_control(0x7, share_data + body), direction="TX")


def data_pdu_control(action=0x0004):
    body = struct.pack("<H", action)
    share_data = struct.pack("<IBBHBBH", 0x13EA, 0, 1, len(body), 0x14, 0, 0)
    return slow_pdu(share_control(0x7, share_data + body), direction="TX")


def redirection_pdu(pdu_type=0x0A):
    body = struct.pack("<HHHII", 0, 0x0400, 12, 0x11223344, 0x00000000)
    return slow_pdu(share_control(pdu_type, body), direction="TX")


def fastpath_bitmap_update(width=2, height=2, bpp=32):
    # Fast-path BITMAP data: numberRectangles(2) + TS_BITMAP_DATA rectangles.
    bitmap = b"\x00\x00\x00\x00"
    rect = struct.pack(
        "<HHHHHHHHH", 0, 0, width - 1, height - 1, width, height, bpp, 0, len(bitmap)
    )
    data = struct.pack("<H", 1) + rect + bitmap
    update_header = bytes([0x01])  # updateCode=1 (BITMAP), frag=SINGLE, no compression
    body = update_header + struct.pack("<H", len(data)) + data
    total = 3 + len(body)
    return bytes([0x00, 0x80 | (total >> 8), total & 0xFF]) + body


def mcs_connect_initial():
    blocks = struct.pack("<HH", 0xC001, 10) + b"\x00" * 6
    blocks += struct.pack("<HH", 0xC002, 8) + b"\x00" * 4
    gcc = bytes([0x65]) + bytes([len(blocks)]) + blocks
    return tpkt(x224_data(gcc))


def x224_cr_with_cookie(cookie=b"Cookie: mstshash=SECRETUSER\r\n", requested=0x0000000B):
    li = 1 + 5 + len(cookie) + 8
    x224 = bytes([li, 0xE0, 0, 0, 0, 0, 0]) + cookie
    x224 += struct.pack("<BBHI", 1, 0, 8, requested)
    return tpkt(x224)


def der_tlv(tag, payload):
    if len(payload) < 0x80:
        return bytes([tag, len(payload)]) + payload
    return bytes([tag, 0x81, len(payload)]) + payload


def tsrequest(version=6, token=b"NTLMSSP\x00SECRETTOKEN"):
    body = der_tlv(0xA0, der_tlv(0x02, bytes([version])))
    body += der_tlv(0xA1, der_tlv(0x30, der_tlv(0x04, token)))
    body += der_tlv(0xA5, b"\x01\x02\x03\x04")
    return der_tlv(0x30, body)


def mcs_connect_response():
    gcc = struct.pack("<HH", 0x0C01, 16) + b"\x00" * 12
    gcc += struct.pack("<HH", 0x0C04, 6) + b"\xec\x03"
    gcc += struct.pack("<HH", 0x0C02, 12) + b"\x00" * 8
    content = bytes([0x0A, 0x01, 0x00]) + bytes([0x02, 0x01, 0x00])
    content += bytes([0x30, 0x1A]) + b"\x00" * 26
    content += bytes([0x04, len(gcc)]) + gcc
    return tpkt(x224_data(bytes([0x7F, 0x66, len(content)]) + content))


def message_channel_pdu(sec_flags, body, direction="TX"):
    return slow_pdu(sec_header(sec_flags) + body, channel_id=1004, direction=direction)


def multitransport_request():
    body = struct.pack("<IHH", 0, 1, 0) + b"\xAA" * 16
    return message_channel_pdu(0x0002, body, direction="TX")


def multitransport_response():
    body = struct.pack("<II", 0, 0x80004004)
    return slow_pdu(sec_header(0x0004) + body, channel_id=1004, direction="RX")


def autodetect_request():
    return message_channel_pdu(0x1000, struct.pack("<BBHH", 6, 0, 35, 0x1001), direction="TX")


def autodetect_response():
    return slow_pdu(
        sec_header(0x2000) + struct.pack("<BBHH", 6, 1, 35, 0x0000),
        channel_id=1004,
        direction="RX",
    )


def license_valid_client_alert():
    payload = struct.pack("<BBH", 0xFF, 0x03, 16) + struct.pack("<IIHH", 7, 2, 4, 0)
    return slow_pdu(sec_header(0x0080) + payload, direction="TX")


def fastpath_input_pdu():
    events = b"\x00\x01\x41"  # SCANCODE event: eventHeader, keyboardFlags, keyCode
    total = 2 + len(events)
    return bytes([0x04, total]) + events  # numberEvents=1, action=0


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------


class DecoderTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rdp-dump-test-")
        self.addCleanup(self.temp.cleanup)

    def write_dump(self, records, name="probe-dump.bin"):
        path = Path(self.temp.name) / name
        path.write_bytes(b"".join(records))
        return str(path)

    def run_decoder(self, path, argv_extra=None):
        argv = [path] + list(argv_extra or [])
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = D.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()


# ---------------------------------------------------------------------------
# Container format
# ---------------------------------------------------------------------------


class ContainerTests(DecoderTestCase):
    def test_crc32b_matches_c_source_and_zlib(self):
        samples = [b"", b"\x00", b"123456789", b"\xff" * 64, bytes(range(256))]
        for data in samples:
            expected = ref_crc32b(data)
            self.assertEqual(D.crc32b(data), expected)
            # streamdump.c crc32b() is bit-identical to standard CRC-32.
            self.assertEqual(expected, zlib.crc32(data) & 0xFFFFFFFF)

    def test_record_header_size(self):
        self.assertEqual(HEADER_SIZE, 21)
        self.assertEqual(D.RECORD_HEADER_SIZE, 21)

    def test_directions_and_timestamps(self):
        path = self.write_dump(
            [
                record(client_info_pdu(), "RX", ts=1000),
                record(license_error_alert(), "TX", ts=1012),
            ]
        )
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("little-endian", out)
        self.assertIn("2 records", out)
        self.assertIn("[0000]    +0.000s RX", out)
        self.assertIn("[0001]    +0.012s TX", out)
        self.assertIn("TX = server -> client", out)

    def test_empty_file(self):
        path = self.write_dump([])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("0 records", out)
        self.assertIn("(no records matched)", out)

    def test_missing_file(self):
        code, _, err = self.run_decoder(str(Path(self.temp.name) / "does-not-exist.bin"))
        self.assertEqual(code, 1)
        self.assertIn("cannot read", err)


# ---------------------------------------------------------------------------
# Payload decoding
# ---------------------------------------------------------------------------


class PayloadTests(DecoderTestCase):
    def test_mcs_connect_initial_gcc_blocks(self):
        path = self.write_dump([record(mcs_connect_initial(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("MCS Connect Initial (0x65)", out)
        self.assertIn("GCC CS_CORE", out)
        self.assertIn("GCC CS_SECURITY", out)

    def test_demand_active(self):
        path = self.write_dump([record(demand_active_pdu(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("MCS SendDataIndication", out)
        self.assertIn("DEMAND_ACTIVE", out)
        self.assertIn("ShareCtrl totalLength=", out)
        self.assertIn("caps=2", out)
        self.assertIn("GENERAL(24)", out)
        self.assertIn("BITMAP(28)", out)
        self.assertIn("sourceDescriptor='RDP'", out)

    def test_confirm_active(self):
        path = self.write_dump([record(confirm_active_pdu(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("MCS SendDataRequest", out)
        self.assertIn("CONFIRM_ACTIVE", out)
        self.assertIn("originatorId=1002", out)

    def test_license_error_alert(self):
        path = self.write_dump([record(license_error_alert(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("SEC flags=0x0080[LICENSE_PKT]", out)
        self.assertIn("License ERROR_ALERT", out)
        self.assertIn("STATUS_VALID_CLIENT", out)
        self.assertIn("ST_NO_TRANSITION", out)

    def test_redirection_pdu_has_flags_0x0400(self):
        for pdu_type in (0x0A, 0x0B):
            path = self.write_dump([record(redirection_pdu(pdu_type), "TX")])
            code, out, _ = self.run_decoder(path)
            self.assertEqual(code, 0)
            self.assertIn("SERVER_REDIRECTION", out)
            self.assertIn("flags=0x0400[SEC_REDIRECTION_PKT]", out)
            self.assertIn("sessionID=0x11223344", out)

    def test_sec_redirection_flag_on_security_header(self):
        payload = sec_header(0x0400) + struct.pack("<HHII", 0x0400, 8, 0x1, 0x0)
        path = self.write_dump([record(slow_pdu(payload, direction="RX"), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("SEC flags=0x0400[REDIRECTION_PKT]", out)
        self.assertIn("Redirection flags=0x0400", out)

    def test_client_info_never_prints_strings(self):
        path = self.write_dump([record(client_info_pdu(user=b"SECRETUSER\x00"), "RX")])
        code, out, _ = self.run_decoder(path, ["--hex"])
        self.assertEqual(code, 0)
        self.assertIn("ClientInfo", out)
        self.assertIn("cbUser=", out)
        self.assertNotIn("SECRETUSER", out)
        self.assertIn("intentionally not printed", out)

    def test_set_error_info_pdu(self):
        path = self.write_dump([record(data_pdu_set_error_info(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("pduType2=SET_ERROR_INFO(0x2f)", out)
        self.assertIn("errorInfo=0x0001000c[ERRINFO_LOGOFF_BY_USER]", out)

    def test_control_pdu(self):
        path = self.write_dump([record(data_pdu_control(0x04), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("pduType2=CONTROL(0x14)", out)
        self.assertIn("controlAction=COOPERATE(0x0004)", out)

    def test_fastpath_bitmap_update(self):
        path = self.write_dump([record(fastpath_bitmap_update(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("FastPath update=BITMAP(0x1)", out)
        self.assertIn("numberRectangles=1", out)
        self.assertIn("firstRect=2x2 bpp=32", out)

    def test_virtual_channel_data(self):
        channel = struct.pack("<II", 8 + 4, 0x00000001) + b"\x01\x02\x03\x04"
        path = self.write_dump([record(slow_pdu(channel, channel_id=1004, direction="RX"), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("ChannelData ch=1004", out)
        self.assertIn("flags=0x00000001[FIRST]", out)
        self.assertNotIn("01 02 03 04", out)

    def test_x224_connection_request_cookie(self):
        path = self.write_dump([record(x224_cr_with_cookie(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("X224 CONNECTION_REQUEST", out)
        self.assertIn("RDP_NEG_REQ", out)
        self.assertIn("requested=0x0000000b[SSL|HYBRID|HYBRID_EX]", out)
        self.assertIn("cookie=29B (not printed)", out)
        self.assertNotIn("SECRETUSER", out)

    def test_tsrequest_structure_only(self):
        path = self.write_dump([record(tsrequest(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("NLA/CredSSP TSRequest CredSSP v6", out)
        self.assertIn("negoTokens=", out)
        self.assertIn("token=NTLMSSP", out)
        self.assertNotIn("SECRETTOKEN", out)

    def test_mcs_connect_response_with_gcc_blocks(self):
        path = self.write_dump([record(mcs_connect_response(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("MCS Connect Response (0x66)", out)
        self.assertIn("GCC SC_CORE", out)
        self.assertIn("GCC SC_SECURITY", out)

    def test_multitransport_request(self):
        path = self.write_dump([record(multitransport_request(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("SEC flags=0x0002[TRANSPORT_REQ]", out)
        self.assertIn("Multitransport Request requestId=0", out)
        self.assertIn("requestedProtocol=UDPFECR(0x0001)", out)
        self.assertIn("securityCookie=16B (not printed)", out)
        self.assertNotIn("aa aa aa aa", out)

    def test_multitransport_response(self):
        path = self.write_dump([record(multitransport_response(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("Multitransport Response requestId=0 hr=0x80004004[E_ABORT]", out)

    def test_autodetect_req_and_rsp(self):
        path = self.write_dump(
            [record(autodetect_request(), "TX"), record(autodetect_response(), "RX")]
        )
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("AUTODETECT_REQ headerLength=6 headerTypeId=REQUEST(0x00)", out)
        self.assertIn("requestType=0x1001[RTT_REQUEST_CONNECTTIME]", out)
        self.assertIn("AUTODETECT_RSP headerLength=6 headerTypeId=RESPONSE(0x01)", out)
        self.assertIn("responseType=0x0000[RTT_RESPONSE]", out)

    def test_license_valid_client_with_error_blob(self):
        path = self.write_dump([record(license_valid_client_alert(), "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("STATUS_VALID_CLIENT", out)
        self.assertIn("binaryBlob(type=BB_ERROR_BLOB len=0)", out)

    def test_fastpath_input_pdu(self):
        path = self.write_dump([record(fastpath_input_pdu(), "RX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("FastPath input length=5 action=0 numberEvents=1", out)
        self.assertIn("firstEvent=SCANCODE(0x0)", out)

    def test_unknown_garbage_payload_does_not_crash(self):
        payload = b"\x03\x00\x00\x99garbage-after-tpkt-length"
        path = self.write_dump([record(payload, "TX")])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 0)
        self.assertIn("TPKT length 153 exceeds record payload", out)


# ---------------------------------------------------------------------------
# Corruption handling
# ---------------------------------------------------------------------------


class CorruptionTests(DecoderTestCase):
    def test_bad_crc_is_reported(self):
        path = self.write_dump([record(demand_active_pdu(), "TX", corrupt_crc=True)])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 2)
        self.assertIn("crc mismatch", out)
        self.assertIn("corrupt", out)
        # The payload still decoded despite the CRC error.
        self.assertIn("DEMAND_ACTIVE", out)

    def test_truncated_payload_is_reported(self):
        good = record(demand_active_pdu(), "TX")
        bad_header = RECORD.pack(1, 0, 0, 4096) + b"\x00" * 8
        path = self.write_dump([good, bad_header])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 2)
        self.assertIn("CORRUPT", out)
        self.assertIn("exceeds remaining file bytes", out)

    def test_truncated_record_header_is_reported(self):
        path = self.write_dump([b"\x01\x02\x03\x04\x05"])
        code, out, _ = self.run_decoder(path)
        self.assertEqual(code, 2)
        self.assertIn("truncated record header", out)


# ---------------------------------------------------------------------------
# CLI behaviour
# ---------------------------------------------------------------------------


class CliTests(DecoderTestCase):
    def build_sequence(self):
        return [
            record(client_info_pdu(), "RX", ts=0),
            record(license_error_alert(), "TX", ts=5),
            record(demand_active_pdu(), "TX", ts=10),
            record(data_pdu_control(0x04), "TX", ts=15),
        ]

    def test_limit(self):
        path = self.write_dump(self.build_sequence())
        code, out, _ = self.run_decoder(path, ["--limit", "2"])
        self.assertEqual(code, 0)
        self.assertIn("[0000]", out)
        self.assertIn("[0001]", out)
        self.assertNotIn("[0002]", out)

    def test_from_record(self):
        path = self.write_dump(self.build_sequence())
        code, out, _ = self.run_decoder(path, ["--from-record", "2"])
        self.assertEqual(code, 0)
        self.assertNotIn("[0001]", out)
        self.assertIn("[0002]", out)
        self.assertIn("[0003]", out)

    def test_direction_filter(self):
        path = self.write_dump(self.build_sequence())
        code, out, _ = self.run_decoder(path, ["--direction", "tx"])
        self.assertEqual(code, 0)
        self.assertIn(" TX len=", out)
        self.assertNotIn(" RX len=", out)

    def test_hex(self):
        path = self.write_dump([record(demand_active_pdu(), "TX")])
        code, out, _ = self.run_decoder(path, ["--hex"])
        self.assertEqual(code, 0)
        self.assertIn("hex: 03 00 00", out)

    def test_summary_reports_tx_after_client_info(self):
        path = self.write_dump(self.build_sequence())
        code, out, _ = self.run_decoder(path, ["--summary"])
        self.assertEqual(code, 0)
        self.assertIn("TX decoded kinds:", out)
        self.assertIn("License:ERROR_ALERT", out)
        self.assertIn("DEMAND_ACTIVE", out)
        self.assertIn("Client Info PDU received at record #0", out)
        self.assertIn("following server TX stream", out)
        # Summary mode does not print the default full record timeline.
        self.assertNotIn("\n[0000]", out)

    def test_summary_with_corruption_still_reports(self):
        path = self.write_dump([record(demand_active_pdu(), "TX", corrupt_crc=True)])
        code, out, _ = self.run_decoder(path, ["--summary"])
        self.assertEqual(code, 2)
        self.assertIn("corruption:", out)
        self.assertIn("crc mismatch", out)

    def test_second_connection_is_detected(self):
        cr = tpkt(bytes([7, 0xE0, 0, 0, 0, 0, 0]) + struct.pack("<BBHI", 1, 0, 8, 3))
        path = self.write_dump(
            [record(cr, "RX", ts=0), record(demand_active_pdu(), "TX", ts=1), record(cr, "RX", ts=2)]
        )
        code, out, _ = self.run_decoder(path, ["--summary"])
        self.assertEqual(code, 0)
        self.assertIn("X.224 CONNECTION_REQUEST (new connection) at records: 0, 2", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)

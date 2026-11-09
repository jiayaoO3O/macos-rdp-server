#!/usr/bin/env python3
"""Exercise the Swift Agent's frame sender against a real Unix socket."""
import contextlib
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "native/macos/Sources/MacAgentCore"
# Sources the wire harness compiles (the file-clipboard codec lives in
# AgentIPCMessage.swift, so the list is unchanged per agent-clipboard).
CORE_FILES = ("CaptureSizeRequest.swift", "AgentFrameDeltaEncoder.swift",
              "AgentIPCMessage.swift", "AgentFrameAssembler.swift", "AgentUnixSocket.swift",
              "MacKeyMap.swift", "KeyboardInputState.swift", "MouseClickState.swift")


@contextlib.contextmanager
def short_temp_directory(prefix, socket_name="s"):
    """Temporary directory whose Unix socket child stays below 104 bytes.

    /tmp is preferred because the Swift harness binds an AF_UNIX socket inside
    this directory; the platform TMPDIR (e.g. /var/folders/...) can be long
    enough to fail bind(). Fall back to TMPDIR only when the resulting path
    still fits, otherwise try the next candidate.
    """
    for base in ("/tmp", "/private/tmp", tempfile.gettempdir()):
        try:
            directory = tempfile.mkdtemp(prefix=prefix, dir=base)
        except OSError:
            continue
        if len(os.fsencode(os.path.join(directory, socket_name))) >= 104:
            shutil.rmtree(directory, ignore_errors=True)
            continue
        try:
            yield Path(directory)
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        return
    raise RuntimeError(
        "no writable temp directory keeps the Unix socket path under 104 bytes")


class AgentWireTest(unittest.TestCase):
    def test_delta_frames_send_only_changed_tiles_and_reconstruct(self):
        with short_temp_directory("ipc-delta-") as directory:
            directory = Path(directory)
            source = directory / "main.swift"
            source.write_text('''import Foundation
let socket = try AgentUnixSocket(path: CommandLine.arguments[1])
var encoder = AgentFrameDeltaEncoder()
var pixels = Data(count: 256 * 256 * 4)
let first = try encoder.encode(pixels: pixels, width: 256, height: 256, generation: 9)
try socket.sendFrameDelta(metadata: AgentFrameMetadata(generation: 9, frameID: 1,
                         width: 256, height: 256, bytesPerPixel: 4), tiles: first)
pixels[(80 * 256 + 80) * 4] = 0xff
let next = try encoder.encode(pixels: pixels, width: 256, height: 256, generation: 9)
try socket.sendFrameDelta(metadata: AgentFrameMetadata(generation: 9, frameID: 2,
                         width: 256, height: 256, bytesPerPixel: 4), tiles: next)
socket.close()
''')
            executable = directory / "sender"
            files = [CORE / name for name in ("CaptureSizeRequest.swift", "AgentFrameDeltaEncoder.swift", "AgentIPCMessage.swift", "AgentFrameAssembler.swift", "AgentUnixSocket.swift")]
            subprocess.run(["swiftc", *map(str, files), str(source), "-o", str(executable)], check=True, capture_output=True)
            path = str(directory / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                process = subprocess.Popen([str(executable), path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    listener.settimeout(5)
                    conn, _ = listener.accept()
                    conn.settimeout(5)
                    with conn:
                        def read_exact(length):
                            result = bytearray()
                            while len(result) < length:
                                chunk = conn.recv(length - len(result))
                                self.assertTrue(chunk, "unexpected socket EOF")
                                result.extend(chunk)
                            return bytes(result)
                        def message():
                            header = read_exact(12)
                            magic, version, kind, length = struct.unpack(">4sHHI", header)
                            self.assertEqual((magic, version), (b"RDPA", 1))
                            return kind, read_exact(length)
                        frame = bytearray(256 * 256 * 4)
                        for frame_id, expected_tiles in ((1, 16), (2, 1)):
                            kind, begin = message()
                            self.assertEqual(kind, 10)
                            generation, current_id, width, height, bpp, count = struct.unpack(">QQIIBI", begin)
                            self.assertEqual((generation, current_id, width, height, bpp, count),
                                             (9, frame_id, 256, 256, 4, expected_tiles))
                            for _ in range(count):
                                kind, patch = message()
                                self.assertEqual(kind, 11)
                                generation, current_id, x, y, tile_width, tile_height = struct.unpack(">QQIIHH", patch[:28])
                                self.assertEqual((generation, current_id), (9, frame_id))
                                tile_data = patch[28:]
                                self.assertEqual(len(tile_data), tile_width * tile_height * 4)
                                for row in range(tile_height):
                                    start = ((y + row) * width + x) * 4
                                    frame[start:start + tile_width * 4] = tile_data[row * tile_width * 4:(row + 1) * tile_width * 4]
                            kind, end = message()
                            self.assertEqual((kind, struct.unpack(">QQI", end)), (12, (9, frame_id, count)))
                        self.assertEqual(frame[(80 * 256 + 80) * 4], 0xff)
                    _, error = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error.decode())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_peer_disconnect_throws_instead_of_terminating_process(self):
        with short_temp_directory("ipc-") as directory:
            directory = Path(directory)
            source = directory / "main.swift"
            source.write_text('''import Darwin
import Foundation
let socket = try AgentUnixSocket(path: CommandLine.arguments[1])
sleep(1)
do {
    try socket.sendFrame(metadata: AgentFrameMetadata(generation: 1, frameID: 1,
                         width: 256, height: 256, bytesPerPixel: 4), pixels: Data(count: 256 * 256 * 4))
    exit(3)
} catch { exit(0) }
''')
            executable = directory / "sender"
            files = [CORE / name for name in ("CaptureSizeRequest.swift", "AgentFrameDeltaEncoder.swift", "AgentIPCMessage.swift", "AgentFrameAssembler.swift", "AgentUnixSocket.swift")]
            subprocess.run(["swiftc", *map(str, files), str(source), "-o", str(executable)], check=True, capture_output=True)
            path = str(directory / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                process = subprocess.Popen([str(executable), path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    listener.settimeout(5)
                    conn, _ = listener.accept()
                    conn.close()
                    _, error = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error.decode())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_frame_chunk_stream_reconstructs_with_slow_reader(self):
        with short_temp_directory("ipc-") as directory:
            directory = Path(directory)
            source = directory / "main.swift"
            source.write_text('''import Foundation
let socket = try AgentUnixSocket(path: CommandLine.arguments[1])
let pixels = Data((0..<(256 * 256 * 4)).map { UInt8($0 % 251) })
try socket.sendFrame(metadata: AgentFrameMetadata(generation: 9, frameID: 17,
                      width: 256, height: 256, bytesPerPixel: 4), pixels: pixels)
socket.close()
''')
            executable = directory / "sender"
            files = [CORE / name for name in ("CaptureSizeRequest.swift", "AgentFrameDeltaEncoder.swift", "AgentIPCMessage.swift", "AgentFrameAssembler.swift", "AgentUnixSocket.swift")]
            subprocess.run(["swiftc", *map(str, files), str(source), "-o", str(executable)], check=True, capture_output=True)
            path = str(directory / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                process = subprocess.Popen([str(executable), path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    listener.settimeout(5)
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(5)
                        def read_exact(length):
                            result = bytearray()
                            while len(result) < length:
                                chunk = conn.recv(min(4096, length - len(result)))
                                self.assertTrue(chunk, "unexpected socket EOF")
                                result.extend(chunk)
                                time.sleep(.0002)
                            return result
                        def message():
                            header = read_exact(12)
                            magic, version, kind, length = struct.unpack(">4sHHI", header)
                            self.assertEqual((magic, version), (b"RDPA", 1))
                            return kind, read_exact(length)
                        kind, metadata = message()
                        self.assertEqual(kind, 2)
                        self.assertEqual(struct.unpack(">QQIIB", metadata), (9, 17, 256, 256, 4))
                        pixels = bytearray()
                        while len(pixels) < 256 * 256 * 4:
                            kind, payload = message()
                            self.assertEqual(kind, 7)
                            generation, frame, offset = struct.unpack(">QQI", payload[:20])
                            self.assertEqual((generation, frame, offset), (9, 17, len(pixels)))
                            pixels.extend(payload[20:])
                        self.assertEqual(pixels, bytes(index % 251 for index in range(256 * 256 * 4)))
                    _, error = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error.decode())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    # --- Issue 3 (file clipboard): IPC types 13/14/15/16 wire contract -------

    def compile_swift(self, directory, source):
        directory = Path(directory)
        main = directory / "main.swift"
        main.write_text(source)
        executable = directory / "harness"
        result = subprocess.run(
            ["swiftc", *[str(CORE / name) for name in CORE_FILES],
             str(main), "-o", str(executable)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, "swiftc failed:\n" + result.stderr)
        return executable

    @staticmethod
    def wire_frame(message_type, payload):
        """One RDPA frame as the worker side sends it to the Agent."""
        return b"RDPA" + struct.pack(">HHI", 1, message_type, len(payload)) + payload

    def test_clipboard_file_ipc_codec_round_trip_and_bounds(self):
        """Pure codec contract for the new file-clipboard IPC types.

        Mirrors the worker's clipboard_files.h codecs and DESIGN section 3:
        big-endian wire fields, exact payload lengths, limit validation and the
        tolerant decode helper used by the Agent's receive loop.
        """
        with tempfile.TemporaryDirectory(prefix="ipc-codec-", dir="/tmp") as directory:
            source = r'''import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        failures += 1
    }
}
func be16(_ value: UInt16) -> [UInt8] {
    return [UInt8(value >> 8), UInt8(value & 0xff)]
}
func be32(_ value: UInt32) -> [UInt8] {
    return [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}
func be64(_ value: UInt64) -> [UInt8] {
    var bytes: [UInt8] = []
    for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
        bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
    return bytes
}
func beginPayload(_ direction: UInt8, _ fileCount: UInt16, _ totalBytes: UInt64,
                  _ flags: UInt32) -> Data {
    var bytes: [UInt8] = [direction, 0]
    bytes += be16(fileCount)
    bytes += be64(totalBytes)
    bytes += be32(flags)
    return Data(bytes)
}
func throwsError(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

do {
    // --- type 13: offer begin (16 bytes, big-endian) ----------------------
    let begin = AgentClipboardFileOfferBegin(direction: .localToRemote, fileCount: 2,
                                             totalBytes: 123456789, flags: 7)
    let encodedBegin = try AgentIPCCodec.encodeClipboardFileOfferBegin(begin)
    check(encodedBegin.count == AgentIPCCodec.clipboardFileOfferBeginPayloadSize,
          "begin payload size")
    check(Array(encodedBegin) == Array(beginPayload(2, 2, 123456789, 7)),
          "begin wire layout")
    check(try AgentIPCCodec.decodeClipboardFileOfferBegin(encodedBegin) == begin,
          "begin round trip")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(Data(encodedBegin.dropLast()))
    }, "begin short payload")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(beginPayload(3, 1, 0, 0))
    }, "begin bad direction")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(beginPayload(1, 0, 0, 0))
    }, "begin zero files")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(beginPayload(1, 101, 0, 0))
    }, "begin too many files")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(
            beginPayload(1, 1, 4 * 1024 * 1024 * 1024 + 1, 0))
    }, "begin total bytes too large")
    var reservedBad = beginPayload(1, 1, 0, 0)
    reservedBad[1] = 1
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferBegin(reservedBad)
    }, "begin reserved byte")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileOfferBegin(
            AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 0, totalBytes: 0))
    }, "begin encode zero files")

    // --- type 15: offer end (8 bytes) -------------------------------------
    let end = AgentClipboardFileOfferEnd(direction: .remoteToLocal, status: .error,
                                         errorCode: 7, fileCount: 3)
    let encodedEnd = try AgentIPCCodec.encodeClipboardFileOfferEnd(end)
    check(encodedEnd.count == AgentIPCCodec.clipboardFileOfferEndPayloadSize,
          "end payload size")
    check(Array(encodedEnd) == [1, 2] + be16(7) + be32(3), "end wire layout")
    check(try AgentIPCCodec.decodeClipboardFileOfferEnd(encodedEnd) == end, "end round trip")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferEnd(Data([1, 3] + be16(0) + be32(0)))
    }, "end bad status")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferEnd(Data([0, 0] + be16(0) + be32(0)))
    }, "end bad direction")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileOfferEnd(Data([1, 0, 0, 0, 0]))
    }, "end short payload")

    // --- type 16: file entry (18-byte header + UTF-8 name/path) -----------
    let name = "\u{4e2d}\u{6587}.txt"          // 中文.txt, 10 UTF-8 bytes
    let path = "/tmp/\u{4e2d}\u{6587}.txt"     // 15 UTF-8 bytes
    let entry = AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 3,
                                        size: 42, name: name, path: path)
    let encodedEntry = try AgentIPCCodec.encodeClipboardFileEntry(entry)
    check(encodedEntry.count == AgentIPCCodec.clipboardFileEntryHeaderSize
          + name.utf8.count + path.utf8.count, "entry wire length")
    check(encodedEntry[0] == 2 && encodedEntry[1] == 0, "entry direction/reserved")
    check(Array(encodedEntry[2..<4]) == be16(UInt16(name.utf8.count)), "entry name length")
    check(Array(encodedEntry[4..<8]) == be32(3), "entry index")
    check(Array(encodedEntry[8..<16]) == be64(42), "entry size")
    check(Array(encodedEntry[16..<18]) == be16(UInt16(path.utf8.count)), "entry path length")
    check(try AgentIPCCodec.decodeClipboardFileEntry(encodedEntry) == entry,
          "entry round trip")
    let remoteEntry = AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0,
                                              size: 0, name: "a.txt")
    check(try AgentIPCCodec.decodeClipboardFileEntry(
              try AgentIPCCodec.encodeClipboardFileEntry(remoteEntry)) == remoteEntry,
          "remote->local entry round trip")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileEntry(
            AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                    name: "../x"))
    }, "entry traversal name")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileEntry(
            AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0, name: ""))
    }, "entry empty name")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileEntry(
            AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0, size: 0,
                                    name: "a.txt", path: "relative/x"))
    }, "entry relative path")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileEntry(
            AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0,
                                    size: 2 * 1024 * 1024 * 1024, name: "a.txt",
                                    path: "/tmp/a.txt"))
    }, "entry 2GiB size")
    var dir1WithPath: [UInt8] = [1, 0]
    dir1WithPath += be16(3)
    dir1WithPath += be32(0)
    dir1WithPath += be64(0)
    dir1WithPath += be16(0)
    dir1WithPath += Array("p.txt".utf8)
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileEntry(Data(dir1WithPath))
    }, "remote->local entry with path")
    var localWithoutPath: [UInt8] = [2, 0]
    localWithoutPath += be16(3)
    localWithoutPath += be32(0)
    localWithoutPath += be64(0)
    localWithoutPath += be16(0)
    localWithoutPath += Array("a.txt".utf8)
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileEntry(Data(localWithoutPath))
    }, "local->remote entry without path")
    var invalidUtf8: [UInt8] = [1, 0]
    invalidUtf8 += be16(2)
    invalidUtf8 += be32(0)
    invalidUtf8 += be64(0)
    invalidUtf8 += be16(0)
    invalidUtf8 += [0xff, 0xfe]
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileEntry(Data(invalidUtf8))
    }, "entry invalid UTF-8 name")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileEntry(Data(encodedEntry.dropLast()))
    }, "entry truncated payload")

    // --- type 14: file chunk (12-byte header + 1...65524 data bytes) -------
    let chunkData = Data((0..<100).map { UInt8($0 % 251) })
    let chunk = AgentClipboardFileChunk(fileIndex: 7, offset: 65524, data: chunkData)
    let encodedChunk = try AgentIPCCodec.encodeClipboardFileChunk(chunk)
    check(encodedChunk.count == AgentIPCCodec.clipboardFileChunkHeaderSize
          + chunkData.count, "chunk wire length")
    check(Array(encodedChunk[0..<4]) == be32(7), "chunk file index")
    check(Array(encodedChunk[4..<12]) == be64(65524), "chunk offset")
    check(Array(encodedChunk[12...]) == Array(chunkData), "chunk data")
    check(try AgentIPCCodec.decodeClipboardFileChunk(encodedChunk) == chunk,
          "chunk round trip")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileChunk(
            AgentClipboardFileChunk(fileIndex: 0, offset: 0, data: Data()))
    }, "chunk empty data")
    let maxChunk = Data(count: AgentIPCCodec.maxClipboardFileChunkData)
    let encodedMaxChunk = try AgentIPCCodec.encodeClipboardFileChunk(
        AgentClipboardFileChunk(fileIndex: 0, offset: 0, data: maxChunk))
    check(encodedMaxChunk.count == AgentIPCCodec.maxClipboardFileChunkData
          + AgentIPCCodec.clipboardFileChunkHeaderSize, "chunk max size accepted")
    check(throwsError {
        _ = try AgentIPCCodec.encodeClipboardFileChunk(
            AgentClipboardFileChunk(fileIndex: 0, offset: 0,
                                    data: Data(count: AgentIPCCodec.maxClipboardFileChunkData + 1)))
    }, "chunk oversized data")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileChunk(Data(encodedChunk[0..<12]))
    }, "chunk without data")
    check(throwsError {
        _ = try AgentIPCCodec.decodeClipboardFileChunk(Data(encodedChunk[0..<11]))
    }, "chunk shorter than header")

    // --- full-frame wrap and tolerant decoding ----------------------------
    let frame = try AgentIPCCodec.encode(
        AgentIPCMessage(type: .clipboardFileOfferBegin, payload: encodedBegin))
    let decodedMessage = try AgentIPCCodec.decode(frame)
    check(decodedMessage.type == .clipboardFileOfferBegin
          && decodedMessage.payload == encodedBegin, "frame wrap round trip")

    var unknownFrame = Data("RDPA".utf8)
    unknownFrame.append(contentsOf: be16(AgentIPCCodec.version))
    unknownFrame.append(contentsOf: be16(99))
    unknownFrame.append(contentsOf: be32(4))
    unknownFrame.append(contentsOf: [1, 2, 3, 4])
    do {
        switch try AgentIPCCodec.decodeTolerant(unknownFrame) {
        case .ignoredType(let type):
            check(type == 99, "tolerant decode reports the unknown type")
        case .message:
            check(false, "tolerant decode must ignore an unknown type")
        }
    } catch {
        check(false, "tolerant decode threw for an unknown type: \(error)")
    }
    check(throwsError { _ = try AgentIPCCodec.decode(unknownFrame) },
          "strict decode of an unknown type throws")
    do {
        switch try AgentIPCCodec.decodeTolerant(frame) {
        case .message(let message):
            check(message.type == .clipboardFileOfferBegin, "tolerant decode known type")
        case .ignoredType:
            check(false, "tolerant decode must accept a known type")
        }
    } catch {
        check(false, "tolerant decode threw for a known type: \(error)")
    }
    var badMagic = unknownFrame
    badMagic[0] = 0x58
    check(throwsError { _ = try AgentIPCCodec.decodeTolerant(badMagic) },
          "tolerant decode still rejects a bad magic")
} catch {
    print("FAIL: unexpected error \(error)")
    failures += 1
}

print(failures == 0 ? "ok" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
'''
            executable = self.compile_swift(Path(directory), source)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0,
                             "Swift codec checks failed:\n" + result.stdout + result.stderr)

    def test_unknown_ipc_type_is_ignored_and_later_messages_flow(self):
        """The Agent must ignore an unknown IPC message type (once logged per
        type per connection) and keep processing later messages instead of
        throwing and exiting the input receiver."""
        with tempfile.TemporaryDirectory(prefix="ipc-tol-", dir="/tmp") as directory:
            directory = Path(directory)
            source = r'''import Foundation
let socket = try AgentUnixSocket(path: CommandLine.arguments[1])
var handled = 0
do {
    try socket.receiveMessages { message in
        handled += 1
        print("event=wire_message type=\(message.type.rawValue)")
        switch message.type {
        case .clipboardFileOfferBegin:
            let value = try AgentIPCCodec.decodeClipboardFileOfferBegin(message.payload)
            print("event=wire_begin direction=\(value.direction.rawValue) files=\(value.fileCount)")
        case .clipboardFileOfferEnd:
            let value = try AgentIPCCodec.decodeClipboardFileOfferEnd(message.payload)
            print("event=wire_end status=\(value.status.rawValue)")
        default:
            break
        }
        fflush(stdout)
    }
} catch {
    // The fake worker closes the socket when it has sent everything: EOF is the
    // expected end of this test, not a failure.
}
print("event=wire_done handled=\(handled)")
fflush(stdout)
exit(0)
'''
            executable = self.compile_swift(directory, source)
            path = str(directory / "s")
            begin_payload = struct.pack(">BBHQI", 2, 0, 1, 5, 0)   # dir2, count1, 5 bytes
            end_payload = struct.pack(">BBHI", 2, 0, 0, 1)         # dir2, complete, 1 file
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                process = subprocess.Popen([str(executable), path], stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
                try:
                    listener.settimeout(5)
                    conn, _ = listener.accept()
                    with conn:
                        conn.sendall(self.wire_frame(99, b"\x01\x02\x03\x04"))
                        conn.sendall(self.wire_frame(99, b"\x05\x06"))
                        conn.sendall(self.wire_frame(13, begin_payload))
                        conn.sendall(self.wire_frame(15, end_payload))
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 0,
                                     "Agent exited on an unknown IPC type:\n"
                                     + stdout + stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
            self.assertEqual(stderr.count("event=ipc_message_ignored type=99"), 1,
                             "unknown type must be logged exactly once per connection:\n"
                             + stderr)
            self.assertNotIn("type=99", stdout,
                             "an unknown type must not be delivered as a message:\n" + stdout)
            self.assertIn("event=wire_message type=13", stdout)
            self.assertIn("event=wire_begin direction=2 files=1", stdout)
            self.assertIn("event=wire_message type=15", stdout)
            self.assertIn("event=wire_end status=0", stdout)
            self.assertIn("event=wire_done handled=2", stdout)
            self.assertLess(stdout.index("event=wire_message type=13"),
                            stdout.index("event=wire_message type=15"))


if __name__ == "__main__":
    unittest.main()

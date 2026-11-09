import Darwin
import Darwin
import Foundation

// Unit tests for the Issue 3 file clipboard logic
// (docs/DESIGN-2026-11-08-clipboard-files.md §3/§5/§6).
//
// Runs from PermissionSnapshotTests.main() because `make agent-check` compiles
// all MacAgentCore sources plus the test files into one executable with a single
// @main entry point. Plain preconditions keep the existing style of the suite.

enum ClipboardFileTransferTests {
    static func run() throws {
        try codecTests()
        try tolerantDecodeTests()
        unknownTypeLogTests()
        nameValidationTests()
        try localOfferTests()
        try assemblyTests()
        try assemblySecurityTests()
        try directoryLifecycleTests()
        try stagingTests()
        try posixStagingFileSystemTests()
        pasteboardTests()
        try posixFileSystemTests()
        try receiveMessagesToleranceTest()
        print("clipboard_file_tests_ok")
    }

    // MARK: - codec

    private static func codecTests() throws {
        precondition(AgentMessageType.clipboardFileOfferBegin.rawValue == 13)
        precondition(AgentMessageType.clipboardFileChunk.rawValue == 14)
        precondition(AgentMessageType.clipboardFileOfferEnd.rawValue == 15)
        precondition(AgentMessageType.clipboardFileEntry.rawValue == 16)
        precondition(AgentClipboardFileDirection.remoteToLocal.rawValue == 1)
        precondition(AgentClipboardFileDirection.localToRemote.rawValue == 2)
        precondition(AgentClipboardFileEndStatus.complete.rawValue == 0)
        precondition(AgentClipboardFileEndStatus.cancelled.rawValue == 1)
        precondition(AgentClipboardFileEndStatus.error.rawValue == 2)

        // Type 13 begin: exact big-endian layout, 16 bytes.
        let begin = AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 1,
                                                 totalBytes: 0)
        let beginPayload = try AgentIPCCodec.encodeClipboardFileOfferBegin(begin)
        precondition(beginPayload == Data([1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        let decodedBegin = try AgentIPCCodec.decodeClipboardFileOfferBegin(beginPayload)
        precondition(decodedBegin == begin)
        let maxBegin = AgentClipboardFileOfferBegin(direction: .localToRemote, fileCount: 100,
                                                    totalBytes: 4 * 1024 * 1024 * 1024,
                                                    flags: 0)
        let maxBeginPayload = try AgentIPCCodec.encodeClipboardFileOfferBegin(maxBegin)
        let decodedMaxBegin = try AgentIPCCodec.decodeClipboardFileOfferBegin(maxBeginPayload)
        precondition(decodedMaxBegin == maxBegin)
        expectThrows("begin count 0") {
            try AgentIPCCodec.encodeClipboardFileOfferBegin(
                AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 0,
                                             totalBytes: 0))
        }
        expectThrows("begin count 101") {
            try AgentIPCCodec.encodeClipboardFileOfferBegin(
                AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 101,
                                             totalBytes: 0))
        }
        expectThrows("begin total too large") {
            try AgentIPCCodec.encodeClipboardFileOfferBegin(
                AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 1,
                                             totalBytes: 4 * 1024 * 1024 * 1024 + 1))
        }
        for length in [0, 15, 17] {
            expectThrows("begin truncation \(length)") {
                try AgentIPCCodec.decodeClipboardFileOfferBegin(
                    Data(repeating: 0, count: length))
            }
        }
        expectThrows("begin reserved nonzero") {
            try AgentIPCCodec.decodeClipboardFileOfferBegin(
                rawBegin(direction: 1, reserved: 1, fileCount: 1, totalBytes: 0))
        }
        expectThrows("begin invalid direction") {
            try AgentIPCCodec.decodeClipboardFileOfferBegin(
                rawBegin(direction: 3, reserved: 0, fileCount: 1, totalBytes: 0))
        }
        expectThrows("begin decode count 0") {
            try AgentIPCCodec.decodeClipboardFileOfferBegin(
                rawBegin(direction: 1, reserved: 0, fileCount: 0, totalBytes: 0))
        }
        expectThrows("begin decode count 101") {
            try AgentIPCCodec.decodeClipboardFileOfferBegin(
                rawBegin(direction: 1, reserved: 0, fileCount: 101, totalBytes: 0))
        }
        expectThrows("begin decode total too large") {
            try AgentIPCCodec.decodeClipboardFileOfferBegin(
                rawBegin(direction: 1, reserved: 0, fileCount: 1,
                         totalBytes: 4 * 1024 * 1024 * 1024 + 1))
        }

        // Type 16 entry: exact big-endian layout for direction 2.
        let asciiEntry = AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 3,
                                                 size: 5, name: "a", path: "/tmp/a")
        let asciiPayload = try AgentIPCCodec.encodeClipboardFileEntry(asciiEntry)
        precondition(asciiPayload == Data([2, 0, 0, 1, 0, 0, 0, 3,
                                           0, 0, 0, 0, 0, 0, 0, 5, 0, 6,
                                           0x61, 0x2f, 0x74, 0x6d, 0x70, 0x2f, 0x61]))
        let decodedAscii = try AgentIPCCodec.decodeClipboardFileEntry(asciiPayload)
        precondition(decodedAscii == asciiEntry)
        let chinese = AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0,
                                              size: 7, name: "测试.txt")
        let decodedChinese = try AgentIPCCodec.decodeClipboardFileEntry(
            try AgentIPCCodec.encodeClipboardFileEntry(chinese))
        precondition(decodedChinese == chinese)
        let longName = String(repeating: "ä", count: 127)   // 254 UTF-8 bytes
        let longNameEntry = AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 1,
                                                    size: 0, name: longName)
        let decodedLongName = try AgentIPCCodec.decodeClipboardFileEntry(
            try AgentIPCCodec.encodeClipboardFileEntry(longNameEntry))
        precondition(decodedLongName == longNameEntry)
        let emptyFileEntry = AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0,
                                                     size: 0, name: "empty")
        let decodedEmptyFile = try AgentIPCCodec.decodeClipboardFileEntry(
            try AgentIPCCodec.encodeClipboardFileEntry(emptyFileEntry))
        precondition(decodedEmptyFile == emptyFileEntry)

        expectThrows("entry empty name") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                        name: ""))
        }
        expectThrows("entry dot name") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                        name: ".."))
        }
        expectThrows("entry slash name") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                        name: "a/b"))
        }
        expectThrows("entry name 256 bytes") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                        name: String(repeating: "a", count: 256)))
        }
        expectThrows("entry dir1 with path") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0, size: 0,
                                        name: "a", path: "/tmp/a"))
        }
        expectThrows("entry dir2 empty path") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0, size: 0,
                                        name: "a", path: ""))
        }
        expectThrows("entry dir2 relative path") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0, size: 0,
                                        name: "a", path: "tmp/a"))
        }
        expectThrows("entry size 2GiB") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: 0,
                                        size: 2 * 1024 * 1024 * 1024, name: "a"))
        }
        expectThrows("entry path 1024 bytes") {
            try AgentIPCCodec.encodeClipboardFileEntry(
                AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0, size: 0,
                                        name: "a", path: "/" + String(repeating: "a", count: 1023)))
        }
        for length in [0, 17] {
            expectThrows("entry truncation \(length)") {
                try AgentIPCCodec.decodeClipboardFileEntry(Data(repeating: 0, count: length))
            }
        }
        expectThrows("entry reserved nonzero") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 1, reserved: 1, fileIndex: 0, size: 0, name: "a", path: ""))
        }
        expectThrows("entry dir1 carries path bytes") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 1, reserved: 0, fileIndex: 0, size: 0, name: "a",
                         path: "/tmp"))
        }
        expectThrows("entry dir2 without path") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 2, reserved: 0, fileIndex: 0, size: 0, name: "a", path: ""))
        }
        expectThrows("entry declared length mismatch") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 1, reserved: 0, fileIndex: 0, size: 0, name: "a",
                         path: "", extraTrailingBytes: 1))
        }
        expectThrows("entry size 2GiB decode") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 1, reserved: 0, fileIndex: 0,
                         size: 2 * 1024 * 1024 * 1024, name: "a", path: ""))
        }
        expectThrows("entry invalid utf8 name") {
            try AgentIPCCodec.decodeClipboardFileEntry(
                rawEntry(direction: 1, reserved: 0, fileIndex: 0, size: 0,
                         nameBytes: [0xff]))
        }

        // Type 14 chunk: 12-byte header + data, data <= 65524.
        let chunk = AgentClipboardFileChunk(fileIndex: 2, offset: 0x0102030405060708,
                                            data: Data([0xaa, 0xbb]))
        let chunkPayload = try AgentIPCCodec.encodeClipboardFileChunk(chunk)
        precondition(chunkPayload.count == 14)
        precondition(chunkPayload.prefix(12) == Data([0, 0, 0, 2,
                                                      1, 2, 3, 4, 5, 6, 7, 8]))
        let decodedChunk = try AgentIPCCodec.decodeClipboardFileChunk(chunkPayload)
        precondition(decodedChunk == chunk)
        let maxChunk = AgentClipboardFileChunk(
            fileIndex: 0, offset: 0,
            data: Data(repeating: 0x5a, count: AgentIPCCodec.maxClipboardFileChunkData))
        precondition(AgentIPCCodec.maxClipboardFileChunkData == 65524)
        let maxChunkPayload = try AgentIPCCodec.encodeClipboardFileChunk(maxChunk)
        precondition(maxChunkPayload.count == 65536)
        let decodedMaxChunk = try AgentIPCCodec.decodeClipboardFileChunk(maxChunkPayload)
        precondition(decodedMaxChunk == maxChunk)
        expectThrows("chunk empty") {
            try AgentIPCCodec.encodeClipboardFileChunk(
                AgentClipboardFileChunk(fileIndex: 0, offset: 0, data: Data()))
        }
        expectThrows("chunk 65525") {
            try AgentIPCCodec.encodeClipboardFileChunk(
                AgentClipboardFileChunk(fileIndex: 0, offset: 0,
                                        data: Data(repeating: 0, count: 65525)))
        }
        expectThrows("chunk header only") {
            try AgentIPCCodec.decodeClipboardFileChunk(Data(repeating: 0, count: 12))
        }
        expectThrows("chunk truncated header") {
            try AgentIPCCodec.decodeClipboardFileChunk(Data(repeating: 0, count: 11))
        }
        expectThrows("chunk oversized decode") {
            try AgentIPCCodec.decodeClipboardFileChunk(Data(repeating: 0, count: 65537))
        }

        // Type 15 end: exact 8 bytes.
        let end = AgentClipboardFileOfferEnd(direction: .remoteToLocal, status: .error,
                                             errorCode: 0x1234, fileCount: 7)
        let endPayload = try AgentIPCCodec.encodeClipboardFileOfferEnd(end)
        precondition(endPayload == Data([1, 2, 0x12, 0x34, 0, 0, 0, 7]))
        let decodedEnd = try AgentIPCCodec.decodeClipboardFileOfferEnd(endPayload)
        precondition(decodedEnd == end)
        for status in [AgentClipboardFileEndStatus.complete, .cancelled, .error] {
            let value = AgentClipboardFileOfferEnd(direction: .localToRemote, status: status,
                                                  errorCode: 0, fileCount: 3)
            let decodedValue = try AgentIPCCodec.decodeClipboardFileOfferEnd(
                try AgentIPCCodec.encodeClipboardFileOfferEnd(value))
            precondition(decodedValue == value)
        }
        for length in [0, 7, 9] {
            expectThrows("end truncation \(length)") {
                try AgentIPCCodec.decodeClipboardFileOfferEnd(Data(repeating: 0, count: length))
            }
        }
        expectThrows("end invalid status") {
            try AgentIPCCodec.decodeClipboardFileOfferEnd(Data([1, 3, 0, 0, 0, 0, 0, 0]))
        }
        expectThrows("end invalid direction") {
            try AgentIPCCodec.decodeClipboardFileOfferEnd(Data([0, 0, 0, 0, 0, 0, 0, 0]))
        }
    }

    // MARK: - tolerant frame decode (unknown type)

    private static func tolerantDecodeTests() throws {
        let unknown = frame(rawType: 99, payload: Data([1, 2, 3]))
        if case let .ignoredType(rawType) = try AgentIPCCodec.decodeTolerant(unknown) {
            precondition(rawType == 99)
        } else {
            preconditionFailure("unknown type must be ignored")
        }
        expectThrows("strict decode still throws unknown") {
            try AgentIPCCodec.decode(unknown)
        }
        // Known types decode normally.
        let begin = AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 1,
                                                 totalBytes: 4)
        let known = try AgentIPCCodec.encode(
            AgentIPCMessage(type: .clipboardFileOfferBegin,
                            payload: try AgentIPCCodec.encodeClipboardFileOfferBegin(begin)))
        if case let .message(message) = try AgentIPCCodec.decodeTolerant(known) {
            precondition(message.type == .clipboardFileOfferBegin)
            let decodedBegin = try AgentIPCCodec.decodeClipboardFileOfferBegin(message.payload)
            precondition(decodedBegin == begin)
        } else {
            preconditionFailure("known type must decode")
        }
        // Version mismatch / bad magic / bad length still throw.
        expectThrows("tolerant version mismatch") {
            try AgentIPCCodec.decodeTolerant(frame(rawType: 99, payload: Data(), version: 2))
        }
        expectThrows("tolerant bad magic") {
            try AgentIPCCodec.decodeTolerant(frame(rawType: 99, payload: Data(),
                                                   magic: "XXXX"))
        }
        expectThrows("tolerant short header") {
            try AgentIPCCodec.decodeTolerant(Data("RDPA".utf8))
        }
        var badLength = Data("RDPA".utf8)
        badLength.append(contentsOf: [0, 1, 0, 99, 0, 0, 0, 4])
        expectThrows("tolerant declared length mismatch") {
            try AgentIPCCodec.decodeTolerant(badLength)
        }
        var tooLarge = Data("RDPA".utf8)
        tooLarge.append(contentsOf: [0, 1, 0, 99, 0, 1, 0, 1])
        expectThrows("tolerant payload too large") {
            try AgentIPCCodec.decodeTolerant(tooLarge)
        }
    }

    private static func unknownTypeLogTests() {
        var log = AgentIPCUnknownTypeLog()
        precondition(log.shouldLog(99))
        precondition(!log.shouldLog(99))
        precondition(log.shouldLog(77))
        precondition(!log.shouldLog(77))
        precondition(log.shouldLog(99) == false)
        var expectedLog = AgentIPCUnknownTypeLog()
        _ = expectedLog.shouldLog(99)
        _ = expectedLog.shouldLog(77)
        precondition(log == expectedLog)
    }

    // MARK: - name / path validation

    private static func nameValidationTests() {
        let valid = AgentClipboardFileValidation.isValidName
        precondition(valid("a.txt"))
        precondition(valid("中文名.txt"))
        precondition(valid("-leading-dash"))
        precondition(valid("with space.txt"))
        precondition(valid(String(repeating: "a", count: 255)))
        precondition(!valid(""))
        precondition(!valid("."))
        precondition(!valid(".."))
        precondition(!valid("a/b"))
        precondition(!valid("a\\b"))
        precondition(!valid("a:b"))
        precondition(!valid("a\0b"))
        precondition(!valid("a\u{7f}b"))
        precondition(!valid("a\nb"))
        precondition(!valid(String(repeating: "a", count: 256)))
        precondition(!valid(String(repeating: "中", count: 86)))   // 258 UTF-8 bytes
        // C1 controls and bidi formatting must be rejected on both sides
        // (worker clipboard_files.h + this Swift mirror, design §5).
        precondition(!valid("a\u{85}b"))            // U+0085 NEL (C1)
        precondition(!valid("a\u{80}b"))            // U+0080 C1 lower bound
        precondition(!valid("a\u{9f}b"))            // U+009F C1 upper bound
        precondition(!valid("a\u{200e}b"))          // LRM
        precondition(!valid("a\u{200f}b"))          // RLM
        precondition(!valid("a\u{202a}b"))          // LRE
        precondition(!valid("a\u{202e}b"))          // RLO
        precondition(!valid("a\u{2066}b"))          // LRI
        precondition(!valid("a\u{2069}b"))          // PDI
        precondition(valid("a\u{a0}b"))             // NBSP is not a control

        let validPath = AgentClipboardFileValidation.isValidAbsolutePath
        precondition(validPath("/tmp/a.txt"))
        precondition(validPath("/"))
        precondition(validPath("/" + String(repeating: "a", count: 1022)))
        precondition(!validPath(""))
        precondition(!validPath("tmp/a"))
        precondition(!validPath("/tmp/a\0b"))
        precondition(!validPath("/tmp/a\nb"))
        precondition(!validPath("/" + String(repeating: "a", count: 1023)))
        precondition(!validPath("/tmp/\u{85}evil"))
        precondition(!validPath("/tmp/\u{202e}evil"))
    }

    // MARK: - local -> remote offer builder

    private static func localOfferTests() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"),
                    URL(fileURLWithPath: "/tmp/中文.bin"),
                    URL(fileURLWithPath: "/tmp/empty.dat")]
        let files: [(size: Int, path: String)] = [
            (size: 10, path: "/tmp/a.txt"),
            (size: 0, path: "/tmp/中文.bin"),
            (size: 3, path: "/tmp/empty.dat"),
        ]
        let offer = try ClipboardLocalFileOfferBuilder.build(
            urls: urls, source: FakeLocalFileSource(files: files))
        precondition(offer.begin.direction == .localToRemote)
        precondition(offer.begin.fileCount == 3)
        precondition(offer.begin.totalBytes == 13)
        precondition(offer.entries.count == 3)
        for (index, entry) in offer.entries.enumerated() {
            precondition(entry.direction == .localToRemote)
            precondition(entry.fileIndex == UInt32(index))
            precondition(entry.path == urls[index].path)
            precondition(entry.name == urls[index].lastPathComponent)
        }
        precondition(offer.entries[0].size == 10)
        precondition(offer.entries[1].name == "中文.bin")
        precondition(offer.entries[1].size == 0)
        precondition(offer.end.direction == .localToRemote)
        precondition(offer.end.status == .complete)
        precondition(offer.end.fileCount == 3)

        let messages = try offer.messages()
        precondition(messages.count == 5)
        precondition(messages.first?.type == .clipboardFileOfferBegin)
        precondition(messages.last?.type == .clipboardFileOfferEnd)
        precondition(messages[1].type == .clipboardFileEntry)
        let decodedMessagesBegin = try AgentIPCCodec.decodeClipboardFileOfferBegin(
            messages[0].payload)
        precondition(decodedMessagesBegin == offer.begin)
        for (index, message) in messages[1...3].enumerated() {
            let decodedMessageEntry = try AgentIPCCodec.decodeClipboardFileEntry(
                message.payload)
            precondition(decodedMessageEntry == offer.entries[index])
        }
        let decodedMessagesEnd = try AgentIPCCodec.decodeClipboardFileOfferEnd(
            messages[4].payload)
        precondition(decodedMessagesEnd == offer.end)

        expectThrows("offer empty") {
            try ClipboardLocalFileOfferBuilder.build(
                urls: [], source: FakeLocalFileSource(files: []))
        }
        expectThrows("offer too many files") {
            let many = (0...AgentIPCCodec.maxClipboardFiles).map {
                URL(fileURLWithPath: "/tmp/file-\($0)")
            }
            let files = many.map { (size: 1, path: $0.path) }
            _ = try ClipboardLocalFileOfferBuilder.build(
                urls: many, source: FakeLocalFileSource(files: files))
        }
        expectThrows("offer invalid file") {
            try ClipboardLocalFileOfferBuilder.build(
                urls: [URL(fileURLWithPath: "/tmp/missing")],
                source: FakeLocalFileSource(files: []))
        }
        expectThrows("offer bad name") {
            try ClipboardLocalFileOfferBuilder.build(
                urls: [URL(fileURLWithPath: "/tmp/a.txt")],
                source: FakeLocalFileSource(raw: [
                    "/tmp/a.txt": ClipboardLocalFileMetadata(name: "../evil", path: "/tmp/a.txt",
                                                             size: 1)]))
        }
        expectThrows("offer bad path") {
            try ClipboardLocalFileOfferBuilder.build(
                urls: [URL(fileURLWithPath: "/tmp/a.txt")],
                source: FakeLocalFileSource(raw: [
                    "/tmp/a.txt": ClipboardLocalFileMetadata(name: "a.txt", path: "tmp/a.txt",
                                                             size: 1)]))
        }
        expectThrows("offer file 2GiB") {
            try ClipboardLocalFileOfferBuilder.build(
                urls: [URL(fileURLWithPath: "/tmp/a.txt")],
                source: FakeLocalFileSource(files: [
                    (size: Int(AgentIPCCodec.maxClipboardFileBytes), path: "/tmp/a.txt")]))
        }
        expectThrows("offer total > 4GiB") {
            let big = Int(AgentIPCCodec.maxClipboardFileBytes) - 1     // just under 2 GiB
            let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/big-\($0)") }
            let files = urls.map { (size: big, path: $0.path) }
            _ = try ClipboardLocalFileOfferBuilder.build(
                urls: urls, source: FakeLocalFileSource(files: files))
        }
        // 100 files each exactly 1 byte is fine and fileIndex is sequential.
        let hundred = (0..<100).map { URL(fileURLWithPath: "/tmp/f\($0)") }
        let hundredFiles = hundred.map { (size: 1, path: $0.path) }
        let hundredOffer = try ClipboardLocalFileOfferBuilder.build(
            urls: hundred, source: FakeLocalFileSource(files: hundredFiles))
        precondition(hundredOffer.entries.count == 100)
        precondition(hundredOffer.entries.last?.fileIndex == 99)
        precondition(hundredOffer.end.fileCount == 100)
    }

    // MARK: - assembly state machine (in-order and protocol errors)

    private static func assemblyTests() throws {
        // In-order, two files, one Chinese name.
        let fs = MemoryClipboardFileSystem()
        let assembler = ClipboardFileAssembler(fileSystem: fs)
        var events = assembler.handle(beginMessage(count: 2, total: 5))
        precondition(events == [.offerStarted(fileCount: 2, totalBytes: 5)])
        precondition(assembler.isAssembling)
        let firstURL = assembler.currentOfferDirectoryURL
        precondition(firstURL != nil)
        events = assembler.handle(entryMessage(index: 0, size: 3, name: "a.txt"))
        precondition(events.isEmpty)
        events = assembler.handle(entryMessage(index: 1, size: 2, name: "中文.txt"))
        precondition(events.isEmpty)
        events = assembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1, 2]))
        precondition(events.isEmpty)
        events = assembler.handle(chunkMessage(index: 0, offset: 2, bytes: [3]))
        precondition(events.count == 1)
        guard case let .fileFinished(index, _, url) = events[0] else {
            preconditionFailure("expected fileFinished")
        }
        precondition(index == 0)
        precondition(url.lastPathComponent == "a.txt")
        precondition(fs.filesData(at: url) == Data([1, 2, 3]))
        events = assembler.handle(chunkMessage(index: 1, offset: 0, bytes: [4, 5]))
        precondition(events.count == 1)
        guard case let .fileFinished(index1, _, url1) = events[0] else {
            preconditionFailure("expected fileFinished")
        }
        precondition(index1 == 1)
        precondition(url1.lastPathComponent == "中文.txt")
        events = assembler.handle(endMessage(status: .complete, fileCount: 2))
        guard events.count == 1, case let .offerCompleted(urls, totalBytes) = events[0] else {
            preconditionFailure("expected offerCompleted")
        }
        precondition(urls == [url, url1])
        precondition(totalBytes == 5)
        precondition(!assembler.isAssembling)
        // Completed directory is kept for the pasteboard, no second directory yet.
        precondition(assembler.previousOfferDirectoryURL == nil)
        precondition(fs.removedDirectories.isEmpty)

        // Empty zero-byte files complete without chunks (leading and trailing).
        let zeroFS = MemoryClipboardFileSystem()
        let zeroAssembler = ClipboardFileAssembler(fileSystem: zeroFS)
        _ = zeroAssembler.handle(beginMessage(count: 3, total: 2))
        _ = zeroAssembler.handle(entryMessage(index: 0, size: 0, name: "empty-0"))
        _ = zeroAssembler.handle(entryMessage(index: 1, size: 2, name: "data"))
        _ = zeroAssembler.handle(entryMessage(index: 2, size: 0, name: "empty-2"))
        events = zeroAssembler.handle(chunkMessage(index: 1, offset: 0, bytes: [9, 9]))
        guard events.count == 3,
              case let .fileFinished(firstIndex, _, first) = events[0],
              case let .fileFinished(secondIndex, _, second) = events[1],
              case let .fileFinished(trailingIndex, _, trailingURL) = events[2] else {
            preconditionFailure("expected empty + data + trailing empty completion")
        }
        precondition(firstIndex == 0 && first.lastPathComponent == "empty-0")
        precondition(secondIndex == 1 && second.lastPathComponent == "data")
        precondition(trailingIndex == 2 && trailingURL.lastPathComponent == "empty-2")
        events = zeroAssembler.handle(endMessage(status: .complete, fileCount: 3))
        guard events.count == 1, case let .offerCompleted(urls, total) = events[0] else {
            preconditionFailure("expected offer completion")
        }
        precondition(total == 2)
        precondition(urls.count == 3)
        precondition(zeroFS.filesData(at: urls[0]).isEmpty)

        // Gaps / overlaps / overflow / out-of-order are rejected and clean up.
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
                return assembler.handle(chunkMessage(index: 0, offset: 2, bytes: [1]))
            },
            expected: .chunkGap(index: 0, expected: 0, actual: 2))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
                _ = assembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1, 2]))
                return assembler.handle(chunkMessage(index: 0, offset: 1, bytes: [3]))
            },
            expected: .chunkOverlap(index: 0, expected: 2, actual: 1))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
                return assembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1, 2, 3, 4, 5]))
            },
            expected: .chunkOverflow(index: 0, expectedLength: 4, actualLength: 5))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 2, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 2, name: "a"))
                _ = assembler.handle(entryMessage(index: 1, size: 2, name: "b"))
                return assembler.handle(chunkMessage(index: 1, offset: 0, bytes: [1]))
            },
            expected: .outOfOrderChunk(index: 1))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                return assembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1]))
            },
            expected: .missingEntry(index: 0))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
                return assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
            },
            expected: .duplicateEntry(index: 0))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 1, total: 4))
                return assembler.handle(entryMessage(index: 3, size: 4, name: "x"))
            },
            expected: .entryIndexOutOfRange(index: 3))
        expectAssemblyFailure(
            setup: { assembler in
                _ = assembler.handle(beginMessage(count: 2, total: 4))
                _ = assembler.handle(entryMessage(index: 0, size: 4, name: "x"))
                return assembler.handle(entryMessage(index: 1, size: 2, name: "y"))
            },
            expected: .entriesExceedTotal(index: 1))

        // End before any chunk: incomplete offer, directory removed.
        let shortFS = MemoryClipboardFileSystem()
        let shortAssembler = ClipboardFileAssembler(fileSystem: shortFS)
        _ = shortAssembler.handle(beginMessage(count: 1, total: 2))
        _ = shortAssembler.handle(entryMessage(index: 0, size: 2, name: "x"))
        _ = shortAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1]))
        events = shortAssembler.handle(endMessage(status: .complete, fileCount: 1))
        guard case let .offerFailed(reason)? = events.first else {
            preconditionFailure("expected failure")
        }
        precondition(reason == .incompleteOffer(received: 2, expected: 2))
        precondition(!shortAssembler.isAssembling)
        precondition(shortFS.removedDirectories.count == 1)

        // Advertised total != sum of entries.
        let totalFS = MemoryClipboardFileSystem()
        let totalAssembler = ClipboardFileAssembler(fileSystem: totalFS)
        _ = totalAssembler.handle(beginMessage(count: 1, total: 10))
        _ = totalAssembler.handle(entryMessage(index: 0, size: 2, name: "x"))
        _ = totalAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1, 2]))
        events = totalAssembler.handle(endMessage(status: .complete, fileCount: 1))
        guard case let .offerFailed(totalReason)? = events.first else {
            preconditionFailure("expected failure")
        }
        precondition(totalReason == .totalSizeMismatch(entries: 2, advertised: 10))
        precondition(totalFS.removedDirectories.count == 1)

        // Peer cancel / peer error clean up and stop assembling.
        let cancelFS = MemoryClipboardFileSystem()
        let cancelAssembler = ClipboardFileAssembler(fileSystem: cancelFS)
        _ = cancelAssembler.handle(beginMessage(count: 1, total: 4))
        _ = cancelAssembler.handle(entryMessage(index: 0, size: 4, name: "x"))
        _ = cancelAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1]))
        events = cancelAssembler.handle(endMessage(status: .cancelled, fileCount: 1))
        precondition(events == [.offerCancelled])
        precondition(!cancelAssembler.isAssembling)
        precondition(cancelFS.removedDirectories.count == 1)

        let errorFS = MemoryClipboardFileSystem()
        let errorAssembler = ClipboardFileAssembler(fileSystem: errorFS)
        _ = errorAssembler.handle(beginMessage(count: 1, total: 4))
        events = errorAssembler.handle(endMessage(status: .error, errorCode: 7, fileCount: 1))
        guard case let .offerFailed(peerError)? = events.first else {
            preconditionFailure("expected peer failure")
        }
        precondition(peerError == .failedByPeer(errorCode: 7))
        precondition(errorFS.removedDirectories.count == 1)

        // A new begin implicitly cancels the in-flight offer.
        let restartFS = MemoryClipboardFileSystem()
        let restartAssembler = ClipboardFileAssembler(fileSystem: restartFS)
        _ = restartAssembler.handle(beginMessage(count: 1, total: 4))
        let firstDirectory = restartAssembler.currentOfferDirectoryURL
        events = restartAssembler.handle(beginMessage(count: 1, total: 2))
        precondition(events.count == 2)
        precondition(events[0] == .offerCancelled)
        guard case let .offerStarted(count, _) = events[1] else {
            preconditionFailure("expected offerStarted")
        }
        precondition(count == 1)
        precondition(restartFS.removedDirectories == [firstDirectory!])
        precondition(restartAssembler.currentOfferDirectoryURL != firstDirectory)

        // Unsupported direction-2 messages from the Worker are ignored.
        let directionFS = MemoryClipboardFileSystem()
        let directionAssembler = ClipboardFileAssembler(fileSystem: directionFS)
        let directionTwoBegin = AgentClipboardFileOfferBegin(direction: .localToRemote,
                                                             fileCount: 1, totalBytes: 0)
        events = directionAssembler.handle(AgentIPCMessage(
            type: .clipboardFileOfferBegin,
            payload: try AgentIPCCodec.encodeClipboardFileOfferBegin(directionTwoBegin)))
        precondition(events.isEmpty)
        precondition(!directionAssembler.isAssembling)
        // Idle entry/chunk produce a failure event, idle end is benign.
        events = directionAssembler.handle(entryMessage(index: 0, size: 1, name: "x"))
        precondition(events == [.offerFailed(.unexpectedEntry)])
        events = directionAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1]))
        precondition(events == [.offerFailed(.unexpectedChunk)])
        precondition(directionAssembler.handle(endMessage(status: .complete,
                                                          fileCount: 1)).isEmpty)
        // abort() cleans up an active offer; no-op when idle.
        _ = directionAssembler.handle(beginMessage(count: 1, total: 1))
        precondition(directionAssembler.abort(reason: .unexpectedChunk)
            == [.offerFailed(.unexpectedChunk)])
        precondition(directionAssembler.abort(reason: .unexpectedChunk).isEmpty)
        precondition(directionFS.removedDirectories.count == 1)
    }

    // MARK: - assembly security (untrusted names, sizes, limits, raw bytes)

    private static func assemblySecurityTests() throws {
        // Path-traversal / absolute / control-char names are rejected.
        for badName in ["../evil", "/etc/passwd", "a/b", "a\\b", "C:evil", "..", ".",
                        "a\u{0}b", "a\nb"] {
            let fs = MemoryClipboardFileSystem()
            let assembler = ClipboardFileAssembler(fileSystem: fs)
            _ = assembler.handle(beginMessage(count: 1, total: 1))
            let raw = rawEntry(direction: 1, reserved: 0, fileIndex: 0, size: 1,
                               nameBytes: Array(badName.utf8))
            let events = assembler.handle(AgentIPCMessage(type: .clipboardFileEntry,
                                                          payload: raw))
            guard case let .offerFailed(reason)? = events.first, case .invalidName = reason else {
                preconditionFailure("expected invalidName for \(badName), got \(events)")
            }
            precondition(!assembler.isAssembling)
            precondition(fs.removedDirectories.count == 1)
            precondition(fs.createdNames.isEmpty)
        }
        // A valid name with a UTF-8 multibyte component is accepted.
        let unicodeFS = MemoryClipboardFileSystem()
        let unicodeAssembler = ClipboardFileAssembler(fileSystem: unicodeFS)
        _ = unicodeAssembler.handle(beginMessage(count: 1, total: 1))
        let unicodeEntry = rawEntry(direction: 1, reserved: 0, fileIndex: 0, size: 1,
                                    nameBytes: Array("中文".utf8))
        _ = unicodeAssembler.handle(AgentIPCMessage(type: .clipboardFileEntry,
                                                    payload: unicodeEntry))
        _ = unicodeAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [7]))
        let unicodeEvents = unicodeAssembler.handle(endMessage(status: .complete, fileCount: 1))
        guard case let .offerCompleted(unicodeURLs, _)? = unicodeEvents.first else {
            preconditionFailure("expected completion")
        }
        precondition(unicodeURLs[0].lastPathComponent == "中文")

        // Entry size >= 2 GiB is rejected by the decoder (invalidMessage).
        let bigFS = MemoryClipboardFileSystem()
        let bigAssembler = ClipboardFileAssembler(fileSystem: bigFS)
        _ = bigAssembler.handle(beginMessage(count: 1, total: 4))
        let bigEntry = bigAssembler.handle(AgentIPCMessage(
            type: .clipboardFileEntry,
            payload: rawEntry(direction: 1, reserved: 0, fileIndex: 0,
                              size: 2 * 1024 * 1024 * 1024, name: "big", path: "")))
        guard case let .offerFailed(bigReason)? = bigEntry.first else {
            preconditionFailure("expected failure")
        }
        precondition(bigReason == .invalidMessage)
        precondition(!bigAssembler.isAssembling)

        // fileCount > 100 / zero begin are rejected (raw payloads bypass encode).
        let countFS = MemoryClipboardFileSystem()
        let countAssembler = ClipboardFileAssembler(fileSystem: countFS)
        do {
            let events = countAssembler.handle(AgentIPCMessage(
                type: .clipboardFileOfferBegin,
                payload: rawBegin(direction: 1, reserved: 0, fileCount: 101,
                                  totalBytes: 0)))
            guard case let .offerFailed(countReason)? = events.first else {
                preconditionFailure("expected failure")
            }
            // The strict codec already rejects count > 100 at decode time.
            precondition(countReason == .invalidMessage)
        }
        let zeroBeginAssembler = ClipboardFileAssembler(fileSystem: MemoryClipboardFileSystem())
        let zeroBeginEvents = zeroBeginAssembler.handle(AgentIPCMessage(
            type: .clipboardFileOfferBegin,
            payload: rawBegin(direction: 1, reserved: 0, fileCount: 0, totalBytes: 0)))
        guard case let .offerFailed(zeroReason)? = zeroBeginEvents.first else {
            preconditionFailure("expected failure")
        }
        precondition(zeroReason == .invalidMessage)
        // Malformed begin payload (truncated) is rejected too.
        let malformedAssembler = ClipboardFileAssembler(fileSystem: MemoryClipboardFileSystem())
        let malformedEvents = malformedAssembler.handle(AgentIPCMessage(
            type: .clipboardFileOfferBegin, payload: Data(repeating: 0, count: 15)))
        guard case let .offerFailed(malformedReason)? = malformedEvents.first else {
            preconditionFailure("expected failure")
        }
        precondition(malformedReason == .invalidMessage)

        // totalBytes > 4 GiB in a raw begin is rejected.
        let totalFS = MemoryClipboardFileSystem()
        let totalAssembler = ClipboardFileAssembler(fileSystem: totalFS)
        let totalEvents = totalAssembler.handle(AgentIPCMessage(
            type: .clipboardFileOfferBegin,
            payload: rawBegin(direction: 1, reserved: 0, fileCount: 1,
                              totalBytes: 4 * 1024 * 1024 * 1024 + 1)))
        guard case let .offerFailed(totalReason)? = totalEvents.first else {
            preconditionFailure("expected failure")
        }
        precondition(totalReason == .invalidMessage)

        // Direction 2 entries from the Worker are a protocol violation.
        let wrongFS = MemoryClipboardFileSystem()
        let wrongAssembler = ClipboardFileAssembler(fileSystem: wrongFS)
        _ = wrongAssembler.handle(beginMessage(count: 1, total: 1))
        do {
            let wrongEntry = AgentClipboardFileEntry(direction: .localToRemote, fileIndex: 0,
                                                    size: 1, name: "x", path: "/tmp/x")
            let events = wrongAssembler.handle(AgentIPCMessage(
                type: .clipboardFileEntry,
                payload: try AgentIPCCodec.encodeClipboardFileEntry(wrongEntry)))
            guard case let .offerFailed(wrongReason)? = events.first else {
                preconditionFailure("expected failure")
            }
            precondition(wrongReason == .wrongDirection)
        }
        precondition(wrongFS.removedDirectories.count == 1)

        // A file system failure fails the offer and removes the directory.
        let throwingFS = MemoryClipboardFileSystem()
        throwingFS.failCreateFile = true
        let throwingAssembler = ClipboardFileAssembler(fileSystem: throwingFS)
        _ = throwingAssembler.handle(beginMessage(count: 1, total: 2))
        _ = throwingAssembler.handle(entryMessage(index: 0, size: 2, name: "x"))
        let ioEvents = throwingAssembler.handle(chunkMessage(index: 0, offset: 0, bytes: [1, 2]))
        guard case let .offerFailed(ioReason)? = ioEvents.first, case .fileSystem = ioReason else {
            preconditionFailure("expected fileSystem failure")
        }
        precondition(!throwingAssembler.isAssembling)
        precondition(throwingFS.removedDirectories.count == 1)
    }

    // MARK: - temp directory lifecycle

    private static func directoryLifecycleTests() throws {
        // current + previous only; the oldest directory is deleted on a new begin.
        let fs = MemoryClipboardFileSystem()
        let assembler = ClipboardFileAssembler(fileSystem: fs)
        _ = assembler.handle(beginMessage(count: 1, total: 0))
        let directoryA = assembler.currentOfferDirectoryURL!
        _ = assembler.handle(entryMessage(index: 0, size: 0, name: "a"))
        _ = assembler.handle(endMessage(status: .complete, fileCount: 1))
        _ = assembler.handle(beginMessage(count: 1, total: 0))
        let directoryB = assembler.currentOfferDirectoryURL!
        precondition(assembler.previousOfferDirectoryURL == directoryA)
        precondition(fs.removedDirectories.isEmpty)
        _ = assembler.handle(entryMessage(index: 0, size: 0, name: "b"))
        _ = assembler.handle(endMessage(status: .complete, fileCount: 1))
        _ = assembler.handle(beginMessage(count: 1, total: 0))
        let directoryC = assembler.currentOfferDirectoryURL!
        precondition(fs.removedDirectories == [directoryA])
        precondition(assembler.previousOfferDirectoryURL == directoryB)
        _ = assembler.handle(endMessage(status: .cancelled, fileCount: 1))
        // Cancelling the active offer removes only the current directory.
        precondition(assembler.currentOfferDirectoryURL == nil)
        precondition(assembler.previousOfferDirectoryURL == directoryB)
        precondition(fs.removedDirectories == [directoryA, directoryC])
    }

    // MARK: - pasteboard conversion

    private static func pasteboardTests() {
        let fileURL = URL(fileURLWithPath: "/tmp/a.txt")
        let webURL = URL(string: "https://example.com/x")!
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: nil) == nil)
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: []) == nil)
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: [fileURL]) == [fileURL])
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: [fileURL as NSURL]) == [fileURL])
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: ["/tmp/b.txt"])
            == [URL(fileURLWithPath: "/tmp/b.txt")])
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: ["relative.txt"]) == nil)
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: [webURL]) == nil)
        precondition(ClipboardPasteboardFileURLs.fileURLs(
            from: [fileURL, webURL, "/tmp/b.txt"] as [Any]) ==
            [fileURL, URL(fileURLWithPath: "/tmp/b.txt")])
        precondition(ClipboardPasteboardFileURLs.fileURLs(from: [42]) == nil)

        precondition(ClipboardLocalClipboardDetector.content(fileURLs: [fileURL], text: "hi")
            == .files([fileURL]))
        precondition(ClipboardLocalClipboardDetector.content(fileURLs: nil, text: "hi")
            == .text("hi"))
        precondition(ClipboardLocalClipboardDetector.content(fileURLs: [], text: nil) == .empty)
        precondition(ClipboardLocalClipboardDetector.content(fileURLs: nil, text: "") == .empty)

        let pasteboard = FakePasteboard()
        precondition(ClipboardRemotePasteboardWriter.applyFileURLs([fileURL], to: pasteboard))
        precondition(pasteboard.writeFileURLCalls == [[fileURL]])
        precondition(!ClipboardRemotePasteboardWriter.applyFileURLs([], to: pasteboard))
        precondition(pasteboard.writeFileURLCalls.count == 1)
    }

    // MARK: - real POSIX temp directory implementation

    private static func posixFileSystemTests() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rdp-clipboard-test-\(UUID().uuidString)", isDirectory: true)
        let fileSystem = PosixClipboardFileAssemblyFileSystem(rootDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try fileSystem.createOfferDirectory()
        var status = stat()
        precondition(lstat(directory.url.path, &status) == 0)
        precondition(status.st_mode & 0o777 == 0o700)
        precondition(status.st_mode & S_IFMT == S_IFDIR)

        let handle = try fileSystem.createFile(named: "中文.txt", in: directory)
        var fileStatus = stat()
        precondition(lstat(directory.url.appendingPathComponent("中文.txt").path, &fileStatus) == 0)
        precondition(fileStatus.st_mode & 0o777 == 0o600)
        precondition(fileStatus.st_mode & S_IFMT == S_IFREG)
        try fileSystem.append(Data([1, 2, 3]), to: handle)
        let fileURL = try fileSystem.finish(handle)
        precondition(fileURL.lastPathComponent == "中文.txt")
        let written = try Data(contentsOf: fileURL)
        precondition(written == Data([1, 2, 3]))

        // O_EXCL: the same file cannot be created twice.
        expectThrows("posix O_EXCL") {
            _ = try fileSystem.createFile(named: "中文.txt", in: directory)
        }
        // Traversal names never reach open(2).
        expectThrows("posix traversal name") {
            _ = try fileSystem.createFile(named: "../evil", in: directory)
        }
        expectThrows("posix absolute name") {
            _ = try fileSystem.createFile(named: "/tmp/evil", in: directory)
        }

        let second = try fileSystem.createOfferDirectory()
        fileSystem.removeDirectory(directory)
        precondition(!FileManager.default.fileExists(atPath: directory.url.path))
        fileSystem.removeDirectory(second)
        precondition(!FileManager.default.fileExists(atPath: second.url.path))
    }

    // MARK: - receiveMessages: unknown types are ignored, keep-alive verified

    private static func receiveMessagesToleranceTest() throws {
        // AF_UNIX paths are limited to 104 bytes, so keep this short.
        let socketPath = "/tmp/rdp-ipc-\(UUID().uuidString.prefix(8)).sock"
        unlink(socketPath)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listenFD >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0)
        precondition(Darwin.listen(listenFD, 1) == 0)
        defer {
            Darwin.close(listenFD)
            unlink(socketPath)
        }

        // Capture stderr for the unknown-type log line assertion.
        let logPath = "/tmp/rdp-ipc-log-\(UUID().uuidString.prefix(8)).log"
        unlink(logPath)
        let savedStderr = dup(2)
        let logFD = open(logPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        precondition(savedStderr >= 0 && logFD >= 0)
        dup2(logFD, 2)

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var receivedTypes: [UInt16] = []
        var endValue: AgentClipboardFileOfferEnd?
        DispatchQueue(label: "rdp-agent-ipc-test.receiver").async {
            defer { done.signal() }
            do {
                let socket = try AgentUnixSocket(path: socketPath)
                try socket.receiveMessages { message in
                    lock.lock()
                    receivedTypes.append(message.type.rawValue)
                    if message.type == .clipboardFileOfferEnd {
                        endValue = try? AgentIPCCodec.decodeClipboardFileOfferEnd(message.payload)
                    }
                    lock.unlock()
                }
            } catch {
                // Expected: the test server closes the socket at the end.
            }
        }

        var clientAddress = sockaddr_un()
        var clientLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFD, $0, &clientLength)
            }
        }
        precondition(clientFD >= 0)
        defer { Darwin.close(clientFD) }

        // Unknown type 99 twice, then a valid begin (13) and end (15).
        writeAll(clientFD, frame(rawType: 99, payload: Data([0xde, 0xad])))
        writeAll(clientFD, frame(rawType: 99, payload: Data([0xbe, 0xef])))
        let begin = AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: 1,
                                                 totalBytes: 0)
        writeAll(clientFD, try AgentIPCCodec.encode(AgentIPCMessage(
            type: .clipboardFileOfferBegin,
            payload: try AgentIPCCodec.encodeClipboardFileOfferBegin(begin))))
        let end = AgentClipboardFileOfferEnd(direction: .remoteToLocal, status: .complete,
                                             fileCount: 1)
        writeAll(clientFD, try AgentIPCCodec.encode(AgentIPCMessage(
            type: .clipboardFileOfferEnd,
            payload: try AgentIPCCodec.encodeClipboardFileOfferEnd(end))))
        Darwin.close(clientFD)
        precondition(done.wait(timeout: .now() + 10) == .success)

        dup2(savedStderr, 2)
        Darwin.close(savedStderr)
        Darwin.close(logFD)
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        unlink(logPath)

        lock.lock()
        let types = receivedTypes
        let decodedEnd = endValue
        lock.unlock()
        precondition(types == [13, 15], "receiver must keep processing after unknown type, got \(types)")
        precondition(decodedEnd == end)
        let ignoredLines = log.split(separator: "\n").filter {
            $0 == "event=ipc_message_ignored type=99"
        }
        precondition(ignoredLines.count == 1, "expected exactly one dedupe log line, got \(log)")
    }


    // MARK: - local->remote staging (TCC / Full Disk Access)

    private static func stagingTests() throws {
        // Success: 3 files incl. a Chinese name and a 0-byte file; entries keep
        // the original names but advertise the staged copies, sized exactly.
        let fs = MemoryStagingFileSystem()
        fs.sources["/tmp/a.txt"] = Data([1, 2, 3])
        fs.sources["/tmp/中文.bin"] = Data([9])
        fs.sources["/tmp/empty.dat"] = Data()
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"),
                    URL(fileURLWithPath: "/tmp/中文.bin"),
                    URL(fileURLWithPath: "/tmp/empty.dat")]
        let source = FakeLocalFileSource(files: [(size: 3, path: "/tmp/a.txt"),
                                                 (size: 1, path: "/tmp/中文.bin"),
                                                 (size: 0, path: "/tmp/empty.dat")])
        let stager = ClipboardLocalFileOfferStager(fileSystem: fs)
        let staged = try stager.stage(urls: urls, source: source)
        precondition(staged.offer.begin.direction == .localToRemote)
        precondition(staged.offer.begin.fileCount == 3)
        precondition(staged.offer.begin.totalBytes == 4)
        precondition(staged.offer.entries.map(\.name) == ["a.txt", "中文.bin", "empty.dat"])
        precondition(staged.offer.entries.map(\.size) == [3, 1, 0])
        precondition(staged.offer.entries.map(\.fileIndex) == [0, 1, 2])
        for (index, entry) in staged.offer.entries.enumerated() {
            // The advertised path is absolute and points at the staged copy, not
            // at the TCC-protected original.
            precondition(entry.path.hasPrefix("/mem/out-"),
                         "staged path \(entry.path) must be the copy")
            precondition(AgentClipboardFileValidation.isValidAbsolutePath(entry.path))
            precondition(entry.path.hasSuffix(staged.stagedURLs[index].lastPathComponent))
        }
        precondition(fs.stagedFileNames == ["0-a.txt", "1-中文.bin", "2-empty.dat"])
        precondition(fs.stagedData(named: "0-a.txt") == Data([1, 2, 3]))
        precondition(fs.stagedData(named: "1-中文.bin") == Data([9]))
        precondition(fs.stagedData(named: "2-empty.dat") == Data())
        precondition(stager.currentOfferDirectoryURL?.path == "/mem/out-1")
        precondition(stager.previousOfferDirectoryURL == nil)
        precondition(fs.removedDirectories.isEmpty)

        // Rotation: current + previous only; the oldest is deleted when a new
        // offer is staged successfully.
        let second = try stager.stage(
            urls: [URL(fileURLWithPath: "/tmp/a.txt")],
            source: FakeLocalFileSource(files: [(size: 3, path: "/tmp/a.txt")]))
        precondition(second.offer.entries.count == 1)
        precondition(stager.currentOfferDirectoryURL?.path == "/mem/out-2")
        precondition(stager.previousOfferDirectoryURL?.path == "/mem/out-1")
        precondition(fs.removedDirectories.isEmpty)
        _ = try stager.stage(urls: [URL(fileURLWithPath: "/tmp/a.txt")],
                             source: FakeLocalFileSource(files: [(size: 3, path: "/tmp/a.txt")]))
        precondition(stager.currentOfferDirectoryURL?.path == "/mem/out-3")
        precondition(stager.previousOfferDirectoryURL?.path == "/mem/out-2")
        precondition(fs.removedDirectories.map(\.path) == ["/mem/out-1"])
        stager.removeAllDirectories()
        precondition(stager.currentOfferDirectoryURL == nil)
        precondition(stager.previousOfferDirectoryURL == nil)
        precondition(fs.removedDirectories.map(\.path)
            == ["/mem/out-1", "/mem/out-2", "/mem/out-3"])

        // Unreadable source (TCC denial / EPERM): the partial directory is
        // deleted and the error carries a sanitized basename + errno.
        let unreadableFS = MemoryStagingFileSystem()
        unreadableFS.sourceErrors["/tmp/secret.txt"] = EPERM
        let unreadableStager = ClipboardLocalFileOfferStager(fileSystem: unreadableFS)
        do {
            _ = try unreadableStager.stage(
                urls: [URL(fileURLWithPath: "/tmp/secret.txt")],
                source: FakeLocalFileSource(files: [(size: 1, path: "/tmp/secret.txt")]))
            preconditionFailure("expected unreadable")
        } catch let error as ClipboardLocalFileStagingError {
            precondition(error == .unreadable(name: "secret.txt", errno: EPERM))
        }
        precondition(unreadableStager.currentOfferDirectoryURL == nil)
        precondition(unreadableFS.removedDirectories.map(\.path) == ["/mem/out-1"])

        // Source changed size during the copy: reject with size_mismatch.
        let mismatchFS = MemoryStagingFileSystem()
        mismatchFS.sources["/tmp/shrunk.txt"] = Data([1, 2])
        let mismatchStager = ClipboardLocalFileOfferStager(fileSystem: mismatchFS)
        do {
            _ = try mismatchStager.stage(
                urls: [URL(fileURLWithPath: "/tmp/shrunk.txt")],
                source: FakeLocalFileSource(files: [(size: 5, path: "/tmp/shrunk.txt")]))
            preconditionFailure("expected sizeMismatch")
        } catch let error as ClipboardLocalFileStagingError {
            precondition(error == .sizeMismatch(name: "shrunk.txt", expected: 5, actual: 2))
        }
        precondition(mismatchFS.removedDirectories.map(\.path) == ["/mem/out-1"])

        // Read failure mid-stream: reject as unreadable, clean up.
        let readFailFS = MemoryStagingFileSystem()
        readFailFS.sources["/tmp/dies.txt"] = Data([1, 2, 3])
        readFailFS.failReadAfterBytes["/tmp/dies.txt"] = 0
        let readFailStager = ClipboardLocalFileOfferStager(fileSystem: readFailFS)
        do {
            _ = try readFailStager.stage(
                urls: [URL(fileURLWithPath: "/tmp/dies.txt")],
                source: FakeLocalFileSource(files: [(size: 3, path: "/tmp/dies.txt")]))
            preconditionFailure("expected read failure")
        } catch let error as ClipboardLocalFileStagingError {
            precondition(error == .readFailed(errno: EIO))
        }
        precondition(readFailFS.removedDirectories.count == 1)

        // Staging-file creation failure: reject as fileSystem, clean up.
        let createFailFS = MemoryStagingFileSystem()
        createFailFS.sources["/tmp/a.txt"] = Data([1])
        createFailFS.failCreateFile = true
        let createFailStager = ClipboardLocalFileOfferStager(fileSystem: createFailFS)
        do {
            _ = try createFailStager.stage(
                urls: [URL(fileURLWithPath: "/tmp/a.txt")],
                source: FakeLocalFileSource(files: [(size: 1, path: "/tmp/a.txt")]))
            preconditionFailure("expected fileSystem failure")
        } catch let error as ClipboardLocalFileStagingError {
            guard case .fileSystem = error else { preconditionFailure("got \(error)") }
        }
        precondition(createFailFS.removedDirectories.count == 1)

        // Contract limits are enforced BEFORE any staging directory is created.
        let limitFS = MemoryStagingFileSystem()
        let limitStager = ClipboardLocalFileOfferStager(fileSystem: limitFS)
        let tooMany = (0...AgentIPCCodec.maxClipboardFiles).map {
            URL(fileURLWithPath: "/tmp/file-\($0)")
        }
        let tooManySource = FakeLocalFileSource(
            files: tooMany.map { (size: 1, path: $0.path) })
        expectStagingError("too many files") {
            _ = try limitStager.stage(urls: tooMany, source: tooManySource)
        } verify: { error in
            precondition((error as? ClipboardLocalFileOfferError) == .tooManyFiles)
        }
        let bigSource = FakeLocalFileSource(
            files: [(size: Int(AgentIPCCodec.maxClipboardFileBytes), path: "/tmp/big")])
        expectStagingError("file too large") {
            _ = try limitStager.stage(urls: [URL(fileURLWithPath: "/tmp/big")],
                                      source: bigSource)
        } verify: { error in
            precondition((error as? ClipboardLocalFileOfferError) == .fileTooLarge(index: 0))
        }
        precondition(limitFS.removedDirectories.isEmpty)
        precondition(limitStager.currentOfferDirectoryURL == nil)

        // Staged name = "<index>-<sanitized name>" truncated to 255 UTF-8 bytes;
        // the advertised entry name is still the original (<=255 bytes) name and
        // duplicate basenames from different folders get unique staged names.
        let nameFS = MemoryStagingFileSystem()
        let longName = String(repeating: "ä", count: 127)   // 254 UTF-8 bytes
        nameFS.sources["/tmp/\(longName)"] = Data()
        nameFS.sources["/a/x.txt"] = Data()
        nameFS.sources["/b/x.txt"] = Data()
        let nameStager = ClipboardLocalFileOfferStager(fileSystem: nameFS)
        let longStaged = try nameStager.stage(
            urls: [URL(fileURLWithPath: "/tmp/\(longName)")],
            source: FakeLocalFileSource(files: [(size: 0, path: "/tmp/\(longName)")]))
        let stagedLongName = longStaged.stagedURLs[0].lastPathComponent
        precondition(stagedLongName.hasPrefix("0-"))
        precondition(stagedLongName.utf8.count <= AgentIPCCodec.maxClipboardNameBytes)
        precondition(AgentClipboardFileValidation.isValidName(stagedLongName))
        precondition(longStaged.offer.entries[0].name == longName)
        let duplicateStaged = try nameStager.stage(
            urls: [URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/x.txt")],
            source: FakeLocalFileSource(files: [(size: 0, path: "/a/x.txt"),
                                                (size: 0, path: "/b/x.txt")]))
        precondition(duplicateStaged.stagedURLs.map(\.lastPathComponent) == ["0-x.txt", "1-x.txt"])
        precondition(duplicateStaged.offer.entries.map(\.name) == ["x.txt", "x.txt"])

        // Empty file name after prefix truncation cannot happen for validated
        // names, but the helper must never produce an invalid component.
        precondition(AgentClipboardFileValidation.isValidName(
            ClipboardLocalFileOfferStager.stagedFileName(index: 0, name: "a")))
        precondition(ClipboardLocalFileOfferStager.stagedFileName(
            index: 99, name: String(repeating: "a", count: 255)).utf8.count
            <= AgentIPCCodec.maxClipboardNameBytes)
    }

    /// Real POSIX staging file system: 0700 dir, 0600 file, streaming copy,
    /// O_NOFOLLOW source protection and cleanup.
    private static func posixStagingFileSystemTests() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rdp-clipboard-out-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let sourceDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rdp-clipboard-src-\(UUID().uuidString)",
                                    isDirectory: true)
        let sourceURL = sourceDirectory.appendingPathComponent("hello 世界.txt")
        let symlinkURL = sourceDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createDirectory(at: sourceDirectory,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL,
                                                   withDestinationURL: sourceURL)

        let fileSystem = PosixClipboardLocalFileStagingFileSystem(rootDirectory: root)
        let stager = ClipboardLocalFileOfferStager(fileSystem: fileSystem)
        let staged = try stager.stage(urls: [sourceURL])
        precondition(staged.offer.entries.count == 1)
        precondition(staged.offer.entries[0].name == "hello 世界.txt")
        precondition(staged.offer.entries[0].path.hasPrefix(root.path + "/"))
        let stagedURL = staged.stagedURLs[0]
        precondition(stagedURL.lastPathComponent == "0-hello 世界.txt")
        let copied = try Data(contentsOf: stagedURL)
        precondition(copied == Data([0xde, 0xad, 0xbe, 0xef]))
        var directoryStatus = stat()
        precondition(lstat(root.path, &directoryStatus) == 0)
        precondition(directoryStatus.st_mode & 0o777 == 0o700)
        var fileStatus = stat()
        precondition(lstat(stagedURL.path, &fileStatus) == 0)
        precondition(fileStatus.st_mode & 0o777 == 0o600)
        precondition(fileStatus.st_mode & S_IFMT == S_IFREG)

        // O_NOFOLLOW: a symlink source is never followed, even if a caller
        // supplied metadata for it.
        let symlinkMetadata = FakeLocalFileSource(raw: [
            symlinkURL.path: ClipboardLocalFileMetadata(
                name: "link.txt", path: symlinkURL.path, size: 4)])
        do {
            _ = try stager.stage(urls: [symlinkURL], source: symlinkMetadata)
            preconditionFailure("expected symlink rejection")
        } catch let error as ClipboardLocalFileStagingError {
            guard case let .unreadable(name, errorNumber) = error else {
                preconditionFailure("got \(error)")
            }
            precondition(name == "link.txt")
            precondition(errorNumber == ELOOP)
        }
        // Missing source after metadata: ENOENT reported with errno.
        let missingURL = sourceDirectory.appendingPathComponent("missing.txt")
        let missingMetadata = FakeLocalFileSource(raw: [
            missingURL.path: ClipboardLocalFileMetadata(
                name: "missing.txt", path: missingURL.path, size: 1)])
        do {
            _ = try stager.stage(urls: [missingURL], source: missingMetadata)
            preconditionFailure("expected missing-source rejection")
        } catch let error as ClipboardLocalFileStagingError {
            guard case let .unreadable(name, errorNumber) = error else {
                preconditionFailure("got \(error)")
            }
            precondition(name == "missing.txt")
            precondition(errorNumber == ENOENT)
        }
        stager.removeAllDirectories()
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        precondition(remaining.isEmpty)
    }

    private static func expectStagingError(
        _ label: String,
        _ body: () throws -> Void,
        verify: (Error) -> Void
    ) {
        do {
            try body()
            preconditionFailure("expected error: \(label)")
        } catch {
            verify(error)
        }
    }

    // MARK: - helpers

    private static func frame(rawType: UInt16, payload: Data, version: UInt16 = 1,
                              magic: String = "RDPA") -> Data {
        var data = Data(magic.utf8)
        data.append(be16(version))
        data.append(be16(rawType))
        data.append(be32(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    private static func rawBegin(direction: UInt8, reserved: UInt8, fileCount: UInt16,
                                 totalBytes: UInt64, flags: UInt32 = 0) -> Data {
        var data = Data([direction, reserved])
        data.append(be16(fileCount))
        data.append(be64(totalBytes))
        data.append(be32(flags))
        return data
    }

    private static func rawEntry(direction: UInt8, reserved: UInt8, fileIndex: UInt32,
                                 size: UInt64, name: String, path: String,
                                 extraTrailingBytes: Int = 0) -> Data {
        rawEntry(direction: direction, reserved: reserved, fileIndex: fileIndex, size: size,
                 nameBytes: Array(name.utf8), pathBytes: Array(path.utf8),
                 extraTrailingBytes: extraTrailingBytes)
    }

    private static func rawEntry(direction: UInt8, reserved: UInt8, fileIndex: UInt32,
                                 size: UInt64, nameBytes: [UInt8],
                                 pathBytes: [UInt8] = [],
                                 extraTrailingBytes: Int = 0) -> Data {
        var data = Data([direction, reserved])
        data.append(be16(UInt16(nameBytes.count)))
        data.append(be32(fileIndex))
        data.append(be64(size))
        data.append(be16(UInt16(pathBytes.count)))
        data.append(contentsOf: nameBytes)
        data.append(contentsOf: pathBytes)
        data.append(Data(repeating: 0, count: extraTrailingBytes))
        return data
    }

    private static func beginMessage(count: UInt16, total: UInt64) -> AgentIPCMessage {
        let begin = AgentClipboardFileOfferBegin(direction: .remoteToLocal, fileCount: count,
                                                 totalBytes: total)
        // swiftlint:disable:next force_try
        return AgentIPCMessage(type: .clipboardFileOfferBegin,
                               payload: try! AgentIPCCodec.encodeClipboardFileOfferBegin(begin))
    }

    private static func entryMessage(index: UInt32, size: UInt64,
                                     name: String) -> AgentIPCMessage {
        let entry = AgentClipboardFileEntry(direction: .remoteToLocal, fileIndex: index,
                                            size: size, name: name)
        return AgentIPCMessage(type: .clipboardFileEntry,
                               payload: try! AgentIPCCodec.encodeClipboardFileEntry(entry))
    }

    private static func chunkMessage(index: UInt32, offset: UInt64,
                                     bytes: [UInt8]) -> AgentIPCMessage {
        let chunk = AgentClipboardFileChunk(fileIndex: index, offset: offset,
                                            data: Data(bytes))
        return AgentIPCMessage(type: .clipboardFileChunk,
                               payload: try! AgentIPCCodec.encodeClipboardFileChunk(chunk))
    }

    private static func endMessage(status: AgentClipboardFileEndStatus, errorCode: UInt16 = 0,
                                   fileCount: UInt32) -> AgentIPCMessage {
        let end = AgentClipboardFileOfferEnd(direction: .remoteToLocal, status: status,
                                             errorCode: errorCode, fileCount: fileCount)
        return AgentIPCMessage(type: .clipboardFileOfferEnd,
                               payload: try! AgentIPCCodec.encodeClipboardFileOfferEnd(end))
    }

    private static func expectThrows<T>(_ label: String, _ body: () throws -> T) {
        do {
            _ = try body()
            preconditionFailure("expected throw: \(label)")
        } catch {
            // expected
        }
    }

    private static func expectAssemblyFailure(
        setup: (ClipboardFileAssembler) -> [ClipboardFileAssemblyEvent],
        expected: ClipboardFileAssemblyFailure) {
        let fs = MemoryClipboardFileSystem()
        let assembler = ClipboardFileAssembler(fileSystem: fs)
        let events = setup(assembler)
        guard let reason = events.compactMap({ event -> ClipboardFileAssemblyFailure? in
            if case let .offerFailed(reason) = event { return reason }
            return nil
        }).first else {
            preconditionFailure("expected failure \(expected), got \(events)")
        }
        precondition(reason == expected, "expected \(expected), got \(reason)")
        precondition(!assembler.isAssembling)
        precondition(fs.removedDirectories.count == 1,
                     "failed offer must delete its directory")
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private static func be64(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset),
                                           rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    preconditionFailure("test write failed errno=\(errno)")
                }
                offset += written
            }
        }
    }
}

// MARK: - test doubles

private struct FakeLocalFileSource: ClipboardLocalFileSource {
    let raw: [String: ClipboardLocalFileMetadata]

    init(files: [(size: Int, path: String)]) {
        var raw: [String: ClipboardLocalFileMetadata] = [:]
        for file in files {
            raw[file.path] = ClipboardLocalFileMetadata(
                name: (file.path as NSString).lastPathComponent, path: file.path,
                size: UInt64(max(0, file.size)))
        }
        self.raw = raw
    }

    init(raw: [String: ClipboardLocalFileMetadata]) {
        self.raw = raw
    }

    func metadata(for url: URL) -> ClipboardLocalFileMetadata? {
        return raw[url.path]
    }
}

private final class FakePasteboard: ClipboardPasteboardBridge {
    var changeCount = 0
    var fileURLs: [URL]?
    var text: String?
    var writeFileURLCalls: [[URL]] = []

    func readFileURLs() -> [URL]? { fileURLs }
    func readText() -> String? { text }
    func writeFileURLs(_ urls: [URL]) -> Bool {
        writeFileURLCalls.append(urls)
        changeCount += 1
        return true
    }
    func writeText(_ text: String) -> Bool {
        self.text = text
        changeCount += 1
        return true
    }
}

private final class MemoryClipboardFileSystem: ClipboardFileAssemblyFileSystem {
    private final class File {
        let url: URL
        var data = Data()
        init(url: URL) { self.url = url }
    }

    private var nextIdentifier = 0
    private var files: [Int: File] = [:]
    var createdNames: [String] = []
    var removedDirectories: [URL] = []
    var failCreateFile = false

    func createOfferDirectory() throws -> ClipboardOfferDirectory {
        nextIdentifier += 1
        let url = URL(fileURLWithPath: "/mem/offer-\(nextIdentifier)", isDirectory: true)
        return ClipboardOfferDirectory(identifier: nextIdentifier, url: url)
    }

    func createFile(named name: String,
                    in directory: ClipboardOfferDirectory) throws -> ClipboardFileAssemblyHandle {
        if failCreateFile { throw MemoryFailure.injected }
        guard AgentClipboardFileValidation.isValidName(name) else {
            throw MemoryFailure.invalidName
        }
        let url = directory.url.appendingPathComponent(name)
        if files.values.contains(where: { $0.url == url }) {
            throw MemoryFailure.exists
        }
        nextIdentifier += 1
        files[nextIdentifier] = File(url: url)
        createdNames.append(name)
        return ClipboardFileAssemblyHandle(identifier: nextIdentifier)
    }

    func append(_ data: Data, to handle: ClipboardFileAssemblyHandle) throws {
        guard let file = files[handle.identifier] else { throw MemoryFailure.missingHandle }
        file.data.append(data)
    }

    func finish(_ handle: ClipboardFileAssemblyHandle) throws -> URL {
        guard let file = files[handle.identifier] else { throw MemoryFailure.missingHandle }
        return file.url
    }

    func discard(_ handle: ClipboardFileAssemblyHandle) {}

    func removeDirectory(_ directory: ClipboardOfferDirectory) {
        removedDirectories.append(directory.url)
    }

    func filesData(at url: URL) -> Data {
        files.values.first(where: { $0.url == url })?.data ?? Data()
    }
}

private enum MemoryFailure: Error {
    case injected
    case invalidName
    case exists
    case missingHandle
}

/// In-memory ClipboardLocalFileStagingFileSystem for the direction-2 staging
/// tests (no real files, deterministic directories/errnos).
private final class MemoryStagingFileSystem: ClipboardLocalFileStagingFileSystem {
    private final class StagedFile {
        let url: URL
        var data = Data()
        init(url: URL) { self.url = url }
    }

    private var nextDirectoryIdentifier = 0
    private var nextFileIdentifier = 0
    private var nextSourceIdentifier = 0
    private var stagedFiles: [Int: StagedFile] = [:]
    private var sourceHandles: [Int: (path: String, data: Data, offset: Int)] = [:]
    var directories: [Int: URL] = [:]
    var removedDirectories: [URL] = []
    var stagedFileNames: [String] = []
    var sources: [String: Data] = [:]
    var sourceErrors: [String: Int32] = [:]
    var failReadAfterBytes: [String: Int] = [:]
    var failCreateFile = false

    func createOfferDirectory() throws -> ClipboardStagingDirectory {
        nextDirectoryIdentifier += 1
        let url = URL(fileURLWithPath: "/mem/out-\(nextDirectoryIdentifier)",
                      isDirectory: true)
        directories[nextDirectoryIdentifier] = url
        return ClipboardStagingDirectory(identifier: nextDirectoryIdentifier, url: url)
    }

    func createFile(named name: String,
                    in directory: ClipboardStagingDirectory) throws -> ClipboardStagingFileHandle {
        if failCreateFile {
            throw ClipboardLocalFileStagingError.fileSystem("injected create failure")
        }
        guard AgentClipboardFileValidation.isValidName(name) else {
            throw ClipboardLocalFileStagingError.invalidStagedName(name)
        }
        nextFileIdentifier += 1
        stagedFiles[nextFileIdentifier] = StagedFile(
            url: directory.url.appendingPathComponent(name, isDirectory: false))
        stagedFileNames.append(name)
        return ClipboardStagingFileHandle(identifier: nextFileIdentifier)
    }

    func append(_ data: Data, to handle: ClipboardStagingFileHandle) throws {
        guard let file = stagedFiles[handle.identifier] else {
            throw ClipboardLocalFileStagingError.fileSystem("missing staged handle")
        }
        file.data.append(data)
    }

    func finish(_ handle: ClipboardStagingFileHandle) throws -> URL {
        guard let file = stagedFiles[handle.identifier] else {
            throw ClipboardLocalFileStagingError.fileSystem("missing staged handle")
        }
        return file.url
    }

    func discard(_ handle: ClipboardStagingFileHandle) {
        stagedFiles.removeValue(forKey: handle.identifier)
    }

    func removeDirectory(_ directory: ClipboardStagingDirectory) {
        removedDirectories.append(directory.url)
    }

    func openSource(path: String) throws -> ClipboardStagingSourceHandle {
        if let errorNumber = sourceErrors[path] {
            throw ClipboardLocalFileStagingError.unreadable(
                name: URL(fileURLWithPath: path).lastPathComponent, errno: errorNumber)
        }
        guard let data = sources[path] else {
            throw ClipboardLocalFileStagingError.unreadable(
                name: URL(fileURLWithPath: path).lastPathComponent, errno: ENOENT)
        }
        nextSourceIdentifier += 1
        sourceHandles[nextSourceIdentifier] = (path: path, data: data, offset: 0)
        return ClipboardStagingSourceHandle(identifier: nextSourceIdentifier)
    }

    func readSourceChunk(_ handle: ClipboardStagingSourceHandle,
                         maxLength: Int) throws -> Data {
        guard var state = sourceHandles[handle.identifier] else {
            throw ClipboardLocalFileStagingError.readFailed(errno: EBADF)
        }
        if let failAfter = failReadAfterBytes[state.path], state.offset >= failAfter {
            throw ClipboardLocalFileStagingError.readFailed(errno: EIO)
        }
        let end = min(state.data.count, state.offset + max(1, maxLength))
        let chunk = Data(state.data[state.offset..<end])
        state.offset = end
        sourceHandles[handle.identifier] = state
        return chunk
    }

    func closeSource(_ handle: ClipboardStagingSourceHandle) {
        sourceHandles.removeValue(forKey: handle.identifier)
    }

    func stagedData(named name: String) -> Data? {
        stagedFiles.values.first { $0.url.lastPathComponent == name }?.data
    }
}

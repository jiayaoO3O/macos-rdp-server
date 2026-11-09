import Foundation
import CoreGraphics

@main
struct PermissionSnapshotTests {
    static func main() throws {
        try DisplayModeTests.run()
        try ClipboardFileTransferTests.run()
        try VirtualDisplayTests.run()
        try KeyboardInputStateTests.run()
        try MouseClickStateTests.run()
        precondition(SnapshotPacing.delayNanoseconds(elapsed: 0) == 33_333_333)
        precondition(SnapshotPacing.delayNanoseconds(elapsed: 20_000_000) == 13_333_333)
        precondition(SnapshotPacing.delayNanoseconds(elapsed: 33_333_333) == 0)
        precondition(SnapshotPacing.delayNanoseconds(elapsed: 300_000_000) == 0)
        var timing = CaptureTiming(windowSize: 2)
        precondition(timing.record(capture: 10_000_000, conversion: 20_000_000, send: 30_000_000) == nil)
        let measured = timing.record(capture: 30_000_000, conversion: 40_000_000, send: 50_000_000)
        precondition(measured?.captureMilliseconds == 20)
        precondition(measured?.conversionMilliseconds == 30)
        precondition(measured?.sendMilliseconds == 40)
        precondition(measured?.waitMilliseconds == 0)
        precondition(timing.record(capture: 0, conversion: 0, send: 0) == nil)
        // Honest pipelined timing: await_ms is measured separately so conversion_ms
        // only contains the conversion work.
        var pipelineTiming = CaptureTiming(windowSize: 1)
        let pipelineMeans = pipelineTiming.record(capture: 31_000_000, conversion: 2_500_000,
                                                  send: 7_000_000, wait: 1_500_000)
        precondition(pipelineMeans?.captureMilliseconds == 31)
        precondition(pipelineMeans?.conversionMilliseconds == 2.5)
        precondition(pipelineMeans?.sendMilliseconds == 7)
        precondition(pipelineMeans?.waitMilliseconds == 1.5)
        precondition(CaptureSizeRequest(width: 2508, height: 1220)?.width == 2508)
        precondition(CaptureSizeRequest(width: 0, height: 1220) == nil)
        precondition(CaptureSizeRequest(width: 16385, height: 1) == nil)
        let captureRequest = CaptureSizeRequest(width: 2508, height: 1220)!
        precondition(AgentIPCCodec.decodeCaptureSize(AgentIPCCodec.encodeCaptureSize(captureRequest)) == captureRequest)
        precondition(AgentIPCCodec.decodeCaptureSize(Data(repeating: 0, count: 8)) == nil)
        let sourcePixels = Data([255, 0, 0, 255, 0, 255, 0, 255])
        let provider = CGDataProvider(data: sourcePixels as CFData)!
        let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                     CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let convertedPixels = try CapturePixelConverter.bgra(image)
        precondition(convertedPixels == Data([0, 0, 255, 255, 0, 255, 0, 255]))
        var deltaEncoder = AgentFrameDeltaEncoder()
        let initialFrame = Data(count: 130 * 70 * 4)
        let initialTiles = try deltaEncoder.encode(pixels: initialFrame, width: 130, height: 70,
                                                   generation: 7)
        precondition(initialTiles.count == 6)
        precondition(initialTiles.last?.x == 128 && initialTiles.last?.y == 64)
        precondition(initialTiles.last?.width == 2 && initialTiles.last?.height == 6)
        let unchangedTiles = try deltaEncoder.encode(pixels: initialFrame, width: 130, height: 70,
                                                      generation: 7)
        precondition(unchangedTiles.isEmpty)
        var changedFrame = initialFrame
        changedFrame[(2 * 130 + 65) * 4 + 1] = 0xff
        let changedTiles = try deltaEncoder.encode(pixels: changedFrame, width: 130, height: 70,
                                                    generation: 7)
        precondition(changedTiles.count == 1)
        precondition(changedTiles[0].x == 64 && changedTiles[0].y == 0)
        precondition(changedTiles[0].width == 64 && changedTiles[0].height == 64)
        let newGenerationTiles = try deltaEncoder.encode(pixels: changedFrame, width: 130, height: 70,
                                                          generation: 8)
        precondition(newGenerationTiles.count == 6)
        let deltaMetadata = AgentFrameMetadata(generation: 7, frameID: 9, width: 130,
                                               height: 70, bytesPerPixel: 4)
        let deltaBegin = try AgentIPCCodec.encodeFrameDeltaBegin(deltaMetadata, tileCount: 1)
        precondition(deltaBegin.type == .frameDeltaBegin && deltaBegin.payload.count == 29)
        let patchTile = AgentFrameTile(x: 64, y: 0, width: 64, height: 64,
                                       pixels: Data(repeating: 0xaa, count: 64 * 64 * 4))
        let patchPrefix = try AgentIPCCodec.encodeFrameTilePrefix(generation: 7, frameID: 9,
                                                                  tile: patchTile)
        precondition(patchPrefix.count == AgentIPCCodec.headerSize + 28)
        let patchMessage = try AgentIPCCodec.encode(AgentIPCMessage(type: .frameTile, payload: patchPrefix.suffix(from: AgentIPCCodec.headerSize) + patchTile.pixels))
        precondition(patchMessage == patchPrefix + patchTile.pixels)
        let deltaEnd = AgentIPCCodec.encodeFrameDeltaEnd(generation: 7, frameID: 9, tileCount: 1)
        precondition(deltaEnd.type == .frameDeltaEnd && deltaEnd.payload.count == 20)
        precondition(AgentStreamDuration(argument: 0)?.isPersistent == true)
        precondition(AgentStreamDuration(argument: 1)?.seconds == 1)
        precondition(AgentStreamDuration(argument: 30)?.seconds == 30)
        precondition(AgentStreamDuration(argument: -1) == nil)
        precondition(AgentStreamDuration(argument: 31) == nil)
        precondition(CaptureExclusion.excludes(bundleIdentifier: "com.microsoft.rdc.macos"))
        precondition(!CaptureExclusion.excludes(bundleIdentifier: "com.apple.finder"))
        precondition(RDPWheel.delta(flags: 0x0278) == 120)
        precondition(RDPWheel.delta(flags: 0x0388) == -120)
        precondition(RDPWheel.delta(flags: 0x0000) == nil)
        // Windows-convention wheel direction for macOS: RDP +120 (away from the
        // user) must scroll the same way Windows does, i.e. wheel1 -1 line; the
        // sign is inverted because macOS posts the opposite sign (field report
        // 2026-11-08: "滚轮 mac 和 win 相反, 要兼容 win 的滚轮模式").
        precondition(RDPWheel.macOSWheel1(flags: 0x0278) == -1)   // +120
        precondition(RDPWheel.macOSWheel1(flags: 0x0388) == 1)    // -120
        precondition(RDPWheel.macOSWheel1(flags: 0x02f8) == -2)   // +240 (two notches)
        precondition(RDPWheel.macOSWheel1(flags: 0x0308) == 2)    // -240
        precondition(RDPWheel.macOSWheel1(flags: 0x0201) == -1)   // sub-notch +1
        precondition(RDPWheel.macOSWheel1(flags: 0x03ff) == 1)    // sub-notch -1 (0x1ff)
        precondition(RDPWheel.macOSWheel1(flags: 0x0200) == nil)  // zero rotation
        precondition(RDPWheel.macOSWheel1(flags: 0x0000) == nil)  // no wheel flag

        var inputAudit = AgentInputAudit()
        precondition(inputAudit.shouldLog(.mouse))
        precondition(!inputAudit.shouldLog(.mouse))
        precondition(inputAudit.shouldLog(.scancode))

        let display = DesktopDisplayRect(originX: -800, originY: 40,
                                         width: 1600, height: 900)
        precondition(DisplayCoordinateMapper.point(x: 2048, y: 1152,
                                                    captureWidth: 4096, captureHeight: 2304,
                                                    display: display) ==
                     DesktopPoint(x: 0, y: 490))
        precondition(DisplayCoordinateMapper.point(x: 4095, y: 2303,
                                                    captureWidth: 4096, captureHeight: 2304,
                                                    display: display) ==
                     DesktopPoint(x: 799.609375, y: 939.609375))
        precondition(DisplayCoordinateMapper.point(x: 4096, y: 0,
                                                    captureWidth: 4096, captureHeight: 2304,
                                                    display: display) == nil)
        precondition(DisplayCoordinateMapper.point(x: 0, y: 0,
                                                    captureWidth: 0, captureHeight: 2304,
                                                    display: display) == nil)

        let missing = PermissionSnapshot(screenRecording: false, accessibility: true)
        precondition(missing.report == "screen_recording=missing accessibility=granted desktop_ready=false")
        precondition(missing.needsScreenRecordingRequest)
        precondition(!missing.needsAccessibilityRequest)

        let granted = PermissionSnapshot(screenRecording: true, accessibility: true)
        precondition(granted.report == "screen_recording=granted accessibility=granted desktop_ready=false")
        precondition(!granted.needsScreenRecordingRequest)
        precondition(!granted.needsAccessibilityRequest)

        let bothMissing = PermissionSnapshot(screenRecording: false, accessibility: false)
        precondition(bothMissing.needsScreenRecordingRequest)
        precondition(bothMissing.needsAccessibilityRequest)

        var capture = CaptureProgress()
        precondition(!capture.record(width: 0, height: 956))
        precondition(!capture.record(width: 1470, height: -1))
        precondition(capture.frameCount == 0)
        precondition(capture.record(width: 1470, height: 956))
        precondition(capture.record(width: 1470, height: 956))
        precondition(capture.frameCount == 2)
        precondition(capture.width == 1470)
        precondition(capture.height == 956)
        precondition(capture.reached(targetFrameCount: 2))
        precondition(!capture.reached(targetFrameCount: 3))

        let message = AgentIPCMessage(type: .frameReady, payload: Data([0xaa, 0xbb]))
        let encoded = try AgentIPCCodec.encode(message)
        precondition(encoded == Data([0x52, 0x44, 0x50, 0x41,
                                     0x00, 0x01, 0x00, 0x02,
                                     0x00, 0x00, 0x00, 0x02,
                                     0xaa, 0xbb]))
        let decoded = try AgentIPCCodec.decode(encoded)
        precondition(decoded == message)

        let wireMetadata = AgentFrameMetadata(generation: 0x0102030405060708,
                                              frameID: 9, width: 1470, height: 956,
                                              bytesPerPixel: 4)
        let encodedMetadata = try AgentIPCCodec.encodeFrameBegin(wireMetadata)
        precondition(encodedMetadata.prefix(16) == Data([1, 2, 3, 4, 5, 6, 7, 8,
                                                        0, 0, 0, 0, 0, 0, 0, 9]))
        let decodedMetadata = try AgentIPCCodec.decodeFrameBegin(encodedMetadata)
        precondition(decodedMetadata == wireMetadata)
        let wireChunk = AgentFrameWireChunk(generation: wireMetadata.generation,
                                            frameID: wireMetadata.frameID, offset: 16,
                                            data: Data("pixels".utf8))
        let encodedChunk = try AgentIPCCodec.encodeFrameChunk(wireChunk)
        let chunkMessage = try AgentIPCCodec.encode(AgentIPCMessage(type: .frameChunk, payload: encodedChunk))
        let chunkPrefix = try AgentIPCCodec.encodeFrameChunkPrefix(generation: wireChunk.generation,
                                                                  frameID: wireChunk.frameID,
                                                                  offset: wireChunk.offset,
                                                                  count: wireChunk.data.count)
        precondition(chunkPrefix + wireChunk.data == chunkMessage)
        do {
            _ = try AgentIPCCodec.encodeFrameChunkPrefix(generation: 0, frameID: 1, offset: 0, count: 1)
            preconditionFailure("invalid generation accepted")
        } catch AgentFrameError.invalidChunk {}
        let decodedChunk = try AgentIPCCodec.decodeFrameChunk(encodedChunk)
        precondition(decodedChunk.generation == wireChunk.generation)
        precondition(decodedChunk.frameID == wireChunk.frameID)
        precondition(decodedChunk.offset == wireChunk.offset)
        precondition(decodedChunk.data == wireChunk.data)

        let mouseEvent = AgentInputEvent(kind: .mouse, flags: 0x0800, x: 1024, y: 768)
        let mousePayload = AgentIPCCodec.encodeInputEvent(mouseEvent)
        precondition(mousePayload == Data([0x01, 0x08, 0x00, 0, 0, 0x04, 0x00, 0x03, 0x00]))
        let decodedMouseEvent = try AgentIPCCodec.decodeInputEvent(mousePayload)
        precondition(decodedMouseEvent == mouseEvent)
        precondition(MacKeyMap.virtualKey(scancode: 0x1e, extended: false) == 0x00)
        precondition(MacKeyMap.virtualKey(scancode: 0x48, extended: true) == 0x7e)
        precondition(MacKeyMap.virtualKey(scancode: 0x33, extended: false) == 0x2b)
        precondition(MacKeyMap.virtualKey(scancode: 0xff, extended: false) == nil)

        precondition(DisplayPixelSize.resolve(pointsWidth: 1470, pointsHeight: 956,
                                              pixelsWidth: 2560, pixelsHeight: 1664) ==
                     DisplayPixelSize(width: 2560, height: 1664))
        precondition(DisplayPixelSize.resolve(pointsWidth: 1470, pointsHeight: 956,
                                              pixelsWidth: 0, pixelsHeight: 1664) ==
                     DisplayPixelSize(width: 1470, height: 956))

        var assembler = AgentFrameAssembler(generation: 7, maxFrameBytes: 32)
        let metadata = AgentFrameMetadata(generation: 7, frameID: 10, width: 4,
                                          height: 2, bytesPerPixel: 4)
        try assembler.begin(metadata)
        precondition(assembler.commit() == nil)
        try assembler.append(AgentFrameChunk(generation: 7, frameID: 10,
                                              offset: 16, data: Data("0123456789abcdef".utf8)))
        try assembler.append(AgentFrameChunk(generation: 7, frameID: 10,
                                              offset: 0, data: Data("0123456789abcdef".utf8)))
        let frame = assembler.commit()
        precondition(frame?.metadata == metadata)
        precondition(frame?.pixels == Data("0123456789abcdef0123456789abcdef".utf8))

        var staleAssembler = AgentFrameAssembler(generation: 9, maxFrameBytes: 16)
        do {
            try staleAssembler.begin(AgentFrameMetadata(generation: 8, frameID: 1,
                                                        width: 1, height: 1, bytesPerPixel: 4))
            preconditionFailure("accepted stale frame generation")
        } catch AgentFrameError.staleGeneration {
        }
        do {
            try staleAssembler.begin(AgentFrameMetadata(generation: 9, frameID: 1,
                                                        width: 3, height: 2, bytesPerPixel: 4))
            preconditionFailure("accepted oversized frame")
        } catch AgentFrameError.invalidFrame {
        }

        // --- new pure-logic coverage (2026-11-07 capture optimisation) ---
        precondition(SnapshotPacing.intervalNanoseconds(targetFramesPerSecond: 30) == 33_333_333)
        precondition(SnapshotPacing.intervalNanoseconds(targetFramesPerSecond: 60) == 16_666_666)
        precondition(SnapshotPacing.intervalNanoseconds(targetFramesPerSecond: 0) == 1_000_000_000)
        precondition(SnapshotPacing.intervalNanoseconds(targetFramesPerSecond: 500) == 8_333_333)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: nil) == 30)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "60") == 60)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "1") == 1)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "120") == 120)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "0") == 30)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "121") == 30)
        precondition(SnapshotPacing.resolvedTargetFramesPerSecond(environmentValue: "fast") == 30)
        precondition(SnapshotPacing.delayNanoseconds(elapsed: 10_000_000,
                                                     intervalNanoseconds: 16_666_666) == 6_666_666)

        var benchmark = CaptureBenchmark()
        precondition(benchmark.stats == nil)
        benchmark.record(nanoseconds: 10_000_000)
        benchmark.record(nanoseconds: 30_000_000)
        benchmark.record(nanoseconds: 20_000_000)
        precondition(benchmark.stats?.count == 3)
        precondition(benchmark.stats?.meanMilliseconds == 20)
        precondition(benchmark.stats?.minMilliseconds == 10)
        precondition(benchmark.stats?.maxMilliseconds == 30)
        precondition(benchmark.stats?.framesPerSecond == 50)
        benchmark.reset()
        precondition(benchmark.stats == nil)

        let directLayout = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                              bitsPerPixel: 32, bytesPerRow: 8,
                                              alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                              byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                              isMask: false)
        precondition(!directLayout.canCopyRowsDirectly)
        let srgbLayout = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                            bitsPerPixel: 32, bytesPerRow: 8,
                                            alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                            byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                            isMask: false,
                                            colorSpaceName: "kCGColorSpaceSRGB")
        precondition(srgbLayout.canCopyRowsDirectly)
        precondition(srgbLayout.isSRGBColorSpace)
        let p3Layout = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: 8,
                                          alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                          byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                          isMask: false,
                                          colorSpaceName: "kCGColorSpaceDisplayP3")
        precondition(!p3Layout.canCopyRowsDirectly)
        precondition(!p3Layout.isSRGBColorSpace)
        precondition(directLayout.isBGRAPremultipliedFirst)
        precondition(!directLayout.isRowPadded)
        precondition(directLayout.pixelBytes == 8)
        let padded = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: 12,
                                        alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                        byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                        isMask: false)
        precondition(padded.isBGRAPremultipliedFirst && padded.isRowPadded)
        let wrongAlpha = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                            bitsPerPixel: 32, bytesPerRow: 8,
                                            alphaInfoRaw: CGImageAlphaInfo.premultipliedLast.rawValue,
                                            byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                            isMask: false)
        precondition(!wrongAlpha.isBGRAPremultipliedFirst)
        let wrongOrder = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 8,
                                            bitsPerPixel: 32, bytesPerRow: 8,
                                            alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                            byteOrderInfoRaw: CGBitmapInfo.byteOrder32Big.rawValue,
                                            isMask: false)
        precondition(!wrongOrder.isBGRAPremultipliedFirst)
        let sixteenBit = CapturePixelLayout(width: 2, height: 1, bitsPerComponent: 16,
                                            bitsPerPixel: 64, bytesPerRow: 16,
                                            alphaInfoRaw: CGImageAlphaInfo.premultipliedFirst.rawValue,
                                            byteOrderInfoRaw: CGBitmapInfo.byteOrder32Little.rawValue,
                                            isMask: false)
        precondition(!sixteenBit.isBGRAPremultipliedFirst)

        let bgraBytes = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let bgraProvider = CGDataProvider(data: bgraBytes as CFData)!
        let bgraImage = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: bgraProvider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
        precondition(CapturePixelConverter.resolvedStrategy(for: bgraImage,
                                                            requested: .automatic) == .directRows)
        let p3Provider = CGDataProvider(data: Data(repeating: 0x40, count: 8) as CFData)!
        let p3Image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                              bitmapInfo: CGBitmapInfo(rawValue:
                                  CGImageAlphaInfo.premultipliedFirst.rawValue |
                                  CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: p3Provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)!
        precondition(CapturePixelConverter.resolvedStrategy(for: p3Image,
                                                            requested: .automatic) == .contextDeviceRGB)
        let p3Direct = try CapturePixelConverter.bgra(p3Image, strategy: .directRows)
        precondition(p3Direct == Data(repeating: 0x40, count: 8))
        precondition(CapturePixelConverter.resolvedStrategy(for: bgraImage,
                                                            requested: .automatic) == .directRows)
        let directPixels = try CapturePixelConverter.bgra(bgraImage)
        precondition(directPixels == bgraBytes)
        let explicitDirectPixels = try CapturePixelConverter.bgra(bgraImage, strategy: .directRows)
        precondition(explicitDirectPixels == bgraBytes)
        var reusedPixels = Data([0xaa])
        try CapturePixelConverter.copyBGRA(bgraImage, into: &reusedPixels)
        precondition(reusedPixels == bgraBytes)
        try CapturePixelConverter.copyBGRA(bgraImage, into: &reusedPixels)
        precondition(reusedPixels == bgraBytes)
        do {
            _ = try CapturePixelConverter.bgra(image, strategy: .directRows)
            preconditionFailure("non-BGRA image accepted by the direct row copy")
        } catch CapturePixelError.unsupportedLayout {}
        let contextPixels = try CapturePixelConverter.bgra(image,
                                                            strategy: .contextImageColorSpace)
        precondition(contextPixels == convertedPixels)

        var recyclingEncoder = AgentFrameDeltaEncoder()
        var recyclingFrame = Data(count: 130 * 70 * 4)
        let recyclingFirst = try recyclingEncoder.encode(pixels: &recyclingFrame, width: 130,
                                                         height: 70, generation: 3)
        precondition(recyclingFirst.count == 6)
        precondition(recyclingFrame.isEmpty)
        recyclingFrame = Data(count: 130 * 70 * 4)
        let recyclingSecond = try recyclingEncoder.encode(pixels: &recyclingFrame, width: 130,
                                                          height: 70, generation: 3)
        precondition(recyclingSecond.isEmpty)
        precondition(recyclingFrame.count == 130 * 70 * 4)
        recyclingFrame[(0 * 130 + 129) * 4 + 2] = 0x7f
        let recycledTiles = try recyclingEncoder.encode(pixels: &recyclingFrame, width: 130,
                                                        height: 70, generation: 3)
        precondition(recycledTiles.count == 1)
        precondition(recycledTiles[0].x == 128 && recycledTiles[0].y == 0)

        precondition(StreamPixelFormat.isBGRA(0x42475241))
        precondition(!StreamPixelFormat.isBGRA(0x34323076))
        let health = StreamCaptureHealth(startupTimeoutNanoseconds: 2_000_000_000)
        precondition(!health.shouldFallBack(frameCount: 0, elapsedNanoseconds: 1_000_000_000))
        precondition(health.shouldFallBack(frameCount: 0, elapsedNanoseconds: 2_000_000_000))
        precondition(!health.shouldFallBack(frameCount: 1, elapsedNanoseconds: 9_000_000_000))
        precondition(StreamCaptureHealth.isUsableFrame(pixelFormat: 0x42475241, width: 2940,
                                                       height: 1912, maxDimension: 16_384))
        precondition(!StreamCaptureHealth.isUsableFrame(pixelFormat: 0x34323076, width: 2940,
                                                        height: 1912, maxDimension: 16_384))
        precondition(!StreamCaptureHealth.isUsableFrame(pixelFormat: 0x42475241, width: 0,
                                                        height: 1912, maxDimension: 16_384))
        let sizePlan = StreamSizePlan(requestedWidth: 3940, requestedHeight: 1888,
                                      configuredWidth: 2940, configuredHeight: 1912)
        precondition(sizePlan.needsReconfigure)
        precondition(!sizePlan.accepts(frameWidth: 2940, frameHeight: 1912))
        precondition(sizePlan.accepts(frameWidth: 3940, frameHeight: 1888))
        let settledPlan = StreamSizePlan(requestedWidth: 2940, requestedHeight: 1912,
                                         configuredWidth: 2940, configuredHeight: 1912)
        precondition(!settledPlan.needsReconfigure)

        // --- 2026-11-07 resolution adaptation: Agent capture policy (design 4) ---
        // Worked examples against the production 2940x1912 display.
        let fit1440 = captureGeometry(desktopWidth: 2560, desktopHeight: 1440)!
        precondition(fit1440.policy == .fit)
        precondition(fit1440.capture == CaptureSizeRequest(width: 2214, height: 1440)!)
        precondition(fit1440.desktopValue == "2560x1440")
        precondition(fit1440.nativeValue == "2940x1912")
        precondition(fit1440.captureValue == "2214x1440")
        precondition(fit1440.logFields ==
                     "desktop=2560x1440 native=2940x1912 capture=2214x1440 policy=fit")
        let fit600 = captureGeometry(desktopWidth: 800, desktopHeight: 600)!
        precondition(fit600.policy == .fit)
        precondition(fit600.capture == CaptureSizeRequest(width: 800, height: 520)!)
        let exact1664 = captureGeometry(desktopWidth: 2560, desktopHeight: 1664)!
        precondition(exact1664.policy == .exact)
        precondition(exact1664.capture == CaptureSizeRequest(width: 2560, height: 1664)!)
        let native4096 = captureGeometry(desktopWidth: 4096, desktopHeight: 2304)!
        precondition(native4096.policy == .native)
        precondition(native4096.capture == CaptureSizeRequest(width: 2940, height: 1912)!)
        let fit3940 = captureGeometry(desktopWidth: 3940, desktopHeight: 1888)!
        precondition(fit3940.policy == .fit)
        precondition(fit3940.capture == CaptureSizeRequest(width: 2903, height: 1888)!)
        // 0.5% relative aspect tolerance is inclusive: exactly 0.5% off is still
        // "exact", one pixel more is "fit".
        let toleranceIn = captureGeometry(desktopWidth: 1990, desktopHeight: 1000,
                                          nativeWidth: 2000, nativeHeight: 1000)!
        precondition(toleranceIn.policy == .exact)
        precondition(toleranceIn.capture == CaptureSizeRequest(width: 1990, height: 1000)!)
        let toleranceOut = captureGeometry(desktopWidth: 1989, desktopHeight: 1000,
                                           nativeWidth: 2000, nativeHeight: 1000)!
        precondition(toleranceOut.policy == .fit)
        precondition(toleranceOut.capture == CaptureSizeRequest(width: 1989, height: 995)!)
        // A matching aspect ratio is not enough for "exact": the box must also
        // fit inside the display, otherwise the capture is native.
        let matchAboveNative = captureGeometry(desktopWidth: 2010, desktopHeight: 1000,
                                               nativeWidth: 2000, nativeHeight: 1000)!
        precondition(matchAboveNative.policy == .native)
        precondition(matchAboveNative.capture == CaptureSizeRequest(width: 2000, height: 1000)!)
        let matchOneAxisAbove = captureGeometry(desktopWidth: 2000, desktopHeight: 1001,
                                                nativeWidth: 2000, nativeHeight: 1000)!
        precondition(matchOneAxisAbove.policy == .native)
        precondition(matchOneAxisAbove.capture ==
                     CaptureSizeRequest(width: 2000, height: 1000)!)
        // A desktop box larger than the display is captured natively, never
        // upscaled. 8192x2048 is exactly the 64 MiB BGRA budget, so it is a
        // legal negotiated desktop box.
        let oversized = captureGeometry(desktopWidth: 8192, desktopHeight: 2048)!
        precondition(oversized.policy == .native)
        precondition(oversized.capture == CaptureSizeRequest(width: 2940, height: 1912)!)
        // Size matrix invariants: capture is always positive and never larger
        // than the native display.
        for (width, height) in [(800, 600), (1024, 768), (1468, 923), (1920, 1080),
                                (2508, 1220), (2560, 1440), (2940, 1912), (3940, 1888),
                                (4096, 2304), (5120, 2880)] {
            guard let plan = captureGeometry(desktopWidth: width, desktopHeight: height) else {
                preconditionFailure("no geometry for \(width)x\(height)")
            }
            precondition(plan.capture.width > 0 && plan.capture.height > 0)
            precondition(plan.capture.width <= plan.nativeWidth)
            precondition(plan.capture.height <= plan.nativeHeight)
        }
        // Degenerate sizes: a 1x1 box still captures (fit branch), and a 1x1
        // display never upscales. An unavailable native size yields nil.
        let onePixelDesktop = captureGeometry(desktopWidth: 1, desktopHeight: 1)!
        precondition(onePixelDesktop.policy == .fit)
        precondition(onePixelDesktop.capture == CaptureSizeRequest(width: 1, height: 1)!)
        let onePixelNative = captureGeometry(desktopWidth: 100, desktopHeight: 100,
                                             nativeWidth: 1, nativeHeight: 1)!
        precondition(onePixelNative.policy == .native)
        precondition(onePixelNative.capture == CaptureSizeRequest(width: 1, height: 1)!)
        precondition(captureGeometry(desktopWidth: 1, desktopHeight: 1,
                                     nativeWidth: 1, nativeHeight: 1)?.policy == .exact)
        precondition(captureGeometry(desktopWidth: 100, desktopHeight: 100,
                                     nativeWidth: 0, nativeHeight: 0) == nil)
        precondition(captureGeometry(desktopWidth: 100, desktopHeight: 100,
                                     nativeWidth: 0, nativeHeight: 100) == nil)
        // CaptureSizeRequest limits used by the final safety clamp: exactly
        // 64 MiB is accepted, one pixel more is rejected.
        precondition(CaptureSizeRequest(width: 16_384, height: 1024) != nil)
        precondition(CaptureSizeRequest(width: 16_384, height: 1025) == nil)
        precondition(CaptureSizeRequest(width: 16_384, height: 16_384) == nil)

        // --- fit-with-bars layout (design section 3) ---
        let bars1440 = DisplayLayout.fit(captureWidth: 2214, captureHeight: 1440,
                                         desktopWidth: 2560, desktopHeight: 1440)!
        precondition(bars1440.contentWidth == 2214 && bars1440.contentHeight == 1440)
        precondition(bars1440.offsetX == 173 && bars1440.offsetY == 0)
        precondition(!bars1440.scaled && !bars1440.isOneToOne)
        let bars600 = DisplayLayout.fit(captureWidth: 800, captureHeight: 520,
                                        desktopWidth: 800, desktopHeight: 600)!
        precondition(bars600.contentWidth == 800 && bars600.contentHeight == 520)
        precondition(bars600.offsetX == 0 && bars600.offsetY == 40)
        precondition(!bars600.scaled)
        let scaled923 = DisplayLayout.fit(captureWidth: 1470, captureHeight: 956,
                                          desktopWidth: 1468, desktopHeight: 923)!
        precondition(scaled923.contentWidth == 1419 && scaled923.contentHeight == 923)
        precondition(scaled923.offsetX == 24 && scaled923.offsetY == 0)
        precondition(scaled923.scaled)
        let upscaled2304 = DisplayLayout.fit(captureWidth: 2940, captureHeight: 1912,
                                             desktopWidth: 4096, desktopHeight: 2304)!
        precondition(upscaled2304.contentWidth == 3543 && upscaled2304.contentHeight == 2304)
        precondition(upscaled2304.offsetX == 276 && upscaled2304.offsetY == 0)
        precondition(upscaled2304.scaled)
        let oneToOne1664 = DisplayLayout.fit(captureWidth: 2560, captureHeight: 1664,
                                             desktopWidth: 2560, desktopHeight: 1664)!
        precondition(oneToOne1664.contentWidth == 2560 && oneToOne1664.contentHeight == 1664)
        precondition(oneToOne1664.offsetX == 0 && oneToOne1664.offsetY == 0)
        precondition(!oneToOne1664.scaled && oneToOne1664.isOneToOne)
        precondition(DisplayLayout.fit(captureWidth: 0, captureHeight: 100,
                                       desktopWidth: 100, desktopHeight: 100) == nil)
        precondition(DisplayLayout.fit(captureWidth: 100, captureHeight: 100,
                                       desktopWidth: 0, desktopHeight: 100) == nil)
        // The content box always fits inside the desktop for every layout above.
        for layout in [bars1440, bars600, scaled923, upscaled2304, oneToOne1664] {
            precondition(layout.contentWidth > 0 && layout.contentHeight > 0)
            precondition(layout.contentWidth <= layout.desktopWidth)
            precondition(layout.contentHeight <= layout.desktopHeight)
            precondition(layout.offsetX >= 0 && layout.offsetY >= 0)
        }

        // --- desktop -> capture -> display mouse mapping (design section 5) ---
        // 1:1 content with 173 px bars left/right inside 2560x1440.
        let displayPoints = DesktopDisplayRect(originX: 0, originY: 0, width: 1470, height: 956)
        func desktopCapture(_ x: Int, _ y: Int) -> CapturePixelPoint? {
            DisplayCoordinateMapper.capturePoint(x: x, y: y,
                                                 desktopWidth: 2560, desktopHeight: 1440,
                                                 captureWidth: 2214, captureHeight: 1440)
        }
        func desktopMapped(_ x: Int, _ y: Int) -> DesktopPoint? {
            DisplayCoordinateMapper.desktopPoint(x: x, y: y,
                                                 desktopWidth: 2560, desktopHeight: 1440,
                                                 captureWidth: 2214, captureHeight: 1440,
                                                 display: displayPoints)
        }
        // Four corners + centre.
        precondition(desktopCapture(0, 0) == CapturePixelPoint(x: 0, y: 0))
        precondition(desktopCapture(2559, 0) == CapturePixelPoint(x: 2213, y: 0))
        precondition(desktopCapture(0, 1439) == CapturePixelPoint(x: 0, y: 1439))
        precondition(desktopCapture(2559, 1439) == CapturePixelPoint(x: 2213, y: 1439))
        precondition(desktopCapture(1280, 720) == CapturePixelPoint(x: 1107, y: 720))
        // Bar clicks clamp to the nearest content edge, never outside the capture.
        precondition(desktopCapture(-7, 720) == CapturePixelPoint(x: 0, y: 720))
        precondition(desktopCapture(172, 720) == CapturePixelPoint(x: 0, y: 720))
        precondition(desktopCapture(173, 720) == CapturePixelPoint(x: 0, y: 720))
        precondition(desktopCapture(2386, 720) == CapturePixelPoint(x: 2213, y: 720))
        precondition(desktopCapture(2559, 720) == CapturePixelPoint(x: 2213, y: 720))
        precondition(desktopCapture(3000, 2000) == CapturePixelPoint(x: 2213, y: 1439))
        // Mapped display points (macOS points; capture -> display is linear).
        precondition(desktopMapped(0, 0) == DesktopPoint(x: 0, y: 0))
        precondition(desktopMapped(1280, 720) == DesktopPoint(x: 735, y: 478))
        precondition(desktopMapped(2559, 0) ==
                     DesktopPoint(x: 1470.0 * 2213.0 / 2214.0, y: 0))
        precondition(desktopMapped(0, 1439) ==
                     DesktopPoint(x: 0, y: 956.0 * 1439.0 / 1440.0))
        precondition(desktopMapped(100, 720) == DesktopPoint(x: 0, y: 478))
        precondition(desktopMapped(2500, 720) ==
                     DesktopPoint(x: 1470.0 * 2213.0 / 2214.0, y: 478))
        // A display with a non-zero origin is still mapped correctly.
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 1280, y: 720, desktopWidth: 2560, desktopHeight: 1440,
            captureWidth: 2214, captureHeight: 1440,
            display: DesktopDisplayRect(originX: -800, originY: 40,
                                        width: 1600, height: 900)) ==
                     DesktopPoint(x: 0, y: 490))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 0, y: 0, desktopWidth: 0, desktopHeight: 1440,
            captureWidth: 2214, captureHeight: 1440, display: displayPoints) == nil)

        // 1:1 content with 40 px bars top/bottom inside 800x600.
        func bars600Capture(_ x: Int, _ y: Int) -> CapturePixelPoint? {
            DisplayCoordinateMapper.capturePoint(x: x, y: y,
                                                 desktopWidth: 800, desktopHeight: 600,
                                                 captureWidth: 800, captureHeight: 520)
        }
        precondition(bars600Capture(0, 0) == CapturePixelPoint(x: 0, y: 0))
        precondition(bars600Capture(799, 0) == CapturePixelPoint(x: 799, y: 0))
        precondition(bars600Capture(0, 599) == CapturePixelPoint(x: 0, y: 519))
        precondition(bars600Capture(799, 599) == CapturePixelPoint(x: 799, y: 519))
        precondition(bars600Capture(400, 300) == CapturePixelPoint(x: 400, y: 260))
        precondition(bars600Capture(400, 0) == CapturePixelPoint(x: 400, y: 0))
        precondition(bars600Capture(400, 559) == CapturePixelPoint(x: 400, y: 519))
        precondition(bars600Capture(400, 560) == CapturePixelPoint(x: 400, y: 519))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 400, y: 300, desktopWidth: 800, desktopHeight: 600,
            captureWidth: 800, captureHeight: 520, display: displayPoints) ==
                     DesktopPoint(x: 735, y: 478))

        // Scaled content 1470x956 inside 1468x923 (bars 24/25 px left/right).
        func scaledCapture(_ x: Int, _ y: Int) -> CapturePixelPoint? {
            DisplayCoordinateMapper.capturePoint(x: x, y: y,
                                                 desktopWidth: 1468, desktopHeight: 923,
                                                 captureWidth: 1470, captureHeight: 956)
        }
        precondition(scaledCapture(0, 0) == CapturePixelPoint(x: 0, y: 0))
        precondition(scaledCapture(1467, 0) == CapturePixelPoint(x: 1469, y: 0))
        precondition(scaledCapture(0, 461) == CapturePixelPoint(x: 0, y: 477))
        precondition(scaledCapture(1467, 922) == CapturePixelPoint(x: 1469, y: 954))
        precondition(scaledCapture(734, 461) == CapturePixelPoint(x: 735, y: 477))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 734, y: 461, desktopWidth: 1468, desktopHeight: 923,
            captureWidth: 1470, captureHeight: 956, display: displayPoints) ==
                     DesktopPoint(x: 735, y: 477))

        // Native capture upscaled into 4096x2304 (bars 276 px left/right).
        func upscaledCapture(_ x: Int, _ y: Int) -> CapturePixelPoint? {
            DisplayCoordinateMapper.capturePoint(x: x, y: y,
                                                 desktopWidth: 4096, desktopHeight: 2304,
                                                 captureWidth: 2940, captureHeight: 1912)
        }
        precondition(upscaledCapture(0, 0) == CapturePixelPoint(x: 0, y: 0))
        precondition(upscaledCapture(4095, 0) == CapturePixelPoint(x: 2939, y: 0))
        precondition(upscaledCapture(0, 2303) == CapturePixelPoint(x: 0, y: 1911))
        precondition(upscaledCapture(4095, 2303) == CapturePixelPoint(x: 2939, y: 1911))
        precondition(upscaledCapture(2048, 1152) == CapturePixelPoint(x: 1470, y: 956))
        precondition(upscaledCapture(100, 1152) == CapturePixelPoint(x: 0, y: 956))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 2048, y: 1152, desktopWidth: 4096, desktopHeight: 2304,
            captureWidth: 2940, captureHeight: 1912, display: displayPoints) ==
                     DesktopPoint(x: 735, y: 478))

        // Exact 1:1 desktop: no layout transform at all.
        let nativePoints = DesktopDisplayRect(originX: 0, originY: 0, width: 1280, height: 832)
        precondition(DisplayCoordinateMapper.capturePoint(
            x: 0, y: 0, desktopWidth: 2560, desktopHeight: 1664,
            captureWidth: 2560, captureHeight: 1664) == CapturePixelPoint(x: 0, y: 0))
        precondition(DisplayCoordinateMapper.capturePoint(
            x: 2559, y: 1663, desktopWidth: 2560, desktopHeight: 1664,
            captureWidth: 2560, captureHeight: 1664) == CapturePixelPoint(x: 2559, y: 1663))
        precondition(DisplayCoordinateMapper.capturePoint(
            x: 1280, y: 832, desktopWidth: 2560, desktopHeight: 1664,
            captureWidth: 2560, captureHeight: 1664) == CapturePixelPoint(x: 1280, y: 832))
        precondition(DisplayCoordinateMapper.desktopPoint(
            x: 1280, y: 832, desktopWidth: 2560, desktopHeight: 1664,
            captureWidth: 2560, captureHeight: 1664, display: nativePoints) ==
                     DesktopPoint(x: 640, y: 416))

        // --- thread-safe geometry state (IPC type 9 = desktop box) ---
        let geometryState = CaptureGeometryState(
            desktop: CaptureSizeRequest(width: 2560, height: 1440)!,
            nativeWidth: 2940, nativeHeight: 1912)
        precondition(geometryState.snapshot().policy == .fit)
        precondition(geometryState.snapshot().capture ==
                     CaptureSizeRequest(width: 2214, height: 1440)!)
        let exactUpdate = geometryState.updateRequested(
            CaptureSizeRequest(width: 2560, height: 1664)!)
        precondition(exactUpdate.policy == .exact)
        precondition(exactUpdate.capture == CaptureSizeRequest(width: 2560, height: 1664)!)
        precondition(geometryState.snapshot().desktopValue == "2560x1664")
        // An unchanged or unavailable native size does not recompute.
        precondition(geometryState.updateNative(width: 2940, height: 1912) == nil)
        precondition(geometryState.updateNative(width: 0, height: 0) == nil)
        precondition(geometryState.updateNative(width: 0, height: 1912) == nil)
        // A display resolution change recomputes against the current desktop box.
        let nativeUpdate = geometryState.updateNative(width: 3840, height: 2160)
        precondition(nativeUpdate?.policy == .fit)
        precondition(nativeUpdate?.capture == CaptureSizeRequest(width: 2560, height: 1440)!)
        precondition(geometryState.snapshot().nativeValue == "3840x2160")
        // An unavailable initial native size degrades to 1x1, never upscaling.
        let degenerateState = CaptureGeometryState(
            desktop: CaptureSizeRequest(width: 100, height: 100)!,
            nativeWidth: 0, nativeHeight: 0)
        precondition(degenerateState.snapshot().nativeValue == "1x1")
        precondition(degenerateState.snapshot().policy == .native)
        precondition(degenerateState.snapshot().capture ==
                     CaptureSizeRequest(width: 1, height: 1)!)

        // --- Windows keys map to the macOS Command keys (design 7, field log) ---
        precondition(MacKeyMap.virtualKey(scancode: 0x5b, extended: false) == 0x37)
        precondition(MacKeyMap.virtualKey(scancode: 0x5b, extended: true) == 0x37)
        precondition(MacKeyMap.virtualKey(scancode: 0x5c, extended: false) == 0x36)
        precondition(MacKeyMap.virtualKey(scancode: 0x5c, extended: true) == 0x36)
        // Existing mappings are unchanged.
        precondition(MacKeyMap.virtualKey(scancode: 0x1e, extended: false) == 0x00)
        precondition(MacKeyMap.virtualKey(scancode: 0x38, extended: false) == 0x3a)
        precondition(MacKeyMap.virtualKey(scancode: 0x1d, extended: true) == 0x3e)
    }

    private static func captureGeometry(desktopWidth: Int, desktopHeight: Int,
                                        nativeWidth: Int = 2940,
                                        nativeHeight: Int = 1912) -> CaptureGeometry? {
        guard let desktop = CaptureSizeRequest(width: desktopWidth,
                                               height: desktopHeight) else { return nil }
        return CaptureGeometry.resolve(desktop: desktop,
                                       nativeWidth: nativeWidth,
                                       nativeHeight: nativeHeight)
    }
}

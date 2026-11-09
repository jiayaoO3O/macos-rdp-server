import Darwin
import Foundation
import CoreGraphics

public enum CapturePixelError: Error, Equatable {
    case invalidImage
    case unsupportedLayout
}

/// How the pixels of a CGImage are laid out in memory.
public struct CapturePixelLayout: Equatable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let alphaInfoRaw: UInt32
    public let byteOrderInfoRaw: UInt32
    public let isMask: Bool
    public let colorSpaceName: String?

    public init(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int,
                bytesPerRow: Int, alphaInfoRaw: UInt32, byteOrderInfoRaw: UInt32,
                isMask: Bool, colorSpaceName: String? = nil) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        self.alphaInfoRaw = alphaInfoRaw
        self.byteOrderInfoRaw = byteOrderInfoRaw
        self.isMask = isMask
        self.colorSpaceName = colorSpaceName
    }

    public init(image: CGImage) {
        self.init(width: image.width, height: image.height,
                  bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                  bytesPerRow: image.bytesPerRow, alphaInfoRaw: image.alphaInfo.rawValue,
                  byteOrderInfoRaw: image.byteOrderInfo.rawValue, isMask: image.isMask,
                  colorSpaceName: image.colorSpace?.name as String?)
    }

    /// True when the image bytes already are exactly the BGRA layout the RDP
    /// planar path consumes: 8-bit components, premultiplied-first alpha,
    /// little-endian 32-bit words.
    public var isBGRAPremultipliedFirst: Bool {
        guard !isMask, width > 0, height > 0, bitsPerComponent == 8, bitsPerPixel == 32,
              bytesPerRow >= width * 4 else { return false }
        return alphaInfoRaw == CGImageAlphaInfo.premultipliedFirst.rawValue &&
            byteOrderInfoRaw == CGBitmapInfo.byteOrder32Little.rawValue
    }

    /// True when the pixels are already in the colour space the RDP client
    /// interprets them in (sRGB). Copying a Display P3 image verbatim would
    /// deliver P3 numbers as if they were sRGB (a visible colour shift), so the
    /// direct copy is only safe for sRGB-tagged images.
    public var isSRGBColorSpace: Bool {
        guard let colorSpaceName else { return false }
        return colorSpaceName == "kCGColorSpaceSRGB" ||
            colorSpaceName == "kCGColorSpaceExtendedSRGB" ||
            colorSpaceName == "kCGColorSpaceLinearSRGB"
    }

    public var canCopyRowsDirectly: Bool {
        isBGRAPremultipliedFirst && isSRGBColorSpace
    }

    public var isRowPadded: Bool { bytesPerRow > width * 4 }
    public var pixelBytes: Int { width * height * 4 }

    public var describe: String {
        "w=" + String(width) + " h=" + String(height) +
            " bpc=" + String(bitsPerComponent) + " bpp=" + String(bitsPerPixel) +
            " bpr=" + String(bytesPerRow) + " alpha=" + String(alphaInfoRaw) +
            " order=" + String(byteOrderInfoRaw) + " mask=" + String(isMask) +
            " colorspace=" + (colorSpaceName ?? "none")
    }
}

public enum CapturePixelStrategy: Equatable {
    /// Direct row copy when the CGImage is BGRA/premultiplied-first and already
    /// sRGB (colour-correct, no conversion). Otherwise convert to sRGB with a
    /// CGContext in CGColorSpaceCreateDeviceRGB() (same result as the historical
    /// code, just slower for P3 images).
    case automatic
    /// Direct row copy; throws when the layout is not directly copyable.
    case directRows
    /// CGContext in the image's own colour space (bit-preserving draw; keeps
    /// display-space values and is only for diagnostics/benchmarks).
    case contextImageColorSpace
    /// Historical behaviour: CGContext in CGColorSpaceCreateDeviceRGB(), which
    /// performs a per-pixel colour conversion for P3 screenshots.
    case contextDeviceRGB

    public var label: String {
        switch self {
        case .automatic: return "automatic"
        case .directRows: return "directRows"
        case .contextImageColorSpace: return "contextImageColorSpace"
        case .contextDeviceRGB: return "contextDeviceRGB"
        }
    }
}

public enum CapturePixelConverter {
    public static func layout(of image: CGImage) -> CapturePixelLayout {
        CapturePixelLayout(image: image)
    }

    public static func resolvedStrategy(for image: CGImage,
                                        requested: CapturePixelStrategy) -> CapturePixelStrategy {
        switch requested {
        case .automatic:
            return layout(of: image).canCopyRowsDirectly ? .directRows : .contextDeviceRGB
        default:
            return requested
        }
    }

    /// Convert to tightly packed BGRA. Kept as the historical entry point.
    public static func bgra(_ image: CGImage) throws -> Data {
        try bgra(image, strategy: .automatic)
    }

    public static func bgra(_ image: CGImage, strategy: CapturePixelStrategy) throws -> Data {
        let descriptor = layout(of: image)
        guard descriptor.width > 0, descriptor.height > 0,
              descriptor.width <= Int(AgentFrameAssembler.maxFrameDimension),
              descriptor.height <= Int(AgentFrameAssembler.maxFrameDimension),
              descriptor.bitsPerComponent == 8, descriptor.pixelBytes > 0 else {
            throw CapturePixelError.invalidImage
        }
        var pixels = Data(count: 0)
        try copyBGRA(image, into: &pixels, strategy: strategy)
        guard pixels.count == descriptor.pixelBytes else { throw CapturePixelError.invalidImage }
        return pixels
    }

    /// Convert to tightly packed BGRA, reusing the buffer when it already has the
    /// right size. The buffer is only allocated (and zero-filled) when the frame
    /// size changes, so the steady-state loop does no per-frame allocation.
    public static func copyBGRA(_ image: CGImage, into pixels: inout Data,
                                strategy: CapturePixelStrategy = .automatic) throws {
        let descriptor = layout(of: image)
        guard descriptor.width > 0, descriptor.height > 0,
              descriptor.width <= Int(AgentFrameAssembler.maxFrameDimension),
              descriptor.height <= Int(AgentFrameAssembler.maxFrameDimension),
              descriptor.bitsPerComponent == 8, descriptor.pixelBytes > 0 else {
            throw CapturePixelError.invalidImage
        }
        switch resolvedStrategy(for: image, requested: strategy) {
        case .automatic:
            fallthrough
        case .directRows:
            try copyRows(image, layout: descriptor, into: &pixels)
        case .contextImageColorSpace:
            try draw(image, layout: descriptor, into: &pixels,
                     space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        case .contextDeviceRGB:
            try draw(image, layout: descriptor, into: &pixels,
                     space: CGColorSpaceCreateDeviceRGB())
        }
    }

    private static func copyRows(_ image: CGImage, layout: CapturePixelLayout,
                                 into pixels: inout Data) throws {
        guard layout.isBGRAPremultipliedFirst,
              let provider = image.dataProvider,
              let providerData = provider.data,
              let source = CFDataGetBytePtr(providerData) else {
            throw CapturePixelError.unsupportedLayout
        }
        let rowBytes = layout.width * 4
        let sourceRowBytes = layout.bytesPerRow
        let needed = rowBytes * layout.height
        guard CFDataGetLength(providerData) >= sourceRowBytes * (layout.height - 1) + rowBytes else {
            throw CapturePixelError.unsupportedLayout
        }
        if pixels.count != needed { pixels = Data(count: needed) }
        pixels.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else { return }
            if sourceRowBytes == rowBytes {
                memcpy(destination, source, needed)
            } else {
                for row in 0..<layout.height {
                    memcpy(destination.advanced(by: row * rowBytes),
                           source.advanced(by: row * sourceRowBytes), rowBytes)
                }
            }
        }
    }

    private static func draw(_ image: CGImage, layout: CapturePixelLayout,
                             into pixels: inout Data, space: CGColorSpace) throws {
        let needed = layout.pixelBytes
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        if pixels.count != needed { pixels = Data(count: needed) }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: layout.width, height: layout.height,
                                          bitsPerComponent: 8, bytesPerRow: layout.width * 4,
                                          space: space, bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
            return true
        }
        guard rendered else { throw CapturePixelError.invalidImage }
    }
}

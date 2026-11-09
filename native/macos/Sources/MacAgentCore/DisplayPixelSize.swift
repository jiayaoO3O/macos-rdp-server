public struct DisplayPixelSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// "WxH" helper shared by the Agent/child log lines.
    public var value: String { "\(width)x\(height)" }

    public static func resolve(pointsWidth: Int, pointsHeight: Int,
                               pixelsWidth: Int, pixelsHeight: Int) -> DisplayPixelSize {
        guard pointsWidth > 0, pointsHeight > 0 else { return DisplayPixelSize(width: 0, height: 0) }
        guard pixelsWidth > 0, pixelsHeight > 0 else {
            return DisplayPixelSize(width: pointsWidth, height: pointsHeight)
        }
        return DisplayPixelSize(width: pixelsWidth, height: pixelsHeight)
    }
}

import Foundation

/// Pixel dimensions of a macOS display mode. The Agent matches the RDP client's
/// requested desktop box against these, so a 16:9 client on a 3:2 panel can be
/// shown with smaller black bars (product decision 2026-11-08: switch the
/// display mode to minimise the bars; do NOT stretch — the Worker keeps the
/// existing fit-with-bars letterbox composition and the existing letterbox mouse
/// mapping).
public struct DisplayModePixels: Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int64 { Int64(width) * Int64(height) }

    public var value: String { "\(width)x\(height)" }

    /// Aspect-ratio difference from `other` in permille of `other`'s aspect
    /// ratio: `|self.w * other.h - self.h * other.w| * 1000 / (other.h * self.w)`.
    /// 0 means an exact aspect match; this is proportional to the black-bar area
    /// for a `self`-mode shown in an `other` desktop (letterbox composition).
    /// Rounded to the nearest permille.
    public func aspectDeltaPermille(from other: DisplayModePixels) -> Int {
        guard other.width > 0, other.height > 0,
              width > 0, height > 0 else { return 0 }
        let difference = Self.aspectDifference(self, other)
        let denominator = Int64(other.height) * Int64(width)
        guard denominator > 0 else { return 0 }
        return Int((difference * 1000 + denominator / 2) / denominator)
    }

    /// Exact (non-rounded) numerator of the aspect difference; used to compare
    /// candidates without permille-rounding ties.
    static func aspectDifference(_ lhs: DisplayModePixels,
                                 _ rhs: DisplayModePixels) -> Int64 {
        abs(Int64(lhs.width) * Int64(rhs.height) - Int64(lhs.height) * Int64(rhs.width))
    }

    /// True when `self` has a strictly smaller aspect difference from
    /// `requested` than `other` (exact integer comparison, no rounding).
    func hasCloserAspect(than other: DisplayModePixels,
                         to requested: DisplayModePixels) -> Bool {
        // delta = diff / (requested.h * mode.w); requested.h is common, so
        // compare diff/w numerically without floating point.
        let selfDiff = Self.aspectDifference(self, requested)
        let otherDiff = Self.aspectDifference(other, requested)
        guard width > 0, other.width > 0 else { return false }
        return selfDiff * Int64(other.width) < otherDiff * Int64(width)
    }
}

/// Why a mode was selected (grep-able `reason=` token).
public enum DisplayModeMatchReason: String, Equatable {
    /// Pixel dimensions equal the requested desktop box (no black bars at all).
    case exact
    /// No exact pixel match exists; the mode with the closest aspect ratio.
    case closest
}

public struct DisplayModeMatch: Equatable {
    public let mode: DisplayModePixels
    public let reason: DisplayModeMatchReason
    public let aspectDeltaPermille: Int

    public init(mode: DisplayModePixels, reason: DisplayModeMatchReason,
                aspectDeltaPermille: Int) {
        self.mode = mode
        self.reason = reason
        self.aspectDeltaPermille = aspectDeltaPermille
    }
}

/// Pure display-mode selection for the auto display-mode matching feature.
///
/// Rule (binding for main.swift, the logs and the tests; product decision
/// "不拉伸，保留小一点的黑边"):
///   * exact pixel match wins (zero black bars),
///   * otherwise choose the mode that MINIMISES the aspect-ratio difference from
///     the requested desktop box (exact integer comparison, not rounded
///     permille), because that minimises the black-bar area of the Worker's
///     fit-with-bars letterbox composition,
///   * tie-break (identical aspect ratio, e.g. scaled variants): larger pixel
///     area, so the letterboxed content keeps the most resolution.
///
/// The Agent only switches when the selected mode improves the aspect delta by
/// more than `DisplayModeSwitchPolicy.minimumImprovementPermille` (20) compared
/// with the current display mode; this avoids pointless mode churn for
/// sub-visible gains (see `shouldSwitch`).
public enum DisplayModeMatcher {
    /// Returns nil only when the request or the available mode list is empty /
    /// degenerate.
    public static func match(requested: DisplayModePixels,
                             available: [DisplayModePixels]) -> DisplayModeMatch? {
        guard requested.width > 0, requested.height > 0 else { return nil }
        let modes = available.filter { $0.width > 0 && $0.height > 0 }
        guard !modes.isEmpty else { return nil }

        if let exact = modes.first(where: {
            $0.width == requested.width && $0.height == requested.height
        }) {
            return DisplayModeMatch(mode: exact, reason: .exact,
                                    aspectDeltaPermille: 0)
        }

        var best: DisplayModePixels?
        for candidate in modes {
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.hasCloserAspect(than: current, to: requested) {
                best = candidate
            } else if !current.hasCloserAspect(than: candidate, to: requested),
                      candidate.pixelCount > current.pixelCount {
                // Identical aspect ratio: keep the larger (more resolution).
                best = candidate
            }
        }
        guard let chosen = best else { return nil }
        return DisplayModeMatch(mode: chosen, reason: .closest,
                                aspectDeltaPermille: chosen.aspectDeltaPermille(from: requested))
    }
}

/// When is a display-mode switch actually worth doing?
public enum DisplayModeSwitchPolicy {
    /// Minimum improvement of the aspect delta (permille) required to switch.
    /// The product decision: switch only when the black bars get meaningfully
    /// smaller (>2% of the desktop aspect), never for churn.
    public static let minimumImprovementPermille = 20

    /// Decides whether the Agent should switch from `current` to `match`.
    ///
    /// * current mode is already the selected mode -> no-op (already optimal),
    /// * otherwise switch only when the aspect delta improves by more than
    ///   `minimumImprovementPermille` (20). This also makes a bar-free exact
    ///   mode skip the switch when the current mode is already within 2% aspect
    ///   (the bars are invisible at that point), and keeps the native mode for
    ///   requests that are already close to it.
    public static func shouldSwitch(from current: DisplayModePixels?,
                                    to match: DisplayModeMatch,
                                    requested: DisplayModePixels,
                                    minimumImprovementPermille: Int =
                                        DisplayModeSwitchPolicy.minimumImprovementPermille) -> Bool {
        if let current, current == match.mode {
            return false // already showing the selected mode
        }
        guard let current else { return true }
        let currentDelta = current.aspectDeltaPermille(from: requested)
        let bestDelta = match.aspectDeltaPermille
        return currentDelta - bestDelta > minimumImprovementPermille
    }
}

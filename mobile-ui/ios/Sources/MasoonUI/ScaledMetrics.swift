import SwiftUI

public enum MasoonScale {
    /// Approximate Dynamic Type scale factor for each `ContentSizeCategory`,
    /// relative to `.large` (the system default = 1.0). Matches the shape of
    /// Apple's published step sizes closely enough to guarantee meaningful growth
    /// at every accessibility step without claiming per-text-style precision.
    public static func factor(for category: ContentSizeCategory) -> CGFloat {
        switch category {
        case .extraSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1.0
        case .extraLarge: return 1.12
        case .extraExtraLarge: return 1.23
        case .extraExtraExtraLarge: return 1.35
        case .accessibilityMedium: return 1.64
        case .accessibilityLarge: return 1.94
        case .accessibilityExtraLarge: return 2.35
        case .accessibilityExtraExtraLarge: return 2.76
        case .accessibilityExtraExtraExtraLarge: return 3.12
        @unknown default: return 1.0
        }
    }

    /// Scales `base` points by `category`'s factor. `minimum`, when given, is a
    /// hard floor — useful for a target that must never shrink below the 44 pt
    /// gate even at the smallest size category.
    public static func value(_ base: CGFloat, for category: ContentSizeCategory, minimum: CGFloat? = nil) -> CGFloat {
        let scaled = base * factor(for: category)
        if let minimum { return max(scaled, minimum) }
        return scaled
    }
}

private struct MasoonScaledFrame: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?
    let minimum: CGFloat?

    @Environment(\.sizeCategory) private var sizeCategory

    func body(content: Content) -> some View {
        content.frame(
            width: width.map { MasoonScale.value($0, for: sizeCategory, minimum: minimum) },
            height: height.map { MasoonScale.value($0, for: sizeCategory, minimum: minimum) }
        )
    }
}

public extension View {
    /// A frame that grows with Dynamic Type.
    func masoonScaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, minimum: CGFloat? = nil) -> some View {
        modifier(MasoonScaledFrame(width: width, height: height, minimum: minimum))
    }
}

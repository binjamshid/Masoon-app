import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Semantic colors for the public controls. Backgrounds follow the host appearance.
public enum MasoonColors {
    public static let primary = Color.primary
    public static let primaryEmphasis = Color.primary.opacity(0.82)
    public static let onPrimary = background
    public static let primarySoft = Color.secondary.opacity(0.14)

    #if canImport(UIKit)
    public static let background = Color(uiColor: .systemBackground)
    public static let surface = Color(uiColor: .systemBackground)
    public static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)
    public static let outline = Color(uiColor: .separator)
    #elseif canImport(AppKit)
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let surface = Color(nsColor: .controlBackgroundColor)
    public static let surfaceSecondary = Color(nsColor: .underPageBackgroundColor)
    public static let outline = Color(nsColor: .separatorColor)
    #endif

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let success = Color.green
    public static let attention = Color.orange
    public static let progressTrack = Color.secondary.opacity(0.22)
}

// MARK: - Spacing

/// 4-pt spacing scale. Use these instead of magic numbers.
public enum MasoonSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

// MARK: - Radii

public enum MasoonRadius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    /// Fully-rounded capsule chips.
    public static let pill: CGFloat = 999
}

// MARK: - Metrics

public enum MasoonMetrics {
    /// Minimum interactive target in points.
    public static let minTarget: CGFloat = 44
}

// MARK: - Typography (`masoon-type-*`)

/// Text styles built on the system font (SF Arabic renders automatically for Arabic
/// script on iOS) with full Dynamic Type scaling — every style maps to a system
/// `Font.TextStyle` so it participates in the user's type-size setting.
public enum MasoonTypeStyle {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption

    public var font: Font {
        switch self {
        case .largeTitle: return .system(.largeTitle, design: .default, weight: .bold)
        case .title: return .system(.title, design: .default, weight: .bold)
        case .title2: return .system(.title2, design: .default, weight: .semibold)
        case .title3: return .system(.title3, design: .default, weight: .semibold)
        case .headline: return .system(.headline, design: .default, weight: .semibold)
        case .body: return .system(.body, design: .default)
        case .callout: return .system(.callout, design: .default)
        case .subheadline: return .system(.subheadline, design: .default)
        case .footnote: return .system(.footnote, design: .default)
        case .caption: return .system(.caption, design: .default)
        }
    }
}

public extension Font {
    /// `Font.masoon(.headline)` — the `masoon-type-*` scale.
    static func masoon(_ style: MasoonTypeStyle) -> Font { style.font }
}

public extension View {
    /// Applies a `masoon-type-*` style with the default primary text color.
    func masoonType(_ style: MasoonTypeStyle, color: Color = MasoonColors.textPrimary) -> some View {
        font(style.font).foregroundStyle(color)
    }
}

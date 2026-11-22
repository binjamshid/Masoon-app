import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DirectionalChevron

/// A "forward" chevron that always points in the reading direction:
/// left in RTL, right in LTR. Use for disclosure/navigation affordances.
public struct DirectionalChevron: View {
    private let color: Color

    public init(color: Color = MasoonColors.textSecondary) {
        self.color = color
    }

    public var body: some View {
        // chevron.forward is direction-aware; SwiftUI mirrors it in RTL.
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true) // decorative; the row carries the label
    }
}

// MARK: - Haptics

/// Cross-platform-safe haptic helper. No-op off iOS so the package builds on macOS.
public enum MasoonHaptics {
    public static func lightImpact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    public static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

// MARK: - Card container

public extension View {
    /// Standard Masoon card: surface fill, hairline outline, large radius.
    func masoonCard() -> some View {
        self
            .background(MasoonColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: MasoonRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MasoonRadius.lg, style: .continuous)
                    .strokeBorder(MasoonColors.outline, lineWidth: 1)
            )
    }
}

// Shared primary, secondary and quiet actions.

import SwiftUI

public struct MasoonButton: View {
    public enum Style {
        case primary, secondary, quiet
    }

    private let title: String
    private let style: Style
    private let icon: String?
    private let isFullWidth: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        style: Style = .primary,
        icon: String? = nil,
        isFullWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.icon = icon
        self.isFullWidth = isFullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: MasoonSpacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.masoon(.headline))
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(minHeight: MasoonMetrics.minTarget)
            .padding(.horizontal, MasoonSpacing.lg)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: MasoonRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MasoonRadius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: style == .secondary ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch style {
        case .primary: return MasoonColors.onPrimary
        case .secondary, .quiet: return MasoonColors.primary
        }
    }

    private var background: Color {
        switch style {
        case .primary: return MasoonColors.primary
        case .secondary: return .clear
        case .quiet: return .clear
        }
    }

    private var borderColor: Color {
        style == .secondary ? MasoonColors.primary : .clear
    }
}

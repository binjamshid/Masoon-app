import SwiftUI

// MARK: - Chip

public struct Chip: View {
    private let text: String
    private let icon: String?
    private let tint: Color
    private let filled: Bool
    private let background: Color?

    /// - Parameter background: explicit fill override. `nil` (default)
    ///   preserves the original behavior (`filled ? surfaceSecondary :
    ///   clear`) for every existing call site. Added for G-17's
    ///   `SegmentedFilterBar`, which needs a selected segment filled with
    ///   `MasoonColors.primarySoft` — Tokens.swift's own documented
    ///   "Selected/quiet-highlight wash" role, not a new color — rather than
    ///   Chip's default neutral `surfaceSecondary`. Genuine, narrow gap:
    ///   Chip had no way to express "filled, but not with the default
    ///   neutral wash" before this.
    public init(
        _ text: String,
        icon: String? = nil,
        tint: Color = MasoonColors.textSecondary,
        filled: Bool = true,
        background: Color? = nil
    ) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.filled = filled
        self.background = background
    }

    public var body: some View {
        HStack(spacing: MasoonSpacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.masoon(.caption))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, MasoonSpacing.sm + 2)
        .padding(.vertical, MasoonSpacing.xs + 1)
        .background(background ?? (filled ? MasoonColors.surfaceSecondary : .clear))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                filled ? Color.clear : MasoonColors.outline,
                lineWidth: 1
            )
        )
        .accessibilityElement(children: .combine)
    }
}

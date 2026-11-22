// Horizontal filter bar built from selectable chips.

import SwiftUI

public struct SegmentedFilterBar<Filter: Hashable>: View {

    public struct Option: Identifiable {
        public let id: Filter
        public let title: String
        public let icon: String?

        public init(_ id: Filter, title: String, icon: String? = nil) {
            self.id = id
            self.title = title
            self.icon = icon
        }
    }

    private let options: [Option]
    @Binding private var selection: Filter

    public init(options: [Option], selection: Binding<Filter>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MasoonSpacing.sm) {
                ForEach(options) { option in
                    segment(option)
                }
            }
            .padding(.vertical, MasoonSpacing.xs)
        }
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.id == selection
        return Button {
            selection = option.id
        } label: {
            Chip(
                option.title,
                icon: option.icon,
                tint: isSelected ? MasoonColors.primary : MasoonColors.textSecondary,
                filled: true,
                // primarySoft is Tokens.swift's own documented "Selected/
                // quiet-highlight wash" — the exact existing token for this
                // exact role, not a new color.
                background: isSelected ? MasoonColors.primarySoft : nil
            )
            .frame(minHeight: MasoonMetrics.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

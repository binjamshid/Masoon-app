// Shared form label, control and validation message.

import SwiftUI

public struct FormField<Control: View>: View {
    @Environment(\.locale) private var locale

    private let label: String
    private let helperText: String?
    private let errorText: String?
    private let isRequired: Bool
    private let control: Control

    public init(
        _ label: String,
        helperText: String? = nil,
        errorText: String? = nil,
        isRequired: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.helperText = helperText
        self.errorText = errorText
        self.isRequired = isRequired
        self.control = control()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
            HStack(spacing: MasoonSpacing.xs) {
                Text(label).masoonType(.subheadline, color: MasoonColors.textSecondary)
                if isRequired {
                    Text("*").masoonType(.subheadline, color: MasoonColors.attention)
                }
            }
            // The control below carries this same text (plus "required") as
            // its own accessibility label, so the visual label row doesn't
            // need to be a second, separate VoiceOver stop.
            .accessibilityHidden(true)

            control
                .accessibilityLabel(Text(accessibleLabel))

            if let errorText {
                HStack(spacing: MasoonSpacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(errorText).masoonType(.footnote, color: MasoonColors.attention)
                }
            } else if let helperText {
                Text(helperText).masoonType(.footnote, color: MasoonColors.textSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var accessibleLabel: String {
        isRequired ? locale.studyText("\(label)، مطلوب", "\(label), required") : label
    }
}

// MARK: - Text field convenience

public extension FormField where Control == TextField<Text> {
    init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        helperText: String? = nil,
        errorText: String? = nil,
        isRequired: Bool = false
    ) {
        self.init(label, helperText: helperText, errorText: errorText, isRequired: isRequired) {
            TextField(placeholder, text: text)
        }
    }
}

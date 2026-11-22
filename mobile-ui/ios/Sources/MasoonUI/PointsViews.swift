// Read-only point summaries and changes.

import SwiftUI

// MARK: - PointsSummaryRow

public struct PointsSummaryRow: View {
    private let total: Int
    private let label: String?

    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - total: an already-computed point total (never computed here).
    ///   - label: optional secondary line, e.g. "هذا الأسبوع".
    public init(total: Int, label: String? = nil) {
        self.total = total
        self.label = label
    }

    public var body: some View {
        HStack(spacing: MasoonSpacing.md) {
            Image(systemName: "seal.fill")
                .font(.title3)
                .foregroundStyle(MasoonColors.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
                Text(MasoonCountedNoun.point.phrase(total, locale: locale))
                    .masoonType(.headline)
                if let label {
                    Text(label).masoonType(.footnote, color: MasoonColors.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MasoonSpacing.lg)
        .padding(.vertical, MasoonSpacing.md)
        .frame(minHeight: MasoonMetrics.minTarget)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - PointsDeltaLabel

public struct PointsDeltaLabel: View {
    private let delta: Int

    @Environment(\.locale) private var locale

    /// - Parameter delta: signed point change, e.g. `+12` or `-3`.
    public init(delta: Int) {
        self.delta = delta
    }

    public var body: some View {
        HStack(spacing: MasoonSpacing.xs) {
            Image(systemName: Self.icon(for: delta))
                .font(.caption2)
                .accessibilityHidden(true)
            Text(Self.magnitudeText(delta: delta, locale: locale))
                .font(.masoon(.caption))
                .monospacedDigit()
        }
        .foregroundStyle(Self.tint(for: delta))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.accessibleLabel(delta: delta, locale: locale)))
    }

    static func icon(for delta: Int) -> String {
        delta > 0 ? "arrow.up" : (delta < 0 ? "arrow.down" : "minus")
    }

    /// Point decreases use a subdued color.
    static func tint(for delta: Int) -> Color {
        delta > 0 ? MasoonColors.success : MasoonColors.textSecondary
    }

    static func magnitudeText(delta: Int, locale: Locale) -> String {
        let magnitude = MasoonNumerals.format(abs(delta), locale: locale)
        if delta > 0 { return "+\(magnitude)" }
        if delta < 0 { return "\u{2212}\(magnitude)" }   // U+2212 minus sign
        return magnitude
    }

    static func accessibleLabel(delta: Int, locale: Locale) -> String {
        if delta > 0 {
            let phrase = MasoonCountedNoun.point.phrase(delta, locale: locale)
            return MasoonNumerals.isArabic(locale) ? "زيادة \(phrase)" : "gained \(phrase)"
        } else if delta < 0 {
            let phrase = MasoonCountedNoun.point.phrase(abs(delta), locale: locale)
            return MasoonNumerals.isArabic(locale) ? "نقصان \(phrase)" : "lost \(phrase)"
        } else {
            return MasoonNumerals.isArabic(locale) ? "لا تغيير في النقاط" : "No point change"
        }
    }
}

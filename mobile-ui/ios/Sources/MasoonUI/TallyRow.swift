import SwiftUI

public struct TallyRow: View {
    private let count: Int
    private let target: Int
    private let noun: MasoonCountedNoun
    private let onIncrement: (() -> Void)?

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// - Parameters:
    ///   - count: current tally (bound by the caller's model — this view is
    ///     stateless/display-only unless `onIncrement` is supplied).
    ///   - target: total to reach, e.g. 5.
    ///   - noun: the counted noun for the row's phrases, for example `.day`.
    ///   - onIncrement: if supplied, the row becomes tappable and
    ///     increments; `nil` renders a plain read-only summary row.
    public init(
        count: Int,
        target: Int,
        noun: MasoonCountedNoun,
        onIncrement: (() -> Void)? = nil
    ) {
        self.count = count
        self.target = max(1, target)
        self.noun = noun
        self.onIncrement = onIncrement
    }

    public var body: some View {
        Group {
            if let onIncrement {
                Button(action: { tap(onIncrement) }) { content }
                    .buttonStyle(.plain)
                    .disabled(isComplete)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.progressText(count: count, target: target, noun: noun, locale: locale)))
        .accessibilityValue(Text(Self.remainingCaption(count: count, target: target, noun: noun, locale: locale)))
        .accessibilityAddTraits(onIncrement != nil ? .isButton : [])
    }

    private var content: some View {
        HStack(spacing: MasoonSpacing.md) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isComplete ? MasoonColors.success : MasoonColors.textSecondary)
                .scaleEffect(pulse && !reduceMotion ? 1.15 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
                Text(Self.progressText(count: count, target: target, noun: noun, locale: locale))
                    .masoonType(.subheadline)
                Text(Self.remainingCaption(count: count, target: target, noun: noun, locale: locale))
                    .masoonType(.footnote, color: MasoonColors.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MasoonSpacing.md)
        .frame(minHeight: MasoonMetrics.minTarget)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: count)
    }

    private var isComplete: Bool { count >= target }

    /// Formats the current count and names the target in its locale-specific noun form.
    static func progressText(count: Int, target: Int, noun: MasoonCountedNoun, locale: Locale) -> String {
        let target = max(1, target)   // matches TallyRow.init's own clamp — safe to call standalone
        let c = MasoonNumerals.format(min(max(count, 0), target), locale: locale)
        let targetNoun = noun.phrase(target, locale: locale)
        return MasoonNumerals.isArabic(locale) ? "\(c) من \(targetNoun)" : "\(c) of \(targetNoun)"
    }

    /// Formats what remains until completion.
    static func remainingCaption(count: Int, target: Int, noun: MasoonCountedNoun, locale: Locale) -> String {
        let target = max(1, target)   // matches TallyRow.init's own clamp — safe to call standalone
        guard count < target else { return MasoonNumerals.isArabic(locale) ? "اكتمل" : "Done" }
        let remaining = max(0, target - count)
        return MasoonNumerals.remainingPhrase(count: remaining, locale: locale)
    }

    private func tap(_ onIncrement: @escaping () -> Void) {
        guard !isComplete else { return }
        onIncrement()
        MasoonHaptics.lightImpact()
        if !reduceMotion {
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pulse = false }
        }
        if count + 1 >= target {
            MasoonHaptics.success()
        }
    }
}

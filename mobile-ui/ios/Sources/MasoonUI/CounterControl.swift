// Repetition counter with a progress ring, haptics and Reduce Motion support.

import SwiftUI

public struct CounterControl: View {
    @Binding private var count: Int
    private let target: Int
    private let label: String?
    private let onComplete: (() -> Void)?

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var pulse = false

    // Scale the button and ring together so they still fit at large type sizes.
    private var scaleFactor: CGFloat {
        min(MasoonScale.factor(for: sizeCategory), 1.6)
    }
    private var buttonDiameter: CGFloat { 140 * scaleFactor }
    private var ringDiameter: CGFloat { 168 * scaleFactor }

    /// - Parameters:
    ///   - count: current repetition count (bound to the caller's model)
    ///   - target: required repetitions, e.g. 5
    ///   - label: what is being counted, e.g. "التكرار"
    ///   - onComplete: called once when count reaches target
    public init(
        count: Binding<Int>,
        target: Int,
        label: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        self._count = count
        self.target = max(1, target)
        self.label = label
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: MasoonSpacing.lg) {
            ZStack {
                ProgressRing(
                    progress: Double(count) / Double(target),
                    size: ringDiameter,
                    lineWidth: 10,
                    tint: isComplete ? MasoonColors.success : MasoonColors.primary
                )
                .accessibilityHidden(true)

                Button(action: increment) {
                    VStack(spacing: MasoonSpacing.xs) {
                        Text(phrase)
                            .font(.system(.title, design: .default, weight: .bold))
                            .foregroundStyle(MasoonColors.textPrimary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(isComplete ? locale.studyText("اكتمل", "Done") : locale.studyText("اضغط للعدّ", "Tap to count"))
                            .masoonType(.footnote, color: MasoonColors.textSecondary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    .frame(width: buttonDiameter, height: buttonDiameter)
                    .background(MasoonColors.surface)
                    .clipShape(Circle())
                    .scaleEffect(pulse && !reduceMotion ? 1.06 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isComplete)
                .accessibilityLabel(Text(label ?? locale.studyText("التكرار", "Repetition")))
                .accessibilityValue(Text(phrase))
                .accessibilityHint(Text(isComplete
                    ? locale.studyText("اكتمل العدّ", "Count complete")
                    : locale.studyText("اضغط مرتين لزيادة العدّ", "Double-tap to increment")))
            }

            if count > 0 && !isComplete {
                Button(action: decrement) {
                    HStack(spacing: MasoonSpacing.xs) {
                        Image(systemName: "arrow.uturn.backward")
                            .accessibilityHidden(true)
                        Text(locale.studyText("تراجع", "Undo"))
                    }
                    .font(.masoon(.subheadline))
                    .foregroundStyle(MasoonColors.textSecondary)
                    .frame(minWidth: MasoonMetrics.minTarget, minHeight: MasoonMetrics.minTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(locale.studyText("تراجع عن آخر عدّة", "Undo last count")))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: count)
    }

    private var isComplete: Bool { count >= target }

    /// "٣ من ٥" — shared between the visible label and accessibilityValue.
    private var phrase: String {
        MasoonNumerals.progressPhrase(count: min(count, target), target: target, locale: locale)
    }

    private func increment() {
        guard !isComplete else { return }
        count += 1
        MasoonHaptics.lightImpact()
        if !reduceMotion {
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pulse = false }
        }
        if count >= target {
            MasoonHaptics.success()
            onComplete?()
        }
    }

    private func decrement() {
        guard count > 0 else { return }
        count -= 1
        MasoonHaptics.lightImpact()
    }
}

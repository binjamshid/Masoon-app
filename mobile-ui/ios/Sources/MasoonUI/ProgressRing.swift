// SwiftUI completion indicator with a localized accessibility label.

import SwiftUI

public struct ProgressRing: View {
    @Environment(\.locale) private var locale
    private let progress: Double
    private let size: CGFloat
    private let lineWidth: CGFloat
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter progress: 0…1, clamped.
    public init(
        progress: Double,
        size: CGFloat = 44,
        lineWidth: CGFloat = 5,
        tint: Color = MasoonColors.primary
    ) {
        self.progress = min(max(progress, 0), 1)
        self.size = size
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(MasoonColors.progressTrack, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Progress sweeps in the reading direction: mirror the sweep in RTL
                // via the environment (the ring itself is direction-neutral).
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: progress)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(locale.studyText("نسبة الإنجاز", "Completion")))
        .accessibilityValue(Text(MasoonNumerals.percent(progress, locale: locale)))
    }
}

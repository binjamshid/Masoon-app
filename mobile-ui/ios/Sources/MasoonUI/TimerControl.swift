// Bound elapsed-time control. The caller owns the timer state.

import Combine
import SwiftUI

public struct TimerControl: View {
    @Binding private var elapsed: TimeInterval
    @Binding private var isRunning: Bool

    @Environment(\.locale) private var locale

    // Keep a stable publisher and connect it only while the visible timer is running.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common)
    @State private var tickerConnection: Cancellable?

    public init(elapsed: Binding<TimeInterval>, isRunning: Binding<Bool>) {
        self._elapsed = elapsed
        self._isRunning = isRunning
    }

    public var body: some View {
        VStack(spacing: MasoonSpacing.lg) {
            Text(MasoonNumerals.elapsedString(elapsed, locale: locale))
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(MasoonColors.textPrimary)
                .accessibilityLabel(Text(locale.studyText("الوقت المنقضي", "Elapsed time")))
                .accessibilityValue(Text(accessibleElapsed))

            Button(action: toggle) {
                HStack(spacing: MasoonSpacing.sm) {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        .accessibilityHidden(true)
                    Text(isRunning ? locale.studyText("إيقاف مؤقت", "Pause") : (elapsed > 0 ? locale.studyText("متابعة", "Resume") : locale.studyText("ابدأ", "Start")))
                }
                .font(.masoon(.headline))
                .foregroundStyle(MasoonColors.onPrimary)
                .frame(minWidth: 160, minHeight: MasoonMetrics.minTarget)
                .background(isRunning ? MasoonColors.primaryEmphasis : MasoonColors.primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isRunning ? locale.studyText("إيقاف المؤقت مؤقتاً", "Pause timer") : locale.studyText("تشغيل المؤقت", "Start timer")))
        }
        .onReceive(ticker) { _ in
            if isRunning { elapsed += 1 }
        }
        .onAppear { syncConnection() }
        .onChange(of: isRunning) { _, _ in syncConnection() }
        .onDisappear {
            tickerConnection?.cancel()
            tickerConnection = nil
        }
    }

    private func syncConnection() {
        if isRunning {
            guard tickerConnection == nil else { return }
            tickerConnection = ticker.connect()
        } else {
            tickerConnection?.cancel()
            tickerConnection = nil
        }
    }

    private func toggle() {
        isRunning.toggle()
        MasoonHaptics.lightImpact()
    }

    private var accessibleElapsed: String {
        let total = Int(elapsed)
        let m = MasoonNumerals.format(total / 60, locale: locale)
        let s = MasoonNumerals.format(total % 60, locale: locale)
        return locale.studyText("\(m) دقيقة و\(s) ثانية", "\(m) minutes \(s) seconds")
    }
}

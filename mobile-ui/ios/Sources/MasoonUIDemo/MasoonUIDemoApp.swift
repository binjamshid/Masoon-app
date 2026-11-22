import MasoonUI
import SwiftUI

@main
struct MasoonUIDemoApp: App {
    var body: some Scene {
        WindowGroup {
            StudyDemoView()
        }
    }
}

struct StudyDemoView: View {
    private enum Panel: Hashable {
        case session, activity
    }

    @State private var arabic = false
    @State private var panel: Panel = .session
    @State private var repetitions = 0
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var showingAttestation = false
    @State private var recordedAttestation = false

    private let repetitionTarget = 5
    private let dailyMinutes = [6, 9, 5, 12, 8, 10, 7]

    private var locale: Locale {
        Locale(identifier: arabic ? "ar@numbers=arab" : "en_US")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MasoonSpacing.lg) {
                    SegmentedFilterBar(
                        options: [
                            .init(Panel.session, title: word("الجلسة", "Session"), icon: "checklist"),
                            .init(Panel.activity, title: word("النشاط", "Activity"), icon: "chart.bar"),
                        ],
                        selection: $panel
                    )

                    switch panel {
                    case .session: session
                    case .activity: activity
                    }
                }
                .frame(maxWidth: 640)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(MasoonColors.background)
            .navigationTitle("Masoon-app")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(arabic ? "English" : "العربية") {
                        arabic.toggle()
                    }
                    .accessibilityLabel(arabic ? "Switch to English" : "التبديل إلى العربية")
                }
            }
            .sheet(isPresented: $showingAttestation) {
                NavigationStack {
                    TasmeeAttestationForm(defaultTime: "09:30") { _ in
                        recordedAttestation = true
                        showingAttestation = false
                    } onCancel: {
                        showingAttestation = false
                    }
                }
            }
        }
        .environment(\.locale, locale)
        .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: MasoonSpacing.lg) {
            SessionCard(
                title: word("جلسة تدريب", "Practice session"),
                subtitle: MasoonNumerals.progressPhrase(
                    count: repetitions,
                    target: repetitionTarget,
                    locale: locale
                ),
                progress: Double(repetitions) / Double(repetitionTarget),
                state: repetitions == repetitionTarget ? .completed : (repetitions == 0 ? .notStarted : .inProgress)
            )

            VStack(spacing: MasoonSpacing.md) {
                TaskRow(
                    kind: .repetition,
                    title: word("تمرين التكرار", "Repetition exercise"),
                    rangeText: word("التمرين أ", "Exercise A"),
                    estMinutes: 5,
                    status: repetitions == repetitionTarget ? .completed : .pending
                )
                CounterControl(count: $repetitions, target: repetitionTarget)
            }
            .padding(.bottom, MasoonSpacing.lg)
            .masoonCard()

            VStack(alignment: .leading, spacing: MasoonSpacing.md) {
                Text(word("وقت التدريب", "Practice time")).masoonType(.headline)
                TimerControl(elapsed: $elapsed, isRunning: $running)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .masoonCard()

            TaskRow(
                kind: .tasmee,
                title: word("تصديق التسميع", "Recitation attestation"),
                rangeText: word("بيانات تجريبية فقط", "Sample data only"),
                status: recordedAttestation ? .completed : .pending
            ) {
                showingAttestation = true
            }
            .masoonCard()
        }
    }

    private var activity: some View {
        let labels = dailyMinutes.indices.map { index in
            let day = MasoonNumerals.format(index + 1, locale: locale)
            return word("اليوم \(day)", "Day \(day)")
        }

        return VStack(alignment: .leading, spacing: MasoonSpacing.lg) {
            MasoonChartCard(
                title: word("دقائق التدريب", "Practice minutes"),
                tableHeader: [word("اليوم", "Day"), word("الدقائق", "Minutes")],
                tableRows: dailyMinutes.indices.map { index in
                    .init(id: String(index), [labels[index], MasoonNumerals.format(dailyMinutes[index], locale: locale)])
                }
            ) {
                MasoonBarChart(
                    data: dailyMinutes.indices.map { index in
                        .init(id: String(index), label: labels[index], value: Double(dailyMinutes[index]))
                    },
                    isRTL: arabic
                )
            }

            VStack(alignment: .leading, spacing: MasoonSpacing.md) {
                Text(word("سجل التدريب التجريبي", "Sample practice history")).masoonType(.headline)
                MasoonHeatmapChart(
                    cells: dailyMinutes.indices.map { index in
                        .init(id: String(index), label: labels[index], intensity: Double(dailyMinutes[index]) / 12)
                    },
                    columns: 7
                )
                TallyRow(count: 7, target: 10, noun: .day)
            }
            .padding()
            .masoonCard()
        }
    }

    private func word(_ arabicText: String, _ englishText: String) -> String {
        arabic ? arabicText : englishText
    }
}

#Preview("Masoon-app study components") {
    StudyDemoView()
}

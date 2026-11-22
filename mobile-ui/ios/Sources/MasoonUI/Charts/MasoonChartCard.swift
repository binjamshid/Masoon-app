// MasoonChartCard.
// Card wrapper around any one chart type (MasoonBarChart/MasoonLineChart/
// MasoonHeatmapChart/MasoonDistributionChart/MasoonSparkline). Deliberate
// compile-time enforcement: `tableHeader`/`tableRows` are NON-OPTIONAL, no
// default of `nil` — no chart can ship through this wrapper without its
// accessible `MasoonDataTable` twin passed in alongside it.

import SwiftUI

public struct MasoonChartCard<Chart: View>: View {
    @Environment(\.locale) private var locale

    private let title: String
    private let subtitle: String?
    private let tableHeader: [String]
    private let tableRows: [MasoonDataTable.Row]
    private let tableCaption: String?
    private let chart: Chart

    @State private var tableExpanded = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// - Parameters:
    ///   - title: chart title, e.g. "Minutes this week".
    ///   - subtitle: optional summary line under the title.
    ///   - tableHeader: the accessible twin's column titles. Required — see
    ///     file header comment.
    ///   - tableRows: the accessible twin's rows, representing the SAME data
    ///     the chart plots. Required — see file header comment.
    ///   - tableCaption: optional caption forwarded to `MasoonDataTable`.
    ///   - chart: the visual chart content (any `MasoonBarChart`/
    ///     `MasoonLineChart`/`MasoonHeatmapChart`/`MasoonDistributionChart`/
    ///     `MasoonSparkline`, or any other view).
    public init(
        title: String,
        subtitle: String? = nil,
        tableHeader: [String],
        tableRows: [MasoonDataTable.Row],
        tableCaption: String? = nil,
        @ViewBuilder chart: () -> Chart
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tableHeader = tableHeader
        self.tableRows = tableRows
        self.tableCaption = tableCaption
        self.chart = chart()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MasoonSpacing.md) {
            VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
                Text(title).masoonType(.headline)
                if let subtitle {
                    Text(subtitle).masoonType(.footnote, color: MasoonColors.textSecondary)
                }
            }

            // The raw chart mark geometry is not meaningfully VoiceOver-
            // navigable (Swift Charts marks have no per-point AX by default
            // for a custom composite like this); MasoonDataTable below is
            // the real accessible surface for this data, so the chart
            // itself is decorative here.
            chart
                .frame(minHeight: ChartTokens.minChartHeight)
                .accessibilityHidden(true)

            tableDisclosure

            // Genuinely reachable by VoiceOver (not just present-but-hidden):
            // rendered whenever `tableVisible` is true, either from the
            // user's toggle or automatically when VoiceOver is running — a
            // VoiceOver user is never required to find/activate the toggle
            // first just to reach data a sighted user gets from the chart
            // directly.
            if tableVisible {
                MasoonDataTable(header: tableHeader, rows: tableRows, caption: tableCaption)
            }
        }
        .padding(MasoonSpacing.lg)
        .masoonCard()
    }

    private var tableVisible: Bool { tableExpanded || voiceOverEnabled }

    private var tableDisclosure: some View {
        Button(action: { tableExpanded.toggle() }) {
            HStack(spacing: MasoonSpacing.xs) {
                Image(systemName: "tablecells")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(tableVisible ? locale.studyText("إخفاء الجدول", "Hide table") : locale.studyText("عرض كجدول", "View as table"))
                    .font(.masoon(.footnote))
                Spacer(minLength: 0)
                // Plain up/down chevron — an expand/collapse affordance, not
                // a navigational one, so it does NOT use DirectionalChevron
                // (which flips forward/back with RTL). Vertical rotation is
                // direction-neutral.
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(tableVisible ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(MasoonColors.primary)
            .frame(minHeight: MasoonMetrics.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hidden from VoiceOver once the table is forced-visible by
        // VoiceOver itself — toggling it further would just re-hide data
        // the user already reached, with no sighted-only benefit.
        .accessibilityHidden(voiceOverEnabled)
    }
}

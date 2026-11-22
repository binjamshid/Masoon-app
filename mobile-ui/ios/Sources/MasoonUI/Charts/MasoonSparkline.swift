// MasoonSparkline.
// A tiny inline trend line (no axes, no legend) — sits next to a number,
// e.g. a points total or a weekly-pace summary. See MasoonBarChart.swift's
// header comment for the RTL mechanism shared by all four Swift-Charts-based
// components.

import SwiftUI
import Charts

public struct MasoonSparkline: View {
    @Environment(\.locale) private var locale

    private let values: [Double]
    private let isRTL: Bool
    private let tint: Color

    public init(values: [Double], isRTL: Bool, tint: Color = MasoonColors.primary) {
        self.values = values
        self.isRTL = isRTL
        self.tint = tint
    }

    static func plottedOrder(_ values: [Double], isRTL: Bool) -> [Double] {
        isRTL ? values.reversed() : values
    }

    public var body: some View {
        let ordered = Array(Self.plottedOrder(values, isRTL: isRTL).enumerated())
        Chart(ordered, id: \.offset) { index, value in
            LineMark(
                x: .value(locale.studyText("الترتيب", "Order"), index),
                y: .value(locale.studyText("القيمة", "Value"), value)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: ChartTokens.sparklineHeight)
        // Decorative by default: a sparkline's meaning is normally already
        // conveyed by an adjacent number/label (e.g. PointsSummaryRow); a
        // caller with genuinely standalone sparkline content should pair it
        // with its own MasoonDataTable/label rather than rely on this mark.
        .accessibilityHidden(true)
    }
}

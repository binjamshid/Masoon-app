// MasoonLineChart.
// Trend chart over Swift Charts. See MasoonBarChart.swift's header comment
// for the RTL mechanism shared by all four Swift-Charts-based components.

import SwiftUI
import Charts

public struct MasoonLineChart: View {
    @Environment(\.locale) private var locale


    public struct DataPoint: Identifiable {
        public let id: String
        /// Pre-formatted x-axis label, e.g. a date string.
        public let label: String
        public let value: Double
        /// `MasoonSeriesPalette` slot index for this line's color.
        public let seriesIndex: Int

        public init(id: String = UUID().uuidString, label: String, value: Double, seriesIndex: Int = 0) {
            self.id = id
            self.label = label
            self.value = value
            self.seriesIndex = seriesIndex
        }
    }

    private let data: [DataPoint]
    private let isRTL: Bool

    public init(data: [DataPoint], isRTL: Bool) {
        self.data = data
        self.isRTL = isRTL
    }

    static func plottedOrder(_ data: [DataPoint], isRTL: Bool) -> [DataPoint] {
        isRTL ? data.reversed() : data
    }

    public var body: some View {
        Chart(Self.plottedOrder(data, isRTL: isRTL)) { point in
            LineMark(
                x: .value(locale.studyText("المحور", "X"), point.label),
                y: .value(locale.studyText("القيمة", "Value"), point.value)
            )
            .foregroundStyle(MasoonSeriesPalette.color(at: point.seriesIndex))
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            PointMark(
                x: .value(locale.studyText("المحور", "X"), point.label),
                y: .value(locale.studyText("القيمة", "Value"), point.value)
            )
            .foregroundStyle(MasoonSeriesPalette.color(at: point.seriesIndex))
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

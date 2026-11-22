// The explicit series order determines RTL rendering. The plot stays LTR to avoid double mirroring.

import SwiftUI
import Charts

public struct MasoonBarChart: View {
    @Environment(\.locale) private var locale


    public struct DataPoint: Identifiable {
        public let id: String
        /// Pre-formatted category label, e.g. a day name.
        public let label: String
        public let value: Double
        /// `MasoonSeriesPalette` slot index for this bar's color.
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

    /// Reading-direction-correct plotting order. Pure/testable in isolation
    /// from Swift Charts itself.
    static func plottedOrder(_ data: [DataPoint], isRTL: Bool) -> [DataPoint] {
        isRTL ? data.reversed() : data
    }

    public var body: some View {
        Chart(Self.plottedOrder(data, isRTL: isRTL)) { point in
            BarMark(
                x: .value(locale.studyText("الفئة", "Category"), point.label),
                y: .value(locale.studyText("القيمة", "Value"), point.value)
            )
            .foregroundStyle(MasoonSeriesPalette.color(at: point.seriesIndex))
            .cornerRadius(MasoonRadius.sm)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

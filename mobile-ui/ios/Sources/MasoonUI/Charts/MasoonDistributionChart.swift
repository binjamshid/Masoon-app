// MasoonDistributionChart.
// A bucketed distribution (e.g. how many completions fall in each quality/
// duration band) rendered as a Swift Charts bar histogram. See
// MasoonBarChart.swift's header comment for the RTL mechanism shared by all
// four Swift-Charts-based components.

import SwiftUI
import Charts

public struct MasoonDistributionChart: View {
    @Environment(\.locale) private var locale


    public struct Bucket: Identifiable {
        public let id: String
        /// Pre-formatted bucket label, e.g. "٠–٢٠٪".
        public let label: String
        public let count: Int

        public init(id: String = UUID().uuidString, label: String, count: Int) {
            self.id = id
            self.label = label
            self.count = count
        }
    }

    private let buckets: [Bucket]
    private let isRTL: Bool

    public init(buckets: [Bucket], isRTL: Bool) {
        self.buckets = buckets
        self.isRTL = isRTL
    }

    static func plottedOrder(_ buckets: [Bucket], isRTL: Bool) -> [Bucket] {
        isRTL ? buckets.reversed() : buckets
    }

    public var body: some View {
        Chart(Self.plottedOrder(buckets, isRTL: isRTL)) { bucket in
            BarMark(
                x: .value(locale.studyText("الفئة", "Bucket"), bucket.label),
                y: .value(locale.studyText("العدد", "Count"), bucket.count)
            )
            .foregroundStyle(MasoonSeriesPalette.color(at: 0))
            .cornerRadius(MasoonRadius.sm)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

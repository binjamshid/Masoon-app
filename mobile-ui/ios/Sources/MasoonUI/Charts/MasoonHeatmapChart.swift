// Cells stay in chronological order. SwiftUI mirrors the grid using the layout direction.

import SwiftUI

public struct MasoonHeatmapChart: View {
    @Environment(\.locale) private var locale


    public struct Cell: Identifiable {
        public let id: String
        /// Accessible label, e.g. a date — read by VoiceOver per cell.
        public let label: String
        /// 0…1 fill intensity (clamped).
        public let intensity: Double

        public init(id: String = UUID().uuidString, label: String, intensity: Double) {
            self.id = id
            self.label = label
            self.intensity = min(max(intensity, 0), 1)
        }
    }

    private let cells: [Cell]
    private let columns: Int
    private let tint: Color

    public init(cells: [Cell], columns: Int, tint: Color = MasoonColors.primary) {
        self.cells = cells
        self.columns = max(1, columns)
        self.tint = tint
    }

    public var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: MasoonSpacing.xs), count: columns),
            spacing: MasoonSpacing.xs
        ) {
            ForEach(cells) { cell in
                RoundedRectangle(cornerRadius: MasoonRadius.sm, style: .continuous)
                    .fill(tint.opacity(0.12 + cell.intensity * 0.78))
                    .frame(minWidth: ChartTokens.heatmapCellSize, minHeight: ChartTokens.heatmapCellSize)
                    .accessibilityLabel(Text(cell.label))
                    .accessibilityValue(Text(intensityDescription(cell.intensity)))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func intensityDescription(_ intensity: Double) -> String {
        return MasoonNumerals.percent(intensity, locale: locale)
    }
}

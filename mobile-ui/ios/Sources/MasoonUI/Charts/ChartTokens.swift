import SwiftUI

/// Cyclic chart series colors based on the standard system colors.
public enum MasoonSeriesPalette {
    private static let slots: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo]

    public static func color(at index: Int) -> Color {
        slots[normalizedIndex(index)]
    }

    static func normalizedIndex(_ index: Int) -> Int {
        ((index % slots.count) + slots.count) % slots.count
    }

    public static func color(for kind: TaskRowKind) -> Color {
        color(at: slotIndex(for: kind))
    }

    static func slotIndex(for kind: TaskRowKind) -> Int {
        switch kind {
        case .newHifz: return 0
        case .murajaah, .warmup: return 1
        case .tasmee: return 2
        case .repetition: return 3
        case .preparation, .review: return 4
        case .listening: return 5
        }
    }
}

// MARK: - ChartTokens

/// Layout constants shared by the `Charts/` component family. No new colors
/// or spacing scale — reuses `MasoonSpacing`/`MasoonRadius` throughout;
/// these are the handful of chart-specific numbers (plot height, heatmap
/// cell size) that don't belong in the general-purpose token set.
public enum ChartTokens {
    /// Minimum plot height for `MasoonBarChart`/`MasoonLineChart`/
    /// `MasoonDistributionChart` inside `MasoonChartCard`.
    public static let minChartHeight: CGFloat = 180
    /// Heatmap cell edge length (square cells).
    public static let heatmapCellSize: CGFloat = 28
    /// Sparkline default height — small enough to sit inline next to a
    /// number, per `MasoonSparkline`'s "tiny inline trend" role.
    public static let sparklineHeight: CGFloat = 32
}

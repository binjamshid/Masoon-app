// Accessible tabular representation of caller-formatted data.

import SwiftUI

public struct MasoonDataTable: View {

    /// One data row. `values.count` should match the header's column count;
    /// mismatched rows still render (extra/missing cells just misalign
    /// visually) rather than crash, since a malformed row is a caller bug,
    /// not a reason to blank the whole table.
    public struct Row: Identifiable {
        public let id: String
        public let values: [String]

        public init(id: String = UUID().uuidString, _ values: [String]) {
            self.id = id
            self.values = values
        }
    }

    /// Visual density. `DenseDataTable` always passes `.compact`.
    public enum Density {
        case regular, compact
    }

    private let header: [String]
    private let rows: [Row]
    private let caption: String?
    private let density: Density
    private let rowAction: ((Row) -> Void)?

    /// - Parameters:
    ///   - header: column titles, already localized/formatted by the caller.
    ///   - rows: data rows, already formatted (e.g. via `MasoonNumerals`).
    ///   - caption: optional table title/summary, read first by VoiceOver.
    ///   - density: `.regular` (default) or `.compact` (tighter padding,
    ///     smaller type — still ≥44pt actionable-row targets when `rowAction`
    ///     is supplied).
    ///   - rowAction: if supplied, each row becomes an accessible button
    ///     (e.g. a roster row drilling into a member's detail). `nil` (the
    ///     chart-twin default) renders a plain, non-interactive table.
    public init(
        header: [String],
        rows: [Row],
        caption: String? = nil,
        density: Density = .regular,
        rowAction: ((Row) -> Void)? = nil
    ) {
        precondition(!header.isEmpty, "MasoonDataTable requires at least one header column")
        self.header = header
        self.rows = rows
        self.caption = caption
        self.density = density
        self.rowAction = rowAction
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let caption {
                    Text(caption)
                        .masoonType(.footnote, color: MasoonColors.textSecondary)
                        .padding(.horizontal, MasoonSpacing.sm)
                        .padding(.bottom, MasoonSpacing.xs)
                }
                headerRow
                Divider()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headerRow: some View {
        HStack(spacing: MasoonSpacing.md) {
            ForEach(Array(header.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .masoonType(.footnote, color: MasoonColors.textSecondary)
                    .fontWeight(.semibold)
                    .frame(minWidth: columnMinWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, MasoonSpacing.sm)
        .padding(.vertical, MasoonSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: Row) -> some View {
        Group {
            if let rowAction {
                Button(action: { rowAction(row) }) { rowContent(row) }
                    .buttonStyle(.plain)
            } else {
                rowContent(row)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibleRowLabel(row)))
        .accessibilityAddTraits(rowAction != nil ? .isButton : [])
    }

    private func rowContent(_ row: Row) -> some View {
        HStack(spacing: MasoonSpacing.md) {
            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .masoonType(density == .compact ? .caption : .subheadline)
                    .frame(minWidth: columnMinWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, MasoonSpacing.sm)
        .padding(.vertical, density == .compact ? MasoonSpacing.xs : MasoonSpacing.sm)
        // Visually tighter in .compact, but the tap target never shrinks
        // below the 44pt release gate when the row is actionable.
        .frame(minHeight: rowAction != nil ? MasoonMetrics.minTarget : nil, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var columnMinWidth: CGFloat { density == .compact ? 64 : 88 }

    /// "Header₁: value₁, Header₂: value₂, …" — one VoiceOver stop per row,
    /// pairing every value with its column so the row reads coherently
    /// without requiring sighted column-scanning.
    func accessibleRowLabel(_ row: Row) -> String {
        zip(header, row.values)
            .map { "\($0): \($1)" }
            .joined(separator: ", ")
    }
}

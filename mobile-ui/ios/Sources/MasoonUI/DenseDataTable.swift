// Compact layout for the same accessible table used by the chart card.

import SwiftUI

public struct DenseDataTable: View {
    private let header: [String]
    private let rows: [MasoonDataTable.Row]
    private let caption: String?
    private let rowAction: ((MasoonDataTable.Row) -> Void)?

    public init(
        header: [String],
        rows: [MasoonDataTable.Row],
        caption: String? = nil,
        rowAction: ((MasoonDataTable.Row) -> Void)? = nil
    ) {
        self.header = header
        self.rows = rows
        self.caption = caption
        self.rowAction = rowAction
    }

    public var body: some View {
        MasoonDataTable(header: header, rows: rows, caption: caption, density: .compact, rowAction: rowAction)
    }
}

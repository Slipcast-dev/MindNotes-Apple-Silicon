import SwiftUI

/// Reading view for CSV/TSV: a grid whose first row is the header. Row `i` is line `i` of the file.
struct CSVTableView: View {
    let table: CSVTable
    let size: CGFloat
    let highlight: SearchHighlight?
    let isScrollTarget: Bool

    @EnvironmentObject private var state: AppState
    @Environment(\.theme) private var theme

    private var charWidth: CGFloat { size * 0.62 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        rowView(row, index: index)
                            .id(index)
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
            .onChange(of: state.scrollTarget) { target in
                guard isScrollTarget, let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target.unit, anchor: .center) }
            }
        }
    }

    private func rowView(_ row: CSVTable.Row, index: Int) -> some View {
        let isHeader = index == 0
        let hits = lineHits(row)
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(table.widths.enumerated()), id: \.offset) { col, width in
                let text = col < row.cells.count ? row.cells[col] : ""
                let offset = col < row.starts.count ? hits.filter { $0 <= row.starts[col] }.count : 0
                Text(AttributedString(text.isEmpty ? " " : text)
                        .highlighted(highlight, unit: index, offset: offset, theme: theme))
                    .font(.system(size: size, weight: isHeader ? .semibold : .regular))
                    .foregroundColor(isHeader ? theme.heading : theme.text)
                    .lineLimit(2)
                    .frame(width: CGFloat(width) * charWidth + 8, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
        .background(isHeader ? theme.codeBackground : (index % 2 == 0 ? theme.codeBackground.opacity(0.35) : Color.clear))
        .overlay(alignment: .bottom) {
            if isHeader { Rectangle().fill(theme.rule).frame(height: 1) }
        }
    }

    /// Character offsets (in the original line) where each hit ends; used to number hits per cell.
    private func lineHits(_ row: CSVTable.Row) -> [Int] {
        guard let q = highlight?.query, !q.isEmpty else { return [] }
        return Searcher.ranges(of: q, in: row.line).map { row.line.distance(from: row.line.startIndex, to: $0.upperBound) }
    }
}

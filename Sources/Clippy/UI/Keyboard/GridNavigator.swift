import Foundation

/// Pure 2D keyboard navigation over a row-major grid of clips (KEY-03).
///
/// The list is a flat array laid out left-to-right in `columns` columns. Date
/// sections each start on a fresh row, so `sectionLengths` partitions the flat
/// index space; the last row of every section may be ragged (shorter than
/// `columns`). All moves clamp at the edges and never leave the index range.
struct GridNavigator: Equatable {
    /// A navigation key.
    enum Move: Equatable {
        case up, down, left, right, home, end, pageUp, pageDown
    }

    /// Result of a move: the new flat index plus the column to remember for
    /// consecutive vertical moves (so a trip through a short row does not lose
    /// the user's column).
    struct Target: Equatable {
        var index: Int
        var column: Int
    }

    private struct Row: Equatable {
        var start: Int
        var length: Int
    }

    /// Effective column count (always at least 1).
    let columns: Int
    /// Rows moved by Page Up / Page Down (always at least 1).
    let pageRows: Int
    /// Total number of items.
    let count: Int
    private let rows: [Row]

    /// - Parameters:
    ///   - columns: real column count of the grid (clamped to at least 1).
    ///   - sectionLengths: item count per section, in order. Empty sections are ignored.
    ///   - pageRows: rows per Page Up / Page Down (clamped to at least 1).
    init(columns: Int, sectionLengths: [Int], pageRows: Int = 4) {
        let cols = max(1, columns)
        self.columns = cols
        self.pageRows = max(1, pageRows)
        var built: [Row] = []
        var start = 0
        for length in sectionLengths where length > 0 {
            var offset = 0
            while offset < length {
                let rowLength = min(cols, length - offset)
                built.append(Row(start: start + offset, length: rowLength))
                offset += rowLength
            }
            start += length
        }
        rows = built
        count = start
    }

    /// Single-section convenience.
    init(columns: Int, count: Int, pageRows: Int = 4) {
        self.init(columns: columns, sectionLengths: [max(0, count)], pageRows: pageRows)
    }

    /// Number of laid-out rows across all sections.
    var rowCount: Int { rows.count }

    /// Row and column of `index` (clamped into range), or nil for an empty grid.
    func location(of index: Int) -> (row: Int, column: Int)? {
        guard count > 0 else { return nil }
        let clamped = max(0, min(count - 1, index))
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rows[mid].start <= clamped { low = mid } else { high = mid - 1 }
        }
        return (low, clamped - rows[low].start)
    }

    /// Where `move` lands from `index`. `stickyColumn` is the column remembered
    /// from a previous vertical move; horizontal moves and Home/End ignore it and
    /// reset the returned column to the landing cell's real column.
    func target(from index: Int, move: Move, stickyColumn: Int? = nil) -> Target {
        guard let here = location(of: index) else { return Target(index: 0, column: 0) }
        let current = max(0, min(count - 1, index))
        switch move {
        case .left: return landing(max(0, current - 1))
        case .right: return landing(min(count - 1, current + 1))
        case .home: return landing(0)
        case .end: return landing(count - 1)
        case .up: return vertical(from: here, by: -1, sticky: stickyColumn)
        case .down: return vertical(from: here, by: 1, sticky: stickyColumn)
        case .pageUp: return vertical(from: here, by: -pageRows, sticky: stickyColumn)
        case .pageDown: return vertical(from: here, by: pageRows, sticky: stickyColumn)
        }
    }

    /// Index-only convenience.
    func index(from index: Int, move: Move) -> Int {
        target(from: index, move: move).index
    }

    private func landing(_ index: Int) -> Target {
        Target(index: index, column: location(of: index)?.column ?? 0)
    }

    private func vertical(from here: (row: Int, column: Int), by delta: Int, sticky: Int?) -> Target {
        let column = sticky ?? here.column
        let row = max(0, min(rows.count - 1, here.row + delta))
        let target = rows[row]
        return Target(index: target.start + min(column, target.length - 1), column: column)
    }
}

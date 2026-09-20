import Foundation
import CoreGraphics

/// Unified layout metrics shared by the root Launchpad grid and expanded
/// folder content. The arrangement mirrors the classic (macOS 10.7–15)
/// Launchpad: a stable icon size, fixed cell bounds and fixed inter-cell
/// spacing, with the whole grid centered rather than stretched across the
/// screen. Wide screens add side margins (and at most a bounded number of
/// extra columns) instead of growing the gaps between icons.
struct LaunchpadLayoutMetrics: Equatable, Sendable {
    static let minimumIconSize = 60.0
    static let maximumIconSize = 112.0
    static let defaultIconSize = 92.0

    static let iconLabelPadding = 7.0
    static let labelHeight = 20.0
    static let labelFontSize = 13.0

    static let maximumColumns = 12
    static let maximumRows = 5
    static let folderMaximumRows = 3

    static let minimumSideMargin = 40.0
    static let maximumSideMargin = 140.0
    static let maximumGridWidth = 1760.0
    static let minimumTopInset = 16.0
    static let bottomReserve = 64.0

    let iconSize: Double
    let cellWidth: Double
    let cellHeight: Double
    let horizontalSpacing: Double
    let verticalSpacing: Double
    let columns: Int
    let rows: Int
    let gridWidth: Double
    let gridHeight: Double
    let topInset: Double

    var capacity: Int { columns * rows }
    var columnStride: Double { cellWidth + horizontalSpacing }
    var rowStride: Double { cellHeight + verticalSpacing }
    var sideDropWidth: Double { max(0, (cellWidth - iconSize) / 2) }

    static func clampedIconSize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, minimumIconSize), maximumIconSize) : defaultIconSize
    }

    static func cellWidth(forIconSize iconSize: Double) -> Double { iconSize + 48 }
    static func cellHeight(forIconSize iconSize: Double) -> Double {
        iconSize + iconLabelPadding + labelHeight
    }
    static func horizontalSpacing(forIconSize iconSize: Double) -> Double {
        max(16, iconSize * 0.24)
    }
    static func verticalSpacing(forIconSize iconSize: Double) -> Double {
        max(12, iconSize * 0.20)
    }

    static func sideMargin(forContainerWidth containerWidth: Double) -> Double {
        min(max(containerWidth * 0.035, minimumSideMargin), maximumSideMargin)
    }

    /// The width the grid is allowed to occupy. Beyond this bound, extra
    /// screen width becomes side margin instead of wider icon spacing.
    static func usableGridWidth(containerWidth: Double) -> Double {
        let sideMargin = sideMargin(forContainerWidth: containerWidth)
        return min(
            max(cellWidth(forIconSize: defaultIconSize), containerWidth - sideMargin * 2),
            maximumGridWidth
        )
    }

    nonisolated static func calculate(
        containerWidth: Double,
        containerHeight: Double,
        preferredIconSize: Double
    ) -> LaunchpadLayoutMetrics {
        let safeWidth = containerWidth.isFinite ? min(max(containerWidth, 1), 100_000) : 1_440
        let safeHeight = containerHeight.isFinite ? min(max(containerHeight, 1), 100_000) : 760
        let iconSize = clampedIconSize(preferredIconSize)
        let horizontalSpacing = horizontalSpacing(forIconSize: iconSize)
        let verticalSpacing = verticalSpacing(forIconSize: iconSize)
        let usableWidth = usableGridWidth(containerWidth: safeWidth)
        let columnStride = cellWidth(forIconSize: iconSize) + horizontalSpacing
        let possibleColumns = Int((usableWidth + horizontalSpacing) / columnStride)
        let columns = min(max(1, possibleColumns), maximumColumns)

        let availableHeight = max(
            cellHeight(forIconSize: iconSize),
            safeHeight - minimumTopInset - bottomReserve
        )
        let rowStride = cellHeight(forIconSize: iconSize) + verticalSpacing
        let possibleRows = Int((availableHeight + verticalSpacing) / rowStride)
        let rows = min(max(1, possibleRows), maximumRows)

        return makeMetrics(
            iconSize: iconSize,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            columns: columns,
            rows: rows,
            containerHeight: safeHeight,
            centersVertically: true
        )
    }

    /// Folder content keeps the exact icon size, cell size and spacing of the
    /// root grid; only the column/row counts adapt to the item count so a
    /// sparse folder stays centered at a natural size instead of stretching.
    nonisolated static func folderContent(
        base: LaunchpadLayoutMetrics,
        itemCount: Int,
        rowLimit: Int
    ) -> LaunchpadLayoutMetrics {
        let safeCount = min(max(0, itemCount), 1_000_000)
        let columns = min(
            base.columns,
            safeCount <= 2 ? max(1, safeCount) : max(3, Int(ceil(Double(safeCount) / 3)))
        )
        let requiredRows = Int(ceil(Double(max(1, safeCount)) / Double(columns)))
        let rows = min(max(1, rowLimit), max(1, requiredRows))
        return makeMetrics(
            iconSize: base.iconSize,
            horizontalSpacing: base.horizontalSpacing,
            verticalSpacing: base.verticalSpacing,
            columns: columns,
            rows: rows,
            containerHeight: 0,
            centersVertically: false
        )
    }

    nonisolated private static func makeMetrics(
        iconSize: Double,
        horizontalSpacing: Double,
        verticalSpacing: Double,
        columns: Int,
        rows: Int,
        containerHeight: Double,
        centersVertically: Bool
    ) -> LaunchpadLayoutMetrics {
        let cellWidth = cellWidth(forIconSize: iconSize)
        let cellHeight = cellHeight(forIconSize: iconSize)
        let safeColumns = max(1, columns)
        let safeRows = max(1, rows)
        let gridWidth = Double(safeColumns) * cellWidth
            + Double(safeColumns - 1) * horizontalSpacing
        let gridHeight = Double(safeRows) * cellHeight
            + Double(safeRows - 1) * verticalSpacing
        let topInset = centersVertically
            ? max(minimumTopInset, (containerHeight - bottomReserve - gridHeight) / 2)
            : 0
        return LaunchpadLayoutMetrics(
            iconSize: iconSize,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            columns: safeColumns,
            rows: safeRows,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            topInset: topInset
        )
    }

    /// Number of grid rows that fit inside the given height.
    func rowsFitting(availableHeight: Double) -> Int {
        max(1, Int((max(0, availableHeight) + verticalSpacing) / rowStride))
    }

    func pageCount(forItemCount itemCount: Int) -> Int {
        max(1, Int(ceil(Double(max(0, itemCount)) / Double(capacity))))
    }
}

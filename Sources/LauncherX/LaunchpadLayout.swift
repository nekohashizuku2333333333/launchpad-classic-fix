import Foundation
import CoreGraphics

/// Place the reference top margin below any camera housing on this display.
/// Wallpaper still fills the physical screen; content and pointer
/// coordinates share this one additional inset.
struct LaunchpadVerticalMetrics: Equatable, Sendable {
    static let referenceSearchTopPadding = 25.0
    static let searchFieldHeight = 25.0
    static let referencePagerTopOffset = referenceSearchTopPadding + searchFieldHeight

    let topSafeAreaInset: Double

    init(topSafeAreaInset: Double = 0) {
        self.topSafeAreaInset = topSafeAreaInset.isFinite
            ? min(max(0, topSafeAreaInset), 1_000) : 0
    }

    var searchTopPadding: Double { Self.referenceSearchTopPadding + topSafeAreaInset }
    var pagerTopOffset: Double { Self.referencePagerTopOffset + topSafeAreaInset }
}

/// Geometry calibrated against a 2880 × 1800 Sequoia screenshot (@2x).
/// At 1440 × 900 points the seven column centres are 180 points apart;
/// rows are 138 points apart. Large screens keep seven columns, while
/// unusually small windows reduce capacity to keep labels and icons apart.
struct LaunchpadLayoutMetrics: Equatable, Sendable {
    static let minimumIconSize = 60.0
    static let maximumIconSize = 112.0
    static let defaultIconSize = 90.0

    static let iconLabelPadding = 2.0
    static let labelHeight = 20.0
    static let labelFontSize = 13.0

    static let maximumColumns = 7
    static let maximumRows = 5
    static let folderMaximumRows = 5

    static let minimumSideMargin = 40.0
    static let maximumSideMargin = 140.0
    static let maximumGridWidth = 3200.0
    static let minimumTopInset = 16.0
    static let bottomReserve = 120.0

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
        preferredIconSize: Double,
        topSafeAreaInset: Double = 0
    ) -> LaunchpadLayoutMetrics {
        let width = containerWidth.isFinite ? min(max(containerWidth, 1), 100_000) : 1_440
        let height = containerHeight.isFinite ? min(max(containerHeight, 1), 100_000) : 850
        let iconSize = clampedIconSize(preferredIconSize)
        let cellWidth = cellWidth(forIconSize: iconSize)
        let cellHeight = cellHeight(forIconSize: iconSize)
        let layoutWidth = min(width, 3_600)
        var columns = maximumColumns
        while columns > 1, layoutWidth / Double(columns + 1) < cellWidth + 12 { columns -= 1 }
        let horizontalSpacing = max(12, layoutWidth / Double(columns + 1) - cellWidth)
        let vertical = LaunchpadVerticalMetrics(topSafeAreaInset: topSafeAreaInset)
        // Keep the row spacing when moving content below the camera housing.
        // Capacity uses the smaller pager height, preserving the Dock reserve.
        let screenHeight = height + vertical.pagerTopOffset
        let topInset = max(12, min(72, screenHeight * 0.08) - LaunchpadVerticalMetrics.referencePagerTopOffset)
        let desiredStride = min(180, screenHeight * (138.0 / 900.0))
        let verticalSpacing = max(12, desiredStride - cellHeight)
        let availableHeight = max(cellHeight, height - topInset - bottomReserve)
        let rows = min(maximumRows, max(1, Int((availableHeight + verticalSpacing) / (cellHeight + verticalSpacing))))
        return makeMetrics(
            iconSize: iconSize, horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing, columns: columns, rows: rows,
            topInset: topInset
        )
    }

    /// Folder columns keep their root positions, including sparse last rows.
    /// The panel grows by whole rows and pages after five rows.
    nonisolated static func folderContent(
        base: LaunchpadLayoutMetrics,
        itemCount: Int,
        rowLimit: Int
    ) -> LaunchpadLayoutMetrics {
        let count = min(max(1, itemCount), 1_000_000)
        let rows = min(max(1, rowLimit), folderMaximumRows, Int(ceil(Double(count) / Double(base.columns))))
        return makeMetrics(
            iconSize: base.iconSize, horizontalSpacing: base.horizontalSpacing,
            verticalSpacing: base.verticalSpacing, columns: base.columns,
            rows: max(1, rows), topInset: 0
        )
    }

    nonisolated private static func makeMetrics(
        iconSize: Double,
        horizontalSpacing: Double,
        verticalSpacing: Double,
        columns: Int,
        rows: Int,
        topInset: Double
    ) -> LaunchpadLayoutMetrics {
        let cellWidth = cellWidth(forIconSize: iconSize)
        let cellHeight = cellHeight(forIconSize: iconSize)
        let columns = max(1, columns)
        let rows = max(1, rows)
        return LaunchpadLayoutMetrics(
            iconSize: iconSize, cellWidth: cellWidth, cellHeight: cellHeight,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            columns: columns, rows: rows,
            gridWidth: Double(columns) * cellWidth + Double(columns - 1) * horizontalSpacing,
            gridHeight: Double(rows) * cellHeight + Double(rows - 1) * verticalSpacing,
            topInset: topInset
        )
    }

    /// Insertion boundary under the pointer, shared by hover and release.
    /// Empty rows naturally clamp to the end of the page in the model.
    func insertionSlot(at point: CGPoint, containerWidth: Double) -> Int {
        guard point.x.isFinite, point.y.isFinite, containerWidth.isFinite else { return 0 }
        let x = point.x - (containerWidth - gridWidth) / 2
        let y = point.y - topInset
        let column = Int(min(max(0, x / columnStride), Double(columns - 1)))
        let row = Int(min(max(0, y / rowStride), Double(rows - 1)))
        let rightHalf = x - Double(column) * columnStride >= cellWidth / 2
        return min(row * columns + column + (rightHalf ? 1 : 0), capacity)
    }

    /// Number of grid rows that fit inside the given height.
    func rowsFitting(availableHeight: Double) -> Int {
        max(1, Int((max(0, availableHeight) + verticalSpacing) / rowStride))
    }

    func pageCount(forItemCount itemCount: Int) -> Int {
        max(1, Int(ceil(Double(max(0, itemCount)) / Double(capacity))))
    }
}

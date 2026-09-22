import Foundation
import CoreGraphics

private struct DisplaySafeAreaTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum DisplaySafeAreaTests {
    static func run() throws -> Int {
        try rectangularDisplayKeepsSequoiaReferenceGeometry()
        try cameraHousingMovesContentWithoutCompressingTheGrid()
        try shorterDisplaysReduceCapacityBeforeReachingTheDock()
        try dragHoverUsesTheSameInsetAsTheVisibleDropSlots()
        try invalidSafeAreaValuesPreserveUsableGeometry()
        return 5
    }

    private static func rectangularDisplayKeepsSequoiaReferenceGeometry() throws {
        let vertical = LaunchpadVerticalMetrics()
        let grid = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_440, containerHeight: 900 - vertical.pagerTopOffset,
            preferredIconSize: 90
        )
        try require(close(vertical.searchTopPadding, 25), "The unnotched Sequoia search position changed")
        try require(close(vertical.pagerTopOffset + grid.topInset, 72), "The unnotched Sequoia first row moved")
        try require(grid.columns == 7 && grid.rows == 5, "The unnotched 1440 × 900 reference lost its 7 × 5 grid")
        try require(close(grid.columnStride, 180) && close(grid.rowStride, 138), "Reference icon centres no longer match the measured Sequoia screenshot")
        try require(vertical.pagerTopOffset + grid.topInset + grid.gridHeight <= 780, "The reference grid entered the bottom Dock reserve")
    }

    private static func cameraHousingMovesContentWithoutCompressingTheGrid() throws {
        for (width, height) in [(1_800.0, 1_169.0), (1_512.0, 982.0)] {
            let vertical = LaunchpadVerticalMetrics(topSafeAreaInset: 38)
            let grid = LaunchpadLayoutMetrics.calculate(
                containerWidth: width, containerHeight: height - vertical.pagerTopOffset,
                preferredIconSize: 112, topSafeAreaInset: 38
            )
            let rectangular = LaunchpadLayoutMetrics.calculate(
                containerWidth: width, containerHeight: height - 50,
                preferredIconSize: 112
            )
            let searchBottom = vertical.searchTopPadding + LaunchpadVerticalMetrics.searchFieldHeight
            let gridTop = vertical.pagerTopOffset + grid.topInset
            let gridBottom = gridTop + grid.gridHeight
            try require(close(vertical.searchTopPadding, 63) && close(gridTop, 110), "The camera housing inset did not move search and the first icon row below the unsafe top area")
            try require(vertical.searchTopPadding >= 38 && searchBottom <= gridTop, "The search field overlaps the camera housing or the app grid")
            try require(gridBottom <= height - 120, "A notched display's last icon row entered the Dock reserve")
            try require(grid.rows == 5 && grid.columns == 7, "A full-size notched display unnecessarily lost a row or column")
            try require(grid.cellHeight < grid.rowStride, "App labels overlap the next row on a notched display")
            try require(
                close(grid.gridWidth, rectangular.gridWidth)
                    && close(grid.columnStride, rectangular.columnStride)
                    && close(grid.rowStride, rectangular.rowStride)
                    && close(grid.iconSize, rectangular.iconSize),
                "Moving below the camera housing squeezed the horizontal grid, icons, or row spacing"
            )
        }
    }

    private static func shorterDisplaysReduceCapacityBeforeReachingTheDock() throws {
        let height = 920.0
        let vertical = LaunchpadVerticalMetrics(topSafeAreaInset: 38)
        let rectangular = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_512, containerHeight: height - 50, preferredIconSize: 112
        )
        let insetGrid = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_512, containerHeight: height - vertical.pagerTopOffset,
            preferredIconSize: 112, topSafeAreaInset: 38
        )
        try require(rectangular.rows == 5 && insetGrid.rows == 4, "A shorter display did not remove the row that would overlap the Dock after applying its top inset")
        try require(insetGrid.columns == rectangular.columns && close(insetGrid.rowStride, rectangular.rowStride), "Reducing capacity changed the established column positions or row spacing")
        try require(vertical.pagerTopOffset + insetGrid.topInset + insetGrid.gridHeight <= height - 120, "Reducing the row count still left icons inside the Dock reserve")
        try require(insetGrid.pageCount(forItemCount: 35) == 2, "Apps in the displaced bottom row were not assigned a second page")
    }

    private static func dragHoverUsesTheSameInsetAsTheVisibleDropSlots() throws {
        let domain = "jp.local.launchpadclassic.safe-area-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw DisplaySafeAreaTestFailure(description: "Could not create isolated defaults for pointer-coordinate tests")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = LauncherModel(defaults: defaults, autoScan: false)
        defer { model.clearReorderDragState(); model.shutdown() }
        let apps = (0..<35).map { index in
            AppItem(url: URL(fileURLWithPath: "/Applications/Safe Area Fixture \(index).app"))
        }
        model.apps = apps
        model.rootOrder = apps.map(\.id)
        let vertical = LaunchpadVerticalMetrics(topSafeAreaInset: 38)
        let width = 1_512.0
        let pagerHeight = 982 - vertical.pagerTopOffset
        let grid = LaunchpadLayoutMetrics.calculate(
            containerWidth: width, containerHeight: pagerHeight,
            preferredIconSize: 112, topSafeAreaInset: 38
        )
        model.updateRootPagerLayout(
            topOffset: vertical.pagerTopOffset,
            size: CGSize(width: width, height: pagerHeight),
            metrics: grid, pageSize: grid.capacity
        )
        model.startReorderDrag(apps[0].id)
        let gridLeft = (width - grid.gridWidth) / 2
        // The points sit just before row boundaries. Forgetting the extra
        // header inset would incorrectly preview insertion on the next row.
        for (row, column, rightSide) in [(0, 2, false), (0, 2, true), (1, 4, false), (3, 1, true)] {
            let pagerPoint = CGPoint(
                x: gridLeft + Double(column) * grid.columnStride + (rightSide ? grid.cellWidth - 4 : 4),
                y: grid.topInset + Double(row + 1) * grid.rowStride - 5
            )
            model.updateReorderDrag(
                localX: pagerPoint.x,
                localYFromTop: vertical.pagerTopOffset + pagerPoint.y
            )
            guard let preview = model.reorderPreview else {
                throw DisplaySafeAreaTestFailure(description: "A visible insertion gap below the inset header did not produce a hover preview")
            }
            let releaseSlot = grid.insertionSlot(at: pagerPoint, containerWidth: width)
            try require(preview.sourceID == apps[0].id && preview.page == 0, "Safe-area coordinate conversion changed the dragged app or page")
            try require(preview.slot == releaseSlot, "Window-coordinate hover and pager-coordinate drop selected different slots below the inset header")
            try require(preview.slot == row * 7 + column + (rightSide ? 1 : 0), "The pointer selected an adjacent row or the wrong side of its visible cell")
        }
        let heldPreview = model.reorderPreview
        let originalOrder = model.rootOrder
        model.updateReorderDrag(localX: width / 2, localYFromTop: vertical.searchTopPadding + 10)
        try require(model.reorderPreview == heldPreview && model.rootOrder == originalOrder,
                    "The search field changed the held grid gap or committed a new insertion")
    }

    private static func invalidSafeAreaValuesPreserveUsableGeometry() throws {
        let reference = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_440, containerHeight: 850, preferredIconSize: 90
        )
        for invalid in [-38.0, Double.nan, Double.infinity, -Double.infinity] {
            let vertical = LaunchpadVerticalMetrics(topSafeAreaInset: invalid)
            let grid = LaunchpadLayoutMetrics.calculate(
                containerWidth: 1_440, containerHeight: 850,
                preferredIconSize: 90, topSafeAreaInset: invalid
            )
            try require(vertical.searchTopPadding.isFinite && vertical.pagerTopOffset.isFinite, "An invalid display inset produced non-finite view coordinates")
            try require(vertical == LaunchpadVerticalMetrics() && grid == reference, "An invalid display inset shifted or resized the usable reference grid")
        }
    }

    private static func close(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) < 0.001
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DisplaySafeAreaTestFailure(description: message) }
    }
}

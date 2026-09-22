import AppKit
import Foundation

@MainActor
enum ReorderContinuityTests {
    static func run() throws -> Int {
        try liftingAnItemImmediatelyPreservesItsRootOrFolderSlot()
        try crossingAnAppCenterKeepsTheLastInsertionGap()
        try draggingAFolderCanReorderAcrossAnAppCenter()
        try pointerAndKeyboardFolderActivationKeepDistinctSelection()
        return 4
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func withModel(_ body: (LauncherModel, [AppItem]) throws -> Void) throws {
        let domain = "LaunchpadClassic.ReorderContinuityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw Failure(description: "Could not create isolated reorder preferences")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = LauncherModel(defaults: defaults, autoScan: false)
        defer { model.shutdown() }
        let apps = (0..<14).map {
            AppItem(url: URL(fileURLWithPath: "/Applications/ReorderContinuity\($0).app"))
        }
        model.apps = apps
        model.rootOrder = apps.map(\.id)
        model.updateRootPagerLayout(
            topOffset: topOffset, size: size, metrics: metrics, pageSize: metrics.capacity
        )
        model.setPageCount(3)
        try body(model, apps)
    }

    private static let topOffset = 80.0
    private static let size = CGSize(width: 900, height: 600)
    private static let metrics = LaunchpadLayoutMetrics(
        iconSize: 90, cellWidth: 138, cellHeight: 112,
        horizontalSpacing: 24, verticalSpacing: 26,
        columns: 3, rows: 2, gridWidth: 462, gridHeight: 250, topInset: 22
    )

    private static var gridOriginX: Double { (size.width - metrics.gridWidth) / 2 }
    private static var firstRowIconCenterY: Double { topOffset + metrics.topInset + metrics.iconSize / 2 }

    private static func liftingAnItemImmediatelyPreservesItsRootOrFolderSlot() throws {
        try withModel { model, apps in
            let originalOrder = model.rootOrder
            model.setCurrentPage(1)
            model.startReorderDrag(apps[8].id)
            try require(
                model.reorderPreview == LauncherReorderPreview(sourceID: apps[8].id, page: 1, slot: 2),
                "Lifting a later-page root app collapsed its slot before the first pointer update"
            )
            try require(model.rootOrder == originalOrder, "Creating the initial root gap committed a reorder")
            model.clearReorderDragState()

            let folder = AppGroup(name: "Continuity Folder", appPaths: apps.prefix(10).map(\.url.path))
            model.groups = [folder]
            model.open(folder)
            model.updateFolderPagerLayout(
                origin: CGPoint(x: 200, y: 260), cellWidth: metrics.cellWidth,
                columnCount: metrics.columns, capacity: metrics.capacity,
                columnSpacing: metrics.horizontalSpacing, rowSpacing: metrics.verticalSpacing,
                itemHeight: metrics.cellHeight
            )
            model.setFolderPageCount(2)
            model.goToFolderPage(1)
            model.startReorderDrag(apps[8].id)
            try require(
                model.reorderPreview == LauncherReorderPreview(sourceID: apps[8].id, page: 1, slot: 2),
                "Lifting a later-page folder app collapsed its slot before the first pointer update"
            )
            try require(model.groups == [folder], "The initial folder gap changed membership before dropping")
            model.clearReorderDragState()
            try require(model.groups == [folder] && model.rootOrder == originalOrder,
                        "Cancelling the initial gap changed saved layout")
        }
    }

    private static func crossingAnAppCenterKeepsTheLastInsertionGap() throws {
        try withModel { model, apps in
            let originalOrder = model.rootOrder
            model.startReorderDrag(apps[0].id)
            model.updateReorderDrag(
                localX: gridOriginX + metrics.columnStride + 1,
                localYFromTop: firstRowIconCenterY
            )
            let gap = LauncherReorderPreview(sourceID: apps[0].id, page: 0, slot: 1)
            try require(model.reorderPreview == gap, "The drag did not establish the insertion gap")
            for _ in 0..<8 {
                model.updateReorderDrag(
                    localX: gridOriginX + metrics.columnStride * 2 + metrics.cellWidth / 2,
                    localYFromTop: firstRowIconCenterY
                )
            }
            try require(model.reorderPreview == gap,
                        "Crossing an app center collapsed the established insertion gap")
            model.updateReorderDrag(localX: gridOriginX - 40, localYFromTop: firstRowIconCenterY)
            model.updateReorderDrag(localX: gridOriginX, localYFromTop: topOffset - 10)
            try require(model.reorderPreview == gap,
                        "Leaving the grid temporarily collapsed the established insertion gap")
            model.updateReorderDrag(
                localX: gridOriginX + 1,
                localYFromTop: firstRowIconCenterY + metrics.rowStride
            )
            try require(model.reorderPreview?.slot == 3,
                        "Leaving the app center prevented the next row from opening a new gap")
            try require(model.rootOrder == originalOrder && model.groups.isEmpty,
                        "Hovering over a potential folder target committed layout changes")
        }
    }

    private static func draggingAFolderCanReorderAcrossAnAppCenter() throws {
        try withModel { model, apps in
            let folder = AppGroup(name: "Move Folder", appPaths: apps.prefix(3).map(\.url.path))
            let folderID = LauncherEntry.group(folder).id
            model.groups = [folder]
            model.rootOrder = [folderID] + apps.dropFirst(3).map(\.id)
            let originalOrder = model.rootOrder
            model.startReorderDrag(folderID)
            let centerX = gridOriginX + metrics.columnStride + metrics.cellWidth / 2
            for (delta, slot) in [(-10.0, 1), (10.0, 2)] {
                model.updateReorderDrag(localX: centerX + delta, localYFromTop: firstRowIconCenterY)
                try require(
                    model.reorderPreview == LauncherReorderPreview(sourceID: folderID, page: 0, slot: slot),
                    "Dragging a folder across an app center failed to update the before/after insertion slot"
                )
            }
            try require(model.groups == [folder] && model.rootOrder == originalOrder,
                        "A folder hover modified membership or committed its position")
        }
    }

    private static func pointerAndKeyboardFolderActivationKeepDistinctSelection() throws {
        try withModel { model, apps in
            let folder = AppGroup(name: "Focus Folder", appPaths: apps.prefix(3).map(\.url.path))
            let entry = LauncherEntry.group(folder)
            model.groups = [folder]
            model.rootOrder = [entry.id] + apps.dropFirst(3).map(\.id)
            model.selectEntry(entry.id)
            model.activateFromPointer(entry)
            try require(model.openGroupID == folder.id && model.selectedEntryID == nil,
                        "Pointer activation retained selection inside the folder")
            model.closeFolder()
            try require(model.selectedEntryID == nil && model.highlightedEntryID == nil,
                        "Closing a pointer-opened folder left the white keyboard highlight behind")

            model.selectEntry(entry.id)
            try require(model.activateKeyboardSelection(), "Keyboard activation did not open the selected folder")
            model.closeFolder()
            try require(model.selectedEntryID == entry.id && model.highlightedEntryID == entry.id,
                        "Closing a keyboard-opened folder lost its return selection")
            model.activateFromPointer(entry)
            model.closeFolder()
            try require(model.selectedEntryID == nil,
                        "A later pointer activation restored an earlier keyboard selection")
        }
    }
}

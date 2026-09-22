import AppKit
import Foundation

@MainActor
enum FolderDragEntryTests {
    static func run() throws -> Int {
        try hoverOpenedFolderWaitsForSlowEntryBeforeCommitting()
        try enteringThenLeavingTheFolderUsesTheExitDwell()
        try draggingFromAnAlreadyOpenFolderCanExitImmediately()
        try cancellationAndReopeningDiscardEntryAndGeometryState()
        try crossingBetweenFoldersPreservesMembershipUntilDrop()
        try reopeningTheSourceFolderWaitsForEntryAgain()
        return 6
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor
    private struct SavedLayout {
        let groups: [AppGroup]
        let order: [String]
        let groupsData: Data?
        let savedOrder: [String]?

        init(model: LauncherModel, defaults: UserDefaults) {
            groups = model.groups
            order = model.rootOrder
            groupsData = defaults.data(forKey: "launcher.groups.v2")
            savedOrder = defaults.stringArray(forKey: "launcher.order.v1")
        }

        func verify(model: LauncherModel, defaults: UserDefaults) throws {
            try require(model.groups == groups && model.rootOrder == order,
                        "Hovering through a folder changed layout before a drop")
            try require(defaults.data(forKey: "launcher.groups.v2") == groupsData
                        && defaults.stringArray(forKey: "launcher.order.v1") == savedOrder,
                        "Hovering through a folder persisted an uncommitted layout")
        }
    }

    private static let metrics = LaunchpadLayoutMetrics(
        iconSize: 90, cellWidth: 138, cellHeight: 112,
        horizontalSpacing: 24, verticalSpacing: 26,
        columns: 3, rows: 2, gridWidth: 462, gridHeight: 250, topInset: 22
    )
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000)
    private static let outside = CGPoint(x: 780, y: 220)
    private static let inside = CGPoint(x: 270, y: 370)

    private static func rootIcon(_ slot: Int) -> CGPoint {
        CGPoint(x: (900 - metrics.gridWidth) / 2
                    + Double(slot) * metrics.columnStride + metrics.cellWidth / 2,
                y: 80 + metrics.topInset + metrics.iconSize / 2)
    }

    private static func update(_ model: LauncherModel, at point: CGPoint, seconds: Double) {
        model.updateReorderDrag(localX: point.x, localYFromTop: point.y,
                                now: now.addingTimeInterval(seconds))
    }

    private static func reportFolder(_ model: LauncherModel, band: CGRect? = nil) {
        model.updateFolderPagerLayout(
            origin: CGPoint(x: 200, y: 330), cellWidth: 138, columnCount: 3,
            capacity: 6, columnSpacing: 24, rowSpacing: 26, itemHeight: 112,
            bandFrame: band ?? CGRect(x: 160, y: 300, width: 580, height: 260)
        )
    }

    private static func withModel(
        _ body: (LauncherModel, [AppItem], AppGroup, UserDefaults) throws -> Void
    ) throws {
        let domain = "LaunchpadClassic.FolderDragEntryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw Failure(description: "Could not create isolated folder drag preferences")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = LauncherModel(defaults: defaults, autoScan: false)
        defer { model.shutdown() }
        let apps = (0..<8).map {
            AppItem(url: URL(fileURLWithPath: "/Applications/FolderDragEntry\($0).app"))
        }
        let folder = AppGroup(name: "Entry Target", appPaths: apps[1...2].map(\.url.path))
        model.apps = apps
        model.groups = [folder]
        model.rootOrder = [apps[0].id, LauncherEntry.group(folder).id] + apps.dropFirst(3).map(\.id)
        model.updateRootPagerLayout(topOffset: 80, size: CGSize(width: 900, height: 600),
                                    metrics: metrics, pageSize: metrics.capacity)
        model.setPageCount(2)
        try body(model, apps, folder, defaults)
    }

    private static func hoverOpen(
        _ model: LauncherModel, folder: AppGroup, slot: Int = 1, seconds: Double = 0
    ) throws {
        update(model, at: rootIcon(slot), seconds: seconds)
        update(model, at: rootIcon(slot), seconds: seconds + 0.64)
        try require(model.openGroupID == nil, "Hover-opening ignored the folder entry dwell")
        update(model, at: rootIcon(slot), seconds: seconds + 0.66)
        try require(model.openGroupID == folder.id, "A sustained folder hover did not open the target")
    }

    private static func hoverOpenedFolderWaitsForSlowEntryBeforeCommitting() throws {
        try withModel { model, apps, folder, defaults in
            let saved = SavedLayout(model: model, defaults: defaults)
            model.startReorderDrag(apps[0].id)
            try hoverOpen(model, folder: folder)
            reportFolder(model)
            for seconds in [0.9, 3, 10, 60] {
                update(model, at: rootIcon(1), seconds: seconds)
                try require(model.openGroupID == folder.id,
                            "A hover-opened folder closed before a slow pointer reached its panel")
                try require(model.reorderDragSourceID == apps[0].id,
                            "Waiting to enter the folder cancelled the drag")
            }
            try saved.verify(model: model, defaults: defaults)
            update(model, at: inside, seconds: 61)
            try require(model.addToOpenGroup(apps[0].id, beside: apps[1].id, after: false),
                        "A slow folder entry could not commit its requested insertion position")
            try require(model.group(for: folder.id)?.appPaths == [apps[0], apps[1], apps[2]].map(\.url.path),
                        "The final drop lost the app or appended it instead of inserting it")
            try require(model.reorderDragSourceID == nil, "The successful drop left drag tracking active")
        }
    }

    private static func enteringThenLeavingTheFolderUsesTheExitDwell() throws {
        try withModel { model, apps, folder, defaults in
            let saved = SavedLayout(model: model, defaults: defaults)
            model.startReorderDrag(apps[0].id)
            try hoverOpen(model, folder: folder)
            reportFolder(model)
            update(model, at: inside, seconds: 2)
            update(model, at: outside, seconds: 3)
            update(model, at: outside, seconds: 3.1)
            try require(model.openGroupID == folder.id, "Leaving a folder skipped the exit dwell")
            update(model, at: inside, seconds: 3.15)
            update(model, at: outside, seconds: 3.18)
            update(model, at: outside, seconds: 3.3)
            try require(model.openGroupID == folder.id, "Re-entering the panel did not reset its exit dwell")
            update(model, at: outside, seconds: 3.4)
            try require(model.openGroupID == nil && model.reorderDragSourceID == apps[0].id,
                        "A deliberate departure did not continue the live drag on the root grid")
            try saved.verify(model: model, defaults: defaults)
        }
    }

    private static func draggingFromAnAlreadyOpenFolderCanExitImmediately() throws {
        try withModel { model, apps, folder, defaults in
            let saved = SavedLayout(model: model, defaults: defaults)
            model.open(folder)
            reportFolder(model)
            model.startReorderDrag(apps[1].id)
            // The first tracked pointer sample can already be outside the band.
            update(model, at: outside, seconds: 0)
            update(model, at: outside, seconds: 0.21)
            try require(model.openGroupID == nil && model.reorderDragSourceID == apps[1].id,
                        "Picking up an existing folder app required an unnecessary re-entry before dragging out")
            try saved.verify(model: model, defaults: defaults)
        }
    }

    private static func cancellationAndReopeningDiscardEntryAndGeometryState() throws {
        try withModel { model, apps, folder, defaults in
            let saved = SavedLayout(model: model, defaults: defaults)
            model.startReorderDrag(apps[0].id)
            try hoverOpen(model, folder: folder)
            reportFolder(model)
            update(model, at: inside, seconds: 1)
            update(model, at: outside, seconds: 2)
            model.clearReorderDragState()
            model.closeFolder()

            // Simulate a prior folder layout whose panel covered the root icon.
            // The next opening must wait for its own panel geometry.
            reportFolder(model, band: CGRect(x: 200, y: 100, width: 500, height: 150))
            model.startReorderDrag(apps[0].id)
            try hoverOpen(model, folder: folder, seconds: 10)
            update(model, at: rootIcon(1), seconds: 12)
            reportFolder(model)
            update(model, at: outside, seconds: 20)
            update(model, at: outside, seconds: 30)
            try require(model.openGroupID == folder.id,
                        "A cancelled drag or stale panel geometry armed the next folder exit")
            model.clearReorderDragState()
            model.closeFolder()
            try saved.verify(model: model, defaults: defaults)
        }
    }

    private static func crossingBetweenFoldersPreservesMembershipUntilDrop() throws {
        try withModel { model, apps, folder, defaults in
            let destination = AppGroup(name: "Second Target", appPaths: apps[3...4].map(\.url.path))
            model.groups.append(destination)
            model.rootOrder = [LauncherEntry.group(folder).id, LauncherEntry.group(destination).id,
                               apps[0].id] + apps.dropFirst(5).map(\.id)
            let saved = SavedLayout(model: model, defaults: defaults)
            model.open(folder)
            reportFolder(model)
            model.startReorderDrag(apps[1].id)
            try require(model.continueReorderDragOutsideFolder(), "A folder app could not reach the root grid")
            try hoverOpen(model, folder: destination)
            reportFolder(model)
            update(model, at: rootIcon(1), seconds: 10)
            update(model, at: rootIcon(1), seconds: 20)
            try require(model.openGroupID == destination.id,
                        "The previous folder's entry state armed exit from the next folder")
            try saved.verify(model: model, defaults: defaults)
            update(model, at: inside, seconds: 21)
            try require(model.addToOpenGroup(apps[1].id, beside: apps[3].id, after: false),
                        "A slow drag between folders could not be committed")
            try require(model.group(for: destination.id)?.appPaths == [apps[1], apps[3], apps[4]].map(\.url.path),
                        "Dragging between folders lost the chosen insertion position")
            try require(!model.groups.filter { $0.id != destination.id }.contains { $0.appPaths.contains(apps[1].url.path) },
                        "The committed cross-folder drop duplicated its source app")
        }
    }

    private static func reopeningTheSourceFolderWaitsForEntryAgain() throws {
        try withModel { model, apps, folder, defaults in
            let saved = SavedLayout(model: model, defaults: defaults)
            model.open(folder)
            reportFolder(model)
            model.startReorderDrag(apps[1].id)
            try require(model.continueReorderDragOutsideFolder(), "The source folder could not close during drag")
            update(model, at: outside, seconds: 1)
            try hoverOpen(model, folder: folder, seconds: 2)
            reportFolder(model)
            update(model, at: rootIcon(1), seconds: 10)
            update(model, at: rootIcon(1), seconds: 20)
            try require(model.openGroupID == folder.id,
                        "An app's existing membership armed exit before it re-entered its source folder")
            model.clearReorderDragState()
            try saved.verify(model: model, defaults: defaults)
        }
    }
}

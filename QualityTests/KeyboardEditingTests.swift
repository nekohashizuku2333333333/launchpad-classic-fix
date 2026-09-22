import AppKit
import Foundation

@MainActor
enum KeyboardEditingTests {
    static let count = 14

    static func run() throws {
        _ = NSApplication.shared
        try temporaryAndPersistentEditingHaveSeparateLifetimes()
        try rootSelectionFollowsGridAndChangesPages()
        try folderSelectionUsesFolderGeometryAndRestoresParent()
        try searchChangesResetSelectionAndConstrainNavigation()
        try pageChangesClearInvisibleSelection()
        try modalAndDragStateProtectKeyboardActions()
        try escapeAndBackgroundClicksRespectInteractionLayers()
        try hiddenLauncherClearsTransientKeyboardState()
        try deleteRequestsResolveCurrentEligibleApplication()
        try emptyAndBoundaryNavigationRemainSafe()
        try clearingSearchRestoresItsOriginalRootPage()
        try draggingSearchResultsReturnsToTheUnfilteredRoot()
        try draggingFolderSearchResultsDefersMembershipChangesUntilDrop()
        try implicitSearchHighlightPreservesCaretAndFollowsVisiblePages()
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func withModel(_ body: (LauncherModel) throws -> Void) throws {
        let domain = "LaunchpadClassic.KeyboardTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw Failure(description: "Could not create keyboard test preferences")
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = LauncherModel(defaults: defaults, autoScan: false)
        defer { model.shutdown() }
        try body(model)
    }

    private static func populate(_ model: LauncherModel, count: Int = 14) -> [AppItem] {
        let apps = (0..<count).map {
            AppItem(url: URL(fileURLWithPath: "/Applications/KeyboardTest\($0).app"))
        }
        model.apps = apps
        model.rootOrder = apps.map(\.id)
        let metrics = LaunchpadLayoutMetrics(
            iconSize: 92, cellWidth: 140, cellHeight: 119,
            horizontalSpacing: 22, verticalSpacing: 18,
            columns: 3, rows: 2, gridWidth: 464, gridHeight: 256, topInset: 16
        )
        model.updateRootPagerLayout(
            topOffset: 60, size: CGSize(width: 900, height: 600), metrics: metrics, pageSize: 6
        )
        model.setPageCount(max(1, (count + 5) / 6))
        return apps
    }

    private static func temporaryAndPersistentEditingHaveSeparateLifetimes() throws {
        try withModel { model in
            model.setOptionKeyPressed(true)
            try require(model.isEditing, "Option did not temporarily enter editing")
            model.setOptionKeyPressed(false)
            try require(!model.isEditing, "Releasing Option left temporary editing active")
            model.beginEditing()
            model.setOptionKeyPressed(true)
            model.setOptionKeyPressed(false)
            try require(model.isEditing, "Option release cancelled long-press editing")
            model.endEditing()
            try require(!model.isEditing, "Ending editing did not clear the locked state")
            model.showLauncherSettings = true
            model.beginEditing()
            model.setOptionKeyPressed(true)
            try require(!model.isEditing, "Settings allowed background editing")
        }
    }

    private static func rootSelectionFollowsGridAndChangesPages() throws {
        try withModel { model in
            let apps = populate(model)
            try require(model.moveKeyboardSelection(.down), "Arrow did not establish root selection")
            try require(model.selectedEntryID == apps[0].id, "Initial selection skipped the first visible app")
            model.moveKeyboardSelection(.down)
            try require(model.selectedEntryID == apps[3].id, "Down did not respect the grid's columns")
            model.moveKeyboardSelection(.right)
            model.moveKeyboardSelection(.right)
            model.moveKeyboardSelection(.right)
            try require(model.currentPage == 1 && model.selectedEntryID == apps[6].id,
                        "Right did not select the first app on the next page")
            model.moveKeyboardSelection(.left)
            try require(model.currentPage == 0 && model.selectedEntryID == apps[5].id,
                        "Left did not return to the preceding page's last app")
            model.goToPage(2)
            model.moveKeyboardSelection(.right)
            try require(model.selectedEntryID == apps[12].id, "Initial arrow ignored the visible page")
        }
    }

    private static func folderSelectionUsesFolderGeometryAndRestoresParent() throws {
        try withModel { model in
            let apps = populate(model)
            let folder = AppGroup(name: "Keyboard Folder", appPaths: apps.map(\.url.path))
            model.groups = [folder]
            model.selectEntry(LauncherEntry.group(folder).id)
            try require(model.activateKeyboardSelection(), "Return did not open the selected folder")
            try require(model.openGroupID == folder.id && model.selectedEntryID == nil,
                        "Opening a folder retained its root selection inside the folder")
            model.updateFolderPagerLayout(
                origin: .zero, cellWidth: 140, columnCount: 3, capacity: 6,
                columnSpacing: 22, rowSpacing: 18, itemHeight: 119
            )
            model.setFolderPageCount(3)
            model.moveKeyboardSelection(.down)
            model.moveKeyboardSelection(.down)
            model.moveKeyboardSelection(.down)
            try require(model.folderPager.page == 1 && model.selectedEntryID == apps[6].id,
                        "Folder selection used root geometry or failed to turn its own page")
            model.closeFolder()
            try require(model.selectedEntryID == LauncherEntry.group(folder).id,
                        "Closing a keyboard-opened folder lost its parent selection")
        }
    }

    private static func searchChangesResetSelectionAndConstrainNavigation() throws {
        try withModel { model in
            let apps = populate(model)
            model.selectEntry(apps[8].id)
            model.search = "KeyboardTest1"
            try require(model.selectedEntryID == nil && model.currentPage == 0,
                        "Changing search retained a stale selection or page")
            model.moveKeyboardSelection(.down)
            try require(model.selectedEntryID == apps[1].id, "Search navigation selected an unfiltered app")
            model.moveKeyboardSelection(.right)
            try require(model.selectedEntryID == apps[10].id, "Search navigation skipped filtered ordering")
            model.search = "No application matches this query"
            try require(!model.moveKeyboardSelection(.down) && !model.activateKeyboardSelection(),
                        "An empty search result was selectable or activatable")
            try require(model.selectedEntryID == nil, "Empty search kept an invisible selection")
        }
    }

    private static func pageChangesClearInvisibleSelection() throws {
        try withModel { model in
            let apps = populate(model)
            model.selectEntry(apps[0].id)
            model.navigateVisiblePages(by: 1)
            try require(model.selectedEntryID == nil, "Command-arrow retained an invisible root selection")
            model.selectEntry(apps[6].id)
            model.setCurrentPage(2)
            try require(model.selectedEntryID == nil, "Direct root paging retained old selection")
            model.selectEntry(apps[12].id)
            model.setPageCount(1)
            try require(model.selectedEntryID == nil, "Clamping root page count retained old selection")
        }
    }

    private static func modalAndDragStateProtectKeyboardActions() throws {
        try withModel { model in
            let apps = populate(model)
            model.errorMessage = "Test modal"
            try require(!model.moveKeyboardSelection(.down) && !model.handleEscape(),
                        "Keyboard interaction escaped behind an error alert")
            model.errorMessage = nil
            model.pendingDeleteApp = apps[0]
            model.beginEditing()
            try require(!model.isEditing && !model.moveKeyboardSelection(.down),
                        "Delete confirmation allowed background editing or navigation")
            model.pendingDeleteApp = nil
            model.beginEditing()
            let originalOrder = model.rootOrder
            model.startReorderDrag(apps[0].id)
            try require(!model.moveKeyboardSelection(.right), "Arrow selection interrupted a native drag")
            try require(model.handleEscape(), "Escape did not handle an active drag")
            try require(model.reorderDragSourceID == nil && model.isEditing,
                        "Escape failed to cancel the drag before leaving editing")
            try require(model.rootOrder == originalOrder, "Cancelling a drag changed saved order")
        }
    }

    private static func escapeAndBackgroundClicksRespectInteractionLayers() throws {
        try withModel { model in
            let apps = populate(model, count: 4)
            let folder = AppGroup(name: "Folder", appPaths: apps.map(\.url.path))
            model.groups = [folder]
            model.open(folder)
            model.beginEditing()
            model.handleEscape()
            try require(!model.isEditing && model.openGroupID == folder.id,
                        "Escape closed the folder before leaving editing")
            model.handleEscape()
            try require(model.openGroupID == nil, "Second Escape did not close the folder")
            model.search = "Keyboard"
            model.beginEditing()
            model.handleEscape()
            try require(model.search == "Keyboard", "Leaving editing unexpectedly cleared search")
            model.handleEscape()
            try require(model.search.isEmpty, "Escape did not clear search before dismissing")
            model.open(folder)
            model.beginEditing()
            model.handleBackgroundClick()
            try require(!model.isEditing && model.openGroupID != nil,
                        "Background click dismissed a folder while leaving editing")
            model.handleBackgroundClick()
            try require(model.openGroupID == nil, "Background click failed to close the folder")
        }
    }

    private static func hiddenLauncherClearsTransientKeyboardState() throws {
        try withModel { model in
            let apps = populate(model)
            model.selectEntry(apps[2].id)
            model.beginEditing()
            model.setOptionKeyPressed(true)
            model.handleApplicationDidHide()
            try require(!model.isEditing && model.selectedEntryID == nil,
                        "Hidden launcher retained editing or keyboard selection")
            model.setOptionKeyPressed(false)
            try require(!model.isEditing, "A late modifier release restored persistent editing")
        }
    }

    private static func deleteRequestsResolveCurrentEligibleApplication() throws {
        try withModel { model in
            let url = URL(fileURLWithPath: "/Applications/StoreTest.app")
            let eligible = AppItem(url: url, isDeletable: true)
            let protected = AppItem(url: url, isDeletable: false)
            model.apps = [protected]
            model.requestDeleteApplication(eligible)
            try require(model.pendingDeleteApp == nil, "Stale deletion eligibility bypassed current app metadata")
            model.apps = [eligible]
            model.requestDeleteApplication(eligible)
            try require(model.pendingDeleteApp == eligible, "Eligible App Store application did not request confirmation")
            model.pendingDeleteApp = nil
            model.startReorderDrag(eligible.id)
            model.requestDeleteApplication(eligible)
            try require(model.pendingDeleteApp == nil, "Drag accidentally requested deletion")
            model.clearReorderDragState()
            model.apps = []
            model.requestDeleteApplication(eligible)
            try require(model.pendingDeleteApp == nil, "Missing app requested deletion")
        }
    }

    private static func emptyAndBoundaryNavigationRemainSafe() throws {
        try withModel { model in
            try require(!model.moveKeyboardSelection(.left), "Empty launcher fabricated a selection")
            let apps = populate(model, count: 1)
            model.moveKeyboardSelection(.left)
            model.moveKeyboardSelection(.up)
            model.moveKeyboardSelection(.right)
            model.moveKeyboardSelection(.down)
            try require(model.selectedEntryID == apps[0].id, "Grid boundary moved beyond the only application")
            model.clearKeyboardSelection()
            model.currentPage = Int.max
            model.moveKeyboardSelection(.down)
            try require(model.currentPage == 0 && model.selectedEntryID == apps[0].id,
                        "Out-of-range page navigation overflowed or selected a missing item")
            try require(LauncherKeyboardCommand.selectionDirection(keyCode: 0) == nil,
                        "A typing key was interpreted as grid navigation")
        }
    }

    private static func clearingSearchRestoresItsOriginalRootPage() throws {
        try withModel { model in
            _ = populate(model)
            model.goToPage(2)
            model.search = "KeyboardTest13"
            try require(model.currentPage == 0 && model.pageCount == 1,
                        "Search did not show the first filtered page")
            model.search = "KeyboardTest1"
            model.search = ""
            try require(model.currentPage == 2 && model.displayedPage == 2 && model.pageCount == 3,
                        "Clearing search did not restore its original page using the full root count")
            model.search = "KeyboardTest13"
            model.apps = Array(model.apps.prefix(3))
            model.search = ""
            try require(model.currentPage == 0 && model.pageCount == 1,
                        "Restoring search did not clamp its page after apps disappeared")
        }
    }

    private static func draggingSearchResultsReturnsToTheUnfilteredRoot() throws {
        try withModel { model in
            let apps = populate(model)
            let originalOrder = model.rootOrder
            model.goToPage(2)
            model.search = "KeyboardTest1"
            model.startReorderDrag(apps[1].id)
            try require(model.search.isEmpty && model.currentPage == 2 && model.pageCount == 3,
                        "Dragging a result did not return to the unfiltered root page")
            try require(model.reorderDragSourceID == apps[1].id && model.rootOrder == originalOrder,
                        "Starting a result drag changed layout before a drop")
            try require(model.reorder(apps[1].id, beside: apps[12].id, after: false),
                        "A result drag could not commit a root reordering")
            let reordered = model.rootEntries.map(\.id)
            guard let moved = reordered.firstIndex(of: apps[1].id),
                  let target = reordered.firstIndex(of: apps[12].id) else {
                throw Failure(description: "Search-result drop lost a root entry")
            }
            try require(moved + 1 == target, "Result drag used a filtered index for its root drop")
        }
    }

    private static func draggingFolderSearchResultsDefersMembershipChangesUntilDrop() throws {
        try withModel { model in
            let apps = populate(model)
            let folder = AppGroup(name: "Search Source", appPaths: Array(apps.prefix(3)).map(\.url.path))
            model.groups = [folder]
            model.setPageCount(2)
            model.goToPage(1)
            model.open(folder)
            model.search = "KeyboardTest0"
            try require(model.openGroupID == nil, "Searching did not close the folder pane")
            model.startReorderDrag(apps[8].id)
            try require(!model.search.isEmpty && model.reorderDragSourceID == nil,
                        "An app outside the results started a search drag")
            model.startReorderDrag(apps[0].id)
            try require(model.search.isEmpty && model.currentPage == 1 && model.openGroupID == nil,
                        "Folder search drag did not restore the root page")
            try require(model.groups == [folder], "Search drag detached a folder app before committing")
            model.clearReorderDragState()
            try require(model.groups == [folder], "Cancelling a search drag changed folder membership")
            model.search = "KeyboardTest0"
            model.startReorderDrag(apps[0].id)
            try require(model.reorder(apps[0].id, beside: apps[9].id, after: false),
                        "Folder search drag could not be placed on the root grid")
            try require(!model.groups.contains(where: { $0.appPaths.contains(apps[0].url.path) }),
                        "Committing a folder search drag failed to move the app out")
        }
    }

    private static func implicitSearchHighlightPreservesCaretAndFollowsVisiblePages() throws {
        try withModel { model in
            let apps = populate(model)
            try require(model.highlightedEntryID == nil, "An unselected root page fabricated a default highlight")
            model.search = "KeyboardTest"
            try require(model.highlightedEntryID == apps[0].id && model.selectedEntryID == nil,
                        "The default search highlight took explicit selection away from the text caret")
            model.goToPage(1)
            try require(model.highlightedEntryID == apps[6].id && model.selectedEntryID == nil,
                        "A search page highlighted an invisible first-page result")
            model.moveKeyboardSelection(.down)
            model.moveKeyboardSelection(.right)
            try require(model.selectedEntryID == apps[7].id && model.highlightedEntryID == apps[7].id,
                        "Explicit keyboard selection did not replace the default search highlight")
            model.search = "KeyboardTest1"
            try require(model.selectedEntryID == nil && model.highlightedEntryID == apps[1].id,
                        "Typing did not restore caret navigation and update the default result")
            model.beginEditing()
            try require(model.highlightedEntryID == nil, "Editing retained a launch-selection highlight")
            model.endEditing()
            model.startReorderDrag(apps[1].id)
            try require(model.highlightedEntryID == nil, "Dragging retained a search highlight")
            model.clearReorderDragState()
            model.search = "No matching application"
            try require(model.highlightedEntryID == nil, "Empty search results produced an invalid highlight")
        }
    }
}

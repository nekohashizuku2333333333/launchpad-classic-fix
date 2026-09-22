import Foundation
import Darwin
import AppKit
import CoreGraphics
import Combine

private struct QualityTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct LauncherQualityTests {
    static func main() async {
        do {
            try invalidSavedPreferencesAreSanitized()
            try freshInstallUsesDesktopWallpaper()
            try traditionalChineseLocalizationIsComplete()
            try systemLanguageResolutionHandlesTraditionalChineseRegions()
            try searchFiltersApplicationsAndResetsPaging()
            try searchResultsCannotMutateSavedLayout()
            try duplicateSavedGroupsAndPathsAreSanitized()
            try duplicateRuntimeOrderDoesNotCrashOrLoseEntries()
            try dropInputValidationRejectsUnknownIdentifiers()
            try folderLifecyclePersistsSafely()
            try folderReorderingMatchesVisibleDropSlots()
            try folderDragPreviewHandlesUncachedIcons()
            try openFolderDropsAcceptExternalAppsAcrossInterior()
            try externalFolderDropsHonorPageAndInsertionSlot()
            try openFolderAllowsMovingAppsOutToRootSlots()
            try folderDragOutCanBeCancelledWithoutSavingMutations()
            try folderDragOutCanInsertBeforeOrAfterRootEntries()
            try folderDragOutDissolvesSourceAtOriginalPosition()
            try folderDragOutCanMoveAcrossRootPages()
            try folderDragOutCanEnterAnotherFolder()
            try folderDragOutCanCreateNewFolder()
            try stationaryDragPublishesOnlyChangedPreviews()
            try hidingLauncherCancelsDragWithoutChangingLayout()
            try await folderRenameControlsPersistExplicitly()
            try folderRemovalMatchesNativeLifecycle()
            try pageNavigationHandlesIntegerBoundaries()
            try await pageNavigationDoesNotRestoreStaleDestinations()
            try await folderNavigationDoesNotRestoreStaleDestinations()
            try modalUIBlocksBackgroundPageNavigation()
            try launcherWindowAcceptsKeyboardFocus()
            try quitShortcutRequiresCommandQ()
            try dismissMotionMatchesReferenceApplication()
            try referenceIconSizingMatchesAttachedApp()
            try rootGridUsesAvailableScreenSpace()
            try systemLanguageResolvesFinderStyleLocalizationOrder()
            try folderGridMetricsNeverOverflowTheirPanel()
            try pageWindowLimitsRenderedPages()
            try scannerGracefullyHandlesMissingRoots()
            try scannerFindsApplicationLinksWithoutDuplicates()
            try sequoiaUtilitiesAreGroupedWithoutOverwritingUserFolders()
            try automaticUpdateConfigurationIsSecureAndEnabled()
            try preparedModelRunsInitialReadinessHandler()
            try await initialPresentationPreloadsInstalledApplications()
            try await applicationMonitorDetectsDirectoryChanges()
            try memoryPolicyKeepsCachesBounded()
            try await imageLoadersHandleMissingFiles()
            try await hiddenLauncherReleasesAndPreparesImagesForReopening()
            try applicationUpdatePreservesUserLayout()
            try await fileOperatorRejectsUnsafeDeleteLocation()
            try KeyboardEditingTests.run()
            let storeTestCount = try await StoreUninstallTests.run()
            let dragTestCount = try await DragProviderTests.run()
            let displayTestCount = try DisplaySafeAreaTests.run()
            let searchTypingTestCount = try SearchTypingTests.run()
            let memoryResourceTestCount = try await MemoryResourceTests.run()
            let reorderContinuityTestCount = try ReorderContinuityTests.run()
            let folderDragEntryCount = try FolderDragEntryTests.run()
            let testCount = 49 + KeyboardEditingTests.count + storeTestCount + dragTestCount + displayTestCount + searchTypingTestCount + memoryResourceTestCount + reorderContinuityTestCount + folderDragEntryCount
            print("Launcher quality tests passed (\(testCount)/\(testCount))")
        } catch {
            FileHandle.standardError.write(Data("Launcher quality tests failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func invalidSavedPreferencesAreSanitized() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        context.defaults.set("unsupported", forKey: "language")
        context.defaults.set(Double.nan, forKey: "iconSize")
        context.defaults.set("file:/tmp/not-an-image.txt", forKey: "background")
        context.defaults.set([
            "app:/Applications/Alpha.app",
            "app:/Applications/Alpha.app",
            "invalid",
            "group:not-a-uuid"
        ], forKey: "launcher.order.v1")

        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        try require(model.language == "en", "Invalid language did not fall back to English")
        try require(model.iconSize == 90, "Non-finite icon size did not fall back to the Sequoia reference default")
        try require(model.background == "wallpaper", "Invalid background was not sanitized")
        try require(model.rootOrder == ["app:/Applications/Alpha.app"], "Invalid root order was not sanitized")
    }

    private static func freshInstallUsesDesktopWallpaper() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)

        try require(
            model.background == LauncherModel.defaultBackground,
            "A fresh install did not default to the Desktop wallpaper"
        )
        try require(
            LauncherModel.defaultBackground == "wallpaper",
            "The default background no longer represents the Desktop wallpaper"
        )
    }

    private static func traditionalChineseLocalizationIsComplete() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.language = "zh-Hant"

        try require(
            model.text("Folder", "フォルダ", "資料夾") == "資料夾",
            "Traditional Chinese did not select its localized UI text"
        )

        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        model.apps = [first, second]
        model.handleDrop(first.id, on: .app(second))
        try require(
            model.groups.first?.name == "資料夾",
            "A folder created in Traditional Chinese did not receive a localized name"
        )

        let utilities = AppGroup(
            name: "Utilities",
            appPaths: ["/Applications/Utilities/Terminal.app"],
            systemKind: "utilities"
        )
        let customUtilities = AppGroup(
            name: "My Tools",
            appPaths: ["/Applications/Utilities/Console.app"],
            systemKind: "utilities"
        )
        model.groups.append(contentsOf: [utilities, customUtilities])
        model.language = "en"
        model.language = "zh-Hant"
        try require(
            model.group(for: utilities.id)?.name == "工具程式",
            "The default Utilities folder did not follow the selected language"
        )
        try require(
            model.group(for: customUtilities.id)?.name == "My Tools",
            "Changing language overwrote a custom system-folder name"
        )

        let restoredModel = LauncherModel(defaults: context.defaults, autoScan: false)
        try require(
            restoredModel.language == "zh-Hant",
            "Traditional Chinese language selection was not preserved"
        )
    }

    private static func systemLanguageResolutionHandlesTraditionalChineseRegions() throws {
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["zh-Hant-TW"]) == "zh-Hant",
            "zh-Hant was not recognized as Traditional Chinese"
        )
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["zh_TW"]) == "zh-Hant",
            "The zh_TW locale was not recognized as Traditional Chinese"
        )
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["zh-HK"]) == "zh-Hant",
            "The zh-HK locale was not recognized as Traditional Chinese"
        )
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["zh-MO"]) == "zh-Hant",
            "The zh-MO locale was not recognized as Traditional Chinese"
        )
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["zh-Hans-CN"]) == "en",
            "Simplified Chinese unexpectedly selected Traditional Chinese text"
        )
        try require(
            LauncherModel.resolvedSystemLanguage(from: ["ja-JP"]) == "ja",
            "Japanese system language resolution regressed"
        )
        try require(
            LauncherModel.sanitizedLanguage("zh-TW") == "zh-Hant",
            "A legacy Traditional Chinese language value was not migrated"
        )
    }

    private static func searchFiltersApplicationsAndResetsPaging() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let alpha = AppItem(url: URL(fileURLWithPath: "/Applications/Alpha Notes.app"))
        let beta = AppItem(url: URL(fileURLWithPath: "/Applications/Beta.app"))
        model.apps = [alpha, beta]
        model.setPageCount(3)
        model.goToPage(2)

        model.search = "alpha"
        try require(model.currentPage == 0, "Starting a search did not return to the first page")
        try require(model.rootEntries == [.app(alpha)], "Search did not filter applications case-insensitively")

        model.search = "Beta"
        try require(model.rootEntries == [.app(beta)], "Search did not update when its query changed")

        model.search = "missing"
        try require(model.rootEntries.isEmpty, "A missing search query returned unexpected applications")
    }

    private static func searchResultsCannotMutateSavedLayout() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let groupedMatch = AppItem(url: URL(fileURLWithPath: "/Applications/Find In Folder.app"))
        let groupedOther = AppItem(url: URL(fileURLWithPath: "/Applications/Other In Folder.app"))
        let looseMatch = AppItem(url: URL(fileURLWithPath: "/Applications/Find Loose.app"))
        let looseOther = AppItem(url: URL(fileURLWithPath: "/Applications/Other Loose.app"))
        let apps = [groupedMatch, groupedOther, looseMatch, looseOther]
        let group = AppGroup(name: "Folder", appPaths: [groupedMatch.url.path, groupedOther.url.path])
        let order = [looseOther.id, LauncherEntry.group(group).id, looseMatch.id]
        model.apps = apps
        model.groups = [group]
        model.rootOrder = order
        let savedGroups = context.defaults.data(forKey: "launcher.groups.v2")
        let savedOrder = context.defaults.stringArray(forKey: "launcher.order.v1")
        model.search = "Find"
        try require(
            model.rootEntries.map(\.id) == [groupedMatch.id, looseMatch.id],
            "The search regression fixture did not include a grouped app and omit other root entries"
        )
        // A result may begin a drag, which exits search before accepting drops.
        // Direct drops while the filtered page is still active must not treat
        // result indices as positions in the saved root arrangement.
        try require(
            !model.reorder(groupedMatch.id, beside: looseMatch.id, after: false),
            "Reordering search results unexpectedly removed an app from its folder"
        )
        try require(
            !model.reorderToSlot(looseMatch.id, page: 0, slot: 0, pageSize: 9),
            "A search result could be inserted into the filtered root order"
        )
        try require(
            !model.reorderToPageEnd(looseMatch.id, page: 0, pageSize: 9),
            "A search result could overwrite the root order through a page-end drop"
        )
        model.handleDrop(groupedMatch.id, on: .app(looseMatch))
        model.handleDrop(looseMatch.id, on: .group(group))
        try require(model.groups == [group] && model.rootOrder == order, "Dropping search results changed folder membership or root order")
        try require(
            context.defaults.data(forKey: "launcher.groups.v2") == savedGroups
                && context.defaults.stringArray(forKey: "launcher.order.v1") == savedOrder,
            "Dropping search results overwrote the persisted layout"
        )
        model.search = ""
        try require(model.rootEntries.map(\.id) == order, "Leaving search did not restore the complete original root layout")
    }

    private static func duplicateSavedGroupsAndPathsAreSanitized() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let groupID = UUID()
        let saved = [
            AppGroup(
                id: groupID,
                name: "\u{0000}Work\n" + String(repeating: "x", count: 100),
                appPaths: ["/Applications/Alpha.app", "/Applications/Alpha.app", "relative.app"]
            ),
            AppGroup(id: groupID, name: "Duplicate", appPaths: ["/Applications/Beta.app"]),
            AppGroup(name: "Empty", appPaths: ["not-an-app"])
        ]
        context.defaults.set(try JSONEncoder().encode(saved), forKey: "launcher.groups.v2")

        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        try require(model.groups.count == 1, "Duplicate or empty groups were not removed")
        guard let group = model.groups.first else { throw QualityTestFailure(description: "Sanitized group is missing") }
        try require(group.id == groupID, "Valid group ID was not preserved")
        try require(group.appPaths == ["/Applications/Alpha.app"], "Duplicate or invalid paths were not removed")
        try require(group.name.count <= 64, "Folder name length was not limited")
        try require(
            !group.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            "Control characters were not removed from the folder name"
        )
    }

    private static func duplicateRuntimeOrderDoesNotCrashOrLoseEntries() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let alpha = AppItem(url: URL(fileURLWithPath: "/Applications/Alpha.app"))
        let beta = AppItem(url: URL(fileURLWithPath: "/Applications/Beta.app"))
        model.apps = [alpha, beta, alpha]
        model.rootOrder = [alpha.id, alpha.id, beta.id]
        try require(
            model.rootEntries.map(\.id) == [alpha.id, alpha.id, beta.id],
            "Duplicate runtime order lost an entry"
        )
    }

    private static func dropInputValidationRejectsUnknownIdentifiers() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let alpha = AppItem(url: URL(fileURLWithPath: "/Applications/Alpha.app"))
        let beta = AppItem(url: URL(fileURLWithPath: "/Applications/Beta.app"))
        model.apps = [alpha, beta]
        model.handleDrop(alpha.id, on: .app(beta))
        guard let group = model.groups.first else { throw QualityTestFailure(description: "Valid drop did not create a folder") }
        model.open(group)
        let originalPaths = group.appPaths

        model.addToOpenGroup("app:/tmp/Injected.app")
        model.moveOutOfOpenGroup("app:/tmp/Injected.app")
        model.reorder("invalid", beside: alpha.id, after: true)
        try require(model.groups.first?.appPaths == originalPaths, "Invalid drop data changed the folder")
        try require(!model.rootOrder.contains("app:/tmp/Injected.app"), "Invalid drop data entered the saved order")
    }

    private static func folderLifecyclePersistsSafely() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        model.apps = [first, second]

        model.handleDrop(first.id, on: .app(second))
        guard let createdGroup = model.groups.first else {
            throw QualityTestFailure(description: "Folder creation failed")
        }
        try require(
            model.apps(in: createdGroup).map(\.url.path) == [second.url.path, first.url.path],
            "Folder row order was not preserved"
        )

        model.renameGroup(createdGroup.id, to: "Work\n")
        model.finalizeGroupName(createdGroup.id)
        guard let savedData = context.defaults.data(forKey: "launcher.groups.v2") else {
            throw QualityTestFailure(description: "Folder data was not saved")
        }
        let savedGroups = try JSONDecoder().decode([AppGroup].self, from: savedData)
        guard let savedGroup = savedGroups.first else {
            throw QualityTestFailure(description: "Saved folder is missing")
        }
        try require(savedGroup.name == "Work", "Sanitized folder name was not persisted")

        model.open(createdGroup)
        model.reorderInOpenGroup(first.id, before: second.id)
        try require(
            model.groups.first?.appPaths == [first.url.path, second.url.path],
            "Folder reordering failed"
        )
        model.moveOutOfOpenGroup(first.id)
        try require(model.rootEntries.contains(.app(first)), "Removed app did not return to the root page")
        try require(model.groups.isEmpty, "A folder with one remaining application was not dissolved")
        try require(model.openGroupID == nil, "A dissolved folder remained open")
    }

    private static func folderReorderingMatchesVisibleDropSlots() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<6).map { AppItem(url: URL(fileURLWithPath: "/Applications/App\($0).app")) }
        let group = AppGroup(name: "Folder", appPaths: apps.map(\.url.path))
        model.apps = apps
        model.groups = [group]
        model.open(group)

        model.reorderInOpenGroup(apps[0].id, beside: apps[3].id, after: true)
        try require(
            model.groups.first?.appPaths == [
                apps[1].url.path,
                apps[2].url.path,
                apps[3].url.path,
                apps[0].url.path,
                apps[4].url.path,
                apps[5].url.path
            ],
            "Dragging an earlier folder app after a later app landed in the wrong slot"
        )

        model.reorderInOpenGroup(apps[5].id, beside: apps[2].id, after: false)
        try require(
            model.groups.first?.appPaths == [
                apps[1].url.path,
                apps[5].url.path,
                apps[2].url.path,
                apps[3].url.path,
                apps[0].url.path,
                apps[4].url.path
            ],
            "Dragging a later folder app before an earlier app landed in the wrong slot"
        )

        model.setFolderPageCount(2)
        model.setFolderPage(0)
        model.reorderInOpenGroupToSlot(apps[4].id, slot: 4, capacity: 9)
        try require(
            model.groups.first?.appPaths == [
                apps[1].url.path,
                apps[5].url.path,
                apps[2].url.path,
                apps[3].url.path,
                apps[4].url.path,
                apps[0].url.path
            ],
            "Dropping a folder app into an empty visible slot did not match the preview slot"
        )
    }

    private static func folderDragPreviewHandlesUncachedIcons() throws {
        try require(
            FolderDragPreview.previewSlotCount(iconCount: 0) == 1,
            "A folder drag preview with no cached icons would render no safe placeholder"
        )
        try require(
            FolderDragPreview.previewSlotCount(iconCount: 4) == 4,
            "A folder drag preview changed the visible cached-icon count"
        )
        try require(
            FolderDragPreview.previewSlotCount(iconCount: 12) == 9,
            "A folder drag preview rendered more than nine mini icons"
        )
    }

    private static func openFolderDropsAcceptExternalAppsAcrossInterior() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        let third = AppItem(url: URL(fileURLWithPath: "/Applications/Third.app"))
        let fourth = AppItem(url: URL(fileURLWithPath: "/Applications/Fourth.app"))
        let group = AppGroup(name: "Folder", appPaths: [first.url.path, second.url.path])
        model.apps = [first, second, third, fourth]
        model.groups = [group]
        model.open(group)

        try require(
            model.dropInOpenGroup(third.id, page: 0, capacity: 9, slot: nil),
            "Dropping an external app on the open folder grid was not accepted"
        )
        try require(
            model.groups.first?.appPaths == [first.url.path, second.url.path, third.url.path],
            "Dropping an external app on the open folder grid did not add it to the folder"
        )

        try require(
            model.dropInOpenGroup(fourth.id, beside: second.id, after: false),
            "Dropping an external app on an open folder app tile was not accepted"
        )
        try require(
            model.groups.first?.appPaths == [
                first.url.path,
                fourth.url.path,
                second.url.path,
                third.url.path
            ],
            "Dropping an external app on an open folder app tile did not insert it into the folder"
        )
    }

    private static func externalFolderDropsHonorPageAndInsertionSlot() throws {
        let cases: [(page: Int, slot: Int?, insertion: Int)] = [
            (page: 0, slot: 0, insertion: 0),
            (page: 1, slot: 1, insertion: 4),
            (page: 0, slot: nil, insertion: 3)
        ]
        for drop in cases {
            let context = try makeDefaults()
            defer { context.defaults.removePersistentDomain(forName: context.domain) }
            let model = LauncherModel(defaults: context.defaults, autoScan: false)
            let apps = (0..<8).map { AppItem(url: URL(fileURLWithPath: "/Applications/ExternalDropApp\($0).app")) }
            let group = AppGroup(name: "Folder", appPaths: apps.prefix(7).map(\.url.path))
            let external = apps[7]
            model.apps = apps
            model.groups = [group]
            model.open(group)
            model.setFolderPageCount(3)
            model.setFolderPage(drop.page)
            model.updateFolderPagerLayout(
                origin: CGPoint(x: 200, y: 260), cellWidth: 140, columnCount: 3,
                capacity: 3, columnSpacing: 24, rowSpacing: 20, itemHeight: 120
            )
            model.startReorderDrag(external.id)
            if let slot = drop.slot {
                model.updateReorderDrag(localX: 201 + Double(slot) * 164, localYFromTop: 280)
                try require(
                    model.reorderPreview == LauncherReorderPreview(sourceID: external.id, page: drop.page, slot: slot),
                    "An external app did not preview its requested folder insertion slot"
                )
            }
            // The mouse-up timer may clear transient state before SwiftUI
            // delivers the drop with its own page and release coordinates.
            model.clearReorderDragState()
            try require(
                model.dropInOpenGroup(external.id, page: drop.page, capacity: 3, slot: drop.slot),
                "An external app drop was rejected after its transient preview cleared"
            )
            var expected = group.appPaths
            expected.insert(external.url.path, at: drop.insertion)
            try require(
                model.group(for: group.id)?.appPaths == expected,
                "An external app ignored its folder page/slot and appended at the global end"
            )
            let restored = LauncherModel(defaults: context.defaults, autoScan: false)
            try require(restored.group(for: group.id)?.appPaths == expected, "The external folder insertion order was not persisted")
        }
    }

    private static func openFolderAllowsMovingAppsOutToRootSlots() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        let loose = AppItem(url: URL(fileURLWithPath: "/Applications/Loose.app"))
        let group = AppGroup(name: "Folder", appPaths: [first.url.path, second.url.path])
        model.apps = [first, second, loose]
        model.groups = [group]
        model.rootOrder = ["group:" + group.id.uuidString, loose.id]
        model.open(group)

        try require(
            model.moveOutOfOpenGroupToSlot(second.id, page: 0, slot: 1, pageSize: 9),
            "Dropping a folder app onto the root grid was not accepted"
        )
        try require(
            model.rootEntries.map(\.id) == [first.id, second.id, loose.id],
            "A dissolved folder app did not land at the requested root slot"
        )
        try require(model.openGroupID == nil, "A dissolved folder stayed open after dragging an app out")

        let third = AppItem(url: URL(fileURLWithPath: "/Applications/Third.app"))
        let fourth = AppItem(url: URL(fileURLWithPath: "/Applications/Fourth.app"))
        let persistentGroup = AppGroup(
            name: "Folder",
            appPaths: [first.url.path, third.url.path, fourth.url.path]
        )
        model.apps = [first, third, fourth, loose, second]
        model.groups = [persistentGroup]
        model.rootOrder = [loose.id, "group:" + persistentGroup.id.uuidString, second.id]
        model.open(persistentGroup)

        try require(
            model.moveOutOfOpenGroupToSlot(third.id, page: 0, slot: 0, pageSize: 9),
            "Dropping a folder app before root entries was not accepted"
        )
        try require(
            model.rootEntries.map(\.id).prefix(3) == [
                third.id,
                loose.id,
                "group:" + persistentGroup.id.uuidString
            ],
            "A folder app dragged out did not insert at the requested root position"
        )
        try require(model.openGroupID == nil, "A successful root drop left its source folder open")
        try require(
            model.group(for: persistentGroup.id)?.appPaths == [first.url.path, fourth.url.path],
            "Closing the source folder after a root drop changed its remaining membership or order"
        )
    }

    private static func folderDragOutCanBeCancelledWithoutSavingMutations() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<3).map { AppItem(url: URL(fileURLWithPath: "/Applications/CancelApp\($0).app")) }
        let group = AppGroup(name: "Folder", appPaths: apps.prefix(2).map(\.url.path))
        let initialOrder = [apps[2].id, LauncherEntry.group(group).id]
        model.apps = apps
        model.groups = [group]
        model.rootOrder = initialOrder
        model.open(group)
        model.updateFolderPagerLayout(
            origin: CGPoint(x: 200, y: 260), cellWidth: 140, columnCount: 2,
            capacity: 6, columnSpacing: 24, rowSpacing: 20, itemHeight: 120,
            bandFrame: CGRect(x: 160, y: 220, width: 400, height: 440)
        )
        let savedGroups = context.defaults.data(forKey: "launcher.groups.v2")
        let savedOrder = context.defaults.stringArray(forKey: "launcher.order.v1")
        let now = Date()
        model.startReorderDrag(apps[0].id)
        model.updateReorderDrag(localX: 600, localYFromTop: 170, now: now)
        try require(model.openGroupID == group.id, "The folder closed immediately on crossing its edge")
        model.updateReorderDrag(localX: 200, localYFromTop: 260, now: now.addingTimeInterval(0.1))
        model.updateReorderDrag(localX: 600, localYFromTop: 170, now: now.addingTimeInterval(0.15))
        try require(model.openGroupID == group.id, "Re-entering the folder did not reset the exit dwell")
        model.updateReorderDrag(localX: 600, localYFromTop: 170, now: now.addingTimeInterval(0.4))

        try require(model.openGroupID == nil, "Hovering outside the folder did not reveal the root grid")
        try require(model.reorderDragSourceID == apps[0].id, "Closing the folder ended the live drag")
        try require(model.groups == [group] && model.rootOrder == initialOrder, "Hovering out mutated the layout before a drop")
        try require(
            context.defaults.data(forKey: "launcher.groups.v2") == savedGroups
                && context.defaults.stringArray(forKey: "launcher.order.v1") == savedOrder,
            "Hovering out saved an uncommitted layout"
        )

        model.clearReorderDragState()
        try require(model.reorderDragSourceID == nil && model.reorderPreview == nil, "Cancelling left a drag placeholder behind")
        let restored = LauncherModel(defaults: context.defaults, autoScan: false)
        restored.apps = apps
        try require(
            restored.groups == [group] && restored.rootEntries.map(\.id) == initialOrder,
            "Cancelling a drag out of a two-app folder changed its persisted membership or order"
        )
    }

    private static func folderDragOutCanInsertBeforeOrAfterRootEntries() throws {
        for after in [false, true] {
            let context = try makeDefaults()
            defer { context.defaults.removePersistentDomain(forName: context.domain) }
            let model = LauncherModel(defaults: context.defaults, autoScan: false)
            let apps = (0..<6).map { AppItem(url: URL(fileURLWithPath: "/Applications/InsertApp\($0).app")) }
            let group = AppGroup(name: "Folder", appPaths: apps.prefix(3).map(\.url.path))
            let groupID = LauncherEntry.group(group).id
            model.apps = apps
            model.groups = [group]
            model.rootOrder = [apps[3].id, groupID, apps[4].id, apps[5].id]
            model.open(group)
            model.startReorderDrag(apps[0].id)
            try require(model.continueReorderDragOutsideFolder(), "A folder drag could not continue on the root grid")
            try require(
                model.reorder(apps[0].id, beside: apps[4].id, after: after),
                "A dragged folder app was rejected by a root tile insertion target"
            )
            let expected = after
                ? [apps[3].id, groupID, apps[4].id, apps[0].id, apps[5].id]
                : [apps[3].id, groupID, apps[0].id, apps[4].id, apps[5].id]
            try require(model.rootEntries.map(\.id) == expected, "A folder app did not land on the requested side of the root target")
            try require(model.groups.first?.appPaths == [apps[1].url.path, apps[2].url.path], "Moving an app out changed the remaining folder order")
            try require(model.reorderDragSourceID == nil, "A committed root insertion left its drag session active")
            let restored = LauncherModel(defaults: context.defaults, autoScan: false)
            restored.apps = apps
            try require(restored.rootEntries.map(\.id) == expected, "The committed root insertion was not persisted")
        }
    }

    private static func folderDragOutDissolvesSourceAtOriginalPosition() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<5).map { AppItem(url: URL(fileURLWithPath: "/Applications/DissolveApp\($0).app")) }
        let group = AppGroup(name: "Folder", appPaths: apps.prefix(2).map(\.url.path))
        model.apps = apps
        model.groups = [group]
        model.rootOrder = [apps[2].id, LauncherEntry.group(group).id, apps[3].id, apps[4].id]
        model.open(group)
        model.startReorderDrag(apps[0].id)
        try require(model.continueReorderDragOutsideFolder(), "The two-app folder did not close for a continued drag")
        try require(model.groups == [group], "The two-app folder dissolved before the drop")
        try require(model.reorder(apps[0].id, beside: apps[3].id, after: true), "The two-app folder drop was rejected")
        try require(model.groups.isEmpty, "The source folder was not dissolved after its second app was removed")
        try require(
            model.rootEntries.map(\.id) == [apps[2].id, apps[1].id, apps[3].id, apps[0].id, apps[4].id],
            "Dissolving the source folder moved its remaining app away from the original folder position"
        )
    }

    private static func folderDragOutCanMoveAcrossRootPages() throws {
        for dropAtPageEnd in [false, true] {
            let context = try makeDefaults()
            defer { context.defaults.removePersistentDomain(forName: context.domain) }
            let model = LauncherModel(defaults: context.defaults, autoScan: false)
            let apps = (0..<10).map { AppItem(url: URL(fileURLWithPath: "/Applications/PageDropApp\($0).app")) }
            let group = AppGroup(name: "Folder", appPaths: apps.prefix(3).map(\.url.path))
            let originalOrder = [LauncherEntry.group(group).id] + apps.dropFirst(3).map(\.id)
            model.apps = apps
            model.groups = [group]
            model.rootOrder = originalOrder
            model.setPageCount(3)
            model.open(group)
            model.startReorderDrag(apps[0].id)
            try require(model.continueReorderDragOutsideFolder(), "The folder drag did not continue across pages")
            model.goToPage(1)
            let accepted = dropAtPageEnd
                ? model.reorderToPageEnd(apps[0].id, page: 1, pageSize: 3)
                : model.reorderToSlot(apps[0].id, page: 1, slot: 1, pageSize: 3)
            try require(accepted, "A folder app could not be dropped on a different root page")
            var expected = originalOrder
            expected.insert(apps[0].id, at: dropAtPageEnd ? 6 : 4)
            try require(model.rootEntries.map(\.id) == expected, "A cross-page drop appended to the global end instead of the requested page slot")
            try require(model.currentPage == 1 && model.displayedPage == 1, "A cross-page drop returned to the source page")
        }
    }

    private static func folderDragOutCanEnterAnotherFolder() throws {
        for dropIntoOpenFolder in [false, true] {
            let context = try makeDefaults()
            defer { context.defaults.removePersistentDomain(forName: context.domain) }
            let model = LauncherModel(defaults: context.defaults, autoScan: false)
            let apps = (0..<6).map { AppItem(url: URL(fileURLWithPath: "/Applications/TransferApp\($0).app")) }
            let source = AppGroup(name: "Source", appPaths: apps.prefix(2).map(\.url.path))
            let target = AppGroup(name: "Target", appPaths: [apps[2].url.path, apps[3].url.path])
            model.apps = apps
            model.groups = [source, target]
            model.rootOrder = [apps[4].id, LauncherEntry.group(source).id, LauncherEntry.group(target).id, apps[5].id]
            model.open(source)
            model.startReorderDrag(apps[0].id)
            try require(model.continueReorderDragOutsideFolder(), "A folder drag could not reach another folder")
            if dropIntoOpenFolder {
                model.open(target)
                try require(
                    model.dropInOpenGroup(apps[0].id, beside: apps[3].id, after: false),
                    "The open target folder rejected a dragged app from another folder"
                )
            } else {
                model.handleDrop(apps[0].id, on: .group(target))
            }
            let expectedPaths = dropIntoOpenFolder
                ? [apps[2].url.path, apps[0].url.path, apps[3].url.path]
                : [apps[2].url.path, apps[3].url.path, apps[0].url.path]
            try require(model.group(for: target.id)?.appPaths == expectedPaths, "The target folder did not retain the requested insertion order")
            try require(model.group(for: source.id) == nil, "Transferring an app left a one-app source folder behind")
            try require(
                model.rootEntries.map(\.id) == [apps[4].id, apps[1].id, LauncherEntry.group(target).id, apps[5].id],
                "Transferring an app moved the source folder's remaining app away from its original slot"
            )
        }
    }

    private static func folderDragOutCanCreateNewFolder() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<5).map { AppItem(url: URL(fileURLWithPath: "/Applications/MergeApp\($0).app")) }
        let source = AppGroup(name: "Source", appPaths: apps.prefix(2).map(\.url.path))
        model.apps = apps
        model.groups = [source]
        model.rootOrder = [apps[3].id, LauncherEntry.group(source).id, apps[2].id, apps[4].id]
        model.open(source)
        model.startReorderDrag(apps[0].id)
        try require(model.continueReorderDragOutsideFolder(), "A dragged folder app could not reach a root app")
        model.handleDrop(apps[0].id, on: .app(apps[2]))
        guard let created = model.groups.first(where: { $0.id != source.id }) else {
            throw QualityTestFailure(description: "Dropping a dragged folder app on a root app did not create a folder")
        }
        try require(model.group(for: source.id) == nil, "Creating a folder left a one-app source folder behind")
        try require(created.appPaths == [apps[2].url.path, apps[0].url.path], "The new folder did not preserve target-first order")
        try require(
            model.rootEntries.map(\.id) == [apps[3].id, apps[1].id, LauncherEntry.group(created).id, apps[4].id],
            "Creating a folder moved the source remainder or the target away from its original position"
        )
    }

    private static func stationaryDragPublishesOnlyChangedPreviews() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<5).map { AppItem(url: URL(fileURLWithPath: "/Applications/PreviewApp\($0).app")) }
        let group = AppGroup(name: "Folder", appPaths: apps.prefix(3).map(\.url.path))
        model.apps = apps
        model.groups = [group]
        model.rootOrder = [apps[3].id, LauncherEntry.group(group).id, apps[4].id]
        let size = CGSize(width: 1_000, height: 640)
        let metrics = LaunchpadLayoutMetrics.calculate(containerWidth: size.width, containerHeight: size.height, preferredIconSize: 92)
        let topOffset = 100.0
        model.updateRootPagerLayout(topOffset: topOffset, size: size, metrics: metrics, pageSize: metrics.capacity)
        model.open(group)
        model.startReorderDrag(apps[0].id)
        try require(model.continueReorderDragOutsideFolder(), "The folder drag did not reach the root preview")
        var publications: [LauncherReorderPreview?] = []
        let subscription = model.$reorderPreview.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel(); model.clearReorderDragState() }
        let firstSlotX = (size.width - metrics.gridWidth) / 2 + 1
        let y = topOffset + metrics.topInset + metrics.iconSize / 2

        for _ in 0..<30 { model.updateReorderDrag(localX: firstSlotX, localYFromTop: y) }
        try require(
            model.reorderPreview == LauncherReorderPreview(sourceID: apps[0].id, page: 0, slot: 0),
            "An app still belonging to its source folder did not receive a root insertion preview"
        )
        try require(publications.count == 1, "A stationary root drag repeatedly published the same preview")
        for _ in 0..<30 { model.updateReorderDrag(localX: firstSlotX + metrics.columnStride, localYFromTop: y) }
        try require(publications.count == 2 && model.reorderPreview?.slot == 1, "Changing root slots did not publish exactly one new preview")
        for _ in 0..<30 { model.updateReorderDrag(localX: firstSlotX, localYFromTop: 20) }
        try require(publications.count == 2 && model.reorderPreview?.slot == 1,
                    "Moving outside the grid collapsed or repeatedly invalidated the held insertion gap")

        model.clearReorderDragState()
        try require(publications.count == 3 && model.reorderPreview == nil, "Finishing the drag did not clear its held gap once")
        model.clearReorderDragState()
        try require(publications.count == 3, "Clearing an already-empty preview emitted another change")
        model.open(group)
        model.updateFolderPagerLayout(
            origin: CGPoint(x: 200, y: 260), cellWidth: 140, columnCount: 3,
            capacity: 9, columnSpacing: 24, rowSpacing: 20, itemHeight: 120
        )
        model.startReorderDrag(apps[0].id)
        for _ in 0..<30 { model.updateReorderDrag(localX: 201, localYFromTop: 280) }
        try require(publications.count == 4 && model.reorderPreview?.slot == 0, "A stationary folder drag repeatedly published the same preview")
        try require(model.groups == [group], "Insertion previews changed folder membership before dropping")
    }

    private static func hidingLauncherCancelsDragWithoutChangingLayout() throws {
        _ = NSApplication.shared
        for applicationDidHide in [false, true] {
            let context = try makeDefaults()
            defer { context.defaults.removePersistentDomain(forName: context.domain) }
            let model = LauncherModel(defaults: context.defaults, autoScan: false)
            let apps = (0..<3).map { AppItem(url: URL(fileURLWithPath: "/Applications/HideDragApp\($0).app")) }
            let group = AppGroup(name: "Folder", appPaths: apps.prefix(2).map(\.url.path))
            let order = [apps[2].id, LauncherEntry.group(group).id]
            model.apps = apps
            model.groups = [group]
            model.rootOrder = order
            let size = CGSize(width: 1_000, height: 640)
            let metrics = LaunchpadLayoutMetrics.calculate(containerWidth: size.width, containerHeight: size.height, preferredIconSize: 92)
            model.updateRootPagerLayout(topOffset: 100, size: size, metrics: metrics, pageSize: metrics.capacity)
            model.open(group)
            model.startReorderDrag(apps[0].id)
            try require(model.continueReorderDragOutsideFolder(), "The cancellation test could not begin a root drag")
            model.updateReorderDrag(
                localX: (size.width - metrics.gridWidth) / 2 + 1,
                localYFromTop: 100 + metrics.topInset + metrics.iconSize / 2
            )
            try require(model.reorderPreview != nil, "The cancellation test did not produce an active drag preview")
            if applicationDidHide { model.handleApplicationDidHide() }
            else { model.dismissLauncher(animated: false) }
            try require(
                model.reorderDragSourceID == nil && model.reorderPreview == nil,
                "Hiding the launcher left an active drag or insertion placeholder"
            )
            try require(model.groups == [group] && model.rootEntries.map(\.id) == order, "Hiding the launcher committed an unfinished drag")
            let restored = LauncherModel(defaults: context.defaults, autoScan: false)
            restored.apps = apps
            try require(
                restored.groups == [group] && restored.rootEntries.map(\.id) == order,
                "Hiding the launcher persisted an unfinished drag"
            )
        }
    }

    private static func folderRemovalMatchesNativeLifecycle() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        let third = AppItem(url: URL(fileURLWithPath: "/Applications/Third.app"))
        model.apps = [first, second, third]

        model.handleDrop(first.id, on: .app(second))
        guard let createdGroup = model.groups.first else {
            throw QualityTestFailure(description: "Folder creation failed")
        }
        model.addToOpenGroup(third.id)
        model.moveOutOfOpenGroup(first.id)
        try require(model.groups.first?.appPaths.count == 2, "A two-application folder was dissolved too early")
        try require(model.openGroupID == createdGroup.id, "A valid folder was closed too early")

        model.moveOutOfOpenGroup(second.id)
        try require(model.groups.isEmpty, "The folder was not dissolved when one application remained")
        try require(model.openGroupID == nil, "The dissolved folder remained open")
        try require(
            Set(model.rootEntries.map(\.id)) == Set([first.id, second.id, third.id]),
            "Dissolving the folder lost an application"
        )
    }

    private static func folderRenameControlsPersistExplicitly() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        model.apps = [first, second]
        let group = AppGroup(name: "Folder", appPaths: [first.url.path, second.url.path])
        model.groups = [group]

        _ = NSApplication.shared
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        parentWindow.makeKeyAndOrderFront(nil)
        defer { parentWindow.orderOut(nil) }

        let coordinator = FolderRenamePanelCoordinator()
        coordinator.present(
            groupID: group.id,
            currentName: group.name,
            model: model,
            parentWindow: parentWindow
        )
        await Task.yield()
        guard let savePanel = coordinator.activePanel,
              let saveField = coordinator.activeTextField else {
            throw QualityTestFailure(description: "The native folder rename panel did not open")
        }
        try require(savePanel.isVisible, "The folder rename panel was not visible")
        try require(saveField.stringValue == "Folder", "The rename panel did not show the current name")
        saveField.stringValue = "Projects"
        coordinator.saveRename()
        await Task.yield()

        try require(model.group(for: group.id)?.name == "Projects", "The edited folder name was not applied")
        try require(!coordinator.isPresenting, "The rename panel remained open after saving")
        try require(coordinator.activePanel == nil, "The saved rename panel was retained")

        guard let savedData = context.defaults.data(forKey: "launcher.groups.v2"),
              let savedGroup = try JSONDecoder().decode([AppGroup].self, from: savedData).first else {
            throw QualityTestFailure(description: "The explicitly saved folder name was not persisted")
        }
        try require(savedGroup.name == "Projects", "The persisted folder name did not match the edit")

        coordinator.present(
            groupID: group.id,
            currentName: savedGroup.name,
            model: model,
            parentWindow: parentWindow
        )
        await Task.yield()
        guard coordinator.activePanel != nil,
              let cancelField = coordinator.activeTextField else {
            throw QualityTestFailure(description: "The cancel rename panel did not open")
        }
        cancelField.stringValue = "Discarded"
        coordinator.cancelRename()
        await Task.yield()

        try require(model.group(for: group.id)?.name == "Projects", "Cancel unexpectedly changed the folder name")
        try require(!coordinator.isPresenting, "The rename panel remained open after cancelling")

        coordinator.present(
            groupID: group.id,
            currentName: savedGroup.name,
            model: model,
            parentWindow: parentWindow
        )
        guard let blankField = coordinator.activeTextField else {
            throw QualityTestFailure(description: "The blank-name rename panel did not open")
        }
        blankField.stringValue = "   "
        coordinator.saveRename()
        try require(
            model.group(for: group.id)?.name == model.text("Folder", "フォルダ", "資料夾"),
            "A blank folder name did not use the localized fallback"
        )
    }

    private static func pageNavigationHandlesIntegerBoundaries() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.setPageCount(3)
        model.changePage(by: Int.max)
        try require(model.currentPage == 2, "Positive page overflow was not clamped")
        model.changePage(by: Int.min)
        try require(model.currentPage == 0, "Negative page overflow was not clamped")

        model.setFolderPageCount(4)
        model.openGroupID = UUID()
        model.navigateVisiblePages(by: Int.max)
        try require(model.folderPager.page == 3, "Positive folder-page overflow was not clamped")
        model.navigateVisiblePages(by: Int.min)
        try require(model.folderPager.page == 0, "Negative folder-page overflow was not clamped")
    }

    private static func pageNavigationDoesNotRestoreStaleDestinations() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.setPageCount(3)

        for page in [1, 2, 0, 2] {
            model.goToPage(page)
            try require(
                model.currentPage == page && model.displayedPage == page,
                "Rapid page navigation delayed the visible destination"
            )
        }

        model.search = "Find an application"
        try await Task.sleep(for: .milliseconds(180))
        try require(
            model.currentPage == 0 && model.displayedPage == 0,
            "An old page transition restored its destination after starting a search"
        )

        model.search = ""
        model.goToPage(2)
        model.setPageCount(1)
        try await Task.sleep(for: .milliseconds(180))
        try require(
            model.currentPage == 0 && model.displayedPage == 0,
            "An old page transition restored an out-of-range page after the page count shrank"
        )
    }

    private static func folderNavigationDoesNotRestoreStaleDestinations() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        let apps = (0..<20).map { AppItem(url: URL(fileURLWithPath: "/Applications/FolderApp\($0).app")) }
        let group = AppGroup(name: "Folder", appPaths: apps.map(\.url.path))
        model.apps = apps
        model.groups = [group]
        model.open(group)
        model.setFolderPageCount(3)

        for page in [1, 2, 0, 2] {
            model.goToFolderPage(page)
            try require(
                model.folderPager.page == page && model.folderPager.displayedPage == page,
                "Rapid folder navigation delayed the visible destination"
            )
        }

        model.setFolderPageCount(1)
        try await Task.sleep(for: .milliseconds(180))
        try require(
            model.folderPager.page == 0 && model.folderPager.displayedPage == 0,
            "An old folder transition restored an out-of-range page after the page count shrank"
        )

        model.setFolderPageCount(3)
        model.goToFolderPage(2)
        model.closeFolder()
        try await Task.sleep(for: .milliseconds(180))
        try require(
            model.openGroupID == nil && model.folderPager.page == 0 && model.folderPager.displayedPage == 0,
            "An old folder transition restored a destination after closing the folder"
        )
    }

    private static func modalUIBlocksBackgroundPageNavigation() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.setPageCount(3)

        model.showLauncherSettings = true
        model.navigateVisiblePages(by: 1)
        try require(model.currentPage == 0, "The page moved behind the launcher settings popover")
        model.showLauncherSettings = false

        model.pendingDeleteApp = AppItem(url: URL(fileURLWithPath: "/Applications/Delete.app"))
        model.navigateVisiblePages(by: 1)
        try require(model.currentPage == 0, "The page moved behind the delete confirmation")
        model.pendingDeleteApp = nil

        model.errorMessage = "Test"
        model.navigateVisiblePages(by: 1)
        try require(model.currentPage == 0, "The page moved behind an error alert")
        model.errorMessage = nil

        model.navigateVisiblePages(by: 1)
        try require(model.currentPage == 1, "Page navigation did not resume after modal UI closed")
    }

    private static func launcherWindowAcceptsKeyboardFocus() throws {
        let window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        LauncherWindowPresentation.configureChrome(of: window)

        try require(window.canBecomeKey, "The full-screen launcher window cannot accept keyboard focus")
        try require(window.canBecomeMain, "The full-screen launcher window cannot become the main window")
        try require(window.styleMask == .borderless, "The launcher window unexpectedly displays title-bar chrome")
        try require(window.toolbar == nil, "The launcher window unexpectedly displays a toolbar")
        try require(window.isOpaque, "The launcher window can expose an unpainted frame during startup")
        try require(
            window.backgroundColor == LauncherWindowPresentation.initialBackgroundColor,
            "The launcher window does not have a stable startup background"
        )
    }

    private static func quitShortcutRequiresCommandQ() throws {
        try require(
            LauncherKeyboardCommand.isQuit(characters: "q", modifierFlags: .command),
            "Command-Q was not recognized as the quit shortcut"
        )
        try require(
            LauncherKeyboardCommand.isQuit(characters: "Q", modifierFlags: .command),
            "Uppercase Command-Q was not recognized as the quit shortcut"
        )
        try require(
            !LauncherKeyboardCommand.isQuit(characters: "q", modifierFlags: []),
            "Plain Q unexpectedly triggered the quit shortcut"
        )
        try require(
            !LauncherKeyboardCommand.isQuit(
                characters: "q",
                modifierFlags: [.command, .shift]
            ),
            "Command-Shift-Q unexpectedly triggered the quit shortcut"
        )
    }

    private static func dismissMotionMatchesReferenceApplication() throws {
        try require(
            abs(LaunchpadDismissMotion.duration - 0.25) < 0.000_1,
            "The launcher dismissal duration no longer matches the reference application"
        )
        try require(
            abs(LaunchpadDismissMotion.scale - 1.10) < 0.000_1,
            "The launcher dismissal scale no longer matches the reference application"
        )
        try require(
            LaunchpadDismissMotion.shouldAnimate(
                requested: true,
                applicationIsActive: true,
                reduceMotion: false,
                windowIsVisible: true
            ),
            "A visible active launcher did not enable its dismissal animation"
        )
        try require(
            !LaunchpadDismissMotion.shouldAnimate(
                requested: true,
                applicationIsActive: true,
                reduceMotion: true,
                windowIsVisible: true
            ),
            "Reduce Motion did not suppress the dismissal animation"
        )
        try require(
            !LaunchpadDismissMotion.shouldAnimate(
                requested: true,
                applicationIsActive: false,
                reduceMotion: false,
                windowIsVisible: true
            ),
            "An inactive launcher attempted to animate its dismissal"
        )
    }

    private static func referenceIconSizingMatchesAttachedApp() throws {
        try require(
            LauncherModel.referenceDefaultIconSize(pageWidth: 1_000) == 72,
            "Reference icon size did not honor its 72-point minimum"
        )
        try require(
            LauncherModel.referenceDefaultIconSize(pageWidth: 1_440) == 90,
            "The 1440-point Sequoia reference did not use a 90-point icon canvas"
        )
        try require(
            abs(LauncherModel.referenceDefaultIconSize(pageWidth: 1_430) - 89.375) < 0.001,
            "Reference icon size did not preserve the measured screen-width proportion"
        )
        try require(
            LauncherModel.referenceDefaultIconSize(pageWidth: 1_800) == 112,
            "Reference icon size did not honor its 112-point maximum"
        )

        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        try require(model.iconSize == 90, "A fresh install did not start with the Sequoia reference icon size")
        model.applyReferenceDefaultIconSize(pageWidth: 1_440)
        try require(model.iconSize == 90, "The reference screen size changed the measured icon canvas")
        model.applyReferenceDefaultIconSize(pageWidth: 1_800)
        try require(model.iconSize == 112, "Automatic icon sizing did not respect its upper limit")
        model.setIconSize(80)
        model.applyReferenceDefaultIconSize(pageWidth: 1_000)
        try require(model.iconSize == 80, "A saved user icon size was overwritten by the automatic default")

        let legacyContext = try makeDefaults()
        defer { legacyContext.defaults.removePersistentDomain(forName: legacyContext.domain) }
        legacyContext.defaults.set(96, forKey: "iconSize")
        let migratedModel = LauncherModel(defaults: legacyContext.defaults, autoScan: false)
        try require(migratedModel.iconSize == 112, "The previous 96-point maximum was not migrated to 112 points")
    }

    private static func systemLanguageResolvesFinderStyleLocalizationOrder() throws {
        // Hong Kong Traditional Chinese system: HK names outrank TW names.
        let hkCandidates = LauncherFileScanner.localizationCandidates(
            languageSetting: "system",
            preferredLanguages: ["zh-Hant-HK", "yue-Hant-HK", "ja-HK"]
        )
        try require(
            hkCandidates.first == "zh-Hant-HK" && hkCandidates.contains("zh_HK"),
            "The HK system order did not start with Hong Kong localizations"
        )
        try require(
            (hkCandidates.firstIndex(of: "zh_HK") ?? .max) < (hkCandidates.firstIndex(of: "zh_TW") ?? .min),
            "The HK system order preferred Taiwan names over Hong Kong names"
        )
        try require(hkCandidates.contains("ja"), "The system order dropped secondary preferences")
        try require(hkCandidates.last == "en", "The system order lacked an English fallback")

        // Taiwan / generic Traditional Chinese.
        let twCandidates = LauncherFileScanner.localizationCandidates(
            languageSetting: "system",
            preferredLanguages: ["zh-TW", "en"]
        )
        try require(
            (twCandidates.firstIndex(of: "zh-Hant") ?? .max) < (twCandidates.firstIndex(of: "zh_TW") ?? .min),
            "The TW system order did not prefer generic Traditional Chinese first"
        )

        // Simplified Chinese system follows simplified localizations.
        let hansCandidates = LauncherFileScanner.localizationCandidates(
            languageSetting: "system",
            preferredLanguages: ["zh-Hans-CN"]
        )
        try require(
            hansCandidates.contains("zh_CN") && !hansCandidates.contains("zh_TW"),
            "The Simplified Chinese system order leaked Traditional localizations"
        )

        // Explicit settings override the system list.
        let explicit = LauncherFileScanner.localizationCandidates(
            languageSetting: "zh-Hant",
            preferredLanguages: ["en"]
        )
        try require(
            explicit.first == "zh-Hant" && !explicit.contains(where: { $0 == "en" && explicit.firstIndex(of: "en") == 0 }),
            "The explicit language order did not take precedence"
        )

        // Any other system language still resolves generically.
        let french = LauncherFileScanner.localizationCandidates(
            languageSetting: "system",
            preferredLanguages: ["fr-FR"]
        )
        try require(
            french.contains("fr-fr") && french.contains("fr"),
            "The generic system language order was not derived from the preference"
        )
    }

    private static func rootGridUsesAvailableScreenSpace() throws {
        // The 2880 × 1800 reference image is a 1440 × 900 point desktop;
        // its root pager begins 50 points below the top of the display.
        let screenshotLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_440,
            containerHeight: 850,
            preferredIconSize: 90
        )
        try require(screenshotLayout.columns == 7, "The Sequoia reference layout did not use seven columns")
        try require(screenshotLayout.rows == 5, "The reference layout did not keep five rows")
        try require(screenshotLayout.capacity == 35, "The Sequoia root page did not hold 35 icons")
        try require(screenshotLayout.iconSize == 90, "The measured icon canvas was not preserved")
        let firstColumnCenter = (1_440 - screenshotLayout.gridWidth) / 2 + screenshotLayout.cellWidth / 2
        try require(abs(firstColumnCenter - 180) < 0.001, "The first icon column missed its measured 180-point centre")
        try require(abs(screenshotLayout.columnStride - 180) < 0.001, "The reference column spacing did not match Sequoia")
        try require(abs(screenshotLayout.rowStride - 138) < 0.001, "The reference row spacing did not match Sequoia")
        try require(abs(screenshotLayout.topInset + 50 - 72) < 0.001, "The first icon row missed its measured 72-point top edge")
        try require(
            abs(firstColumnCenter + Double(screenshotLayout.columns - 1) * screenshotLayout.columnStride - 1_260) < 0.001,
            "The last icon column was not symmetric with the first"
        )
        try require(
            screenshotLayout.topInset + screenshotLayout.gridHeight + LaunchpadLayoutMetrics.bottomReserve <= 850,
            "The reference grid encroached on its page-indicator and Dock reserve"
        )

        let compactLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 760,
            containerHeight: 472,
            preferredIconSize: 112
        )
        try require(compactLayout.columns == 3, "The compact layout did not reduce its column count")
        try require(compactLayout.rows == 2, "The compact layout did not reduce its row count")
        try require(
            compactLayout.columnStride >= compactLayout.cellWidth + 12
                && compactLayout.rowStride >= compactLayout.cellHeight + 12
                && compactLayout.gridWidth <= 760,
            "Compact geometry overlapped icon cells or clipped its horizontal grid"
        )
        try require(
            compactLayout.topInset + compactLayout.gridHeight + LaunchpadLayoutMetrics.bottomReserve <= 472,
            "The compact root grid overflowed its page"
        )

        let extremeLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: .greatestFiniteMagnitude,
            containerHeight: .greatestFiniteMagnitude,
            preferredIconSize: .greatestFiniteMagnitude
        )
        try require(extremeLayout.capacity == 35, "Extreme root geometry did not remain bounded to seven columns and five rows")

        // Sequoia retains seven columns on larger displays. Their spacing may
        // grow, but unusually wide monitors must not add extra app columns.
        let laptopLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_512,
            containerHeight: 868,
            preferredIconSize: 92
        )
        let wideLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 4_096,
            containerHeight: 1_300,
            preferredIconSize: 92
        )
        try require(
            laptopLayout.columns == 7 && wideLayout.columns == 7,
            "A larger display changed the native seven-column arrangement"
        )
        try require(
            wideLayout.columnStride > laptopLayout.columnStride,
            "A larger display did not distribute its seven columns across the available width"
        )
        try require(
            wideLayout.gridWidth <= LaunchpadLayoutMetrics.maximumGridWidth + 0.001,
            "The wide-screen grid exceeded its maximum width"
        )
        let invalidLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: .nan,
            containerHeight: .infinity,
            preferredIconSize: .nan
        )
        try require(
            invalidLayout.capacity == 35 && invalidLayout.iconSize == 90
                && invalidLayout.gridWidth.isFinite && invalidLayout.gridHeight.isFinite,
            "Invalid root geometry did not fall back to a usable Sequoia layout"
        )
    }

    private static func folderGridMetricsNeverOverflowTheirPanel() throws {
        let base = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_440,
            containerHeight: 850,
            preferredIconSize: 90
        )
        let singleRowLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 2,
            rowLimit: 3
        )
        try require(singleRowLayout.columns == 7, "A sparse folder compressed the native seven-column grid")
        try require(singleRowLayout.rows == 1, "A two-application folder kept unused rows")
        try require(singleRowLayout.capacity == 7, "The single-row folder capacity was incorrect")
        try require(folderGridFits(singleRowLayout, base: base), "The single-row folder grid overflowed")
        let singleAppLayout = LaunchpadLayoutMetrics.folderContent(base: base, itemCount: 1, rowLimit: 5)
        try require(
            singleAppLayout.gridWidth == singleRowLayout.gridWidth && singleAppLayout.rows == 1,
            "A one-app folder shrank its panel or changed its column positions"
        )

        let smallFolderLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 4,
            rowLimit: 3
        )
        try require(smallFolderLayout.columns == 7, "The small folder did not preserve seven columns")
        try require(smallFolderLayout.rows == 1, "Four apps wrapped before the native row was full")
        try require(folderGridFits(smallFolderLayout, base: base), "The small folder grid overflowed")
        let twoRowLayout = LaunchpadLayoutMetrics.folderContent(base: base, itemCount: 8, rowLimit: 5)
        try require(twoRowLayout.rows == 2 && twoRowLayout.capacity == 14, "The eighth folder app did not start the second row")
        try require(
            twoRowLayout.columnStride == base.columnStride && twoRowLayout.rowStride == base.rowStride,
            "Folder icon positions did not reuse the root's measured spacing"
        )

        let multiPageLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 50,
            rowLimit: 5
        )
        try require(
            multiPageLayout.columns == base.columns,
            "The large folder did not reuse the root column count"
        )
        try require(multiPageLayout.rows == 5, "The large folder did not fit the native five rows")
        try require(
            multiPageLayout.capacity == 35 && multiPageLayout.pageCount(forItemCount: 50) == 2,
            "The large folder did not page after its thirty-fifth icon"
        )
        try require(
            multiPageLayout.gridHeight > singleRowLayout.gridHeight,
            "Folder grid height did not grow with its application count"
        )
        try require(folderGridFits(multiPageLayout, base: base), "The large folder grid overflowed")

        let compactBase = LaunchpadLayoutMetrics.calculate(
            containerWidth: 760,
            containerHeight: 540,
            preferredIconSize: 96
        )
        let compactLayout = LaunchpadLayoutMetrics.folderContent(
            base: compactBase,
            itemCount: 20,
            rowLimit: 2
        )
        try require(compactLayout.rows == 2, "A compact folder ignored its row limit")
        try require(
            compactLayout.columns == compactBase.columns
                && compactLayout.columnStride >= compactLayout.cellWidth + 12
                && compactLayout.rowStride >= compactLayout.cellHeight + 12,
            "Compact folder cells overlapped or departed from the root's available columns"
        )
        try require(
            compactLayout.pageCount(forItemCount: 20) >= 3,
            "The compact folder page count was incorrect"
        )
        try require(folderGridFits(compactLayout, base: compactBase), "The compact folder grid overflowed")

        let invalidLayout = LaunchpadLayoutMetrics.folderContent(
            base: LaunchpadLayoutMetrics.calculate(
                containerWidth: .nan,
                containerHeight: .nan,
                preferredIconSize: .nan
            ),
            itemCount: 0,
            rowLimit: 3
        )
        try require(invalidLayout.capacity > 0, "Invalid geometry produced an unusable folder capacity")

        let extremeLayout = LaunchpadLayoutMetrics.folderContent(
            base: LaunchpadLayoutMetrics.calculate(
                containerWidth: .greatestFiniteMagnitude,
                containerHeight: .greatestFiniteMagnitude,
                preferredIconSize: .greatestFiniteMagnitude
            ),
            itemCount: Int.max,
            rowLimit: 3
        )
        try require(
            extremeLayout.columns <= LaunchpadLayoutMetrics.maximumColumns,
            "Extreme geometry was not safely bounded"
        )
        try require(folderGridFits(extremeLayout, base: extremeLayout), "Extreme geometry overflowed")
    }

    private static func folderGridFits(
        _ metrics: LaunchpadLayoutMetrics,
        base: LaunchpadLayoutMetrics
    ) -> Bool {
        let expectedWidth = Double(metrics.columns) * base.cellWidth
            + Double(metrics.columns - 1) * base.horizontalSpacing
        let expectedHeight = Double(metrics.rows) * base.cellHeight
            + Double(metrics.rows - 1) * base.verticalSpacing
        return metrics.gridWidth <= expectedWidth + 0.001
            && metrics.gridHeight <= expectedHeight + 0.001
            && metrics.columns <= base.columns
    }

    private static func pageWindowLimitsRenderedPages() throws {
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: 50, pageCount: 100) == [49, 50, 51],
            "The pager rendered more than the adjacent pages"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: 0, pageCount: 100) == [0, 1],
            "The first page window was incorrect"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: 99, pageCount: 100) == [98, 99],
            "The final page window was incorrect"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: Int.max, pageCount: 0) == [0],
            "Invalid page state was not clamped safely"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: 1, pageCount: 3, reduceMotion: true) == [1],
            "Reduce Motion left transparent neighboring pages mounted as native drop targets"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: 0, pageCount: 3, reduceMotion: true) == [0]
                && LaunchpadPageMotion.visiblePages(currentPage: 2, pageCount: 3, reduceMotion: true) == [2],
            "Reduce Motion rendered an invisible page at a pagination boundary"
        )
        try require(
            LaunchpadPageMotion.visiblePages(currentPage: Int.max, pageCount: 0, reduceMotion: true) == [0],
            "Reduce Motion did not clamp an invalid page safely"
        )
    }

    private static func scannerGracefullyHandlesMissingRoots() throws {
        let missingRoot = URL(fileURLWithPath: "/tmp/launcherx-missing-\(UUID().uuidString)")
        let result = LauncherFileScanner.scanApplications(in: [missingRoot])
        try require(result.apps.isEmpty, "Missing scan root produced applications")
        try require(result.accessibleRootCount == 0, "Missing scan root was marked accessible")
    }

    private static func scannerFindsApplicationLinksWithoutDuplicates() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("launcherx-symlink-scan-\(UUID().uuidString)", isDirectory: true)
        let applicationsRoot = temporaryRoot.appendingPathComponent("Applications", isDirectory: true)
        let utilitiesRoot = applicationsRoot.appendingPathComponent("Utilities", isDirectory: true)
        let systemRoot = temporaryRoot.appendingPathComponent("SystemApps", isDirectory: true)
        let realSafari = systemRoot.appendingPathComponent("Safari.app", isDirectory: true)
        let realFeedback = systemRoot.appendingPathComponent("Feedback Assistant.app", isDirectory: true)
        let linkedSafari = applicationsRoot.appendingPathComponent("Safari.app", isDirectory: true)
        let linkedFeedback = utilitiesRoot.appendingPathComponent("Feedback Assistant.app", isDirectory: true)

        try fileManager.createDirectory(at: utilitiesRoot, withIntermediateDirectories: true)
        try createTestApplication(at: realSafari, identifier: "com.example.Safari")
        try createTestApplication(at: realFeedback, identifier: "com.example.FeedbackAssistant")
        try fileManager.createSymbolicLink(at: linkedSafari, withDestinationURL: realSafari)
        try fileManager.createSymbolicLink(at: linkedFeedback, withDestinationURL: realFeedback)
        defer {
            do {
                try fileManager.removeItem(at: temporaryRoot)
            } catch {
                FileHandle.standardError.write(
                    Data("Could not remove scanner test directory: \(error.localizedDescription)\n".utf8)
                )
            }
        }

        let result = LauncherFileScanner.scanApplications(in: [applicationsRoot, systemRoot])
        let discoveredPaths = Set(result.apps.map { $0.url.standardizedFileURL.path })
        try require(result.apps.count == 2, "Linked and resolved applications were not deduplicated")
        try require(
            discoveredPaths == Set([linkedSafari.standardizedFileURL.path, linkedFeedback.standardizedFileURL.path]),
            "Top-level or nested symbolic-link applications were not retained as visible launch URLs"
        )
        try require(
            result.apps.allSatisfy { !$0.isDeletable },
            "Synthetic linked applications were incorrectly made deletable"
        )

        let standardRoots = LauncherFileScanner.applicationRoots(homeDirectory: fileManager.homeDirectoryForCurrentUser)
            .map(\.standardizedFileURL.path)
        try require(
            standardRoots.contains("/System/Library/CoreServices/Applications"),
            "CoreServices applications are missing from the standard scan roots"
        )
        try require(
            standardRoots.contains("/System/Cryptexes/App/System/Applications"),
            "Cryptex applications are missing from the standard scan roots"
        )

        let installedSafari = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        if fileManager.fileExists(atPath: installedSafari.path) {
            let installedApps = LauncherFileScanner.scanApplications(
                in: LauncherFileScanner.applicationRoots(
                    homeDirectory: fileManager.homeDirectoryForCurrentUser
                )
            )
            try require(
                installedApps.apps.contains(where: {
                    Bundle(url: $0.url)?.bundleIdentifier == "com.apple.Safari"
                }),
                "The installed Safari application was not discovered"
            )
        }
    }

    private static func sequoiaUtilitiesAreGroupedWithoutOverwritingUserFolders() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        context.defaults.set(true, forKey: "launcher.defaultGroups.v1")

        let activityMonitor = AppItem(
            url: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            bundleIdentifier: "com.apple.ActivityMonitor"
        )
        let keychainAccess = AppItem(
            url: URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app"),
            bundleIdentifier: "com.apple.keychainaccess"
        )
        let thirdPartyUtility = AppItem(
            url: URL(fileURLWithPath: "/Applications/Utilities/Third Party.app"),
            bundleIdentifier: "com.example.utility"
        )
        let customGroup = AppGroup(name: "Security", appPaths: [keychainAccess.url.path])
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.apps = [activityMonitor, keychainAccess, thirdPartyUtility]
        model.groups = [customGroup]

        model.reconcileSequoiaUtilitiesIfNeeded()

        try require(
            LaunchpadStandardUtilities.contains(activityMonitor),
            "A standard Apple utility was not recognized"
        )
        try require(
            LaunchpadStandardUtilities.contains(keychainAccess),
            "A relocated Sequoia utility was not recognized by bundle identifier"
        )
        try require(
            !LaunchpadStandardUtilities.contains(thirdPartyUtility),
            "A third-party application was incorrectly classified as a standard utility"
        )
        try require(
            model.groups.first(where: { $0.systemKind == "utilities" })?.appPaths
                == [activityMonitor.url.path],
            "The default Utilities folder did not receive the ungrouped standard utility"
        )
        try require(
            model.group(for: customGroup.id)?.appPaths == [keychainAccess.url.path],
            "The Utilities migration moved an application out of a user folder"
        )

        model.reconcileSequoiaUtilitiesIfNeeded()
        try require(
            model.groups.filter { $0.systemKind == "utilities" }.count == 1,
            "The Utilities migration was not idempotent"
        )
    }

    private static func automaticUpdateConfigurationIsSecureAndEnabled() throws {
        let infoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let info = object as? [String: Any] else {
            throw QualityTestFailure(description: "Info.plist is not a dictionary")
        }
        guard let feedValue = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feedValue),
              feedURL.scheme == "https",
              feedURL.host == "raw.githubusercontent.com" else {
            throw QualityTestFailure(description: "The update feed is not a trusted HTTPS GitHub URL")
        }
        guard let publicKey = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32 else {
            throw QualityTestFailure(description: "The Sparkle public signing key is invalid")
        }
        try require(
            info["SUEnableAutomaticChecks"] as? Bool == true,
            "Automatic update checks are disabled"
        )
        try require(
            info["SUAutomaticallyUpdate"] as? Bool == true,
            "Automatic update installation is disabled"
        )
    }

    private static func createTestApplication(at url: URL, identifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private static func preparedModelRunsInitialReadinessHandler() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        var callbackCount = 0

        model.whenInitialContentIsReady {
            callbackCount += 1
        }

        try require(model.isInitialContentReady, "A preconfigured model was not ready for presentation")
        try require(callbackCount == 1, "A ready model did not present exactly once")
    }

    private static func initialPresentationPreloadsInstalledApplications() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: true)
        defer { model.shutdown() }
        var callbackCount = 0
        model.whenInitialContentIsReady {
            callbackCount += 1
        }

        for _ in 0..<400 where !model.isInitialContentReady {
            try await Task.sleep(for: .milliseconds(50))
        }

        try require(model.isInitialContentReady, "Initial launcher content did not finish preloading")
        try require(!model.apps.isEmpty, "Initial launcher preparation did not discover installed applications")
        try require(callbackCount == 1, "Initial launcher readiness was delivered more than once")
    }

    private static func applicationMonitorDetectsDirectoryChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcherx-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                FileHandle.standardError.write(
                    Data("Could not remove application monitor test directory: \(error.localizedDescription)\n".utf8)
                )
            }
        }

        var notificationCount = 0
        var detectedApps: [AppItem] = []
        let monitor = LauncherApplicationMonitor(
            roots: [root, root],
            debounceInterval: .milliseconds(50)
        ) {
            notificationCount += 1
            detectedApps = LauncherFileScanner.scanApplications(in: [root]).apps
        }
        monitor.start()
        defer { monitor.stop() }

        try require(monitor.monitoredRootCount == 1, "Duplicate application roots were monitored more than once")
        let installedApp = root.appendingPathComponent("Newly Installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installedApp, withIntermediateDirectories: true)

        for _ in 0..<40 where notificationCount == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(notificationCount == 1, "A newly installed application did not trigger an automatic refresh")
        try require(
            detectedApps.contains(where: { $0.url.standardizedFileURL == installedApp.standardizedFileURL }),
            "A newly installed application was not discovered by the automatic refresh"
        )

        notificationCount = 0
        try FileManager.default.removeItem(at: installedApp)
        for _ in 0..<40 where notificationCount == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(notificationCount == 1, "Removing an application did not trigger an automatic refresh")
        try require(detectedApps.isEmpty, "A removed application remained in the automatic refresh result")
    }

    private static func memoryPolicyKeepsCachesBounded() throws {
        try require(LauncherMemoryPolicy.iconPixelSize <= 256, "Application icons use more pixels than required")
        try require(
            LauncherMemoryPolicy.iconLogicalPointSize * 2 == LauncherMemoryPolicy.iconPixelSize,
            "Application icons are not represented at Retina density"
        )
        try require(LauncherMemoryPolicy.iconDataCacheCount <= 48, "Too many encoded icons can remain cached")
        try require(LauncherMemoryPolicy.iconImageCacheCount <= 48, "Too many decoded icons can remain cached")
        try require(LauncherMemoryPolicy.backgroundCacheCount == 1, "Multiple full-size backgrounds can remain cached")
        try require(LauncherMemoryPolicy.backgroundMaximumPixelSize <= 1_536, "Blurred background decoding is insufficiently bounded")
        try require(
            LauncherMemoryPolicy.maximumPersistentCacheCost <= 37 * 1_024 * 1_024,
            "Persistent image caches can exceed the memory budget"
        )
    }

    private static func imageLoadersHandleMissingFiles() async throws {
        let missingApp = URL(fileURLWithPath: "/tmp/launcherx-missing-\(UUID().uuidString).app")
        guard let missingIconData = await LauncherIconLoader().iconData(for: missingApp),
              let icon = NSImage(data: missingIconData) else {
            throw QualityTestFailure(description: "Missing app path did not return safe icon data")
        }
        try require(icon.size.width > 0 && icon.size.height > 0, "Missing app path did not return a safe placeholder icon")
        let expectedIconSize = NSSize(
            width: LauncherMemoryPolicy.iconLogicalPointSize,
            height: LauncherMemoryPolicy.iconLogicalPointSize
        )
        try require(icon.size == expectedIconSize, "The app icon was not normalized for stable rendering")
        var missingIconRect = NSRect(origin: .zero, size: icon.size)
        guard let missingIconCGImage = icon.cgImage(
            forProposedRect: &missingIconRect,
            context: nil,
            hints: nil
        ) else {
            throw QualityTestFailure(description: "The normalized placeholder icon had no pixel data")
        }
        try require(
            missingIconCGImage.width == LauncherMemoryPolicy.iconPixelSize
                && missingIconCGImage.height == LauncherMemoryPolicy.iconPixelSize,
            "The normalized placeholder icon lost its Retina pixel density"
        )

        let fakeApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcherx-icon-\(UUID().uuidString).app", isDirectory: true)
        let contents = fakeApp.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: fakeApp)
            } catch {
                FileHandle.standardError.write(
                    Data("Could not remove test app: \(error.localizedDescription)\n".utf8)
                )
            }
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIconFile": "AppIcon.png"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        guard let testIconData = makeTestIconData() else {
            throw QualityTestFailure(description: "Could not create a test app icon")
        }
        try testIconData.write(
            to: resources.appendingPathComponent("AppIcon.png"),
            options: .atomic
        )
        guard let bundleIconData = await LauncherIconLoader().iconData(for: fakeApp),
              let bundleIcon = NSImage(data: bundleIconData) else {
            throw QualityTestFailure(description: "The bundle icon data could not be decoded")
        }
        try require(
            bundleIcon.size == expectedIconSize,
            "A bundle icon was not normalized for stable rendering"
        )
        var proposedRect = NSRect(origin: .zero, size: bundleIcon.size)
        guard let bundleCGImage = bundleIcon.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ),
        let bundlePixels = bundleCGImage.dataProvider?.data as Data? else {
            throw QualityTestFailure(description: "The normalized bundle icon had no pixel data")
        }
        try require(
            bundleCGImage.width == LauncherMemoryPolicy.iconPixelSize
                && bundleCGImage.height == LauncherMemoryPolicy.iconPixelSize,
            "The normalized bundle icon lost its Retina pixel density"
        )
        try require(
            bundlePixels.contains(where: { $0 != 0 }),
            "The normalized bundle icon was transparent"
        )

        let missingWallpaper = URL(fileURLWithPath: "/tmp/launcherx-missing-\(UUID().uuidString).png")
        let image = await LauncherBackgroundImageLoader().imageData(for: missingWallpaper)
        try require(image == nil, "Missing wallpaper unexpectedly produced an image")

        let wallpaperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcherx-wallpaper-\(UUID().uuidString).png")
        try testIconData.write(to: wallpaperURL, options: .atomic)
        defer {
            do {
                try FileManager.default.removeItem(at: wallpaperURL)
            } catch {
                FileHandle.standardError.write(
                    Data("Could not remove test wallpaper: \(error.localizedDescription)\n".utf8)
                )
            }
        }
        guard let wallpaperData = await LauncherBackgroundImageLoader().imageData(for: wallpaperURL),
              wallpaperData.makeImage() != nil else {
            throw QualityTestFailure(description: "Background image data could not be reconstructed on MainActor")
        }
    }

    private static func hiddenLauncherReleasesAndPreparesImagesForReopening() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        defer { model.shutdown() }
        let app = AppItem(
            url: URL(fileURLWithPath: "/tmp/launcherx-reopen-\(UUID().uuidString).app")
        )
        model.apps = [app]
        _ = await model.loadIcon(for: app)
        try require(model.cachedIcon(for: app) != nil, "The reopening test icon was not prepared")
        model.handleApplicationDidHide()
        try require(
            model.cachedIcon(for: app) == nil && model.selectedBackgroundImage == nil,
            "Hiding the launcher retained image resources"
        )
        let cancelledLoad = Task { await model.loadIcon(for: app) }
        cancelledLoad.cancel()
        _ = await cancelledLoad.value
        try require(model.cachedIcon(for: app) == nil, "A cancelled icon load refilled the hidden cache")
        await model.prepareForPresentation()
        try require(model.cachedIcon(for: app) != nil, "Reopening did not prepare the visible icon before presentation")
        try require(!model.isLauncherVisible, "Preparing images made the hidden window visible early")
    }

    private static func applicationUpdatePreservesUserLayout() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let first = AppItem(url: URL(fileURLWithPath: "/Applications/First.app"))
        let second = AppItem(url: URL(fileURLWithPath: "/Applications/Second.app"))
        let third = AppItem(url: URL(fileURLWithPath: "/Applications/Third.app"))
        let group = AppGroup(
            name: "Projects",
            appPaths: [first.url.path, second.url.path]
        )

        let previousVersion = LauncherModel(defaults: context.defaults, autoScan: false)
        previousVersion.apps = [first, second, third]
        previousVersion.groups = [group]
        previousVersion.rootOrder = ["group:\(group.id.uuidString)", third.id]
        previousVersion.language = "ja"
        previousVersion.background = "ocean"
        previousVersion.setIconSize(80)

        let updatedVersion = LauncherModel(defaults: context.defaults, autoScan: false)
        updatedVersion.apps = [first, second, third]
        try require(updatedVersion.groups == [group], "An application update lost the user's folders")
        try require(
            updatedVersion.rootOrder == ["group:\(group.id.uuidString)", third.id],
            "An application update lost the user's launcher order"
        )
        try require(updatedVersion.language == "ja", "An application update lost the selected language")
        try require(updatedVersion.background == "ocean", "An application update lost the selected background")
        try require(updatedVersion.iconSize == 80, "An application update lost the selected icon size")
    }

    private static func makeTestIconData() -> Data? {
        let dimension = 32
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func fileOperatorRejectsUnsafeDeleteLocation() async throws {
        let fileOperator = LauncherFileOperator()
        let outcome = await fileOperator.moveApplicationToTrash(
            URL(fileURLWithPath: "/System/Applications/Finder.app"),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        guard case .failure = outcome else {
            throw QualityTestFailure(description: "A system application was accepted for deletion")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw QualityTestFailure(description: description) }
    }

    private static func makeDefaults() throws -> (defaults: UserDefaults, domain: String) {
        let domain = "jp.local.launchpadclassic.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw QualityTestFailure(description: "Could not create isolated UserDefaults")
        }
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }
}

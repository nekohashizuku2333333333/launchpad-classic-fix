import Foundation
import Darwin
import AppKit
import CoreGraphics

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
            try duplicateSavedGroupsAndPathsAreSanitized()
            try duplicateRuntimeOrderDoesNotCrashOrLoseEntries()
            try dropInputValidationRejectsUnknownIdentifiers()
            try folderLifecyclePersistsSafely()
            try await folderRenameControlsPersistExplicitly()
            try folderRemovalMatchesNativeLifecycle()
            try pageNavigationHandlesIntegerBoundaries()
            try modalUIBlocksBackgroundPageNavigation()
            try launcherWindowAcceptsKeyboardFocus()
            try quitShortcutRequiresCommandQ()
            try dismissMotionMatchesReferenceApplication()
            try referenceIconSizingMatchesAttachedApp()
            try rootGridUsesAvailableScreenSpace()
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
            try await hiddenLauncherRetainsPreparedIconsForReopening()
            try applicationUpdatePreservesUserLayout()
            try await fileOperatorRejectsUnsafeDeleteLocation()
            print("Launcher quality tests passed (32/32)")
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
        try require(model.iconSize == 92, "Non-finite icon size was not sanitized")
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
            abs(LauncherModel.referenceDefaultIconSize(pageWidth: 1_430) - 92.95) < 0.001,
            "Reference icon size did not follow the enlarged screen-width formula"
        )
        try require(
            LauncherModel.referenceDefaultIconSize(pageWidth: 1_800) == 112,
            "Reference icon size did not honor its 112-point maximum"
        )

        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        model.applyReferenceDefaultIconSize(pageWidth: 1_800)
        try require(model.iconSize == 112, "A fresh install did not use the enlarged default icon size")
        model.setIconSize(80)
        model.applyReferenceDefaultIconSize(pageWidth: 1_000)
        try require(model.iconSize == 80, "A saved user icon size was overwritten by the automatic default")

        let legacyContext = try makeDefaults()
        defer { legacyContext.defaults.removePersistentDomain(forName: legacyContext.domain) }
        legacyContext.defaults.set(96, forKey: "iconSize")
        let migratedModel = LauncherModel(defaults: legacyContext.defaults, autoScan: false)
        try require(migratedModel.iconSize == 112, "The previous 96-point maximum was not migrated to 112 points")
    }

    private static func rootGridUsesAvailableScreenSpace() throws {
        let screenshotLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_848,
            containerHeight: 956,
            preferredIconSize: 112
        )
        try require(screenshotLayout.columns == 9, "The reference layout did not use nine columns")
        try require(screenshotLayout.rows == 5, "The reference layout did not keep five rows")
        try require(screenshotLayout.capacity == 45, "The reference page capacity was incorrect")
        try require(screenshotLayout.iconSize == 112, "The enlarged icon size was not preserved")
        let bottomInset = 956 - LaunchpadLayoutMetrics.bottomReserve
            - screenshotLayout.topInset - screenshotLayout.gridHeight
        try require(abs(bottomInset - screenshotLayout.topInset) < 0.001, "The root grid was not vertically balanced")

        let compactLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: 760,
            containerHeight: 472,
            preferredIconSize: 112
        )
        try require(compactLayout.columns == 3, "The compact layout did not reduce its column count")
        try require(compactLayout.rows == 2, "The compact layout did not reduce its row count")
        try require(
            compactLayout.topInset + compactLayout.gridHeight + LaunchpadLayoutMetrics.bottomReserve <= 472,
            "The compact root grid overflowed its page"
        )

        let extremeLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: .greatestFiniteMagnitude,
            containerHeight: .greatestFiniteMagnitude,
            preferredIconSize: .greatestFiniteMagnitude
        )
        try require(extremeLayout.capacity == 45, "Extreme root geometry was not safely bounded")

        // Spacing stays fixed as the screen grows; extra width becomes margin.
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
            abs(laptopLayout.columnStride - wideLayout.columnStride) < 0.001,
            "Icon spacing changed with screen width"
        )
        try require(
            wideLayout.gridWidth <= LaunchpadLayoutMetrics.maximumGridWidth + 0.001,
            "The wide-screen grid exceeded its maximum width"
        )
        try require(
            wideLayout.columns > laptopLayout.columns,
            "The wide screen did not add columns at the same fixed density"
        )
        try require(
            wideLayout.columns == Int((LaunchpadLayoutMetrics.usableGridWidth(containerWidth: 4_096)
                + wideLayout.horizontalSpacing) / wideLayout.columnStride),
            "The wide-screen column count did not follow the fixed density rule"
        )

        let invalidLayout = LaunchpadLayoutMetrics.calculate(
            containerWidth: .nan,
            containerHeight: .infinity,
            preferredIconSize: .nan
        )
        try require(invalidLayout.capacity > 0, "Invalid root geometry produced an unusable capacity")
    }

    private static func folderGridMetricsNeverOverflowTheirPanel() throws {
        let base = LaunchpadLayoutMetrics.calculate(
            containerWidth: 1_822,
            containerHeight: 992,
            preferredIconSize: 92
        )
        let singleRowLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 2,
            rowLimit: 3
        )
        try require(singleRowLayout.columns == 2, "A two-application folder kept unused columns")
        try require(singleRowLayout.rows == 1, "A two-application folder kept unused rows")
        try require(singleRowLayout.capacity == 2, "The single-row folder capacity was incorrect")
        try require(folderGridFits(singleRowLayout, base: base), "The single-row folder grid overflowed")

        let smallFolderLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 4,
            rowLimit: 3
        )
        try require(smallFolderLayout.columns == 3, "The small folder did not use three columns")
        try require(smallFolderLayout.rows == 2, "The small folder did not wrap to a second row")
        try require(folderGridFits(smallFolderLayout, base: base), "The small folder grid overflowed")

        let multiPageLayout = LaunchpadLayoutMetrics.folderContent(
            base: base,
            itemCount: 50,
            rowLimit: 3
        )
        try require(
            multiPageLayout.columns == base.columns,
            "The large folder did not reuse the root column count"
        )
        try require(multiPageLayout.rows == 3, "The large folder did not fit three rows")
        try require(
            multiPageLayout.pageCount(forItemCount: 50) > 1,
            "The large folder unexpectedly fit on one page"
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
        try require(LauncherMemoryPolicy.backgroundMaximumPixelSize <= 3_072, "Background decoding is insufficiently bounded")
        try require(
            LauncherMemoryPolicy.maximumPersistentCacheCost <= 80 * 1_024 * 1_024,
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

    private static func hiddenLauncherRetainsPreparedIconsForReopening() async throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.domain) }
        let model = LauncherModel(defaults: context.defaults, autoScan: false)
        defer { model.shutdown() }
        let app = AppItem(
            url: URL(fileURLWithPath: "/tmp/launcherx-reopen-\(UUID().uuidString).app")
        )

        _ = await model.loadIcon(for: app)
        try require(model.cachedIcon(for: app) != nil, "The reopening test icon was not prepared")
        model.handleApplicationDidHide()
        try require(
            model.cachedIcon(for: app) != nil,
            "Hiding the launcher discarded the icon required for an immediate reopen"
        )
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

import SwiftUI
import AppKit
import QuartzCore

extension Notification.Name {
    static let launcherCheckForUpdates = Notification.Name(
        "jp.local.launchpadclassic27.check-for-updates"
    )
}

struct AppItem: Identifiable, Hashable, Sendable {
    let url: URL
    let bundleIdentifier: String?
    let category: String?
    let isDeletable: Bool
    let displayName: String?
    init(
        url: URL,
        bundleIdentifier: String? = nil,
        category: String? = nil,
        isDeletable: Bool = false,
        displayName: String? = nil
    ) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.isDeletable = isDeletable
        self.displayName = displayName
    }
    var id: String { "app:" + url.path }
    /// Localized name exactly as Finder shows it in /Applications; falls back
    /// to the file name when no localized display name is available.
    var name: String { displayName ?? url.deletingPathExtension().lastPathComponent }
}

struct WallpaperItem: Identifiable, Hashable, Sendable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct AppGroup: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var appPaths: [String]
    var systemKind: String? = nil
}

enum LauncherEntry: Identifiable, Hashable, Sendable {
    case app(AppItem)
    case group(AppGroup)
    var id: String {
        switch self {
        case .app(let app): app.id
        case .group(let group): "group:" + group.id.uuidString
        }
    }
}

struct LauncherReorderPreview: Equatable {
    let sourceID: String
    let page: Int
    let slot: Int
}

struct RootPagerLayoutInfo {
    let topOffset: Double
    let size: CGSize
    let metrics: LaunchpadLayoutMetrics
    let pageSize: Int
}

struct FolderPagerLayoutInfo {
    let origin: CGPoint
    let cellWidth: Double
    let columnCount: Int
    let capacity: Int
    let columnSpacing: Double
    let rowSpacing: Double
    let itemHeight: Double
    let bandFrame: CGRect?
}

enum LaunchpadPageMotion {
    static let maximumVelocity = 4_000.0
    static let velocityProjectionDuration = 0.32
    static let pageDecisionRatio = 0.15
    static let standardDuration = 0.36
    static let minimumDuration = 0.22
    static let reducedMotionDuration = 0.16

    static func animation(reduceMotion: Bool = false, initialVelocity: Double = 0) -> Animation {
        if reduceMotion {
            return .easeInOut(duration: reducedMotionDuration)
        }
        let safeVelocity = initialVelocity.isFinite
            ? min(max(initialVelocity, 0), maximumVelocity)
            : 0
        let velocityReduction = min(safeVelocity * 0.025, standardDuration - minimumDuration)
        return .timingCurve(
            0.22,
            0.86,
            0.24,
            1.00,
            duration: standardDuration - velocityReduction
        )
    }

    static func normalizedInitialVelocity(
        translation: CGFloat,
        projectedTranslation: CGFloat,
        pageWidth: CGFloat
    ) -> Double {
        guard pageWidth.isFinite, pageWidth > 0 else { return 0 }
        let projectedDelta = Double(abs(projectedTranslation - translation))
        let pointsPerSecond = min(projectedDelta / velocityProjectionDuration, maximumVelocity)
        return pointsPerSecond / Double(pageWidth)
    }

    nonisolated static func visiblePages(
        currentPage: Int,
        pageCount: Int,
        reduceMotion: Bool = false
    ) -> [Int] {
        let safePageCount = max(1, pageCount)
        let safeCurrentPage = min(max(0, currentPage), safePageCount - 1)
        // Transparent neighboring pages can still receive native AppKit drops
        // even when SwiftUI hit testing is disabled. A reduced-motion pager
        // must mount only its active page, rather than stack hidden targets.
        if reduceMotion { return [safeCurrentPage] }
        let firstPage = max(0, safeCurrentPage - 1)
        let lastPage = min(safePageCount - 1, safeCurrentPage + 1)
        return Array(firstPage...lastPage)
    }
}

enum LaunchpadDismissMotion {
    static let duration = 0.25
    static let scale = 1.10
    static let reducedMotionFadeDuration = 0.18

    nonisolated static func shouldAnimate(
        requested: Bool,
        applicationIsActive: Bool,
        reduceMotion: Bool,
        windowIsVisible: Bool
    ) -> Bool {
        requested && applicationIsActive && !reduceMotion && windowIsVisible
    }
}

enum LauncherSelectionDirection {
    case left, right, up, down
}

enum LauncherKeyboardCommand {
    nonisolated static func selectionDirection(keyCode: UInt16) -> LauncherSelectionDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    nonisolated static func isQuit(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevantModifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        return relevantModifiers == .command && characters?.lowercased() == "q"
    }
}

enum LaunchpadStandardUtilities {
    private static let relocatedUtilityBundleIdentifiers: Set<String> = [
        "com.apple.archiveutility",
        "com.apple.bootcampassistant",
        "com.apple.DirectoryUtility",
        "com.apple.keychainaccess",
        "com.apple.wifi.diagnostics"
    ]

    nonisolated static func contains(_ app: AppItem) -> Bool {
        let path = app.url.standardizedFileURL.path
        let isAppleUtilityLocation = path.hasPrefix("/System/Applications/Utilities/")
            || path.hasPrefix("/Applications/Utilities/")
        let identifier = app.bundleIdentifier ?? Bundle(url: app.url)?.bundleIdentifier
        guard let identifier, identifier.hasPrefix("com.apple.") else { return false }
        return isAppleUtilityLocation || relocatedUtilityBundleIdentifiers.contains(identifier)
    }
}

@MainActor
final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // This accessory app has no Edit menu to dispatch text shortcuts.
        // Keep editing in AppKit so selection, undo and input methods retain
        // their native behavior, including inside folder-name fields.
        if event.type == .keyDown,
           let editor = firstResponder as? NSTextView, editor.window === self {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == .command {
                switch key {
                case "a": editor.selectAll(nil); return true
                case "c": editor.copy(nil); return true
                case "v" where editor.isEditable: editor.paste(nil); return true
                case "x" where editor.isEditable: editor.cut(nil); return true
                case "z" where editor.isEditable:
                    if let undoManager = editor.undoManager, undoManager.canUndo { undoManager.undo() }
                    return true
                default: break
                }
            } else if modifiers == [.command, .shift], key == "z", editor.isEditable {
                if let undoManager = editor.undoManager, undoManager.canRedo { undoManager.redo() }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
enum LauncherWindowPresentation {
    static let initialBackgroundColor = NSColor(
        calibratedRed: 0.10,
        green: 0.08,
        blue: 0.28,
        alpha: 1
    )

    static func configureChrome(of window: NSWindow) {
        window.styleMask = .borderless
        window.title = ""
        window.toolbar = nil
        window.isOpaque = true
        window.backgroundColor = initialBackgroundColor
        window.hasShadow = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = initialBackgroundColor.cgColor
    }
}

/// Folder paging lives in its own observable so that flipping pages inside
/// an open folder does not invalidate (and re-render) the root Launchpad
/// grid, which would stutter the page-slide and split animations.
@MainActor
final class FolderPagerState: ObservableObject {
    @Published var page = 0
    @Published var displayedPage = 0
    @Published var pageCount = 1
}

@MainActor final class LauncherModel: ObservableObject {
    static let defaultBackground = "wallpaper"

    @Published var apps: [AppItem] = []
    @Published var groups: [AppGroup] = [] { didSet { saveGroups() } }
    @Published var search = "" { didSet {
        let cleaned = Self.sanitizedSearch(search)
        if cleaned != search { search = cleaned }
        if oldValue != search {
            if oldValue.isEmpty, !search.isEmpty { pageBeforeSearch = currentPage }
            let capacity = max(1, rootPagerLayoutInfo?.pageSize ?? 35)
            let count = max(1, (rootEntries.count + capacity - 1) / capacity)
            let destination = search.isEmpty ? min(max(0, pageBeforeSearch ?? 0), count - 1) : 0
            pageCount = count
            currentPage = destination
            displayedPage = destination
            if search.isEmpty { pageBeforeSearch = nil }
            clearKeyboardSelection()
            folderReturnSelectionID = nil
        }
        if !search.isEmpty, openGroupID != nil { closeFolder() }
    } }
    @Published var showLauncherSettings = false { didSet {
        if showLauncherSettings { endEditing() }
    } }
    @Published private(set) var selectedEntryID: String?
    @Published private(set) var isEditing = false
    @Published var openGroupID: UUID?
    @Published var currentPage = 0
    @Published var pageCount = 1
    @Published private(set) var displayedPage = 0
    @Published private(set) var reorderPreview: LauncherReorderPreview?
    @Published private(set) var reorderDragSourceID: String?
    let folderPager = FolderPagerState()
    @Published var rootOrder: [String] = [] { didSet { saveOrder() } }
    @Published var wallpapers: [WallpaperItem] = []
    @Published private(set) var selectedBackgroundImage: NSImage?
    @Published var pendingDeleteApp: AppItem?
    @Published private(set) var isScanning = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isDismissing = false
    @Published private(set) var isLauncherVisible = true
    @Published private(set) var isInitialContentReady = false
    @Published private(set) var displayTopSafeAreaInset: Double = 0
    @Published var errorMessage: String?
    @Published var language: String { didSet {
        let cleaned = Self.sanitizedLanguage(language)
        if cleaned != language { language = cleaned; return }
        defaults.set(language, forKey: "language")
        updateLocalizedSystemGroupNames()
        if oldValue != language { scan() }
    } }
    @Published var background: String { didSet {
        let cleaned = Self.sanitizedBackground(background)
        if cleaned != background { background = cleaned; return }
        defaults.set(background, forKey: "background")
        refreshBackgroundImage()
    } }
    @Published var iconSize: Double { didSet {
        let cleaned = Self.sanitizedIconSize(iconSize)
        if cleaned != iconSize { iconSize = cleaned; return }
        if isApplyingReferenceIconSize { return }
        usesReferenceIconSize = false
        defaults.set(iconSize, forKey: "iconSize")
    } }
    @Published private(set) var reducesTransparency =
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @Published private(set) var reducesMotion =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let groupsKey = "launcher.groups.v2"
    private let orderKey = "launcher.order.v1"
    private let defaultsKey = "launcher.defaultGroups.v1"
    private let sequoiaUtilitiesMigrationKey = "launcher.sequoiaUtilities.v1"
    private let displayVersionKey = "launcher.display.version"
    private let defaults: UserDefaults
    private let applicationScanner = LauncherFileScanner()
    private let wallpaperScanner = LauncherFileScanner()
    private let fileOperator = LauncherFileOperator()
    private let iconLoader = LauncherIconLoader()
    private let backgroundImageLoader = LauncherBackgroundImageLoader()
    private let iconImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = LauncherMemoryPolicy.iconImageCacheCount
        cache.totalCostLimit = LauncherMemoryPolicy.iconImageCacheCost
        return cache
    }()
    private var applicationMonitor: LauncherApplicationMonitor?
    private var applicationScanTask: Task<Void, Never>?
    private var wallpaperScanTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var backgroundLoadTask: Task<Void, Never>?
    private var cacheMaintenanceTask: Task<Void, Never>?
    private var imageResourceGeneration = 0
    private var initialIconPreloadTask: Task<Void, Never>?
    private var requestedBackgroundPath: String?
    private var presentationRequestID: UUID?
    private var dismissalRequestID: UUID?
    private weak var registeredLauncherWindow: NSWindow?
    private var initialApplicationsReady = false
    private var initialBackgroundReady = false
    private var initialWindowFrameReady = false
    private var initialReadinessHandlers: [@MainActor () -> Void] = []
    private var usesReferenceIconSize = true
    private var isApplyingReferenceIconSize = false
    private var reorderDragTimer: Timer?
    private var reorderEdgeHoverDirection: Int?
    private var reorderEdgeHoverStartDate: Date?
    private var reorderEdgeHoverHasFlipped = false
    private var reorderFolderHoverID: UUID?
    private var reorderFolderHoverStartDate: Date?
    private var reorderFolderExitStartDate: Date?
    private var exitedDragFolderID: UUID?
    private var accessibilityOptionsObserver: NSObjectProtocol?
    private var launcherDisplayObservers: [NSObjectProtocol] = []
    private var isUpdatingLauncherDisplayGeometry = false
    private var squareIconPaths: Set<String> = []
    private var rootPagerLayoutInfo: RootPagerLayoutInfo?
    private var folderPagerLayoutInfo: FolderPagerLayoutInfo?
    private var folderReturnSelectionID: String?
    private var isEditingLocked = false
    private var isOptionKeyPressed = false
    private var pageBeforeSearch: Int?

    init(defaults: UserDefaults = .standard, autoScan: Bool = true) {
        self.defaults = defaults
        initialApplicationsReady = !autoScan
        initialBackgroundReady = !autoScan
        isInitialContentReady = !autoScan
        language = Self.sanitizedLanguage(defaults.string(forKey: "language"))
        if let storedNumber = defaults.object(forKey: "iconSize") as? NSNumber,
           storedNumber.doubleValue.isFinite {
            let storedSize = storedNumber.doubleValue
            let needsLegacyMaximumMigration = defaults.integer(forKey: displayVersionKey) < 2
                && abs(storedSize - 96) < 0.001
            iconSize = Self.sanitizedIconSize(needsLegacyMaximumMigration ? 112 : storedSize)
            usesReferenceIconSize = false
        } else {
            iconSize = 90
            usesReferenceIconSize = true
            defaults.removeObject(forKey: "iconSize")
        }
        defaults.set(2, forKey: displayVersionKey)
        background = Self.sanitizedBackground(
            defaults.string(forKey: "background") ?? Self.defaultBackground
        )
        if let data = defaults.data(forKey: groupsKey), data.count <= 2_000_000,
           let saved = try? JSONDecoder().decode([AppGroup].self, from: data) {
            groups = Self.sanitizedGroups(saved)
        }
        rootOrder = Self.sanitizedOrder(defaults.stringArray(forKey: orderKey) ?? [])
        updateLocalizedSystemGroupNames()
        if autoScan {
            startApplicationMonitoring()
            scanWallpapers()
            scan()
        }
        refreshBackgroundImage()
        accessibilityOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let workspace = NSWorkspace.shared
                let transparency = workspace.accessibilityDisplayShouldReduceTransparency
                let motion = workspace.accessibilityDisplayShouldReduceMotion
                if self.reducesTransparency != transparency { self.reducesTransparency = transparency }
                if self.reducesMotion != motion { self.reducesMotion = motion }
            }
        }
    }

    var resolvedLanguage: String {
        language == "system"
            ? Self.resolvedSystemLanguage(from: Locale.preferredLanguages)
            : language
    }

    func text(_ en: String, _ ja: String, _ zhHant: String) -> String {
        switch resolvedLanguage {
        case "ja": ja
        case "zh-Hant": zhHant
        default: en
        }
    }

    var rootEntries: [LauncherEntry] {
        if !search.isEmpty {
            return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }.map(LauncherEntry.app)
        }
        let grouped = Set(groups.flatMap(\.appPaths))
        let availablePaths = Set(apps.map(\.url.path))
        let folders = groups.filter { group in
            group.appPaths.contains(where: availablePaths.contains)
        }.map(LauncherEntry.group)
        let looseApps = apps.filter { !grouped.contains($0.url.path) }.map(LauncherEntry.app)
        let entries = folders + looseApps
        var rank: [String: Int] = [:]
        for (offset, identifier) in rootOrder.enumerated() where rank[identifier] == nil {
            rank[identifier] = offset
        }
        return entries.enumerated().sorted {
            let left = rank[$0.element.id] ?? (rootOrder.count + $0.offset)
            let right = rank[$1.element.id] ?? (rootOrder.count + $1.offset)
            return left < right
        }.map(\.element)
    }

    func apps(in group: AppGroup) -> [AppItem] {
        var byPath: [String: AppItem] = [:]
        for app in apps where byPath[app.url.path] == nil { byPath[app.url.path] = app }
        return group.appPaths.compactMap { byPath[$0] }
    }

    func loadIcon(for app: AppItem) async -> NSImage {
        guard !Task.isCancelled else { return NSImage(size: .zero) }
        let generation = imageResourceGeneration
        let key = app.url.standardizedFileURL.path as NSString
        if let cached = iconImageCache.object(forKey: key) { return cached }
        let iconData = await iconLoader.iconData(for: app.url)
        guard !Task.isCancelled, generation == imageResourceGeneration else {
            return NSImage(size: .zero)
        }
        let icon = iconData.flatMap(NSImage.init(data:))
            ?? NSWorkspace.shared.icon(forFile: app.url.path)
        let pixelSize = LauncherMemoryPolicy.iconPixelSize
        let logicalSize = LauncherMemoryPolicy.iconLogicalPointSize
        icon.size = NSSize(width: logicalSize, height: logicalSize)
        let standardizedPath = app.url.standardizedFileURL.path
        if !squareIconPaths.contains(standardizedPath),
           Self.iconHasOpaqueCorners(icon) {
            squareIconPaths.insert(standardizedPath)
        }
        iconImageCache.setObject(icon, forKey: key, cost: pixelSize * pixelSize * 4)
        return icon
    }

    func iconNeedsRoundedCorners(for app: AppItem) -> Bool {
        squareIconPaths.contains(app.url.standardizedFileURL.path)
    }

    func cachedIcon(for app: AppItem) -> NSImage? {
        iconImageCache.object(forKey: app.url.standardizedFileURL.path as NSString)
    }

    func scan() {
        applicationScanTask?.cancel()
        if !initialApplicationsReady {
            initialIconPreloadTask?.cancel()
            initialIconPreloadTask = nil
        }
        isScanning = true
        let scanner = applicationScanner
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let localizations = LauncherFileScanner.localizationCandidates(
            languageSetting: language,
            preferredLanguages: Locale.preferredLanguages
        )
        applicationScanTask = Task { [weak self] in
            let result = await scanner.scanApplications(
                homeDirectory: homeDirectory,
                preferredLocalizations: localizations
            )
            guard !Task.isCancelled, let self else { return }
            self.applicationScanTask = nil
            self.isScanning = false
            guard result.accessibleRootCount > 0 else {
                self.presentError(
                    en: "The Applications folders could not be read.",
                    ja: "アプリケーションフォルダを読み込めませんでした。",
                    zhHant: "無法讀取應用程式檔案夾。"
                )
                self.markInitialApplicationsReady()
                return
            }
            if self.apps != result.apps {
                let availablePaths = Set(result.apps.map { $0.url.standardizedFileURL.path })
                for previousApp in self.apps
                    where !availablePaths.contains(previousApp.url.standardizedFileURL.path) {
                    self.iconImageCache.removeObject(
                        forKey: previousApp.url.standardizedFileURL.path as NSString
                    )
                }
                self.apps = result.apps
            }
            self.removeMissingApplicationsFromOpenState()
            self.bootstrapDefaultGroupsIfNeeded()
            self.reconcileSequoiaUtilitiesIfNeeded()
            self.syncNewGames()
            self.preloadInitialPageIconsIfNeeded()
        }
    }

    func whenInitialContentIsReady(_ handler: @escaping @MainActor () -> Void) {
        if isInitialContentReady {
            handler()
        } else if initialReadinessHandlers.count < 8 {
            initialReadinessHandlers.append(handler)
        }
    }

    func scanWallpapers() {
        wallpaperScanTask?.cancel()
        let scanner = wallpaperScanner
        wallpaperScanTask = Task { [weak self] in
            let discovered = await scanner.scanWallpapers()
            guard !Task.isCancelled, let self else { return }
            self.wallpaperScanTask = nil
            self.wallpapers = discovered
            if self.background.hasPrefix("file:") {
                let selectedPath = String(self.background.dropFirst(5))
                if !discovered.contains(where: { $0.url.path == selectedPath }) {
                    self.background = "wallpaper"
                }
            }
        }
    }

    func launch(_ app: AppItem) {
        guard apps.contains(where: { $0.id == app.id }),
              app.url.isFileURL,
              app.url.pathExtension.lowercased() == "app" else {
            presentError(
                en: "This application is no longer available.",
                ja: "このアプリケーションは利用できません。",
                zhHant: "此應用程式已無法使用。"
            )
            return
        }
        dismissLauncher()
        NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.restoreLauncherAfterFailedLaunch()
                    self.presentError(
                        en: "The application could not be opened: \(error.localizedDescription)",
                        ja: "アプリケーションを開けませんでした: \(error.localizedDescription)",
                        zhHant: "無法開啟應用程式：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func activateFromPointer(_ entry: LauncherEntry) {
        // Pointer activation does not establish keyboard focus. In particular,
        // closing a mouse-opened folder must not leave a selected tile behind.
        clearKeyboardSelection()
        switch entry {
        case .app(let app): if !isEditing { launch(app) }
        case .group(let group): open(group)
        }
    }

    func open(_ group: AppGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        folderReturnSelectionID = selectedEntryID == LauncherEntry.group(group).id
            ? selectedEntryID : nil
        clearKeyboardSelection()
        folderPager.page = 0
        folderPager.displayedPage = 0
        clearReorderPreview()
        withAnimation(Self.folderVisibilityAnimation) {
            openGroupID = group.id
        }
        updateLauncherPresentationOptions()
    }
    func dismissLauncher(animated: Bool = true) {
        clearReorderDragState()
        resetKeyboardInteraction()
        guard dismissalRequestID == nil else { return }
        presentationRequestID = nil
        guard let window = launcherWindow(), window.isVisible else {
            NSApp.presentationOptions = []
            return
        }

        let requestID = UUID()
        dismissalRequestID = requestID
        isDismissing = true
        let shouldScale = LaunchpadDismissMotion.shouldAnimate(
            requested: animated,
            applicationIsActive: NSApp.isActive,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            windowIsVisible: window.isVisible
        )
        let shouldFadeOut = animated && window.isVisible
        if shouldScale || shouldFadeOut {
            animateLauncherDismissal(requestID: requestID, window: window, includesScale: shouldScale)
            return
        }
        finishLauncherDismissal(requestID: requestID, window: window)
    }

    func handleApplicationDidResignActive() {
        guard !showLauncherSettings else { return }
        dismissLauncher(animated: true)
    }

    func handleApplicationDidHide() {
        clearReorderDragState()
        resetKeyboardInteraction()
        presentationRequestID = nil
        isDismissing = false
        isLauncherVisible = false
        NSApp.presentationOptions = []
        if let window = launcherWindow() {
            resetLauncherWindowVisualState(window)
        }
        releaseTransientImageResources()
    }
    func closeFolder() {
        let returnSelectionID = folderReturnSelectionID
        folderReturnSelectionID = nil
        clearKeyboardSelection()
        withAnimation(Self.folderVisibilityAnimation) {
            openGroupID = nil
        }
        updateLauncherPresentationOptions()
        folderPager.page = 0
        folderPager.displayedPage = 0
        folderPager.pageCount = 1
        resetReorderFolderHover()
        clearReorderPreview()
        if search.isEmpty, let returnSelectionID,
           rootEntries.contains(where: { $0.id == returnSelectionID }) {
            selectedEntryID = returnSelectionID
        }
    }
    func group(for id: UUID?) -> AppGroup? { groups.first { $0.id == id } }

    private var acceptsLauncherKeyboardInteraction: Bool {
        !isDismissing && !showLauncherSettings && pendingDeleteApp == nil
            && errorMessage == nil && !isDeleting
    }

    private var keyboardEntries: [LauncherEntry] {
        if let group = group(for: openGroupID) {
            return apps(in: group).map(LauncherEntry.app)
        }
        return rootEntries
    }

    var highlightedEntryID: String? {
        guard reorderDragSourceID == nil, !isEditing else { return nil }
        if let selectedEntryID { return selectedEntryID }
        guard !search.isEmpty, openGroupID == nil else { return nil }
        let entries = rootEntries
        guard !entries.isEmpty else { return nil }
        let capacity = max(1, rootPagerLayoutInfo?.pageSize ?? 35)
        let page = min(max(0, currentPage), (entries.count - 1) / capacity)
        // Highlighting the default search result does not take selection away
        // from the text caret: Left/Right still edit until an arrow enters the
        // grid. Return uses this same visible result as its default target.
        return entries[page * capacity].id
    }

    func selectEntry(_ id: String?) {
        guard let id else { clearKeyboardSelection(); return }
        guard keyboardEntries.contains(where: { $0.id == id }) else { return }
        selectedEntryID = id
    }

    func clearKeyboardSelection() {
        if selectedEntryID != nil { selectedEntryID = nil }
    }

    func beginEditing() {
        guard acceptsLauncherKeyboardInteraction else { return }
        isEditingLocked = true
        if !isEditing { isEditing = true }
    }

    func setOptionKeyPressed(_ pressed: Bool) {
        // A modifier release must always clear its transient state, including
        // when a confirmation sheet appeared while Option was held down.
        isOptionKeyPressed = pressed && acceptsLauncherKeyboardInteraction
        let next = isEditingLocked || isOptionKeyPressed
        if isEditing != next { isEditing = next }
    }

    func endEditing() {
        isEditingLocked = false
        isOptionKeyPressed = false
        if isEditing { isEditing = false }
    }

    private func resetKeyboardInteraction() {
        endEditing()
        clearKeyboardSelection()
        folderReturnSelectionID = nil
    }

    @discardableResult
    func moveKeyboardSelection(_ direction: LauncherSelectionDirection) -> Bool {
        guard acceptsLauncherKeyboardInteraction, reorderDragSourceID == nil else { return false }
        let entries = keyboardEntries
        guard !entries.isEmpty else { clearKeyboardSelection(); return false }
        let inFolder = openGroupID != nil
        let columns = max(1, inFolder
            ? (folderPagerLayoutInfo?.columnCount ?? 7)
            : (rootPagerLayoutInfo?.metrics.columns ?? 7))
        let capacity = max(1, inFolder
            ? (folderPagerLayoutInfo?.capacity ?? 35)
            : (rootPagerLayoutInfo?.pageSize ?? 35))
        let requestedPage = inFolder ? folderPager.page : currentPage
        let visiblePage = min(max(0, requestedPage), (entries.count - 1) / capacity)
        let index: Int
        if let selectedEntryID, let selected = entries.firstIndex(where: { $0.id == selectedEntryID }),
           selected / capacity == visiblePage {
            let offset: Int
            switch direction {
            case .left: offset = -1
            case .right: offset = 1
            case .up: offset = -columns
            case .down: offset = columns
            }
            index = min(max(0, selected + offset), entries.count - 1)
        } else {
            // The first arrow press establishes selection on the visible page;
            // it never jumps back to page one after mouse or trackpad paging.
            index = min(visiblePage * capacity, entries.count - 1)
        }
        let destinationPage = index / capacity
        if inFolder { goToFolderPage(destinationPage) }
        else { goToPage(destinationPage) }
        selectedEntryID = entries[index].id
        return true
    }

    @discardableResult
    func activateKeyboardSelection() -> Bool {
        guard acceptsLauncherKeyboardInteraction, reorderDragSourceID == nil else { return false }
        let entries = keyboardEntries
        let highlightedID = highlightedEntryID
        let selected = entries.first(where: { $0.id == selectedEntryID })
            ?? entries.first(where: { $0.id == highlightedID })
        guard let selected else { return false }
        switch selected {
        case .app(let app):
            guard !isEditing else { return false }
            launch(app)
        case .group(let group): open(group)
        }
        return true
    }

    @discardableResult
    func handleEscape() -> Bool {
        guard acceptsLauncherKeyboardInteraction else { return false }
        if reorderDragSourceID != nil { clearReorderDragState() }
        else if isEditing { endEditing(); clearKeyboardSelection() }
        else if !search.isEmpty { search = "" }
        else if openGroupID != nil { closeFolder() }
        else { dismissLauncher() }
        return true
    }

    func handleBackgroundClick() {
        guard acceptsLauncherKeyboardInteraction, reorderDragSourceID == nil else { return }
        clearKeyboardSelection()
        if isEditing { endEditing() }
        else if openGroupID != nil { closeFolder() }
        else { dismissLauncher() }
    }

    func requestDeleteApplication(_ app: AppItem) {
        guard app.isDeletable, !isDeleting, reorderDragSourceID == nil,
              let current = apps.first(where: { $0.id == app.id }), current.isDeletable else { return }
        pendingDeleteApp = current
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = Self.sanitizedGroupName(
            name,
            allowEmpty: true,
            fallback: text("Folder", "フォルダ", "資料夾")
        )
    }

    func finalizeGroupName(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = Self.sanitizedGroupName(
            groups[index].name,
            allowEmpty: false,
            fallback: text("Folder", "フォルダ", "資料夾")
        )
    }

    func applyReferenceDefaultIconSize(pageWidth: Double) {
        guard usesReferenceIconSize else { return }
        let calculatedSize = Self.referenceDefaultIconSize(pageWidth: pageWidth)
        guard calculatedSize != iconSize else { return }
        isApplyingReferenceIconSize = true
        iconSize = calculatedSize
        isApplyingReferenceIconSize = false
    }

    func setIconSize(_ size: Double) { iconSize = Self.sanitizedIconSize(size) }
    func adjustIconSize(by amount: Double) { setIconSize(iconSize + amount) }

    func setPageCount(_ count: Int) {
        let count = max(1, count)
        if pageCount != count { pageCount = count }
        let destination = min(max(0, currentPage), count - 1)
        if currentPage != destination { clearKeyboardSelection(); currentPage = destination }
        if displayedPage != destination { displayedPage = destination }
    }

    func goToPage(_ page: Int, initialVelocity: Double = 0) {
        let destination = min(max(0, page), pageCount - 1)
        guard destination != currentPage else { return }
        clearKeyboardSelection()
        // Both pages remain present during the opacity transition. Updating
        // immediately also lets a new gesture retarget an in-flight fade,
        // without a delayed callback overwriting a search or page-count change.
        withAnimation(LaunchpadPageMotion.animation(
            reduceMotion: reducesMotion,
            initialVelocity: initialVelocity
        )) {
            currentPage = destination
            displayedPage = destination
        }
    }

    func changePage(by delta: Int, initialVelocity: Double = 0) {
        let addition = currentPage.addingReportingOverflow(delta)
        goToPage(
            addition.overflow ? (delta > 0 ? Int.max : Int.min) : addition.partialValue,
            initialVelocity: initialVelocity
        )
    }

    func setCurrentPage(_ page: Int) {
        let clamped = min(max(0, page), pageCount - 1)
        if currentPage != clamped { clearKeyboardSelection(); currentPage = clamped }
        if displayedPage != clamped { displayedPage = clamped }
    }

    func setFolderPageCount(_ count: Int) {
        let count = max(1, count)
        if folderPager.pageCount != count { folderPager.pageCount = count }
        let destination = min(max(0, folderPager.page), count - 1)
        if folderPager.page != destination { clearKeyboardSelection(); folderPager.page = destination }
        if folderPager.displayedPage != destination { folderPager.displayedPage = destination }
    }

    func setFolderPage(_ page: Int) {
        let clamped = min(max(0, page), folderPager.pageCount - 1)
        if folderPager.page != clamped { clearKeyboardSelection(); folderPager.page = clamped }
        if folderPager.displayedPage != clamped { folderPager.displayedPage = clamped }
    }

    func goToFolderPage(_ page: Int, initialVelocity: Double = 0) {
        let destination = min(max(0, page), folderPager.pageCount - 1)
        guard destination != folderPager.page else { return }
        clearKeyboardSelection()
        withAnimation(LaunchpadPageMotion.animation(
            reduceMotion: reducesMotion,
            initialVelocity: initialVelocity
        )) {
            folderPager.page = destination
            folderPager.displayedPage = destination
        }
    }

    private static var folderVisibilityAnimation: Animation? {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeInOut(duration: LaunchpadPageMotion.reducedMotionDuration)
        }
        return .spring(response: 0.34, dampingFraction: 0.92)
    }

    func navigateVisiblePages(by delta: Int) {
        guard !showLauncherSettings, pendingDeleteApp == nil, errorMessage == nil else { return }
        if openGroupID == nil { changePage(by: delta) }
        else {
            let addition = folderPager.page.addingReportingOverflow(delta)
            goToFolderPage(addition.overflow ? (delta > 0 ? Int.max : Int.min) : addition.partialValue)
        }
    }

    func remove(_ app: AppItem, from group: AppGroup) {
        moveAppOut(app, from: group.id)
    }

    func handleDrop(_ sourceID: String, on target: LauncherEntry) {
        guard search.isEmpty, sourceID.count <= 4_200, sourceID != target.id,
              let source = entry(for: sourceID),
              let resolvedTarget = entry(for: target.id) else { return }
        switch (source, resolvedTarget) {
        case (.app(let sourceApp), .app(let targetApp)):
            detachFromGroups(paths: [sourceApp.url.path, targetApp.url.path])
            let previousOrder = rootEntries.map(\.id)
            let group = AppGroup(
                name: text("Folder", "フォルダ", "資料夾"),
                appPaths: [targetApp.url.path, sourceApp.url.path]
            )
            groups.append(group)
            replaceOrderItems([targetApp.id, sourceApp.id], with: "group:" + group.id.uuidString, in: previousOrder)
            openGroupID = group.id
        case (.app(let sourceApp), .group(let targetGroup)):
            guard !targetGroup.appPaths.contains(sourceApp.url.path) else {
                clearReorderDragState()
                return
            }
            detachFromGroups(paths: [sourceApp.url.path])
            guard let index = groups.firstIndex(where: { $0.id == targetGroup.id }) else { break }
            if !groups[index].appPaths.contains(sourceApp.url.path) { groups[index].appPaths.append(sourceApp.url.path) }
            open(groups[index])
        default: break
        }
        clearReorderDragState()
    }

    @discardableResult
    func reorder(_ sourceID: String, beside targetID: String, after: Bool) -> Bool {
        guard sourceID.count <= 4_200, targetID.count <= 4_200, sourceID != targetID else { return false }
        let order = rootEntries.map(\.id)
        guard let targetIndex = order.firstIndex(of: targetID) else { return false }
        return commitRootMove(sourceID, to: targetIndex + (after ? 1 : 0))
    }

    @discardableResult
    func addToOpenGroup(_ sourceID: String) -> Bool {
        guard sourceID.count <= 4_200, sourceID.hasPrefix("app:"),
              let sourceApp = apps.first(where: { $0.id == sourceID }),
              let groupID = openGroupID,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let path = sourceApp.url.path
        guard !groups[index].appPaths.contains(path) else { return false }
        detachFromGroups(paths: [path])
        guard let refreshedIndex = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        if !groups[refreshedIndex].appPaths.contains(path) { groups[refreshedIndex].appPaths.append(path) }
        clearReorderDragState()
        return true
    }

    @discardableResult
    func addToOpenGroup(_ sourceID: String, beside targetID: String, after: Bool) -> Bool {
        guard sourceID.count <= 4_200, targetID.count <= 4_200,
              sourceID.hasPrefix("app:"), targetID.hasPrefix("app:"),
              let sourceApp = apps.first(where: { $0.id == sourceID }),
              let groupID = openGroupID,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let sourcePath = sourceApp.url.path
        let targetPath = String(targetID.dropFirst(4))
        guard !groups[index].appPaths.contains(sourcePath),
              groups[index].appPaths.contains(targetPath) else { return false }
        detachFromGroups(paths: [sourcePath])
        guard let refreshedIndex = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let targetIndex = groups[refreshedIndex].appPaths.firstIndex(of: targetPath)
            ?? groups[refreshedIndex].appPaths.count
        let insertion = min(
            targetIndex + (after && targetIndex < groups[refreshedIndex].appPaths.count ? 1 : 0),
            groups[refreshedIndex].appPaths.count
        )
        groups[refreshedIndex].appPaths.insert(sourcePath, at: insertion)
        clearReorderDragState()
        return true
    }

    func moveOutOfOpenGroup(_ sourceID: String) {
        guard sourceID.count <= 4_200, sourceID.hasPrefix("app:"),
              let sourceApp = apps.first(where: { $0.id == sourceID }),
              let groupID = openGroupID else { return }
        moveAppOut(sourceApp, from: groupID)
    }

    @discardableResult
    func moveOutOfOpenGroupToSlot(
        _ sourceID: String,
        page: Int,
        slot: Int,
        pageSize: Int
    ) -> Bool {
        guard sourceIsInOpenGroup(sourceID) else { return false }
        let moved = reorderToSlot(sourceID, page: page, slot: slot, pageSize: pageSize)
        if moved { closeFolder() }
        return moved
    }

    @discardableResult
    func reorderInOpenGroup(_ sourceID: String, before targetID: String) -> Bool {
        reorderInOpenGroup(sourceID, beside: targetID, after: false)
    }

    @discardableResult
    func reorderInOpenGroup(_ sourceID: String, beside targetID: String, after: Bool) -> Bool {
        guard sourceID.count <= 4_200, targetID.count <= 4_200,
              sourceID.hasPrefix("app:"), targetID.hasPrefix("app:"), sourceID != targetID,
              let groupID = openGroupID, let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let sourcePath = String(sourceID.dropFirst(4))
        let targetPath = String(targetID.dropFirst(4))
        guard groups[index].appPaths.contains(sourcePath),
              groups[index].appPaths.contains(targetPath) else { return false }
        groups[index].appPaths.removeAll { $0 == sourcePath }
        guard let targetIndex = groups[index].appPaths.firstIndex(of: targetPath) else { return false }
        let insertion = min(
            targetIndex + (after ? 1 : 0),
            groups[index].appPaths.count
        )
        groups[index].appPaths.insert(sourcePath, at: insertion)
        clearReorderDragState()
        return true
    }

    @discardableResult
    func reorderToPageEnd(_ sourceID: String, page: Int, pageSize: Int) -> Bool {
        reorderToSlot(sourceID, page: page, slot: pageSize, pageSize: pageSize)
    }

    @discardableResult
    func reorderToSlot(_ sourceID: String, page: Int, slot: Int, pageSize: Int) -> Bool {
        guard sourceID.count <= 4_200, pageSize > 0 else { return false }
        let count = rootEntries.count
        // Clamp before multiplication so malformed drag input cannot overflow.
        let pageStart = min(max(0, page), count / pageSize) * pageSize
        let insertion = pageStart + min(max(0, slot), min(pageSize, count - pageStart))
        return commitRootMove(sourceID, to: insertion)
    }

    /// Commit only on drop. While a folder closes under a live drag, its
    /// membership and saved order remain intact, so cancelling is lossless.
    private func commitRootMove(_ sourceID: String, to proposedIndex: Int) -> Bool {
        guard search.isEmpty, sourceID.count <= 4_200, let source = entry(for: sourceID) else { return false }
        let previousOrder = rootEntries.map(\.id)
        let insertion = min(max(0, proposedIndex), previousOrder.count)
        var dissolvedFolderID: String?
        var replacementIDs: [String] = []
        if case .app(let app) = source,
           let groupIndex = groups.firstIndex(where: { $0.appPaths.contains(app.url.path) }) {
            var updatedGroups = groups
            updatedGroups[groupIndex].appPaths.removeAll { $0 == app.url.path }
            let remaining = apps(in: updatedGroups[groupIndex])
            if remaining.count <= 1 {
                let groupID = updatedGroups[groupIndex].id
                dissolvedFolderID = "group:" + groupID.uuidString
                replacementIDs = remaining.map(\.id)
                updatedGroups.remove(at: groupIndex)
                if openGroupID == groupID { closeFolder() }
            }
            groups = updatedGroups
        } else if !previousOrder.contains(sourceID) {
            return false
        }
        func retainedIDs(_ ids: ArraySlice<String>) -> [String] {
            ids.flatMap { id -> [String] in
                if id == sourceID { return [] }
                if id == dissolvedFolderID { return replacementIDs }
                return [id]
            }
        }
        var order = retainedIDs(previousOrder[...])
        let adjustedIndex = retainedIDs(previousOrder[..<insertion]).count
        order.insert(sourceID, at: min(adjustedIndex, order.count))
        rootOrder = order
        clearReorderDragState()
        return true
    }

    @discardableResult
    func reorderInOpenGroupToPageEnd(_ sourceID: String, page: Int, capacity: Int) -> Bool {
        guard sourceID.count <= 4_200, sourceID.hasPrefix("app:"), capacity > 0,
              let groupID = openGroupID,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let sourcePath = String(sourceID.dropFirst(4))
        let paths = groups[index].appPaths
        guard paths.contains(sourcePath) else { return false }
        let start = min(max(0, page) * capacity, paths.count)
        let end = min(start + capacity, paths.count)
        let anchor = paths[start..<end].last(where: { $0 != sourcePath })
        groups[index].appPaths.removeAll { $0 == sourcePath }
        if let anchor, let anchorIndex = groups[index].appPaths.firstIndex(of: anchor) {
            groups[index].appPaths.insert(sourcePath, at: anchorIndex + 1)
        } else {
            groups[index].appPaths.insert(sourcePath, at: min(groups[index].appPaths.count, start))
        }
        clearReorderDragState()
        return true
    }

    @discardableResult
    func reorderInOpenGroupToSlot(_ sourceID: String, slot: Int, capacity: Int) -> Bool {
        guard sourceID.count <= 4_200, sourceID.hasPrefix("app:"), capacity > 0,
              let groupID = openGroupID,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let sourcePath = String(sourceID.dropFirst(4))
        let paths = groups[index].appPaths
        guard paths.contains(sourcePath) else { return false }
        let pageStart = min(folderPager.page * capacity, paths.count)
        let pageEnd = min(pageStart + capacity, paths.count)
        let pagePaths = Array(paths[pageStart..<pageEnd])
        groups[index].appPaths.removeAll { $0 == sourcePath }
        if slot < capacity {
            let desiredIndex = min(pageStart + max(0, slot), paths.count)
            let adjustedIndex = desiredIndex - paths[..<desiredIndex].filter { $0 == sourcePath }.count
            groups[index].appPaths.insert(
                sourcePath,
                at: min(max(0, adjustedIndex), groups[index].appPaths.count)
            )
        } else if slot < pagePaths.count,
           let anchor = pagePaths[slot...].first(where: { $0 != sourcePath }),
           let anchorIndex = groups[index].appPaths.firstIndex(of: anchor) {
            groups[index].appPaths.insert(sourcePath, at: anchorIndex)
        } else if let lastAnchor = pagePaths.last(where: { $0 != sourcePath }),
                  let anchorIndex = groups[index].appPaths.firstIndex(of: lastAnchor) {
            groups[index].appPaths.insert(sourcePath, at: anchorIndex + 1)
        } else {
            groups[index].appPaths.insert(sourcePath, at: min(groups[index].appPaths.count, pageStart))
        }
        clearReorderDragState()
        return true
    }

    func dropInOpenGroup(_ sourceID: String, page: Int, capacity: Int, slot: Int?) -> Bool {
        if sourceIsInOpenGroup(sourceID) {
            if let slot {
                return reorderInOpenGroupToSlot(sourceID, slot: slot, capacity: capacity)
            }
            return reorderInOpenGroupToPageEnd(sourceID, page: page, capacity: capacity)
        }
        guard sourceID.count <= 4_200, sourceID.hasPrefix("app:"), capacity > 0,
              let app = apps.first(where: { $0.id == sourceID }),
              let groupID = openGroupID,
              let group = group(for: groupID) else { return false }
        let count = group.appPaths.count
        let pageStart = min(max(0, page), count / capacity) * capacity
        let insertion = pageStart + min(max(0, slot ?? capacity), min(capacity, count - pageStart))
        detachFromGroups(paths: [app.url.path])
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        groups[index].appPaths.insert(app.url.path, at: min(insertion, groups[index].appPaths.count))
        clearReorderDragState()
        return true
    }

    func dropInOpenGroup(_ sourceID: String, beside targetID: String, after: Bool) -> Bool {
        if sourceIsInOpenGroup(sourceID) {
            return reorderInOpenGroup(sourceID, beside: targetID, after: after)
        }
        return addToOpenGroup(sourceID, beside: targetID, after: after)
    }

    private func sourceIsInOpenGroup(_ sourceID: String) -> Bool {
        guard sourceID.hasPrefix("app:"),
              let groupID = openGroupID,
              let group = groups.first(where: { $0.id == groupID }) else { return false }
        return group.appPaths.contains(String(sourceID.dropFirst(4)))
    }

    func startReorderDrag(_ sourceID: String) {
        guard sourceID.count <= 4_200, let source = entry(for: sourceID) else { return }
        if !search.isEmpty {
            // Native Launchpad leaves search as soon as a result is dragged.
            // Restore the unfiltered page before interpreting any drop slots;
            // apps inside a folder remain there until the drop is committed.
            guard case .app = source, rootEntries.contains(where: { $0.id == sourceID }) else { return }
            search = ""
            if openGroupID != nil { closeFolder() }
        }
        clearKeyboardSelection()
        if reorderDragSourceID != sourceID { reorderDragSourceID = sourceID }
        if reorderPreview == nil {
            if let group = group(for: openGroupID),
               let index = apps(in: group).firstIndex(where: { $0.id == sourceID }) {
                let capacity = max(1, folderPagerLayoutInfo?.capacity ?? 35)
                setReorderPreview(LauncherReorderPreview(sourceID: sourceID, page: index / capacity, slot: index % capacity))
            } else if let index = rootEntries.firstIndex(where: { $0.id == sourceID }) {
                let capacity = max(1, rootPagerLayoutInfo?.pageSize ?? 35)
                setReorderPreview(LauncherReorderPreview(sourceID: sourceID, page: index / capacity, slot: index % capacity))
            }
        }
        reorderFolderExitStartDate = nil
        exitedDragFolderID = nil
        resetReorderEdgeHover()
        guard reorderDragTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickReorderDrag() }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        reorderDragTimer = timer
    }

    private func endReorderDrag() {
        clearReorderDragState()
    }

    func clearReorderDragState() {
        reorderDragTimer?.invalidate()
        reorderDragTimer = nil
        setReorderPreview(nil)
        if reorderDragSourceID != nil { reorderDragSourceID = nil }
        reorderFolderExitStartDate = nil
        exitedDragFolderID = nil
        resetReorderEdgeHover()
        resetReorderFolderHover()
    }

    private func setReorderPreview(_ preview: LauncherReorderPreview?) {
        guard reorderPreview != preview else { return }
        reorderPreview = preview
    }

    private func clearReorderPreview() {
        setReorderPreview(nil)
    }

    @discardableResult
    func continueReorderDragOutsideFolder() -> Bool {
        guard let sourceID = reorderDragSourceID,
              sourceID.hasPrefix("app:"), entry(for: sourceID) != nil,
              let groupID = openGroupID else { return false }
        exitedDragFolderID = groupID
        reorderFolderExitStartDate = nil
        closeFolder()
        resetReorderEdgeHover()
        return true
    }

    func updateRootPagerLayout(
        topOffset: Double,
        size: CGSize,
        metrics: LaunchpadLayoutMetrics,
        pageSize: Int
    ) {
        rootPagerLayoutInfo = RootPagerLayoutInfo(
            topOffset: topOffset,
            size: size,
            metrics: metrics,
            pageSize: pageSize
        )
    }

    func updateFolderPagerLayout(
        origin: CGPoint,
        cellWidth: Double,
        columnCount: Int,
        capacity: Int,
        columnSpacing: Double,
        rowSpacing: Double,
        itemHeight: Double,
        bandFrame: CGRect? = nil
    ) {
        folderPagerLayoutInfo = FolderPagerLayoutInfo(
            origin: origin,
            cellWidth: cellWidth,
            columnCount: columnCount,
            capacity: capacity,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            itemHeight: itemHeight,
            bandFrame: bandFrame
        )
    }

    private func tickReorderDrag() {
        if (NSEvent.pressedMouseButtons & 1) == 0 {
            endReorderDrag()
            return
        }
        guard let window = registeredLauncherWindow ?? launcherWindow() else { return }
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        guard frame.contains(mouse) else {
            resetReorderEdgeHover()
            return
        }
        updateReorderDrag(
            localX: mouse.x - frame.minX,
            localYFromTop: frame.maxY - mouse.y
        )
    }

    /// Coordinates use the launcher window's top-left origin, including search.
    func updateReorderDrag(localX: Double, localYFromTop: Double, now: Date = Date()) {
        guard reorderDragSourceID != nil,
              localX.isFinite, localYFromTop.isFinite else { return }
        if openGroupID != nil, let band = folderPagerLayoutInfo?.bandFrame {
            let point = CGPoint(x: localX, y: localYFromTop)
            if band.insetBy(dx: -12, dy: -12).contains(point) {
                reorderFolderExitStartDate = nil
            } else if let began = reorderFolderExitStartDate {
                if now.timeIntervalSince(began) >= 0.20 {
                    continueReorderDragOutsideFolder()
                }
            } else {
                reorderFolderExitStartDate = now
            }
        }
        let pagerTopOffset = rootPagerLayoutInfo?.topOffset
            ?? LaunchpadVerticalMetrics(topSafeAreaInset: displayTopSafeAreaInset).pagerTopOffset
        guard localYFromTop >= pagerTopOffset else {
            resetReorderEdgeHover()
            return
        }
        let width = rootPagerLayoutInfo?.size.width ?? 0
        if localX < 48 {
            advanceReorderEdgeHover(direction: -1)
        } else if width > 0, localX > width - 48 {
            advanceReorderEdgeHover(direction: 1)
        } else {
            resetReorderEdgeHover()
        }
        updateReorderPreview(localX: localX, localYFromTop: localYFromTop)
        updateFolderHoverOpen(localX: localX, localYFromTop: localYFromTop)
    }

    private func updateReorderPreview(localX: Double, localYFromTop: Double) {
        if openGroupID == nil {
            updateRootReorderPreview(localX: localX, localYFromTop: localYFromTop)
        } else {
            updateFolderReorderPreview(localX: localX, localYFromTop: localYFromTop)
        }
    }

    private func updateRootReorderPreview(localX: Double, localYFromTop: Double) {
        guard let sourceID = reorderDragSourceID, search.isEmpty,
              let layout = rootPagerLayoutInfo,
              layout.size.width > 1, layout.size.height > 1,
              entry(for: sourceID) != nil else {
            setReorderPreview(nil)
            return
        }
        let metrics = layout.metrics
        let pagerY = localYFromTop - layout.topOffset
        let gridOriginX = (layout.size.width - metrics.gridWidth) / 2
        guard localX >= gridOriginX - 8,
              localX <= gridOriginX + metrics.gridWidth + 8,
              pagerY >= metrics.topInset - 12,
              pagerY <= metrics.topInset + metrics.gridHeight + 12 else {
            return
        }
        let column = min(
            max(0, Int((localX - gridOriginX) / metrics.columnStride)),
            metrics.columns - 1
        )
        let row = min(
            max(0, Int((pagerY - metrics.topInset) / metrics.rowStride)),
            metrics.rows - 1
        )
        let cellDX = localX - gridOriginX - Double(column) * metrics.columnStride
            - metrics.cellWidth / 2
        let cellDY = pagerY - metrics.topInset - Double(row) * metrics.rowStride
        let iconHalf = metrics.iconSize / 2
        let entries = rootEntries
        let index = displayedPage * layout.pageSize + row * metrics.columns + column
        if sourceID.hasPrefix("app:"), entries.indices.contains(index), entries[index].id != sourceID,
           abs(cellDX) < iconHalf, cellDY >= -4, cellDY <= metrics.iconSize + 4 {
            // Keep the last insertion gap while hovering a potential folder
            // target. Collapsing it here made every tile jump back and forth.
            return
        }
        let pageCount = max(1, Int(ceil(Double(entries.count) / Double(layout.pageSize))))
        let page = min(displayedPage, pageCount - 1)
        let slot = min(
            max(0, row * metrics.columns + column + (cellDX >= 0 ? 1 : 0)),
            layout.pageSize
        )
        setReorderPreview(LauncherReorderPreview(sourceID: sourceID, page: page, slot: slot))
    }

    private func updateFolderReorderPreview(localX: Double, localYFromTop: Double) {
        guard let sourceID = reorderDragSourceID, sourceID.hasPrefix("app:"),
              let layout = folderPagerLayoutInfo,
              let groupID = openGroupID,
              let group = groups.first(where: { $0.id == groupID }) else {
            setReorderPreview(nil)
            return
        }
        let dx = localX - layout.origin.x
        let dy = localYFromTop - layout.origin.y
        let columnStride = layout.cellWidth + layout.columnSpacing
        let rowStride = layout.itemHeight + layout.rowSpacing
        let rowCount = max(1, layout.capacity / max(1, layout.columnCount))
        guard dx >= -16, dx <= Double(layout.columnCount) * columnStride,
              dy >= -12, dy <= Double(rowCount) * rowStride else {
            return
        }
        let column = min(max(0, Int(dx / columnStride)), layout.columnCount - 1)
        let row = min(max(0, Int(dy / rowStride)), rowCount - 1)
        let cellDX = dx - Double(column) * columnStride - layout.cellWidth / 2
        let pageCount = max(1, Int(ceil(Double(group.appPaths.count) / Double(layout.capacity))))
        let page = min(folderPager.displayedPage, pageCount - 1)
        let slot = min(
            max(0, row * layout.columnCount + column + (cellDX >= 0 ? 1 : 0)),
            layout.capacity
        )
        setReorderPreview(LauncherReorderPreview(sourceID: sourceID, page: page, slot: slot))
    }

    private func updateFolderHoverOpen(localX: Double, localYFromTop: Double) {
        guard openGroupID == nil,
              let sourceID = reorderDragSourceID,
              sourceID.hasPrefix("app:"),
              let layout = rootPagerLayoutInfo,
              search.isEmpty else {
            resetReorderFolderHover()
            return
        }
        guard let hoveredGroup = groupEntryAt(localX: localX, localYFromTop: localYFromTop, layout: layout),
              "group:" + hoveredGroup.id.uuidString != sourceID else {
            resetReorderFolderHover()
            exitedDragFolderID = nil
            return
        }
        guard hoveredGroup.id != exitedDragFolderID else { return }
        let now = Date()
        if reorderFolderHoverID != hoveredGroup.id {
            reorderFolderHoverID = hoveredGroup.id
            reorderFolderHoverStartDate = now
            return
        }
        guard let start = reorderFolderHoverStartDate,
              now.timeIntervalSince(start) >= 0.65 else { return }
        open(hoveredGroup)
        resetReorderFolderHover()
    }

    private func groupEntryAt(
        localX: Double,
        localYFromTop: Double,
        layout: RootPagerLayoutInfo
    ) -> AppGroup? {
        let metrics = layout.metrics
        let pagerY = localYFromTop - layout.topOffset
        let gridOriginX = (layout.size.width - metrics.gridWidth) / 2
        guard localX >= gridOriginX,
              localX <= gridOriginX + metrics.gridWidth,
              pagerY >= metrics.topInset,
              pagerY <= metrics.topInset + metrics.gridHeight else { return nil }
        let column = min(max(0, Int((localX - gridOriginX) / metrics.columnStride)), metrics.columns - 1)
        let row = min(max(0, Int((pagerY - metrics.topInset) / metrics.rowStride)), metrics.rows - 1)
        let slot = row * metrics.columns + column
        let page = min(displayedPage, pageCount - 1)
        let index = page * layout.pageSize + slot
        guard rootEntries.indices.contains(index),
              case .group(let group) = rootEntries[index] else { return nil }
        let cellX = localX - gridOriginX - Double(column) * metrics.columnStride
        let cellY = pagerY - metrics.topInset - Double(row) * metrics.rowStride
        let iconMinX = (metrics.cellWidth - metrics.iconSize) / 2
        let isInsideIcon = cellX >= iconMinX
            && cellX <= iconMinX + metrics.iconSize
            && cellY >= 0
            && cellY <= metrics.iconSize
        return isInsideIcon ? group : nil
    }

    private func advanceReorderEdgeHover(direction: Int) {
        let now = Date()
        if reorderEdgeHoverDirection != direction {
            reorderEdgeHoverDirection = direction
            reorderEdgeHoverStartDate = now
            reorderEdgeHoverHasFlipped = false
            return
        }
        let dwell = reorderEdgeHoverHasFlipped ? 0.55 : 0.7
        guard let start = reorderEdgeHoverStartDate,
              now.timeIntervalSince(start) >= dwell else { return }
        reorderEdgeHoverHasFlipped = true
        reorderEdgeHoverStartDate = now
        if openGroupID == nil {
            guard search.isEmpty else { return }
            changePage(by: direction)
        } else {
            goToFolderPage(folderPager.page + direction)
        }
    }

    private func resetReorderEdgeHover() {
        reorderEdgeHoverDirection = nil
        reorderEdgeHoverStartDate = nil
        reorderEdgeHoverHasFlipped = false
    }

    private func resetReorderFolderHover() {
        reorderFolderHoverID = nil
        reorderFolderHoverStartDate = nil
    }

    func deletePendingApplication() {
        guard !isDeleting else { return }
        guard let requested = pendingDeleteApp,
              let app = apps.first(where: { $0.id == requested.id }), app.isDeletable else {
            pendingDeleteApp = nil
            return
        }
        pendingDeleteApp = nil
        isDeleting = true
        let fileOperator = fileOperator
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        deleteTask = Task { [weak self] in
            let outcome = await fileOperator.moveApplicationToTrash(app.url, homeDirectory: homeDirectory)
            guard !Task.isCancelled, let self else { return }
            self.deleteTask = nil
            self.isDeleting = false
            switch outcome {
            case .success:
                self.detachFromGroups(paths: [app.url.path])
                self.apps.removeAll { $0.id == app.id }
                self.rootOrder.removeAll { $0 == app.id }
                if self.selectedEntryID == app.id { self.clearKeyboardSelection() }
                self.scan()
            case .failure(let details):
                self.presentError(
                    en: "The application could not be moved to the Trash: \(details)",
                    ja: "アプリケーションをゴミ箱へ移動できませんでした: \(details)",
                    zhHant: "無法將應用程式移到垃圾桶：\(details)"
                )
            }
        }
    }

    func maximizeLauncherWindow() {
        guard initialWindowFrameReady else { return }
        dismissalRequestID = nil
        isDismissing = false
        isLauncherVisible = true
        let requestID = UUID()
        presentationRequestID = requestID
        configureLauncherWindow(requestID: requestID, remainingAttempts: 6)
    }

    func registerLauncherWindow(_ window: NSWindow) {
        removeLauncherDisplayObservers()
        registeredLauncherWindow = window
        initialWindowFrameReady = false
        updateDisplayTopSafeAreaInset(for: window.screen ?? NSScreen.main)
        let center = NotificationCenter.default
        let notifications: [(Notification.Name, AnyObject?)] = [
            (NSApplication.didChangeScreenParametersNotification, nil),
            (NSWindow.didChangeScreenNotification, window),
            (NSWindow.didChangeBackingPropertiesNotification, window)
        ]
        for (name, object) in notifications {
            launcherDisplayObservers.append(center.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLauncherDisplayChange() }
            })
        }
    }

    func markInitialWindowFrameReady() {
        initialWindowFrameReady = true
    }

    private func configureLauncherWindow(requestID: UUID, remainingAttempts: Int) {
        guard presentationRequestID == requestID else { return }
        let mainWindow = launcherWindow()

        guard let window = mainWindow, let screen = window.screen ?? NSScreen.main else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.configureLauncherWindow(
                    requestID: requestID,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        updateDisplayTopSafeAreaInset(for: screen)
        NSApp.setActivationPolicy(.accessory)
        LauncherWindowPresentation.configureChrome(of: window)
        window.hasShadow = false
        window.level = .floating
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.setFrame(screen.frame, display: true, animate: false)
        resetLauncherWindowVisualState(window)
        refreshBackgroundImage(screen: screen)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        updateLauncherPresentationOptions()
    }

    private func updateDisplayTopSafeAreaInset(for screen: NSScreen?) {
        let sanitized = LaunchpadVerticalMetrics(
            topSafeAreaInset: Double(screen?.safeAreaInsets.top ?? 0)
        ).topSafeAreaInset
        if displayTopSafeAreaInset != sanitized { displayTopSafeAreaInset = sanitized }
    }

    private func handleLauncherDisplayChange() {
        guard !isUpdatingLauncherDisplayGeometry,
              let window = registeredLauncherWindow else { return }
        let screen = window.screen ?? NSScreen.main
        updateDisplayTopSafeAreaInset(for: screen)
        // Resolution, display placement and scale changes update an already
        // visible launcher in place. Notifications must never reopen a hidden
        // launcher or steal focus from the user's current application.
        guard let screen, window.isVisible, !isDismissing else { return }
        isUpdatingLauncherDisplayGeometry = true
        defer { isUpdatingLauncherDisplayGeometry = false }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true, animate: false)
        }
        refreshBackgroundImage(screen: screen)
    }

    private func removeLauncherDisplayObservers() {
        for observer in launcherDisplayObservers { NotificationCenter.default.removeObserver(observer) }
        launcherDisplayObservers.removeAll(keepingCapacity: false)
    }

    private func updateLauncherPresentationOptions() {
        guard let application = NSApp, application.isActive, !isDismissing,
              let window = registeredLauncherWindow, window.isVisible else { return }
        // Root Launchpad keeps the real Dock available. hideMenuBar alone is
        // an invalid AppKit combination; autoHideMenuBar is supported without
        // hiding the Dock on the modern macOS versions this app targets.
        let options: NSApplication.PresentationOptions = openGroupID == nil
            ? [.autoHideMenuBar] : [.hideDock, .hideMenuBar]
        if application.presentationOptions != options { application.presentationOptions = options }
    }

    private func launcherWindow() -> NSWindow? {
        if let registeredLauncherWindow { return registeredLauncherWindow }
        guard let app = NSApp else { return nil }
        if let keyWindow = app.keyWindow,
           keyWindow.sheetParent == nil,
           !(keyWindow is NSPanel) {
            return keyWindow
        }
        return app.windows.first(where: { window in
            window.sheetParent == nil && !(window is NSPanel)
        })
    }

    private func animateLauncherDismissal(
        requestID: UUID,
        window: NSWindow,
        includesScale: Bool
    ) {
        if includesScale {
            let contentLayer = window.contentView.flatMap { contentView -> CALayer? in
                contentView.wantsLayer = true
                return contentView.layer
            }
            if let contentLayer {
                centerAnchorPoint(of: contentLayer)
                let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
                scaleAnimation.fromValue = 1.0
                scaleAnimation.toValue = LaunchpadDismissMotion.scale
                scaleAnimation.duration = LaunchpadDismissMotion.duration
                scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                contentLayer.transform = CATransform3DMakeScale(
                    LaunchpadDismissMotion.scale,
                    LaunchpadDismissMotion.scale,
                    1
                )
                CATransaction.commit()
                contentLayer.add(scaleAnimation, forKey: "launchpad.dismiss.scale")
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = includesScale
                ? LaunchpadDismissMotion.duration
                : LaunchpadDismissMotion.reducedMotionFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.finishLauncherDismissal(requestID: requestID, window: window)
            }
        }
    }

    private func finishLauncherDismissal(requestID: UUID, window: NSWindow) {
        guard dismissalRequestID == requestID else { return }
        window.orderOut(nil)
        resetLauncherWindowVisualState(window)
        for childWindow in window.childWindows ?? [] {
            childWindow.close()
        }
        showLauncherSettings = false
        pendingDeleteApp = nil
        closeFolder()
        search = ""
        isLauncherVisible = false
        releaseTransientImageResources()
        NSApp.presentationOptions = []
        dismissalRequestID = nil
        isDismissing = false
        NSApp.hide(nil)
    }

    private func restoreLauncherAfterFailedLaunch() {
        dismissalRequestID = nil
        isDismissing = false
        isLauncherVisible = true
        NSApp.unhide(nil)
        if let window = launcherWindow() {
            resetLauncherWindowVisualState(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        maximizeLauncherWindow()
    }

    func shutdown() {
        removeLauncherDisplayObservers()
        applicationMonitor?.stop()
        applicationMonitor = nil
        applicationScanTask?.cancel()
        wallpaperScanTask?.cancel()
        deleteTask?.cancel()
        backgroundLoadTask?.cancel()
        cacheMaintenanceTask?.cancel()
        initialIconPreloadTask?.cancel()
        reorderDragTimer?.invalidate()
        reorderDragTimer = nil
        if let accessibilityOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityOptionsObserver)
        }
        accessibilityOptionsObserver = nil
        iconImageCache.removeAllObjects()
        selectedBackgroundImage = nil
        requestedBackgroundPath = nil
        registeredLauncherWindow = nil
        initialReadinessHandlers.removeAll(keepingCapacity: false)
    }

    private func startApplicationMonitoring() {
        let roots = LauncherFileScanner.applicationRoots(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let monitor = LauncherApplicationMonitor(roots: roots) { [weak self] in
            guard let self else { return }
            self.scan()
        }
        applicationMonitor = monitor
        monitor.start()
    }

    private func releaseTransientImageResources() {
        imageResourceGeneration &+= 1
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        selectedBackgroundImage = nil
        requestedBackgroundPath = nil
        iconImageCache.removeAllObjects()
        let previousCleanup = cacheMaintenanceTask
        let iconLoader = iconLoader
        cacheMaintenanceTask = Task {
            await previousCleanup?.value
            await iconLoader.removeAllCachedIcons()
        }
        // Keep only the loader's one downsampled wallpaper (at most 9 MiB).
        // Re-decoding the original on every reopen caused higher transient
        // peaks than retaining this small pixel buffer between presentations.
    }

    /// Warm only the page about to be shown before making the window visible.
    /// Hidden windows can then release image state without a blank reopening.
    func prepareForPresentation() async {
        await cacheMaintenanceTask?.value
        guard !Task.isCancelled else { return }
        cacheMaintenanceTask = nil
        refreshBackgroundImage(screen: registeredLauncherWindow?.screen)
        let backgroundTask = backgroundLoadTask
        let capacity = max(1, rootPagerLayoutInfo?.pageSize ?? 35)
        let entries = rootEntries
        let start = min(max(0, currentPage) * capacity, entries.count)
        let visibleEntries = entries.dropFirst(start).prefix(capacity)
        var seen: Set<String> = []
        for entry in visibleEntries {
            let needed: [AppItem]
            switch entry {
            case .app(let app): needed = [app]
            case .group(let group): needed = Array(apps(in: group).prefix(9))
            }
            for app in needed where seen.insert(app.id).inserted {
                guard !Task.isCancelled else { return }
                _ = await loadIcon(for: app)
            }
        }
        await backgroundTask?.value
    }

    private func preloadInitialPageIconsIfNeeded() {
        guard !initialApplicationsReady else {
            evaluateInitialContentReadiness()
            return
        }

        var seenPaths: Set<String> = []
        var preloadApps: [AppItem] = []
        for entry in rootEntries.prefix(35) {
            let entryApps: [AppItem]
            switch entry {
            case .app(let app):
                entryApps = [app]
            case .group(let group):
                entryApps = Array(apps(in: group).prefix(9))
            }
            for app in entryApps where seenPaths.insert(app.url.path).inserted {
                preloadApps.append(app)
                if preloadApps.count >= LauncherMemoryPolicy.iconImageCacheCount { break }
            }
            if preloadApps.count >= LauncherMemoryPolicy.iconImageCacheCount { break }
        }

        initialIconPreloadTask?.cancel()
        initialIconPreloadTask = Task { [weak self] in
            guard let self else { return }
            for app in preloadApps {
                guard !Task.isCancelled else { return }
                _ = await self.loadIcon(for: app)
            }
            guard !Task.isCancelled else { return }
            self.initialIconPreloadTask = nil
            self.markInitialApplicationsReady()
        }
    }

    private func markInitialApplicationsReady() {
        guard !initialApplicationsReady else { return }
        initialApplicationsReady = true
        evaluateInitialContentReadiness()
    }

    private func markInitialBackgroundReady() {
        guard !initialBackgroundReady else { return }
        initialBackgroundReady = true
        evaluateInitialContentReadiness()
    }

    private func evaluateInitialContentReadiness() {
        guard !isInitialContentReady,
              initialApplicationsReady,
              initialBackgroundReady else { return }
        isInitialContentReady = true
        let handlers = initialReadinessHandlers
        initialReadinessHandlers.removeAll(keepingCapacity: false)
        for handler in handlers { handler() }
    }

    private func resetLauncherWindowVisualState(_ window: NSWindow) {
        window.alphaValue = 1
        guard let contentLayer = window.contentView?.layer else { return }
        contentLayer.removeAnimation(forKey: "launchpad.dismiss.scale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func centerAnchorPoint(of layer: CALayer) {
        let centeredAnchor = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != centeredAnchor else { return }
        let oldPoint = CGPoint(
            x: layer.bounds.width * layer.anchorPoint.x,
            y: layer.bounds.height * layer.anchorPoint.y
        )
        let newPoint = CGPoint(
            x: layer.bounds.width * centeredAnchor.x,
            y: layer.bounds.height * centeredAnchor.y
        )
        var position = layer.position
        position.x += newPoint.x - oldPoint.x
        position.y += newPoint.y - oldPoint.y
        layer.position = position
        layer.anchorPoint = centeredAnchor
    }

    private func entry(for id: String) -> LauncherEntry? {
        if id.hasPrefix("app:"), let app = apps.first(where: { $0.id == id }) { return .app(app) }
        if id.hasPrefix("group:"), let uuid = UUID(uuidString: String(id.dropFirst(6))),
           let group = groups.first(where: { $0.id == uuid }) { return .group(group) }
        return nil
    }

    private func saveGroups() {
        do {
            let data = try JSONEncoder().encode(groups)
            defaults.set(data, forKey: groupsKey)
        } catch {
            presentError(
                en: "The folder arrangement could not be saved.",
                ja: "フォルダの構成を保存できませんでした。",
                zhHant: "無法儲存資料夾配置。"
            )
        }
    }

    private func refreshBackgroundImage(screen: NSScreen? = nil) {
        backgroundLoadTask?.cancel()
        let imageURL: URL?
        if background.hasPrefix("file:") {
            imageURL = URL(fileURLWithPath: String(background.dropFirst(5)))
        } else if background == "wallpaper", let targetScreen = screen ?? NSScreen.main {
            imageURL = NSWorkspace.shared.desktopImageURL(for: targetScreen)
        } else {
            imageURL = nil
        }

        guard let imageURL else {
            requestedBackgroundPath = nil
            selectedBackgroundImage = nil
            markInitialBackgroundReady()
            return
        }
        let path = imageURL.standardizedFileURL.path
        if requestedBackgroundPath == path, selectedBackgroundImage != nil {
            markInitialBackgroundReady()
            return
        }
        requestedBackgroundPath = path
        selectedBackgroundImage = nil
        let loader = backgroundImageLoader
        backgroundLoadTask = Task { [weak self] in
            let imageData = await loader.imageData(for: imageURL)
            guard !Task.isCancelled, let self, self.requestedBackgroundPath == path else { return }
            self.backgroundLoadTask = nil
            self.selectedBackgroundImage = imageData?.makeImage()
            if imageData == nil { self.requestedBackgroundPath = nil }
            self.markInitialBackgroundReady()
        }
    }
    private func saveOrder() { defaults.set(Self.sanitizedOrder(rootOrder), forKey: orderKey) }

    private func updateLocalizedSystemGroupNames() {
        var updatedGroups = groups
        var changed = false

        for index in updatedGroups.indices {
            let knownNames: Set<String>
            let localizedName: String
            switch updatedGroups[index].systemKind {
            case "utilities":
                knownNames = ["Utilities", "ユーティリティ", "工具程式"]
                localizedName = text("Utilities", "ユーティリティ", "工具程式")
            case "games":
                knownNames = ["Games", "ゲーム", "遊戲"]
                localizedName = text("Games", "ゲーム", "遊戲")
            default:
                continue
            }

            guard knownNames.contains(updatedGroups[index].name),
                  updatedGroups[index].name != localizedName else { continue }
            updatedGroups[index].name = localizedName
            changed = true
        }

        if changed { groups = updatedGroups }
    }

    private func bootstrapDefaultGroupsIfNeeded() {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        let alreadyGrouped = Set(groups.flatMap(\.appPaths))
        let utilities = apps.filter {
            LaunchpadStandardUtilities.contains($0) && !alreadyGrouped.contains($0.url.path)
        }
        let games = apps.filter { $0.category == "public.app-category.games" && !alreadyGrouped.contains($0.url.path) }
        if !utilities.isEmpty {
            groups.append(AppGroup(
                name: text("Utilities", "ユーティリティ", "工具程式"),
                appPaths: utilities.map(\.url.path),
                systemKind: "utilities"
            ))
        }
        if !games.isEmpty {
            groups.append(AppGroup(
                name: text("Games", "ゲーム", "遊戲"),
                appPaths: games.map(\.url.path),
                systemKind: "games"
            ))
        }
        defaults.set(true, forKey: defaultsKey)
        defaults.set(true, forKey: sequoiaUtilitiesMigrationKey)
    }

    func reconcileSequoiaUtilitiesIfNeeded() {
        guard !defaults.bool(forKey: sequoiaUtilitiesMigrationKey) else { return }
        defer { defaults.set(true, forKey: sequoiaUtilitiesMigrationKey) }

        let grouped = Set(groups.flatMap(\.appPaths))
        let newPaths = apps.filter(LaunchpadStandardUtilities.contains).map(\.url.path).filter {
            !grouped.contains($0)
        }
        guard !newPaths.isEmpty else { return }

        if let index = groups.firstIndex(where: { $0.systemKind == "utilities" }) {
            groups[index].appPaths.append(contentsOf: newPaths)
        } else {
            groups.append(AppGroup(
                name: text("Utilities", "ユーティリティ", "工具程式"),
                appPaths: newPaths,
                systemKind: "utilities"
            ))
        }
    }
    private func syncNewGames() {
        let gamePaths = apps.filter { $0.category == "public.app-category.games" }.map(\.url.path)
        guard !gamePaths.isEmpty else { return }
        let grouped = Set(groups.flatMap(\.appPaths))
        let newPaths = gamePaths.filter { !grouped.contains($0) }
        guard !newPaths.isEmpty else { return }
        if let index = groups.firstIndex(where: { $0.systemKind == "games" }) {
            groups[index].appPaths.append(contentsOf: newPaths)
        } else {
            groups.append(AppGroup(
                name: text("Games", "ゲーム", "遊戲"),
                appPaths: newPaths,
                systemKind: "games"
            ))
        }
    }
    private func detachFromGroups(paths: Set<String>) {
        let previousOrder = rootEntries.map(\.id)
        var replacements: [String: [String]] = [:]
        var updatedGroups: [AppGroup] = []
        for var group in groups {
            guard group.appPaths.contains(where: paths.contains) else {
                updatedGroups.append(group)
                continue
            }
            group.appPaths.removeAll { paths.contains($0) }
            let remaining = apps(in: group)
            if remaining.count <= 1 {
                replacements["group:" + group.id.uuidString] = remaining.map(\.id)
                if openGroupID == group.id { closeFolder() }
            } else {
                updatedGroups.append(group)
            }
        }
        groups = updatedGroups
        if !replacements.isEmpty {
            rootOrder = previousOrder.flatMap { replacements[$0] ?? [$0] }
        }
    }

    private func moveAppOut(_ sourceApp: AppItem, from groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].appPaths.contains(sourceApp.url.path) else { return }

        let previousOrder = rootEntries.map(\.id)
        let folderID = "group:" + groupID.uuidString
        groups[index].appPaths.removeAll { $0 == sourceApp.url.path }

        var replacements = [folderID, sourceApp.id]
        let remainingApps = apps(in: groups[index])
        if remainingApps.count <= 1 {
            groups.remove(at: index)
            replacements = remainingApps.map(\.id) + [sourceApp.id]
            if openGroupID == groupID { closeFolder() }
        }

        var order = previousOrder
        let insertion = order.firstIndex(of: folderID) ?? order.count
        order.removeAll { $0 == folderID || replacements.contains($0) }
        order.insert(contentsOf: replacements, at: min(insertion, order.count))
        rootOrder = order
        clearReorderDragState()
    }
    private func replaceOrderItems(_ removed: [String], with newID: String, in existingOrder: [String]) {
        var order = existingOrder
        let indices = removed.compactMap { order.firstIndex(of: $0) }
        let insertion = indices.min() ?? order.count
        order.removeAll { removed.contains($0) }
        order.removeAll { $0 == newID }
        order.insert(newID, at: min(insertion, order.count))
        rootOrder = order
    }

    private func removeMissingApplicationsFromOpenState() {
        if let selectedEntryID, !keyboardEntries.contains(where: { $0.id == selectedEntryID }) {
            clearKeyboardSelection()
        }
        if let pendingDeleteApp, !apps.contains(where: { $0.id == pendingDeleteApp.id }) {
            self.pendingDeleteApp = nil
        }
        if let openGroupID {
            guard let group = groups.first(where: { $0.id == openGroupID }) else {
                closeFolder()
                return
            }
            if apps(in: group).isEmpty { closeFolder() }
        }
    }

    func clearError() { errorMessage = nil }

    private func presentError(en: String, ja: String, zhHant: String) {
        errorMessage = text(en, ja, zhHant)
    }

    nonisolated static func sanitizedLanguage(_ value: String?) -> String {
        guard let value else { return "en" }
        switch value {
        case "system", "en", "ja", "zh-Hant": return value
        case "zh-TW", "zh-HK", "zh-MO": return "zh-Hant"
        default: return "en"
        }
    }

    nonisolated static func resolvedSystemLanguage(from preferredLanguages: [String]) -> String {
        guard let preferredLanguage = preferredLanguages.first else { return "en" }
        let normalized = preferredLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("ja") { return "ja" }
        if normalized.hasPrefix("zh-hant")
            || normalized.hasPrefix("zh-tw")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        return "en"
    }

    nonisolated static func sanitizedIconSize(_ value: Double) -> Double {
        guard value.isFinite else { return 92 }
        return min(max(value, 60), 112)
    }

    nonisolated static func referenceDefaultIconSize(pageWidth: Double) -> Double {
        guard pageWidth.isFinite, pageWidth > 0 else { return 90 }
        return min(max(pageWidth * 90 / 1440, 72), 112)
    }

    nonisolated static func iconHasOpaqueCorners(_ icon: NSImage) -> Bool {
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let side = 24
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        func isCornerOpaque(_ x: Int, _ y: Int) -> Bool {
            pixels[(y * side + x) * 4 + 3] >= 246
        }
        let inset = 2
        return isCornerOpaque(inset, inset)
            && isCornerOpaque(side - 1 - inset, inset)
            && isCornerOpaque(inset, side - 1 - inset)
            && isCornerOpaque(side - 1 - inset, side - 1 - inset)
    }

    nonisolated static func sanitizedBackground(_ value: String) -> String {
        let builtInValues: Set<String> = ["wallpaper", "aurora", "ocean", "dark", "light"]
        if builtInValues.contains(value) { return value }
        guard value.hasPrefix("file:") else { return "wallpaper" }
        let path = String(value.dropFirst(5))
        let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        guard path.hasPrefix("/"), path.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              allowedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: path) else { return "wallpaper" }
        return "file:" + URL(fileURLWithPath: path).standardizedFileURL.path
    }

    nonisolated static func sanitizedSearch(_ value: String) -> String {
        let withoutControls = value.components(separatedBy: .controlCharacters).joined()
        return String(withoutControls.prefix(128))
    }

    nonisolated static func sanitizedGroupName(_ value: String, allowEmpty: Bool, fallback: String) -> String {
        let withoutControls = value.components(separatedBy: .controlCharacters).joined()
        let limited = String(withoutControls.prefix(64))
        if allowEmpty { return limited }
        let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated static func sanitizedOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values.prefix(10_000) {
            guard value.count <= 4_200, isStructurallyValidEntryID(value), seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    nonisolated static func sanitizedGroups(_ values: [AppGroup]) -> [AppGroup] {
        var seenGroupIDs: Set<UUID> = []
        var assignedPaths: Set<String> = []
        var result: [AppGroup] = []

        for group in values.prefix(500) where seenGroupIDs.insert(group.id).inserted {
            var paths: [String] = []
            for path in group.appPaths.prefix(2_000) {
                guard isStructurallyValidAppPath(path), assignedPaths.insert(path).inserted else { continue }
                paths.append(path)
            }
            guard !paths.isEmpty else { continue }
            let fallback = group.systemKind == "utilities" ? "Utilities" : (group.systemKind == "games" ? "Games" : "Folder")
            let systemKind = ["utilities", "games"].contains(group.systemKind ?? "") ? group.systemKind : nil
            result.append(AppGroup(
                id: group.id,
                name: sanitizedGroupName(group.name, allowEmpty: false, fallback: fallback),
                appPaths: paths,
                systemKind: systemKind
            ))
        }
        return result
    }

    nonisolated private static func isStructurallyValidEntryID(_ value: String) -> Bool {
        if value.hasPrefix("app:") { return isStructurallyValidAppPath(String(value.dropFirst(4))) }
        if value.hasPrefix("group:") { return UUID(uuidString: String(value.dropFirst(6))) != nil }
        return false
    }

    nonisolated private static func isStructurallyValidAppPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 4_096
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }
}

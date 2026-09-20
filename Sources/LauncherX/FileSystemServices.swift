import Foundation
import AppKit
import ImageIO
import CryptoKit
import Darwin

enum LauncherMemoryPolicy {
    static let iconPixelSize = 256
    static let iconLogicalPointSize = 128
    static let iconDataCacheCount = 48
    static let iconDataCacheCost = 12 * 1_024 * 1_024
    static let iconImageCacheCount = 48
    static let iconImageCacheCost = 16 * 1_024 * 1_024
    static let backgroundMaximumPixelSize = 3_072
    static let backgroundCacheCount = 1
    static let backgroundCacheCost = 48 * 1_024 * 1_024

    static let maximumPersistentCacheCost = iconDataCacheCost
        + iconImageCacheCost
        + backgroundCacheCost
}

struct AppScanResult: Sendable {
    let apps: [AppItem]
    let accessibleRootCount: Int
}

enum FileOperationOutcome: Sendable {
    case success
    case failure(String)
}

actor LauncherFileScanner {
    nonisolated static func applicationRoots(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    func scanApplications(
        homeDirectory: URL,
        preferredLocalizations: [String] = ["en"]
    ) -> AppScanResult {
        Self.scanApplications(
            in: Self.applicationRoots(homeDirectory: homeDirectory),
            preferredLocalizations: preferredLocalizations
        )
    }

    func scanWallpapers() -> [WallpaperItem] {
        let roots = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true)
        ]
        return Self.scanWallpapers(in: roots)
    }

    nonisolated static func scanApplications(
        in roots: [URL],
        preferredLocalizations: [String] = ["en"]
    ) -> AppScanResult {
        let fileManager = FileManager()
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let maximumDirectoriesPerRoot = 20_000
        var accessibleRootCount = 0
        var found: [String: AppItem] = [:]

        for root in roots.prefix(64) {
            guard !Task.isCancelled, root.isFileURL,
                  fileManager.fileExists(atPath: root.path) else { continue }

            var pendingDirectories = [root.standardizedFileURL]
            var visitedDirectories: Set<String> = []
            var didReadRoot = false

            while let directory = pendingDirectories.popLast(),
                  visitedDirectories.count < maximumDirectoriesPerRoot {
                guard !Task.isCancelled else {
                    return AppScanResult(apps: [], accessibleRootCount: accessibleRootCount)
                }
                let resolvedDirectory = directory.resolvingSymlinksInPath()
                guard visitedDirectories.insert(resolvedDirectory.path).inserted,
                      let children = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: [.skipsHiddenFiles]
                      ) else { continue }

                if !didReadRoot {
                    accessibleRootCount += 1
                    didReadRoot = true
                }

                for child in children {
                    guard !Task.isCancelled else {
                        return AppScanResult(apps: [], accessibleRootCount: accessibleRootCount)
                    }
                    if isSafeFileURL(child, extensions: ["app"]) {
                        addApplication(
                            at: child,
                            fileManager: fileManager,
                            preferredLocalizations: preferredLocalizations,
                            to: &found
                        )
                        continue
                    }

                    guard child.path.count <= 4_096,
                          !child.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                          let values = try? child.resourceValues(forKeys: resourceKeys),
                          values.isDirectory == true,
                          values.isPackage != true,
                          values.isSymbolicLink != true else { continue }
                    pendingDirectories.append(child)
                }
            }
        }

        let apps = found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return AppScanResult(apps: apps, accessibleRootCount: accessibleRootCount)
    }

    nonisolated private static func addApplication(
        at url: URL,
        fileManager: FileManager,
        preferredLocalizations: [String],
        to found: inout [String: AppItem]
    ) {
        let standardizedURL = url.standardizedFileURL
        let resolvedURL = standardizedURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resolvedURL.isFileURL,
              resolvedURL.path.count <= 4_096,
              !resolvedURL.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              resolvedURL.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let deduplicationPath = resolvedURL.path
        let bundle = Bundle(url: standardizedURL)
        guard found[deduplicationPath] == nil, !isLauncherSelf(url: standardizedURL, bundle: bundle) else { return }
        let category = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let receipt = standardizedURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        let isSystemApp = resolvedURL.path.hasPrefix("/System/")
        let deletable = !isSystemApp && fileManager.fileExists(atPath: receipt)
        found[deduplicationPath] = AppItem(
            url: standardizedURL,
            bundleIdentifier: bundle?.bundleIdentifier,
            category: category,
            isDeletable: deletable,
            displayName: Self.localizedApplicationName(
                bundle: bundle,
                preferredLocalizations: preferredLocalizations
            )
        )
    }

    /// The launcher itself must never appear in its own application grid.
    nonisolated private static func isLauncherSelf(url: URL, bundle: Bundle?) -> Bool {
        let main = Bundle.main
        if let identifier = bundle?.bundleIdentifier,
           let mainIdentifier = main.bundleIdentifier,
           identifier == mainIdentifier {
            return true
        }
        return url.standardizedFileURL.path == main.bundleURL.standardizedFileURL.path
    }

    /// Resolves the application name Finder shows, following the effective
    /// language preference order. Finder honors localized CFBundleDisplayName
    /// / CFBundleName (from InfoPlist.strings or the modern
    /// InfoPlist.loctable); a bare non-localized CFBundleDisplayName is
    /// ignored (e.g. OBS.app), and otherwise the file name is shown.
    nonisolated private static func localizedApplicationName(
        bundle: Bundle?,
        preferredLocalizations: [String]
    ) -> String? {
        guard let bundle else { return nil }
        let available = Set(bundle.localizations)
        for candidate in preferredLocalizations where available.contains(candidate) {
            if let name = infoPlistStringValue(bundle: bundle, localization: candidate) {
                return name
            }
        }
        return nil
    }

    /// Ordered localization directory/table names mirroring the way Finder
    /// applies the user's language preference list. `languageSetting`
    /// "system" derives the order from the actual preferred languages, so
    /// any system language (zh-Hant-HK, zh-Hans, ja, fr, …) resolves names
    /// just as Finder does; an explicit setting uses that language's order.
    nonisolated static func localizationCandidates(
        languageSetting: String,
        preferredLanguages: [String]
    ) -> [String] {
        var ordered: [String] = []
        if languageSetting == "system" {
            for preference in preferredLanguages.prefix(8) {
                ordered.append(contentsOf: lprojCandidates(forPreference: preference))
            }
        } else {
            ordered.append(contentsOf: lprojCandidates(forPreference: languageSetting))
        }
        ordered.append(contentsOf: ["Base", "en"])
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    nonisolated private static func lprojCandidates(forPreference preference: String) -> [String] {
        let normalized = preference.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("yue") {
            return ["yue", "zh-Hant-HK", "zh-HK", "zh_HK", "zh-Hant", "zh_TW"]
        }
        if normalized.hasPrefix("zh-hant-hk")
            || normalized.hasPrefix("zh-hant-mo")
            || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-mo") {
            return ["zh-Hant-HK", "zh-HK", "zh_HK", "zh-Hant", "zh_TW"]
        }
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") {
            return ["zh-Hant", "zh_TW", "zh-Hant-HK", "zh_HK", "zh-HK", "zh_CN", "zh"]
        }
        if normalized.hasPrefix("zh-hans")
            || normalized.hasPrefix("zh-cn")
            || normalized.hasPrefix("zh-sg")
            || normalized == "zh" {
            return ["zh-Hans", "zh_CN", "zh-Hans-CN", "zh-Hans-SG", "zh"]
        }
        if normalized.hasPrefix("ja") { return ["ja", "ja-JP", "ja_JP"] }
        if normalized.hasPrefix("ko") { return ["ko", "ko-KR", "ko_KR"] }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return [normalized, base].filter { !$0.isEmpty }
    }

    nonisolated private static func infoPlistStringValue(
        bundle: Bundle,
        localization: String
    ) -> String? {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        if let resourceURL = bundle.resourceURL,
           let table = NSDictionary(
               contentsOfFile: resourceURL.appendingPathComponent("InfoPlist.loctable").path
           ),
           let entry = table[localization] as? [String: String] {
            for key in keys where sanitizedDisplayName(entry[key]) != nil {
                return sanitizedDisplayName(entry[key])
            }
        }
        if let path = bundle.path(
            forResource: "InfoPlist",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: localization
        ),
           let strings = NSDictionary(contentsOfFile: path) as? [String: String] {
            for key in keys where sanitizedDisplayName(strings[key]) != nil {
                return sanitizedDisplayName(strings[key])
            }
        }
        return nil
    }

    nonisolated private static func sanitizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 128 else { return nil }
        return cleaned
    }

    nonisolated static func scanWallpapers(in roots: [URL]) -> [WallpaperItem] {
        let fileManager = FileManager()
        let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        var found: [String: WallpaperItem] = [:]

        for root in roots {
            guard !Task.isCancelled, root.isFileURL,
                  fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }
                  ) else { continue }

            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return [] }
                guard isSafeFileURL(url, extensions: allowedExtensions) else { continue }
                let standardizedURL = url.standardizedFileURL
                found[standardizedURL.path] = WallpaperItem(url: standardizedURL)
            }
        }

        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func isSafeFileURL(_ url: URL, extensions: Set<String>) -> Bool {
        guard url.isFileURL, url.path.count <= 4_096,
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              extensions.contains(url.pathExtension.lowercased()) else { return false }
        return true
    }
}

@MainActor
final class LauncherApplicationMonitor {
    private let roots: [URL]
    private let debounceInterval: Duration
    private let onChange: @MainActor () -> Void
    private let eventQueue = DispatchQueue(
        label: "jp.local.launchpadclassic.application-monitor",
        qos: .utility
    )
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?

    private(set) var monitoredRootCount = 0

    init(
        roots: [URL],
        debounceInterval: Duration = .seconds(1.5),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.roots = roots
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    func start() {
        stopSources()
        for root in Self.monitorableRoots(from: roots) {
            let descriptor = Darwin.open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
                queue: eventQueue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleChangeNotification()
                }
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
        monitoredRootCount = sources.count
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        stopSources()
    }

    nonisolated static func monitorableRoots(from roots: [URL]) -> [URL] {
        let fileManager = FileManager()
        var seen: Set<String> = []
        var result: [URL] = []
        for root in roots.prefix(16) {
            let standardizedURL = root.standardizedFileURL
            let path = standardizedURL.path
            var isDirectory: ObjCBool = false
            guard standardizedURL.isFileURL,
                  path.count <= 4_096,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(path).inserted else { continue }
            result.append(standardizedURL)
        }
        return result
    }

    private func scheduleChangeNotification() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.onChange()
        }
    }

    private func stopSources() {
        for source in sources { source.cancel() }
        sources.removeAll(keepingCapacity: false)
        monitoredRootCount = 0
    }
}

actor LauncherFileOperator {
    func moveApplicationToTrash(_ url: URL, homeDirectory: URL) -> FileOperationOutcome {
        let fileManager = FileManager()
        let appURL = url.standardizedFileURL
        let appPath = appURL.path
        let userApplicationsPath = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        let isInApplications = appPath.hasPrefix("/Applications/") || appPath.hasPrefix(userApplicationsPath)
        let receiptPath = appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path

        guard appURL.isFileURL,
              appURL.pathExtension.lowercased() == "app",
              appPath.count <= 4_096,
              !appPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              isInApplications,
              fileManager.fileExists(atPath: appPath),
              fileManager.fileExists(atPath: receiptPath) else {
            return .failure("The application is no longer in a deletable location.")
        }

        do {
            try fileManager.trashItem(at: appURL, resultingItemURL: nil)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

actor LauncherIconLoader {
    private static let renderedPixelSize = LauncherMemoryPolicy.iconPixelSize
    private static let pngMagicBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let maximumDiskCacheEntries = 512
    private static let diskCacheSweepTrigger = 128
    private static let diskCacheAgeLimit: TimeInterval = 60 * 24 * 3_600
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = LauncherMemoryPolicy.iconDataCacheCount
        cache.totalCostLimit = LauncherMemoryPolicy.iconDataCacheCost
        return cache
    }()
    private var writesSinceSweep = 0
    private var didPerformInitialSweep = false

    func iconData(for url: URL) -> Data? {
        let standardizedURL = url.standardizedFileURL
        let key = standardizedURL.path as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        if let diskData = Self.readDiskIcon(for: standardizedURL) {
            cache.setObject(diskData as NSData, forKey: key, cost: diskData.count)
            return diskData
        }
        let iconData: Data?
        if let bundleIcon = Self.bundleIcon(for: standardizedURL),
           let normalizedBundleIconData = Self.normalizedIconData(bundleIcon) {
            iconData = normalizedBundleIconData
        } else {
            let workspaceIcon = NSWorkspace.shared.icon(forFile: standardizedURL.path)
            iconData = Self.normalizedIconData(workspaceIcon)
        }
        guard !Task.isCancelled, let iconData else { return nil }
        cache.setObject(iconData as NSData, forKey: key, cost: iconData.count)
        Self.writeDiskIcon(iconData, for: standardizedURL)
        registerDiskWrite()
        return iconData
    }

    func removeAllCachedIcons() {
        cache.removeAllObjects()
    }

    private func registerDiskWrite() {
        if !didPerformInitialSweep {
            didPerformInitialSweep = true
            Self.sweepDiskCache()
            return
        }
        writesSinceSweep += 1
        guard writesSinceSweep >= Self.diskCacheSweepTrigger else { return }
        writesSinceSweep = 0
        Self.sweepDiskCache()
    }

    private static func diskCacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent(
            "jp.local.launchpadclassic27.iconcache",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            return nil
        }
    }

    private static func diskCacheURL(for appURL: URL) -> URL? {
        guard let directory = diskCacheDirectory(),
              let modificationDate = bundleModificationDate(appURL) else { return nil }
        let identity = appURL.path + "\n" + String(Int64(modificationDate.timeIntervalSince1970))
        let digest = SHA256.hash(data: Data(identity.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".png"
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func bundleModificationDate(_ url: URL) -> Date? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ) else { return nil }
        return values.contentModificationDate
    }

    private static func readDiskIcon(for appURL: URL) -> Data? {
        guard let cacheURL = diskCacheURL(for: appURL),
              let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              data.count > 32,
              Array(data.prefix(8)) == pngMagicBytes else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: cacheURL.path
        )
        return data
    }

    private static func writeDiskIcon(_ data: Data, for appURL: URL) {
        guard let cacheURL = diskCacheURL(for: appURL) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func sweepDiskCache() {
        guard let directory = diskCacheDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let cutoff = Date().addingTimeInterval(-diskCacheAgeLimit)
        var items: [(url: URL, date: Date)] = []
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            guard let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            if date < cutoff {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
            items.append((entry, date))
        }
        guard items.count > maximumDiskCacheEntries else { return }
        let removalCount = items.count - maximumDiskCacheEntries
        for item in items.sorted(by: { $0.date < $1.date }).prefix(removalCount) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    private nonisolated static func bundleIcon(for appURL: URL) -> NSImage? {
        guard appURL.isFileURL, appURL.pathExtension.lowercased() == "app" else { return nil }
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        var iconNames: [String] = []

        do {
            let data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            if let dictionary = propertyList as? [String: Any] {
                if let iconFile = dictionary["CFBundleIconFile"] as? String {
                    iconNames.append(iconFile)
                }
                if let iconName = dictionary["CFBundleIconName"] as? String {
                    iconNames.append(iconName)
                }
            }
        } catch {
            iconNames = []
        }

        var visitedNames: Set<String> = []
        for rawName in iconNames where visitedNames.insert(rawName).inserted {
            guard let safeName = sanitizedIconResourceName(rawName) else { continue }
            let names = URL(fileURLWithPath: safeName).pathExtension.isEmpty
                ? [safeName + ".icns", safeName]
                : [safeName]
            for name in names {
                let iconURL = resourcesURL.appendingPathComponent(name, isDirectory: false)
                if FileManager.default.isReadableFile(atPath: iconURL.path),
                   let image = NSImage(contentsOf: iconURL) {
                    return image
                }
            }
        }

        do {
            let resourceURLs = try FileManager.default.contentsOfDirectory(
                at: resourcesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for iconURL in resourceURLs.prefix(512)
                where iconURL.pathExtension.lowercased() == "icns" {
                if let image = NSImage(contentsOf: iconURL) { return image }
            }
        } catch {
            return nil
        }
        return nil
    }

    private nonisolated static func sanitizedIconResourceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 255,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              URL(fileURLWithPath: trimmed).lastPathComponent == trimmed else { return nil }
        return trimmed
    }

    private nonisolated static func normalizedIconData(_ source: NSImage) -> Data? {
        var proposedRect = NSRect(
            x: 0,
            y: 0,
            width: renderedPixelSize,
            height: renderedPixelSize
        )
        guard let sourceImage = source.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ),
        let context = CGContext(
            data: nil,
            width: renderedPixelSize,
            height: renderedPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: renderedPixelSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clear(CGRect(x: 0, y: 0, width: renderedPixelSize, height: renderedPixelSize))
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: renderedPixelSize, height: renderedPixelSize)
        )
        guard let renderedImage = context.makeImage() else { return nil }
        guard let pixelData = renderedImage.dataProvider?.data,
              (pixelData as Data).contains(where: { $0 != 0 }) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: renderedImage)
        bitmap.size = NSSize(
            width: LauncherMemoryPolicy.iconLogicalPointSize,
            height: LauncherMemoryPolicy.iconLogicalPointSize
        )
        return bitmap.representation(
            using: .png,
            properties: [:]
        )
    }
}

struct LauncherDecodedImage: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int

    var memoryCost: Int { pixels.count }

    @MainActor
    func makeImage() -> NSImage? {
        guard width > 0,
              height > 0,
              bytesPerRow == width * 4,
              pixels.count == bytesPerRow * height,
              let provider = CGDataProvider(data: pixels as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: width, height: height)
        )
    }
}

actor LauncherBackgroundImageLoader {
    private static let maximumCachedImages = LauncherMemoryPolicy.backgroundCacheCount
    private static let maximumCacheCost = LauncherMemoryPolicy.backgroundCacheCost
    private var cache: [String: LauncherDecodedImage] = [:]
    private var cacheOrder: [String] = []
    private var cacheCost = 0

    func imageData(for url: URL) -> LauncherDecodedImage? {
        let standardizedURL = url.standardizedFileURL
        let key = standardizedURL.path
        if let cached = cachedImage(forKey: key) { return cached }
        guard !Task.isCancelled,
              standardizedURL.isFileURL,
              FileManager.default.isReadableFile(atPath: standardizedURL.path) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: LauncherMemoryPolicy.backgroundMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithURL(standardizedURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
              ),
              !Task.isCancelled,
              let decodedImage = Self.rgbaImage(from: cgImage),
              !Task.isCancelled else { return nil }
        store(decodedImage, forKey: key)
        return decodedImage
    }

    func removeAllCachedImages() {
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        cacheCost = 0
    }

    private func cachedImage(forKey key: String) -> LauncherDecodedImage? {
        guard let image = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return image
    }

    private func store(_ image: LauncherDecodedImage, forKey key: String) {
        guard image.memoryCost <= Self.maximumCacheCost else { return }
        if let existing = cache.removeValue(forKey: key) {
            cacheCost -= existing.memoryCost
        }
        cacheOrder.removeAll { $0 == key }
        while (cache.count >= Self.maximumCachedImages
            || cacheCost + image.memoryCost > Self.maximumCacheCost),
            let oldestKey = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldestKey) {
                cacheCost -= removed.memoryCost
            }
        }
        cache[key] = image
        cacheOrder.append(key)
        cacheCost += image.memoryCost
    }

    private nonisolated static func rgbaImage(from source: CGImage) -> LauncherDecodedImage? {
        let width = source.width
        let height = source.height
        let rowCalculation = width.multipliedReportingOverflow(by: 4)
        guard width > 0,
              height > 0,
              !rowCalculation.overflow else { return nil }
        let bytesPerRow = rowCalculation.partialValue
        let sizeCalculation = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !sizeCalculation.overflow,
              sizeCalculation.partialValue <= maximumCacheCost else { return nil }

        var pixels = Data(count: sizeCalculation.partialValue)
        let didRender = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didRender else { return nil }
        return LauncherDecodedImage(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

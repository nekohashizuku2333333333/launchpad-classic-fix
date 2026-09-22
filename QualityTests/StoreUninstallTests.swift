import Foundation

private struct StoreUninstallTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// All destructive operations are confined to disposable fake bundles. The
/// real trash implementation is never called by this suite.
enum StoreUninstallTests {
    static func run() async throws -> Int {
        try storeBadgesMatchInstalledBundleEligibility()
        try receiptMustBeAContainedRegularFile()
        try applicationLinksAndRedirectedParentsAreNotDeletable()
        try applicationsPrefixAndNestedBundlesAreNotDeletable()
        try wrappedStoreApplicationsAreDetected()
        try wrappedMetadataMustMatchTheInnerApplication()
        try wrappedApplicationCannotEscapeItsContainer()
        try await successfulDeletionMovesOnlyTheSelectedBundle()
        try await failedDeletionPreservesTheApplication()
        try await runningApplicationIsNotTrashed()
        try await deletionRevalidatesAfterTheRunningCheck()
        try await cancelledDeletionDoesNotTrashAnything()
        return 12
    }

    private static func storeBadgesMatchInstalledBundleEligibility() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.app("Store.app", receipt: true)
        let nested = try fixture.app("Utilities/Nested Store.app", receipt: true)
        let other = try fixture.app("Other.app", receipt: false)
        let scan = LauncherFileScanner.scanApplications(in: [fixture.applications], homeDirectory: fixture.home)
        let deletablePaths = Set(scan.apps.filter(\.isDeletable).map { $0.url.path })
        try require(deletablePaths == Set([store.path, nested.path]), "Delete badges did not match installed store apps")
        try require(scan.apps.contains { $0.url.path == other.path }, "A non-store app disappeared from the scan")
    }

    private static func receiptMustBeAContainedRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Invalid Receipt.app", receipt: false)
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        let manager = FileManager()
        try manager.createDirectory(at: receipt, withIntermediateDirectories: true)
        try require(!fixture.canUninstall(app), "A directory named receipt enabled deletion")
        try manager.removeItem(at: receipt)
        try Data().write(to: receipt)
        try require(!fixture.canUninstall(app), "An empty receipt enabled deletion")
        try manager.removeItem(at: receipt)
        let externalReceipt = fixture.home.appendingPathComponent("external-receipt")
        try Data("receipt fixture".utf8).write(to: externalReceipt)
        try manager.createSymbolicLink(at: receipt, withDestinationURL: externalReceipt)
        try require(!fixture.canUninstall(app), "A receipt symlink outside the bundle enabled deletion")
    }

    private static func applicationLinksAndRedirectedParentsAreNotDeletable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = try fixture.app("Real.app", receipt: true)
        let link = fixture.applications.appendingPathComponent("Linked.app")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
        try require(!fixture.canUninstall(link), "A linked app was offered as a deletable installed bundle")
        let aliasRoot = fixture.home.appendingPathComponent("Aliases")
        try FileManager().createDirectory(at: aliasRoot, withIntermediateDirectories: true)
        try FileManager().createSymbolicLink(at: aliasRoot.appendingPathComponent("First.app"), withDestinationURL: target)
        let scan = LauncherFileScanner.scanApplications(in: [aliasRoot, fixture.applications], homeDirectory: fixture.home)
        try require(scan.apps.count == 1 && scan.apps.first?.url.path == target.path && scan.apps.first?.isDeletable == true,
                    "Scanning an alias first hid the real installed store app's delete badge")
        let externalDirectory = fixture.home.appendingPathComponent("External")
        let external = externalDirectory.appendingPathComponent("External.app")
        try Fixture.createApp(at: external, receipt: true)
        let redirected = fixture.applications.appendingPathComponent("Redirected")
        try FileManager().createSymbolicLink(at: redirected, withDestinationURL: externalDirectory)
        try require(!fixture.canUninstall(redirected.appendingPathComponent("External.app")), "A parent symlink escaped Applications")
    }

    private static func applicationsPrefixAndNestedBundlesAreNotDeletable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sibling = fixture.home.appendingPathComponent("Applications-extra/External.app")
        try Fixture.createApp(at: sibling, receipt: true)
        try require(!fixture.canUninstall(sibling), "A similarly named Applications directory was accepted")
        let nested = try fixture.app("Host.app/Contents/Helpers/Helper.app", receipt: true)
        try require(!fixture.canUninstall(nested), "An app embedded inside another app was accepted for deletion")
        try require(!fixture.canUninstall(URL(fileURLWithPath: "/System/Applications/Mail.app")), "A system app was accepted for deletion")
    }

    private static func wrappedStoreApplicationsAreDetected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrapper = try fixture.wrappedApp("iPad App.app")
        try require(fixture.canUninstall(wrapper), "The App Store's iPhone/iPad wrapper was not recognized")
        let scan = LauncherFileScanner.scanApplications(in: [fixture.applications], homeDirectory: fixture.home)
        try require(scan.apps.count == 1 && scan.apps.first?.isDeletable == true, "A wrapped store app did not receive its delete badge")
        try require(scan.apps.first?.url.path == wrapper.path, "Scanner exposed the inner iOS bundle instead of the installed wrapper")
    }

    private static func wrappedMetadataMustMatchTheInnerApplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrapper = try fixture.wrappedApp("Mismatched.app", metadataIdentifier: "com.example.some-other-app")
        try require(!fixture.canUninstall(wrapper), "Store metadata for a different app enabled deletion")
        let metadata = wrapper.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        try FileManager().removeItem(at: metadata)
        try require(!fixture.canUninstall(wrapper), "A wrapper without store evidence enabled deletion")
    }

    private static func wrappedApplicationCannotEscapeItsContainer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrapper = try fixture.wrappedApp("Escaping.app")
        let link = wrapper.appendingPathComponent("WrappedBundle")
        try FileManager().removeItem(at: link)
        let outside = try fixture.app("Outside.app", receipt: true)
        try FileManager().createSymbolicLink(at: link, withDestinationURL: outside)
        try require(!fixture.canUninstall(wrapper), "A WrappedBundle link outside its container enabled deletion")
    }

    private static func successfulDeletionMovesOnlyTheSelectedBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.wrappedApp("Selected.app")
        let neighbor = try fixture.app("Neighbor.app", receipt: true)
        let destination = fixture.home.appendingPathComponent("Fake Trash.app")
        let fileOperator = LauncherFileOperator(
            trashAction: { try FileManager().moveItem(at: $0, to: destination) },
            runningApplicationCheck: { _ in false }
        )
        let outcome = await fileOperator.moveApplicationToTrash(app, homeDirectory: fixture.home)
        guard case .success = outcome else { throw StoreUninstallTestFailure(description: "The fake store app could not be uninstalled") }
        try require(!FileManager().fileExists(atPath: app.path), "Successful uninstall left the original bundle in place")
        try require(FileManager().fileExists(atPath: destination.appendingPathComponent("Wrapper/Inner.app/Info.plist").path), "Uninstall moved the inner bundle instead of the whole wrapper")
        try require(FileManager().fileExists(atPath: neighbor.path), "Uninstall affected a neighboring application")
        let scan = LauncherFileScanner.scanApplications(in: [fixture.applications], homeDirectory: fixture.home)
        try require(scan.apps.map { $0.url.path } == [neighbor.path], "Rescanning after uninstall retained the removed app")
        try FileManager().moveItem(at: destination, to: app)
        try require(fixture.canUninstall(app), "Moving the fake app back from the test trash did not restore its complete store wrapper")
    }

    private static func failedDeletionPreservesTheApplication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Failure.app", receipt: true)
        let fileOperator = LauncherFileOperator(
            trashAction: { _ in throw StoreUninstallTestFailure(description: "Injected permission failure") },
            runningApplicationCheck: { _ in false }
        )
        let outcome = await fileOperator.moveApplicationToTrash(app, homeDirectory: fixture.home)
        guard case .failure = outcome else { throw StoreUninstallTestFailure(description: "An injected trash failure was reported as success") }
        try require(FileManager().fileExists(atPath: app.path), "Failed uninstall removed the original bundle")
    }

    private static func runningApplicationIsNotTrashed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Running.app", receipt: true)
        let recorder = TrashRecorder()
        let fileOperator = LauncherFileOperator(trashAction: { recorder.record($0) }, runningApplicationCheck: { _ in true })
        let outcome = await fileOperator.moveApplicationToTrash(app, homeDirectory: fixture.home)
        guard case .failure(let message) = outcome, message.contains("Quit") else { throw StoreUninstallTestFailure(description: "A running app did not request that the user quit first") }
        try require(recorder.paths.isEmpty, "A running application reached the trash action")
    }

    private static func deletionRevalidatesAfterTheRunningCheck() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Updated.app", receipt: true)
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        let recorder = TrashRecorder()
        let fileOperator = LauncherFileOperator(
            trashAction: { recorder.record($0) },
            runningApplicationCheck: { _ in
                try? FileManager().removeItem(at: receipt)
                return false
            }
        )
        let outcome = await fileOperator.moveApplicationToTrash(app, homeDirectory: fixture.home)
        guard case .failure = outcome else { throw StoreUninstallTestFailure(description: "An app changed during validation was deleted") }
        try require(recorder.paths.isEmpty, "Uninstall used stale store eligibility after awaiting the running check")
    }

    private static func cancelledDeletionDoesNotTrashAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app("Cancelled.app", receipt: true)
        let recorder = TrashRecorder()
        let fileOperator = LauncherFileOperator(
            trashAction: { recorder.record($0) },
            runningApplicationCheck: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
        )
        let operation = Task { await fileOperator.moveApplicationToTrash(app, homeDirectory: fixture.home) }
        let outcome = await operation.value
        guard case .failure = outcome else { throw StoreUninstallTestFailure(description: "A cancelled uninstall was reported as success") }
        try require(recorder.paths.isEmpty, "Cancellation did not prevent the trash action")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw StoreUninstallTestFailure(description: message) }
    }

    private final class TrashRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedPaths: [String] = []
        var paths: [String] { lock.withLock { recordedPaths } }
        func record(_ url: URL) { lock.withLock { recordedPaths.append(url.path) } }
    }

    private struct Fixture {
        let home: URL
        var applications: URL { home.appendingPathComponent("Applications", isDirectory: true) }

        init() throws {
            home = FileManager().temporaryDirectory.appendingPathComponent("launcher-store-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager().createDirectory(at: applications, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager().removeItem(at: home) }
        func canUninstall(_ url: URL) -> Bool { LauncherStoreAppPolicy.canUninstall(url, homeDirectory: home) }

        func app(_ name: String, receipt: Bool) throws -> URL {
            let url = applications.appendingPathComponent(name)
            try Self.createApp(at: url, receipt: receipt)
            return url
        }

        func wrappedApp(_ name: String, metadataIdentifier: String = "com.example.wrapped-store-app") throws -> URL {
            let outer = applications.appendingPathComponent(name)
            let inner = outer.appendingPathComponent("Wrapper/Inner.app")
            try FileManager().createDirectory(at: inner, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.example.wrapped-store-app",
                "CFBundlePackageType": "APPL",
                "CFBundleSupportedPlatforms": ["iPhoneOS"]
            ]
            try Self.writePlist(info, to: inner.appendingPathComponent("Info.plist"))
            try Self.writePlist(["itemId": 123_456, "softwareVersionBundleId": metadataIdentifier], to: outer.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
            try FileManager().createSymbolicLink(atPath: outer.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
            return outer
        }

        static func createApp(at url: URL, receipt: Bool) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager().createDirectory(at: contents, withIntermediateDirectories: true)
            try writePlist(["CFBundleIdentifier": "com.example.store-test.\(UUID().uuidString)", "CFBundlePackageType": "APPL"], to: contents.appendingPathComponent("Info.plist"))
            if receipt {
                let receiptDirectory = contents.appendingPathComponent("_MASReceipt")
                try FileManager().createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
                try Data("disposable store receipt fixture".utf8).write(to: receiptDirectory.appendingPathComponent("receipt"))
            }
        }

        static func writePlist(_ value: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
        }
    }
}

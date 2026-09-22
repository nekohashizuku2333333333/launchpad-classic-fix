import Foundation
import CoreTransferable
import UniformTypeIdentifiers

private struct DragProviderTestFailure: Error, CustomStringConvertible {
    let description: String
}

enum DragProviderTests {
    static func run() async throws -> Int {
        try await appDragLoadsBothInternalIDAndExternalFileURL(
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        )
        try await appDragLoadsBothInternalIDAndExternalFileURL(
            URL(fileURLWithPath: "/Applications/測試 應用程式 #1.app", isDirectory: true)
        )
        try await folderDragExposesItsInternalIDWithoutAFileURL()
        return 3
    }

    private static func appDragLoadsBothInternalIDAndExternalFileURL(_ url: URL) async throws {
        let entry = LauncherEntry.app(AppItem(url: url))
        let provider = LauncherDragProvider.make(for: entry)
        try require(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "An app drag did not offer its file URL to external destinations"
        )

        // This is the same Transferable type used by SwiftUI's internal
        // dropDestination(for: String.self), not a lookup of advertised types.
        let internalID = try await loadString(from: provider)
        try require(internalID == entry.id, "An app drag replaced its internal identifier with a file URL")

        // Generic NSURL loading previously returned the app: identifier:
        // NSString had claimed public.url before the real URL was registered.
        let externalURL = try await loadURL(from: provider)
        try require(externalURL.isFileURL, "An external app drag received the internal app: scheme instead of a file URL")
        try require(
            externalURL.standardizedFileURL.path == url.standardizedFileURL.path,
            "The external file URL changed the app path or its non-ASCII/escaped characters"
        )

        // Loading the URL must not consume or rewrite the representation
        // subsequently requested by an internal drop destination.
        let reloadedID = try await loadString(from: provider)
        try require(reloadedID == entry.id, "Loading the external URL changed the internal drag identifier")
    }

    private static func folderDragExposesItsInternalIDWithoutAFileURL() async throws {
        let folder = AppGroup(name: "工具 程式", appPaths: ["/Applications/Example.app"])
        let entry = LauncherEntry.group(folder)
        let provider = LauncherDragProvider.make(for: entry)
        let internalID = try await loadString(from: provider)
        try require(internalID == entry.id, "A folder drag did not preserve its group identifier")
        try require(
            !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "A virtual Launchpad folder was incorrectly offered as a filesystem item"
        )
    }

    private static func loadString(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: String.self) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = object as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(throwing: DragProviderTestFailure(description: "The app drag did not load an NSURL"))
                }
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DragProviderTestFailure(description: message) }
    }
}

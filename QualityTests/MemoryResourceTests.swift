import AppKit
import ImageIO

private struct MemoryResourceTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum MemoryResourceTests {
    static func run() async throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await largeWallpaperDecodesToBoundedPixels(in: directory)
        try await squareWallpaperFitsTheActualByteBudget(in: directory)
        try await cancelledRequestsDoNotReturnCachedImages(in: directory)
        return 3
    }

    private static func largeWallpaperDecodesToBoundedPixels(in directory: URL) async throws {
        let url = directory.appendingPathComponent("wide.png")
        try writeImage(width: 4_096, height: 2_304, to: url)
        guard let decoded = await LauncherBackgroundImageLoader().imageData(for: url),
              let image = decoded.makeImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw MemoryResourceTestFailure(description: "A large wallpaper could not be decoded/reconstructed")
        }
        try require(decoded.width == 1_536 && decoded.height == 864,
                    "Wallpaper downsampling did not preserve the bounded 16:9 dimensions")
        try require(decoded.memoryCost == 1_536 * 864 * 4,
                    "The downsampled wallpaper retained unexpected additional pixel storage")
        try require(cgImage.width == decoded.width && cgImage.height == decoded.height,
                    "NSImage reconstruction expanded the wallpaper back to the source resolution")
        try require(decoded.pixels.contains(where: { $0 != 0 }),
                    "Wallpaper downsampling produced an empty transparent image")
    }

    private static func squareWallpaperFitsTheActualByteBudget(in directory: URL) async throws {
        let url = directory.appendingPathComponent("square.png")
        try writeImage(width: 3_200, height: 3_200, to: url)
        guard let decoded = await LauncherBackgroundImageLoader().imageData(for: url) else {
            throw MemoryResourceTestFailure(description: "The largest permitted square wallpaper was rejected")
        }
        try require(decoded.width == 1_536 && decoded.height == 1_536,
                    "Square wallpaper exceeded the maximum decoded dimension")
        try require(decoded.memoryCost == 9 * 1_024 * 1_024
                    && decoded.memoryCost <= LauncherMemoryPolicy.backgroundCacheCost,
                    "Wallpaper pixel storage exceeded its 9 MiB budget")
    }

    private static func cancelledRequestsDoNotReturnCachedImages(in directory: URL) async throws {
        let url = directory.appendingPathComponent("cancelled.png")
        try writeImage(width: 32, height: 32, to: url)
        let loader = LauncherBackgroundImageLoader()
        guard await loader.imageData(for: url) != nil else {
            throw MemoryResourceTestFailure(description: "Cancellation test could not warm the background cache")
        }
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await loader.imageData(for: url)
        }
        let result = await request.value
        try require(result == nil, "A cancelled view request received a cached wallpaper and could retain it again")
    }

    private static func writeImage(width: Int, height: Int, to url: URL) throws {
        try autoreleasepool {
            guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw MemoryResourceTestFailure(description: "Could not create the wallpaper test image")
            }
            context.setFillColor(CGColor(red: 0.65, green: 0.2, blue: 0.35, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw MemoryResourceTestFailure(description: "Could not encode the wallpaper test image")
            }
            CGImageDestinationAddImage(destination, image, nil)
            try require(CGImageDestinationFinalize(destination), "Could not save the wallpaper test image")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MemoryResourceTestFailure(description: message) }
    }
}

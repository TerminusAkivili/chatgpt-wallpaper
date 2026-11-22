import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WallpaperImage {
    static let fileURL = URL.applicationSupportDirectory
        .appending(path: "ChatGPT Wallpaper", directoryHint: .isDirectory)
        .appending(path: "Wallpaper.png")
    private static let maximumDimension = 32_768
    private static let maximumPixels = 80_000_000
    private static let thumbnailDimension = 3072

    static func saved() -> CGImage? {
        try? decode(Self.fileURL)
    }

    static func save(_ source: URL) throws -> CGImage {
        let image = try decode(source)
        let encoded = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw WallpaperImageError.cannotSave
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw WallpaperImageError.cannotSave }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (encoded as Data).write(to: fileURL, options: .atomic)
        return image
    }

    private static func decode(_ file: URL) throws -> CGImage {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int else {
            throw WallpaperImageError.unreadable
        }
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              width * height <= maximumPixels else {
            throw WallpaperImageError.tooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
            throw WallpaperImageError.unreadable
        }
        return image
    }
}

private enum WallpaperImageError: LocalizedError {
    case unreadable
    case tooLarge
    case cannotSave

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取这张图片。"
        case .tooLarge: "图片超过 8,000 万像素，或单边超过 32,768 像素。"
        case .cannotSave: "无法保存壁纸图片。"
        }
    }
}

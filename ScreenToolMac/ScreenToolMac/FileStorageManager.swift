import AppKit
import ImageIO

class FileStorageManager {
    static let shared = FileStorageManager()

    let imageDirectory: URL
    private let thumbCache = NSCache<NSString, NSImage>()

    private init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenToolMac/Screenshots", isDirectory: true)
        imageDirectory = docs
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    func url(for fileName: String) -> URL {
        imageDirectory.appendingPathComponent(fileName)
    }

    func save(image: NSImage) -> String? {
        let fileName = UUID().uuidString + ".png"
        let fileURL = url(for: fileName)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: fileURL)
            return fileName
        } catch {
            return nil
        }
    }

    func load(fileName: String) -> NSImage? {
        NSImage(contentsOf: url(for: fileName))
    }

    /// A small, cached thumbnail for grid/strip display. Uses ImageIO so it never
    /// decodes the full-resolution PNG, and caches the result so re-rendering the
    /// grid (e.g. switching folders) doesn't re-decode from disk.
    func thumbnail(fileName: String, maxPixel: CGFloat = 320) -> NSImage? {
        let key = fileName as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(url(for: fileName) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    func invalidateThumbnail(fileName: String) {
        thumbCache.removeObject(forKey: fileName as NSString)
    }

    /// Overwrite an existing image file in place (used by re-crop).
    @discardableResult
    func overwrite(fileName: String, image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url(for: fileName))
            thumbCache.removeObject(forKey: fileName as NSString)
            return true
        } catch {
            return false
        }
    }
}

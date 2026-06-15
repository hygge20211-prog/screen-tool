import AppKit
import ImageIO

class FileStorageManager {
    static let shared = FileStorageManager()

    let imageDirectory: URL
    private let thumbCache = NSCache<NSString, NSImage>()
    private var sizeCache: [String: CGSize] = [:]   // header-read pixel sizes
    /// Saved screenshots are capped to this on their longest side (only oversized
    /// full-screen Retina grabs shrink; normal captures stay pixel-perfect).
    private let maxStoredPixel: CGFloat = 2048
    /// Opaque captures stay lossless PNG up to this size; bigger (photographic) ones
    /// switch to high-quality JPEG so files stay small. Text/UI shots compress tiny as PNG.
    private let pngKeepLimit = 4_000_000
    private let jpegQuality: CGFloat = 0.9

    private init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenToolMac/Screenshots", isDirectory: true)
        imageDirectory = docs
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    func url(for fileName: String) -> URL {
        imageDirectory.appendingPathComponent(fileName)
    }

    func save(image: NSImage, into subdir: String = "未分类") -> String? {
        guard let (data, ext) = encode(from: image) else { return nil }
        let prefix = subdir.isEmpty ? "" : subdir + "/"
        let fileName = prefix + UUID().uuidString + "." + ext
        do {
            try ensureSubdir(subdir)
            try data.write(to: url(for: fileName))
            return fileName
        } catch { return nil }
    }

    func load(fileName: String) -> NSImage? {
        NSImage(contentsOf: url(for: fileName))
    }

    /// Create a folder subdirectory under the Screenshots root if needed.
    private func ensureSubdir(_ subdir: String) throws {
        guard !subdir.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: imageDirectory.appendingPathComponent(subdir, isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// Move a stored file into `subdir` (keeping its basename). Returns the new relative name.
    func moveFile(_ fileName: String, toSubdir subdir: String) -> String? {
        let basename = (fileName as NSString).lastPathComponent
        let newName = (subdir.isEmpty ? "" : subdir + "/") + basename
        let src = url(for: fileName), dst = url(for: newName)
        if src.path == dst.path { return fileName }
        do {
            try ensureSubdir(subdir)
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: src, to: dst)
            thumbCache.removeAllObjects()
            sizeCache[fileName] = nil
            return newName
        } catch { return nil }
    }

    /// Copy an image file into `subdir` under a fresh name (used when duplicating a folder).
    func copyFile(_ fileName: String, into subdir: String = "未分类") -> String? {
        let ext = (fileName as NSString).pathExtension
        let newName = (subdir.isEmpty ? "" : subdir + "/") + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        do {
            try ensureSubdir(subdir)
            try FileManager.default.copyItem(at: url(for: fileName), to: url(for: newName))
            return newName
        } catch { return nil }
    }

    /// Downscale to the `maxStoredPixel` cap and report whether the result is fully
    /// opaque. Preserves alpha (lasso / polygon captures keep their transparency).
    private func render(from image: NSImage) -> (cg: CGImage, opaque: Bool)? {
        guard let cg0 = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = max(cg0.width, cg0.height)
        let f = CGFloat(longest) > maxStoredPixel ? maxStoredPixel / CGFloat(longest) : 1
        let nw = max(1, Int((CGFloat(cg0.width) * f).rounded()))
        let nh = max(1, Int((CGFloat(cg0.height) * f).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg0, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, isOpaque(ctx))
    }

    /// Scan the rendered RGBA buffer for any non-opaque pixel (premultipliedLast → A at +3).
    private func isOpaque(_ ctx: CGContext) -> Bool {
        guard let data = ctx.data else { return false }
        let w = ctx.width, h = ctx.height, rb = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: rb * h)
        for y in 0..<h { let r = y * rb; for x in 0..<w where p[r + x*4 + 3] != 255 { return false } }
        return true
    }

    /// (data, extension) for a screenshot: lossless PNG when it stays small (text/UI) or
    /// has transparency; high-quality JPEG when PNG would be large (photographic content).
    private func encode(from image: NSImage) -> (Data, String)? {
        guard let (cg, opaque) = render(from: image) else {
            if let tiff = image.tiffRepresentation, let bm = NSBitmapImageRep(data: tiff),
               let d = bm.representation(using: .png, properties: [:]) { return (d, "png") }
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        if opaque, let png = rep.representation(using: .png, properties: [:]), png.count > pngKeepLimit,
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) {
            return (jpg, "jpg")
        }
        if let png = rep.representation(using: .png, properties: [:]) { return (png, "png") }
        return nil
    }

    /// Re-encode an existing file with the current size cap + format policy. Returns the
    /// (possibly renamed, e.g. .png→.jpg) fileName if it was rewritten meaningfully smaller,
    /// else nil (kept untouched — never re-encodes a file that wouldn't shrink).
    func recompress(fileName: String) -> String? {
        let oldURL = url(for: fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: oldURL.path),
              let oldSize = (attrs[.size] as? NSNumber)?.intValue,
              let image = NSImage(contentsOf: oldURL),
              let (data, ext) = encode(from: image) else { return nil }
        guard data.count < Int(Double(oldSize) * 0.9) else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        let newFileName = base + "." + ext
        do {
            try data.write(to: url(for: newFileName))
            if newFileName != fileName { try? FileManager.default.removeItem(at: oldURL) }
            thumbCache.removeAllObjects()
            sizeCache[fileName] = nil
            sizeCache[newFileName] = nil
            return newFileName
        } catch { return nil }
    }

    /// Pixel dimensions read straight from the file header — no full-image decode.
    func pixelSize(fileName: String) -> CGSize? {
        if let c = sizeCache[fileName] { return c }
        guard let src = CGImageSourceCreateWithURL(url(for: fileName) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        let sz = CGSize(width: w, height: h)
        sizeCache[fileName] = sz
        return sz
    }

    /// A small, cached thumbnail for grid/strip display. Uses ImageIO so it never
    /// decodes the full-resolution PNG, and caches the result so re-rendering the
    /// grid (e.g. switching folders) doesn't re-decode from disk.
    func thumbnail(fileName: String, maxPixel: CGFloat = 320) -> NSImage? {
        // Cache per (file, size) so different render-quality buckets coexist.
        let key = "\(fileName)@\(Int(maxPixel))" as NSString
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
        // Thumbnails are now keyed by (file, size); clear all buckets. Called only
        // on re-crop / in-place edits, so the full clear is cheap and rare.
        thumbCache.removeAllObjects()
    }

    /// Overwrite an existing image file in place (used by re-crop).
    @discardableResult
    func overwrite(fileName: String, image: NSImage) -> Bool {
        guard let (cg, _) = render(from: image) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        let lower = fileName.lowercased()
        let isJPEG = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
        let data = isJPEG ? rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
                          : rep.representation(using: .png, properties: [:])
        guard let d = data else { return false }
        do {
            try d.write(to: url(for: fileName))
            thumbCache.removeAllObjects()   // thumbnails are size-bucketed; clear all buckets
            sizeCache[fileName] = nil
            return true
        } catch {
            return false
        }
    }
}

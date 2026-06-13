import AppKit

class FileStorageManager {
    static let shared = FileStorageManager()

    let imageDirectory: URL

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
}

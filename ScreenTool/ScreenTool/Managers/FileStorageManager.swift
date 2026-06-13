import UIKit

class FileStorageManager {
    static let shared = FileStorageManager()

    let imageDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        imageDirectory = docs.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    }

    func save(image: UIImage) -> String? {
        let fileName = UUID().uuidString + ".png"
        let url = imageDirectory.appendingPathComponent(fileName)
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: url)
            return fileName
        } catch {
            return nil
        }
    }

    func load(fileName: String) -> UIImage? {
        let url = imageDirectory.appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
    }
}

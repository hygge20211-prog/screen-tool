import Foundation
import UIKit

struct Screenshot: Identifiable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var createdAt: Date
    var folderId: UUID?

    var imageURL: URL {
        FileStorageManager.shared.imageDirectory.appendingPathComponent(fileName)
    }
}

struct Folder: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
}

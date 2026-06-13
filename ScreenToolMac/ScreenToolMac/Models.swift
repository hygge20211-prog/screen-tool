import Foundation

struct Screenshot: Identifiable, Codable {
    var id: UUID = UUID()
    var fileName: String
    var createdAt: Date
    var folderId: UUID?
}

struct Folder: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
}

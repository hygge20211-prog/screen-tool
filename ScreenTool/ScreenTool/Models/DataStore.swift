import Foundation
import Combine

class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var screenshots: [Screenshot] = []
    @Published var folders: [Folder] = []

    private let screenshotsKey = "screenshots_data"
    private let foldersKey = "folders_data"

    private init() {
        load()
    }

    func addScreenshot(_ screenshot: Screenshot) {
        screenshots.insert(screenshot, at: 0)
        save()
    }

    func deleteScreenshot(_ screenshot: Screenshot) {
        try? FileManager.default.removeItem(at: screenshot.imageURL)
        screenshots.removeAll { $0.id == screenshot.id }
        save()
    }

    func addFolder(name: String) {
        let folder = Folder(id: UUID(), name: name, createdAt: Date())
        folders.append(folder)
        save()
    }

    func deleteFolder(_ folder: Folder) {
        // Move screenshots in this folder to unassigned
        for i in screenshots.indices where screenshots[i].folderId == folder.id {
            screenshots[i].folderId = nil
        }
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func moveScreenshot(_ screenshot: Screenshot, to folderId: UUID?) {
        if let idx = screenshots.firstIndex(where: { $0.id == screenshot.id }) {
            screenshots[idx].folderId = folderId
            save()
        }
    }

    func screenshots(in folderId: UUID?) -> [Screenshot] {
        screenshots.filter { $0.folderId == folderId }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(screenshots) {
            UserDefaults.standard.set(data, forKey: screenshotsKey)
        }
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: foldersKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: screenshotsKey),
           let decoded = try? JSONDecoder().decode([Screenshot].self, from: data) {
            screenshots = decoded
        }
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = decoded
        }
    }
}

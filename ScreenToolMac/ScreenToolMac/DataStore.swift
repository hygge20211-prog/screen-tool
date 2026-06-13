import Foundation
import Combine

class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var screenshots: [Screenshot] = []
    @Published var folders: [Folder] = []

    private let ssKey = "mac_screenshots"
    private let fKey  = "mac_folders"

    private init() { load() }

    func addScreenshot(_ s: Screenshot) {
        screenshots.insert(s, at: 0)
        save()
    }

    func delete(_ s: Screenshot) {
        try? FileManager.default.removeItem(at: FileStorageManager.shared.url(for: s.fileName))
        screenshots.removeAll { $0.id == s.id }
        save()
    }

    func addFolder(name: String) {
        folders.append(Folder(id: UUID(), name: name, createdAt: Date()))
        save()
    }

    func deleteFolder(_ f: Folder) {
        for i in screenshots.indices where screenshots[i].folderId == f.id {
            screenshots[i].folderId = nil
        }
        folders.removeAll { $0.id == f.id }
        save()
    }

    func renameFolder(_ f: Folder, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        folders[i].name = trimmed
        save()
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func move(_ s: Screenshot, to folderId: UUID?) {
        if let i = screenshots.firstIndex(where: { $0.id == s.id }) {
            screenshots[i].folderId = folderId
            save()
        }
    }

    /// An image file was edited in place — drop its cached thumbnail and republish
    /// so views re-read it.
    func imageDidChange(_ fileName: String) {
        FileStorageManager.shared.invalidateThumbnail(fileName: fileName)
        screenshots = screenshots
    }

    func rename(_ s: Screenshot, to name: String?) {
        guard let i = screenshots.firstIndex(where: { $0.id == s.id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        screenshots[i].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    func screenshots(in folderId: UUID?) -> [Screenshot] {
        screenshots.filter { $0.folderId == folderId }
    }

    // MARK: - Infinite-canvas layout persistence (one layout per folder)

    private func canvasKey(_ folderId: UUID?) -> String {
        "mac_canvas_layout_" + (folderId?.uuidString ?? "all")
    }

    func loadCanvasLayout(folderId: UUID?) -> CanvasLayout {
        guard let d = UserDefaults.standard.data(forKey: canvasKey(folderId)),
              let v = try? JSONDecoder().decode(CanvasLayout.self, from: d) else { return CanvasLayout() }
        return v
    }

    func saveCanvasLayout(_ layout: CanvasLayout, folderId: UUID?) {
        if let d = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(d, forKey: canvasKey(folderId))
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(screenshots) { UserDefaults.standard.set(d, forKey: ssKey) }
        if let d = try? JSONEncoder().encode(folders)     { UserDefaults.standard.set(d, forKey: fKey) }
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: ssKey), let v = try? JSONDecoder().decode([Screenshot].self, from: d) { screenshots = v }
        if let d = UserDefaults.standard.data(forKey: fKey),  let v = try? JSONDecoder().decode([Folder].self, from: d)     { folders = v }
    }
}

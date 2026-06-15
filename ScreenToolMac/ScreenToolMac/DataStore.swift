import Foundation
import Combine

class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var screenshots: [Screenshot] = []
    @Published var folders: [Folder] = []

    /// The folder currently shown in the gallery (nil = 全部). New screenshots go here.
    var currentFolderId: UUID?

    private let ssKey = "mac_screenshots"
    private let fKey  = "mac_folders"

    private init() { load() }

    /// On-disk subdirectory name for a folder (nil = unfiled → "未分类").
    func subdirName(for folderId: UUID?) -> String {
        guard let fid = folderId, let f = folders.first(where: { $0.id == fid }) else { return "未分类" }
        return DataStore.sanitizeFolderName(f.name)
    }
    static func sanitizeFolderName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

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
            if let nn = FileStorageManager.shared.moveFile(screenshots[i].fileName, toSubdir: "未分类") {
                screenshots[i].fileName = nn
            }
            screenshots[i].folderId = nil
        }
        folders.removeAll { $0.id == f.id }
        save()
    }

    /// Duplicate a folder in place: a new folder right after it, with copies of every
    /// screenshot (new files) and the same canvas arrangement (ids remapped).
    func duplicateFolder(_ f: Folder) {
        let newFolder = Folder(id: UUID(), name: f.name + " 副本", createdAt: Date())
        if let idx = folders.firstIndex(where: { $0.id == f.id }) {
            folders.insert(newFolder, at: idx + 1)
        } else { folders.append(newFolder) }

        // Copy screenshots + files, recording old→new id mapping for the layout remap.
        let newSubdir = subdirName(for: newFolder.id)
        var idMap: [String: String] = [:]
        for s in screenshots(in: f.id) {
            guard let newName = FileStorageManager.shared.copyFile(s.fileName, into: newSubdir) else { continue }
            let newId = UUID()
            idMap[s.id.uuidString] = newId.uuidString
            var copy = s
            copy.id = newId
            copy.fileName = newName
            copy.folderId = newFolder.id
            screenshots.insert(copy, at: 0)
        }

        // Carry over the canvas layout with image keys remapped to the new ids.
        var l = loadCanvasLayout(folderId: f.id)
        func remapKey(_ k: String) -> String? { k.hasPrefix("t:") ? k : idMap[k] }
        l.positions = Dictionary(uniqueKeysWithValues: l.positions.compactMap { k, v in idMap[k].map { ($0, v) } })
        l.sizes     = Dictionary(uniqueKeysWithValues: l.sizes.compactMap     { k, v in idMap[k].map { ($0, v) } })
        l.rotations = Dictionary(uniqueKeysWithValues: l.rotations.compactMap { k, v in idMap[k].map { ($0, v) } })
        l.order     = l.order.compactMap(remapKey)
        l.locked    = l.locked.compactMap(remapKey)
        l.groups    = l.groups.map { $0.compactMap(remapKey) }.filter { $0.count >= 2 }
        l.whiteEdge = l.whiteEdge.compactMap { idMap[$0] }
        l.polaroid  = l.polaroid.compactMap { idMap[$0] }
        l.noShadow  = l.noShadow.compactMap { idMap[$0] }
        saveCanvasLayout(l, folderId: newFolder.id)

        save()
    }

    func renameFolder(_ f: Folder, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        folders[i].name = trimmed
        // Relocate the folder's files into the renamed subdirectory.
        let newSubdir = subdirName(for: f.id)
        for j in screenshots.indices where screenshots[j].folderId == f.id {
            if let nn = FileStorageManager.shared.moveFile(screenshots[j].fileName, toSubdir: newSubdir) {
                screenshots[j].fileName = nn
            }
        }
        save()
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func move(_ s: Screenshot, to folderId: UUID?) {
        guard let i = screenshots.firstIndex(where: { $0.id == s.id }) else { return }
        if let nn = FileStorageManager.shared.moveFile(screenshots[i].fileName, toSubdir: subdirName(for: folderId)) {
            screenshots[i].fileName = nn
        }
        screenshots[i].folderId = folderId
        save()
    }

    /// One-time: move pre-existing flat files into per-folder subdirectories on disk.
    /// Same-volume moves are instant renames, so this runs synchronously — each filename
    /// updates in lockstep with its file (no window of dangling references).
    func migrateToFoldersIfNeeded() {
        let doneKey = "mac_folders_v1_done"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        var updated = screenshots
        for i in updated.indices {
            let subdir = subdirName(for: updated[i].folderId)
            if (updated[i].fileName as NSString).deletingLastPathComponent == subdir { continue }  // already in place
            if let nn = FileStorageManager.shared.moveFile(updated[i].fileName, toSubdir: subdir) {
                updated[i].fileName = nn
            }
        }
        screenshots = updated
        save()
        UserDefaults.standard.set(true, forKey: doneKey)
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

    /// One-time: re-compress pre-existing oversized/lossless screenshots to the current
    /// size cap + format policy. Runs once (guarded by a flag), off the main thread.
    func recompressAllIfNeeded() {
        let doneKey = "mac_recompress_v1_done"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let snapshot = screenshots
        DispatchQueue.global(qos: .utility).async {
            var renames: [UUID: String] = [:]
            for s in snapshot {
                autoreleasepool {
                    if let newName = FileStorageManager.shared.recompress(fileName: s.fileName),
                       newName != s.fileName {
                        renames[s.id] = newName
                    }
                }
            }
            DispatchQueue.main.async {
                for (id, newName) in renames {
                    if let i = self.screenshots.firstIndex(where: { $0.id == id }) {
                        self.screenshots[i].fileName = newName
                    }
                }
                self.save()
                UserDefaults.standard.set(true, forKey: doneKey)
            }
        }
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

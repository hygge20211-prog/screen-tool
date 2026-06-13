import SwiftUI
import AppKit

// MARK: - Root Gallery

struct GalleryView: View {
    @EnvironmentObject var store: DataStore
    let onCapture: () -> Void

    // Explicit init so it stays callable despite the private @State below
    // (a synthesized memberwise init would be private).
    init(onCapture: @escaping () -> Void = {}) {
        self.onCapture = onCapture
    }

    @State private var selectedFolderId: UUID? = nil   // nil = "全部"
    @State private var isAllSelected = true
    @State private var selectedScreenshots: Set<UUID> = []
    @State private var isSelecting = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var showExportPanel = false

    var currentScreenshots: [Screenshot] {
        store.screenshots(in: isAllSelected ? nil : selectedFolderId)
    }

    var body: some View {
        NavigationView {
            // MARK: Sidebar
            List {
                Section("") {
                    folderRow(id: nil, name: "全部截图", icon: "photo.on.rectangle.angled", isAll: true)
                }
                Section("文件夹") {
                    ForEach(store.folders) { folder in
                        folderRow(id: folder.id, name: folder.name, icon: "folder", isAll: false)
                            .contextMenu {
                                Button(role: .destructive) { store.deleteFolder(folder) } label: {
                                    Label("删除文件夹", systemImage: "trash")
                                }
                            }
                    }
                    Button {
                        showAddFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            // MARK: Main content
            VStack(spacing: 0) {
                toolbar
                Divider()
                if currentScreenshots.isEmpty {
                    emptyState
                } else {
                    screenshotGrid
                }
            }
        }
        .sheet(isPresented: $showAddFolder) {
            addFolderSheet
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Folder row

    private func folderRow(id: UUID?, name: String, icon: String, isAll: Bool) -> some View {
        let isActive = isAll ? isAllSelected : (selectedFolderId == id && !isAllSelected)
        return Label(name, systemImage: icon)
            .foregroundColor(isActive ? .accentColor : .primary)
            .fontWeight(isActive ? .semibold : .regular)
            .contentShape(Rectangle())
            .onTapGesture {
                isAllSelected = isAll
                selectedFolderId = id
                selectedScreenshots.removeAll()
                isSelecting = false
            }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onCapture) {
                Label("截图", systemImage: "camera.viewfinder")
            }
            .keyboardShortcut("5", modifiers: [.command, .shift])
            .help("框选屏幕上的任意区域进行截图")

            Text(isAllSelected ? "全部截图" : (store.folders.first(where: { $0.id == selectedFolderId })?.name ?? ""))
                .font(.headline)

            Spacer()

            if isSelecting {
                Text("\(selectedScreenshots.count) 张已选")
                    .foregroundColor(.secondary)
                    .font(.subheadline)

                Button("导出到文件夹") { exportSelected() }
                    .disabled(selectedScreenshots.isEmpty)

                Button("删除所选") { deleteSelected() }
                    .foregroundColor(.red)
                    .disabled(selectedScreenshots.isEmpty)

                Button("完成") {
                    isSelecting = false
                    selectedScreenshots.removeAll()
                }
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button { isSelecting = true } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    private var screenshotGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(currentScreenshots) { ss in
                    ScreenshotTile(
                        screenshot: ss,
                        isSelecting: isSelecting,
                        isSelected: selectedScreenshots.contains(ss.id)
                    )
                    .onTapGesture {
                        if isSelecting {
                            if selectedScreenshots.contains(ss.id) { selectedScreenshots.remove(ss.id) }
                            else { selectedScreenshots.insert(ss.id) }
                        } else {
                            openInPreview(ss)
                        }
                    }
                    .contextMenu { contextMenu(for: ss) }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for ss: Screenshot) -> some View {
        Button { openInPreview(ss) } label: { Label("在预览中打开", systemImage: "eye") }
        Button { revealInFinder(ss) } label: { Label("在 Finder 中显示", systemImage: "folder") }
        Divider()
        Menu("移动到…") {
            Button("未分类") { store.move(ss, to: nil) }
            ForEach(store.folders) { f in
                Button(f.name) { store.move(ss, to: f.id) }
            }
        }
        Divider()
        Button(role: .destructive) { store.delete(ss) } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("还没有截图")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("点击左上角「截图」按钮，或按 ⌘⇧5 开始截图")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add folder sheet

    private var addFolderSheet: some View {
        VStack(spacing: 20) {
            Text("新建文件夹").font(.headline)
            TextField("文件夹名称", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("取消") { showAddFolder = false; newFolderName = "" }
                Button("创建") {
                    if !newFolderName.isEmpty {
                        store.addFolder(name: newFolderName)
                        newFolderName = ""
                    }
                    showAddFolder = false
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(newFolderName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    // MARK: - Actions

    private func openInPreview(_ ss: Screenshot) {
        let url = FileStorageManager.shared.url(for: ss.fileName)
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ ss: Screenshot) {
        let url = FileStorageManager.shared.url(for: ss.fileName)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func exportSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到此文件夹"
        panel.message = "选择保存位置"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        var count = 0
        for ss in currentScreenshots where selectedScreenshots.contains(ss.id) {
            let src = FileStorageManager.shared.url(for: ss.fileName)
            let dst = dest.appendingPathComponent(ss.fileName)
            try? FileManager.default.copyItem(at: src, to: dst)
            count += 1
        }

        let alert = NSAlert()
        alert.messageText = "导出完成"
        alert.informativeText = "已导出 \(count) 张截图到：\(dest.path)"
        alert.runModal()

        isSelecting = false
        selectedScreenshots.removeAll()
    }

    private func deleteSelected() {
        for ss in currentScreenshots where selectedScreenshots.contains(ss.id) {
            store.delete(ss)
        }
        isSelecting = false
        selectedScreenshots.removeAll()
    }
}

// MARK: - Screenshot Tile

struct ScreenshotTile: View {
    let screenshot: Screenshot
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = FileStorageManager.shared.load(fileName: screenshot.fileName) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 160, height: 120)
            .clipped()
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .white)
                    .background(Circle().fill(Color.black.opacity(0.3)))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            Text(screenshot.createdAt, style: .date)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .cornerRadius(4)
                .padding(4)
        }
        .shadow(radius: isSelected ? 0 : 2)
    }
}

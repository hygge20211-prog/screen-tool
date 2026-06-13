import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root Gallery

struct GalleryView: View {
    @EnvironmentObject var store: DataStore
    let onCapture: (CaptureMode) -> Void

    // Explicit init so it stays callable despite the private @State below
    // (a synthesized memberwise init would be private).
    init(onCapture: @escaping (CaptureMode) -> Void = { _ in }) {
        self.onCapture = onCapture
    }

    @State private var selectedFolderId: UUID? = nil   // nil = "全部"
    @State private var isAllSelected = true
    @State private var selectedScreenshots: Set<UUID> = []
    @State private var isSelecting = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var showExportPanel = false
    @State private var viewer: ViewerContext? = nil   // non-nil while the image viewer is open
    @State private var renamingFolder: Folder? = nil  // non-nil while the rename sheet is open
    @State private var renameText = ""
    @State private var draggedFolder: Folder? = nil   // the folder currently being dragged to reorder
    @State private var marquee: CGRect? = nil          // rubber-band rect while box-selecting
    @State private var tileFrames: [UUID: CGRect] = [:] // each tile's frame in the grid space

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
                                Button { renameText = folder.name; renamingFolder = folder } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button(role: .destructive) { store.deleteFolder(folder) } label: {
                                    Label("删除文件夹", systemImage: "trash")
                                }
                            }
                            .opacity(draggedFolder?.id == folder.id ? 0.4 : 1)
                            .onDrag {
                                draggedFolder = folder
                                return NSItemProvider(object: folder.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text],
                                    delegate: FolderDropDelegate(target: folder,
                                                                 dragged: $draggedFolder,
                                                                 store: store))
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
            .sheet(item: $renamingFolder) { folder in renameFolderSheet(folder) }

            // MARK: Main content — grid, or inline image viewer when one is open
            if let ctx = viewer {
                ImageViewerView(screenshots: currentScreenshots,
                                startIndex: ctx.startIndex,
                                onClose: { viewer = nil })
                    .id(ctx.id)   // fresh state each time a viewer session opens
            } else {
                ZStack(alignment: .bottomTrailing) {
                    VStack(spacing: 0) {
                        toolbar
                        Divider()
                        if currentScreenshots.isEmpty {
                            emptyState
                        } else {
                            screenshotGrid
                        }
                    }
                    captureButtons   // floating capture buttons, bottom-right
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
                viewer = nil   // leave the inline viewer when switching folders
            }
    }

    // MARK: - Floating capture button (bottom-right). The shape (rectangle /
    // polygon / lasso) is chosen inside the capture overlay itself.

    private var captureButtons: some View {
        Button { onCapture(.freeform) } label: {
            Image("CaptureIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(24)
        .keyboardShortcut("a", modifiers: .option)   // ⌥A
        .help("开始截图（⌥A，或全局 ⌃⌘5）；进入后可选 矩形 / 多边形 / 套索")
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(isAllSelected ? "全部截图" : (store.folders.first(where: { $0.id == selectedFolderId })?.name ?? ""))
                .font(.headline)

            Spacer()

            if isSelecting {
                Text("\(selectedScreenshots.count) 张已选")
                    .foregroundColor(.secondary)
                    .font(.subheadline)

                Menu("移动到…") {
                    Button("未分类") { moveSelected(to: nil) }
                    ForEach(store.folders) { f in
                        Button(f.name) { moveSelected(to: f.id) }
                    }
                }
                .disabled(selectedScreenshots.isEmpty || store.folders.isEmpty)
                .fixedSize()

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
            // Fixed 160-wide cells packed from the leading edge: avoids the empty
            // "dead zones" that centered, wider-than-tile cells create — which made
            // the left-column thumbnails miss taps in selection mode.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(currentScreenshots) { ss in
                    ScreenshotTile(
                        screenshot: ss,
                        isSelecting: isSelecting,
                        isSelected: selectedScreenshots.contains(ss.id)
                    )
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TileFramesKey.self,
                                               value: [ss.id: geo.frame(in: .named("gridSpace"))])
                    })
                    .contentShape(Rectangle())   // whole tile is the tap target
                    .onTapGesture {
                        if isSelecting {
                            if selectedScreenshots.contains(ss.id) { selectedScreenshots.remove(ss.id) }
                            else { selectedScreenshots.insert(ss.id) }
                        } else if let idx = currentScreenshots.firstIndex(where: { $0.id == ss.id }) {
                            viewer = ViewerContext(startIndex: idx)
                        }
                    }
                    .contextMenu { contextMenu(for: ss) }
                }
            }
            .padding(12)
        }
        .coordinateSpace(name: "gridSpace")
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        .overlay(marqueeOverlay)
        // Box-select by dragging — only in selection mode. On macOS a mouse drag
        // doesn't scroll a ScrollView (that's the wheel), so this won't fight scroll.
        .gesture(marqueeGesture, including: isSelecting ? .all : .subviews)
    }

    @ViewBuilder private var marqueeOverlay: some View {
        if let r = marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("gridSpace"))
            .onChanged { value in
                let r = CGRect(x: min(value.startLocation.x, value.location.x),
                               y: min(value.startLocation.y, value.location.y),
                               width: abs(value.location.x - value.startLocation.x),
                               height: abs(value.location.y - value.startLocation.y))
                marquee = r
                selectedScreenshots = Set(tileFrames.filter { $0.value.intersects(r) }.map(\.key))
            }
            .onEnded { _ in marquee = nil }
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
            Text("点击右下角「截图」按钮，或按全局快捷键 ⌃⌘5 开始截图")
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

    // MARK: - Rename folder sheet

    private func renameFolderSheet(_ folder: Folder) -> some View {
        VStack(spacing: 20) {
            Text("重命名文件夹").font(.headline)
            TextField("文件夹名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("取消") { renamingFolder = nil }
                Button("保存") {
                    store.renameFolder(folder, to: renameText)
                    renamingFolder = nil
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func moveSelected(to folderId: UUID?) {
        for ss in currentScreenshots where selectedScreenshots.contains(ss.id) {
            store.move(ss, to: folderId)
        }
        isSelecting = false
        selectedScreenshots.removeAll()
    }
}

// MARK: - Tile frame reporting (for box / marquee selection)

struct TileFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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

// MARK: - Image Viewer (large preview + arrows + thumbnail strip)

/// Identifies an open viewer session. Carries which image to show first.
struct ViewerContext: Identifiable {
    let id = UUID()
    let startIndex: Int
}

// MARK: - Folder reordering via drag & drop

/// Reorders folders live as the dragged row hovers over another row.
struct FolderDropDelegate: DropDelegate {
    let target: Folder
    @Binding var dragged: Folder?
    let store: DataStore

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged.id != target.id,
              let from = store.folders.firstIndex(where: { $0.id == dragged.id }),
              let to = store.folders.firstIndex(where: { $0.id == target.id })
        else { return }
        withAnimation {
            store.moveFolders(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}

struct ImageViewerView: View {
    let screenshots: [Screenshot]
    let onClose: () -> Void
    @State private var index: Int

    init(screenshots: [Screenshot], startIndex: Int, onClose: @escaping () -> Void) {
        self.screenshots = screenshots
        self.onClose = onClose
        _index = State(initialValue: startIndex)
    }

    private var current: Screenshot? {
        screenshots.indices.contains(index) ? screenshots[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: back to grid + counter
            HStack {
                Button(action: onClose) {
                    Label("返回", systemImage: "chevron.left")
                        .font(.body.weight(.medium))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc returns to the grid
                .help("返回截图库（Esc）")
                Spacer()
                Text("\(index + 1) / \(screenshots.count)")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(12)

            // Large image with side navigation
            ZStack {
                Color.black.opacity(0.05)
                if let ss = current, let img = FileStorageManager.shared.load(fileName: ss.fileName) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Text("无法加载图片").foregroundColor(.secondary)
                }

                HStack {
                    navButton("chevron.left.circle.fill", disabled: index <= 0) { go(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    navButton("chevron.right.circle.fill", disabled: index >= screenshots.count - 1) { go(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 16)
            }

            Divider()

            // Bottom thumbnail strip — click to jump, auto-scrolls to keep current centered
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(screenshots.enumerated()), id: \.element.id) { i, ss in
                            thumbnail(ss, selected: i == index)
                                .id(i)
                                .onTapGesture { index = i }
                        }
                    }
                    .padding(10)
                }
                .frame(height: 96)
                .onChange(of: index) { newValue in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newValue, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(index, anchor: .center) }
            }
        }
        // Fill the detail pane; no fixed min width (a large one would squeeze the
        // sidebar below its own minimum and throw off click hit-testing).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func go(_ delta: Int) {
        let n = index + delta
        if screenshots.indices.contains(n) { index = n }
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.4))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.2 : 1)
        .disabled(disabled)
    }

    private func thumbnail(_ ss: Screenshot, selected: Bool) -> some View {
        Group {
            if let img = FileStorageManager.shared.load(fileName: ss.fileName) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: 110, height: 70)
        .clipped()
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
    }
}

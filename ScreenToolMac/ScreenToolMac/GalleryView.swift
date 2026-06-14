import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root Gallery

enum ViewMode: Hashable {
    case icon      // thumbnail grid
    case gallery   // large preview + arrows + thumbnail strip
    case canvas    // infinite, freely-arrangeable board
}

struct GalleryView: View {
    @EnvironmentObject var store: DataStore
    let onCapture: (CaptureMode) -> Void
    let onCaptureNoHide: (CaptureMode) -> Void
    let onRecrop: (Screenshot) -> Void

    // Explicit init so it stays callable despite the private @State below
    // (a synthesized memberwise init would be private).
    init(onCapture: @escaping (CaptureMode) -> Void = { _ in },
         onCaptureNoHide: @escaping (CaptureMode) -> Void = { _ in },
         onRecrop: @escaping (Screenshot) -> Void = { _ in }) {
        self.onCapture = onCapture
        self.onCaptureNoHide = onCaptureNoHide
        self.onRecrop = onRecrop
    }

    @State private var selectedFolderId: UUID? = nil   // nil = "全部"
    @State private var isAllSelected = true
    @State private var selectedScreenshots: Set<UUID> = []
    @State private var isSelecting = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var showExportPanel = false
    @State private var viewMode: ViewMode = .canvas
    @State private var galleryStart = 0               // index the gallery opens at
    @State private var gallerySession = UUID()        // bump to reset the gallery's browsing state
    @State private var renamingFolder: Folder? = nil  // non-nil while the rename sheet is open
    @State private var renamingScreenshot: Screenshot? = nil
    @State private var renameText = ""
    @State private var draggedFolder: Folder? = nil   // the folder currently being dragged to reorder
    @State private var marquee: CGRect? = nil          // rubber-band rect while box-selecting
    @State private var tileFrames: [UUID: CGRect] = [:] // each tile's frame in the grid space
    @State private var isImportTarget = false           // Finder image hovering over the grid
    @State private var lastViewedId: UUID? = nil         // keep the last-previewed tile highlighted
    @State private var copyMonitor: Any? = nil           // ⌘C key monitor

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

            // MARK: Main content — switchable: icon grid / gallery / infinite canvas
            VStack(spacing: 0) {
                toolbar
                Divider()
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if currentScreenshots.isEmpty {
                            emptyState
                        } else {
                            switch viewMode {
                            case .icon:    screenshotGrid
                            case .gallery: galleryModeView
                            case .canvas:  InfiniteCanvasView(screenshots: currentScreenshots,
                                                              folderId: isAllSelected ? nil : selectedFolderId,
                                                              menu: { ss in AnyView(contextMenu(for: ss)) })
                                .id(isAllSelected ? "all" : (selectedFolderId?.uuidString ?? "none"))
                            }
                        }
                    }
                    if viewMode != .gallery { captureButtons }
                }
                // Drag image files in from Finder to import them into the current folder.
                .onDrop(of: [UTType.fileURL], isTargeted: $isImportTarget, perform: importDropped)
                .overlay {
                    if isImportTarget {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddFolder) {
            addFolderSheet
        }
        .sheet(item: $renamingScreenshot) { ss in renameScreenshotSheet(ss) }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { startCopyMonitor() }
        .onDisappear { stopCopyMonitor() }
    }

    // MARK: - ⌘C copy

    private func startCopyMonitor() {
        copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Let text fields handle keys themselves; the canvas has its own handler.
            if NSApp.keyWindow?.firstResponder is NSText { return e }
            if viewMode == .canvas { return e }

            // ⌘C — copy
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               e.charactersIgnoringModifiers == "c" {
                let shots: [Screenshot]
                if isSelecting && !selectedScreenshots.isEmpty {
                    shots = currentScreenshots.filter { selectedScreenshots.contains($0.id) }
                } else if let lid = lastViewedId, let s = currentScreenshots.first(where: { $0.id == lid }) {
                    shots = [s]
                } else { shots = [] }
                guard !shots.isEmpty else { return e }
                let imgs = shots.compactMap { FileStorageManager.shared.load(fileName: $0.fileName) }
                guard !imgs.isEmpty else { return e }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(imgs)
                return nil
            }
            // Delete / Backspace — delete selected (icon selection mode)
            if (e.keyCode == 51 || e.keyCode == 117),
               isSelecting, !selectedScreenshots.isEmpty {
                deleteSelected()
                return nil
            }
            return e
        }
    }

    private func stopCopyMonitor() {
        if let m = copyMonitor { NSEvent.removeMonitor(m); copyMonitor = nil }
    }

    // MARK: - Folder row

    private func folderRow(id: UUID?, name: String, icon: String, isAll: Bool) -> some View {
        let isActive = isAll ? isAllSelected : (selectedFolderId == id && !isAllSelected)
        return Label(name, systemImage: icon)
            .foregroundColor(isActive ? .accentColor : .primary)
            .fontWeight(isActive ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.secondary.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isAllSelected = isAll
                selectedFolderId = id
                store.currentFolderId = isAll ? nil : id   // new screenshots land here
                selectedScreenshots.removeAll()
                isSelecting = false
                lastViewedId = nil
                galleryStart = 0
                gallerySession = UUID()   // gallery/canvas show the new folder afresh
            }
    }

    // MARK: - Gallery mode (large preview)

    private var galleryModeView: some View {
        ImageViewerView(screenshots: currentScreenshots,
                        startIndex: min(galleryStart, max(0, currentScreenshots.count - 1)),
                        onClose: { viewMode = .icon },
                        onCurrent: { lastViewedId = $0.id },
                        menu: { ss in AnyView(contextMenu(for: ss)) })
            .id(gallerySession)   // reset browsing state only on a new session
    }

    private func openInGallery(_ ss: Screenshot) {
        if let idx = currentScreenshots.firstIndex(where: { $0.id == ss.id }) {
            galleryStart = idx
            gallerySession = UUID()
            viewMode = .gallery
        }
    }

    // MARK: - Floating capture button (bottom-right). The shape (rectangle /
    // polygon / lasso) is chosen inside the capture overlay itself.

    private var captureButtons: some View {
        HStack(spacing: 12) {
            // Capture without hiding the app (so its own window is in the shot)
            Button { onCaptureNoHide(.freeform) } label: {
                Image(systemName: "camera.on.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.gray.opacity(0.85)))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("截图（不隐藏本应用，可截到本窗口）")

            Button { onCapture(.freeform) } label: {
                Image("CaptureIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: .option)   // ⌥A
            .help("开始截图（⌥A，或全局 ⌃⌘5）；进入后可选 矩形 / 多边形 / 套索")
        }
        .padding(24)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(isAllSelected ? "全部截图" : (store.folders.first(where: { $0.id == selectedFolderId })?.name ?? ""))
                .font(.headline)

            Spacer()

            // View switcher: infinite canvas / gallery / icon grid
            Picker("", selection: $viewMode) {
                Image(systemName: "infinity").tag(ViewMode.canvas)
                Image(systemName: "photo").tag(ViewMode.gallery)
                Image(systemName: "square.grid.2x2").tag(ViewMode.icon)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("无限画板 / 画廊视图 / 图标视图")

            if viewMode == .icon {
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
                        isSelected: selectedScreenshots.contains(ss.id),
                        isHighlighted: !isSelecting && ss.id == lastViewedId
                    )
                    .background {
                        // Only report frames while selecting — otherwise this fires on
                        // every layout pass and rewrites top-level state, which janks
                        // normal browsing and folder switches.
                        if isSelecting {
                            GeometryReader { geo in
                                Color.clear.preference(key: TileFramesKey.self,
                                                       value: [ss.id: geo.frame(in: .named("gridSpace"))])
                            }
                        }
                    }
                    .contentShape(Rectangle())   // whole tile is the tap target
                    .onTapGesture {
                        if isSelecting {
                            if selectedScreenshots.contains(ss.id) { selectedScreenshots.remove(ss.id) }
                            else { selectedScreenshots.insert(ss.id) }
                        }
                        // (Single-click no longer jumps to gallery — use the view
                        //  switcher, or the right-click menu's “查看大图”.)
                    }
                    // Drag the screenshot file out to Finder / other apps.
                    .onDrag {
                        NSItemProvider(contentsOf: FileStorageManager.shared.url(for: ss.fileName))
                            ?? NSItemProvider()
                    }
                    .contextMenu { contextMenu(for: ss) }
                }
            }
            .padding(12)
        }
        .coordinateSpace(name: "gridSpace")
        .onPreferenceChange(TileFramesKey.self) { if isSelecting { tileFrames = $0 } }
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

    /// Shared right-click menu used by the icon grid, gallery and canvas views.
    @ViewBuilder
    private func contextMenu(for ss: Screenshot) -> some View {
        Button { openInGallery(ss) } label: { Label("查看大图", systemImage: "eye") }
        Button { openInPreview(ss) } label: { Label("在预览中打开", systemImage: "macwindow") }
        Button { revealInFinder(ss) } label: { Label("在 Finder 中显示", systemImage: "folder") }
        Button {
            if let img = FileStorageManager.shared.load(fileName: ss.fileName) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        } label: { Label("复制图片", systemImage: "doc.on.doc") }
        Button { renameText = ss.name ?? ""; renamingScreenshot = ss } label: { Label("重命名", systemImage: "pencil") }
        Button { onRecrop(ss) } label: { Label("重新裁剪", systemImage: "crop") }
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

    private func renameScreenshotSheet(_ ss: Screenshot) -> some View {
        VStack(spacing: 20) {
            Text("重命名图片").font(.headline)
            TextField("名称（留空恢复默认）", text: $renameText)
                .textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Button("取消") { renamingScreenshot = nil }
                Button("保存") { store.rename(ss, to: renameText); renamingScreenshot = nil }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24).frame(width: 320)
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

    // Import image files dragged in from Finder into the current folder.
    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let folderId = isAllSelected ? nil : selectedFolderId
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                guard let fileURL = url,
                      let img = NSImage(contentsOf: fileURL),
                      let name = FileStorageManager.shared.save(image: img) else { return }
                DispatchQueue.main.async {
                    store.addScreenshot(Screenshot(fileName: name, createdAt: Date(), folderId: folderId))
                }
            }
        }
        return handled
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
    var isHighlighted: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = FileStorageManager.shared.thumbnail(fileName: screenshot.fileName) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()            // keep original aspect ratio, no cropping
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 160, height: 120)
            .background(Color.secondary.opacity(0.08))
            .clipped()
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected || isHighlighted ? Color.accentColor : Color.clear,
                            lineWidth: isHighlighted && !isSelected ? 3 : 2.5)
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
    let onCurrent: (Screenshot) -> Void
    let menu: (Screenshot) -> AnyView
    @State private var index: Int

    init(screenshots: [Screenshot], startIndex: Int,
         onClose: @escaping () -> Void,
         onCurrent: @escaping (Screenshot) -> Void = { _ in },
         menu: @escaping (Screenshot) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.screenshots = screenshots
        self.onClose = onClose
        self.onCurrent = onCurrent
        self.menu = menu
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
                        .contentShape(Rectangle())
                        .contextMenu { menu(ss) }
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
                    if screenshots.indices.contains(newValue) { onCurrent(screenshots[newValue]) }
                }
                .onAppear {
                    proxy.scrollTo(index, anchor: .center)
                    if let c = current { onCurrent(c) }
                }
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
            if let img = FileStorageManager.shared.thumbnail(fileName: ss.fileName) {
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

// MARK: - Infinite Canvas

/// A freely-arrangeable white board: screenshots laid out compactly by default.
/// Drag an image to move it, click it to view the original, drag empty space or
/// scroll to pan, pinch / use the ± buttons to zoom, and add text notes. The
/// layout (positions, texts, pan, zoom) is saved when you leave the canvas.
struct InfiniteCanvasView: View {
    let screenshots: [Screenshot]
    let folderId: UUID?
    var menu: (Screenshot) -> AnyView

    @State private var positions: [String: CGPoint] = [:]   // content coords (center)
    @State private var sizes: [String: CGFloat] = [:]       // per-image width (content pts)
    @State private var rotations: [String: CGFloat] = [:]   // per-image rotation (degrees)
    @State private var aspects: [String: CGFloat] = [:]     // width/height per image
    @State private var texts: [CanvasTextItem] = []
    @State private var pan: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var selected: Set<String> = []           // image uuid or "t:"+uuid
    @State private var marquee: CGRect? = nil               // screen-space rubber band
    @State private var groupDelta: CGSize = .zero           // live group-move offset (screen)
    @State private var groupActive = false
    @State private var resizeBaseSizes: [String: CGFloat] = [:]  // per-image base width at resize start
    @GestureState private var magLive: CGFloat = 1
    @State private var scrollMonitor: Any?
    @State private var panMonitor: Any?
    @State private var copyMonitor: Any?
    @State private var loaded = false
    @State private var isInteracting = false             // true while panning / dragging an item
    @State private var interactClear: DispatchWorkItem?  // debounced reset for scroll/trackpad pan
    @State private var viewport: CGSize = .zero
    @State private var bgColor: Color = .white
    @State private var gridStyle: String = "none"   // "none" / "grid" / "dots"
    @State private var exportRect: CGRect? = nil     // export frame (content coords)
    @State private var exportTarget: CGSize? = nil   // target px (aspect locked)
    @State private var exportDragStart: CGRect? = nil
    @State private var order: [String] = []          // z-order (bottom→top)
    @State private var locked: Set<String> = []      // locked item keys
    @State private var groups: [[String]] = []       // grouped item keys
    @State private var whiteEdge: Set<String> = []   // images with a white border
    @State private var polaroid: Set<String> = []    // images with a Polaroid frame
    @State private var noShadow: Set<String> = []     // images with no drop shadow
    @State private var styledCache: [String: NSImage] = [:]   // key+flags → styled thumbnail
    @State private var styledAspectCache: [String: CGFloat] = [:]   // key → styled aspect (O(1))
    /// Canvas render quality (0=低/1=中/2=高). Lower = smaller thumbnails = smoother.
    @AppStorage("canvasRenderQuality") private var renderQuality = 0

    private let defaultW: CGFloat = 160
    private let gap: CGFloat = 16

    private var effScale: CGFloat { scale * magLive }
    /// Thumbnail pixel size used for on-canvas display, driven by the quality picker.
    private var renderMaxPixel: CGFloat { [256, 512, 1024][min(2, max(0, renderQuality))] }

    private func imgW(_ id: String) -> CGFloat { sizes[id] ?? defaultW }
    private func imgH(_ id: String) -> CGFloat { imgW(id) / displayAspect(id) }
    private func textKey(_ t: CanvasTextItem) -> String { "t:" + t.id.uuidString }

    private func isStyled(_ key: String) -> Bool { whiteEdge.contains(key) || polaroid.contains(key) }

    /// Aspect (w/h) used for layout — O(1); reflects any frame so canvas == export.
    private func displayAspect(_ key: String) -> CGFloat {
        if isStyled(key), let a = styledAspectCache[key] { return a }
        return aspects[key] ?? (160.0 / 120.0)
    }

    /// Styled thumbnail for canvas display (takes the resolved screenshot to avoid
    /// per-item lookups; caches the styled image + its aspect).
    private func canvasImage(_ ss: Screenshot) -> NSImage? {
        let key = ss.id.uuidString
        guard let base = FileStorageManager.shared.thumbnail(fileName: ss.fileName, maxPixel: renderMaxPixel) else { return nil }
        guard isStyled(key) else { return base }
        let cacheKey = key + (whiteEdge.contains(key) ? "|w" : "") + (polaroid.contains(key) ? "|p" : "") + "@\(renderQuality)"
        if let c = styledCache[cacheKey] { return c }
        let styled = ImageStyler.styled(base, whiteEdge: whiteEdge.contains(key), polaroid: polaroid.contains(key))
        styledCache[cacheKey] = styled
        if styled.size.height > 0 { styledAspectCache[key] = styled.size.width / styled.size.height }
        return styled
    }

    private func toggleStyle(_ key: String, _ kind: String) {
        switch kind {
        case "white": if whiteEdge.contains(key) { whiteEdge.remove(key) } else { whiteEdge.insert(key) }
        case "polaroid": if polaroid.contains(key) { polaroid.remove(key) } else { polaroid.insert(key) }
        case "shadow": if noShadow.contains(key) { noShadow.remove(key) } else { noShadow.insert(key) }
        default: break
        }
        // Drop every cached variant (all flags, all quality buckets) for this image.
        styledCache = styledCache.filter { !$0.key.hasPrefix(key) }
        styledAspectCache.removeValue(forKey: key)
        persist()
    }

    /// Floating toolbar shown to the right of a selected (unlocked) image: frame-style
    /// toggles, stacked vertically. Layer / lock / group live in the right-click menu.
    @ViewBuilder private func frameButtonRow(_ key: String) -> some View {
        VStack(spacing: 6) {
            Button { toggleStyle(key, "white") } label: { Image(systemName: "square.dashed") }
                .foregroundColor(whiteEdge.contains(key) ? .accentColor : .primary)
                .help(whiteEdge.contains(key) ? "去掉白边" : "加白边")
            Button { toggleStyle(key, "polaroid") } label: { Image(systemName: "photo.artframe") }
                .foregroundColor(polaroid.contains(key) ? .accentColor : .primary)
                .help(polaroid.contains(key) ? "去掉拍立得相框" : "拍立得相框")
            Button { toggleStyle(key, "shadow") } label: { Image(systemName: "square.on.square") }
                .foregroundColor(noShadow.contains(key) ? .accentColor : .primary)
                .help(noShadow.contains(key) ? "恢复阴影" : "取消阴影")
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 4).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    // Viewport culling: render only items near the visible area (selected always shown).
    private func isImageVisible(_ key: String, in viewport: CGSize) -> Bool {
        if selected.contains(key) { return true }
        let c = center(key), w = imgW(key) * effScale, h = imgH(key) * effScale
        let m: CGFloat = 150
        return CGRect(x: c.x - w/2 - m, y: c.y - h/2 - m, width: w + 2*m, height: h + 2*m)
            .intersects(CGRect(origin: .zero, size: viewport))
    }
    private func isTextVisible(_ t: CanvasTextItem, in viewport: CGSize) -> Bool {
        if selected.contains(textKey(t)) { return true }
        let c = textCenter(t)
        let w = max(40, CGFloat(t.text.count) * 16 * effScale * 0.7), h = 40 * effScale
        let m: CGFloat = 150
        return CGRect(x: c.x - w/2 - m, y: c.y - h/2 - m, width: w + 2*m, height: h + 2*m)
            .intersects(CGRect(origin: .zero, size: viewport))
    }

    private func center(_ id: String) -> CGPoint {
        let p = positions[id] ?? CGPoint(x: 200, y: 200)
        let extra = (groupActive && selected.contains(id)) ? groupDelta : .zero
        return CGPoint(x: pan.width + p.x * effScale + extra.width,
                       y: pan.height + p.y * effScale + extra.height)
    }
    private func textCenter(_ t: CanvasTextItem) -> CGPoint {
        let extra = (groupActive && selected.contains(textKey(t))) ? groupDelta : .zero
        return CGPoint(x: pan.width + t.x * effScale + extra.width,
                       y: pan.height + t.y * effScale + extra.height)
    }
    /// Item center WITHOUT pan. Items live inside the pan-offset container, so pan is
    /// applied once to the whole layer instead of being baked into every item — this is
    /// what lets panning move everything without re-rendering each item.
    private func contentCenter(_ id: String) -> CGPoint {
        let p = positions[id] ?? CGPoint(x: 200, y: 200)
        let extra = (groupActive && selected.contains(id)) ? groupDelta : .zero
        return CGPoint(x: p.x * effScale + extra.width, y: p.y * effScale + extra.height)
    }

    var body: some View {
        GeometryReader { geo in
            // Build O(1) lookups once per render (avoids O(n²) per-item scans).
            let byId = Dictionary(screenshots.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            let txtIndex = Dictionary(texts.enumerated().map { (textKey($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
            // Only on-screen items get a view (identity/gestures/menus track visible count, not total).
            let visible = displayOrder.filter { key in
                if key.hasPrefix("t:") { return txtIndex[key].map { isTextVisible(texts[$0], in: geo.size) } ?? false }
                return byId[key] != nil && isImageVisible(key, in: geo.size)
            }
            let interacting = isInteracting || magLive != 1
            ZStack(alignment: .topLeading) {
                // Board background — left-drag = box-select; single-click = confirm
                // text edit + clear selection. Pan via middle-drag / scroll.
                bgColor
                    .overlay { if gridStyle != "none" { gridOverlay } }
                    .contentShape(Rectangle())
                    .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil); selected.removeAll(); persist() }
                    .gesture(marqueeGesture)

                // Pan-offset container: panning moves this whole layer (.offset below)
                // instead of re-rendering each item. Scale stays baked per item so zoom
                // stays crisp. "canvas" space lives here too → rotation sees content coords.
                ZStack(alignment: .topLeading) {
                // Single ordered pass so images & texts interleave by z-order.
                // `visible` already excludes off-screen items.
                ForEach(visible, id: \.self) { key in
                    if key.hasPrefix("t:") {
                        if let i = txtIndex[key] {
                            CanvasTextView(item: $texts[i], pan: .zero, scale: effScale,
                                           groupOffset: (groupActive && selected.contains(key)) ? groupDelta : .zero,
                                           selected: selected.contains(key),
                                           locked: locked.contains(key),
                                           onSelect: { selectItem(key) },
                                           onDuplicate: { duplicateText(texts[i]) },
                                           extraMenu: { AnyView(layerLockGroupMenu(key)) },
                                           onCommit: persist,
                                           onDelete: { deleteKey(key) })
                        }
                    } else if let ss = byId[key] {
                        CanvasItemView(
                            screenshot: ss,
                            image: canvasImage(ss),
                            noShadow: noShadow.contains(key),
                            interacting: interacting,
                            center: contentCenter(key),
                            width: imgW(key) * effScale,
                            height: imgH(key) * effScale,
                            selected: selected.contains(key),
                            locked: locked.contains(key),
                            onSelect: { selectItem(key) },
                            onMove: { t in beginGroupDrag(key); groupDelta = t },
                            onMoveEnded: { commitGroupDrag() },
                            onResizeBegan: { beginResize(key) },
                            onResize: { factor in applyResize(factor) },
                            onResizeEnded: { persist() },
                            rotation: rotations[key] ?? 0,
                            onRotate: { angle in rotateSelectedOrSelf(id: key, toAngle: angle) },
                            onRotateEnded: { persist() },
                            onDuplicate: { duplicateImage(ss) },
                            menu: { AnyView(Group { menu(ss); Divider(); layerLockGroupMenu(key) }) },
                            frameButtons: { AnyView(frameButtonRow(key)) }
                        )
                    }
                }
                }   // end pan-offset container
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .coordinateSpace(name: "canvas")
                .offset(x: pan.width, y: pan.height)

                if let m = marquee {
                    Rectangle().fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                        .frame(width: m.width, height: m.height)
                        .position(x: m.midX, y: m.midY)
                        .allowsHitTesting(false)
                }

                exportFrameOverlay(viewport: geo.size)
            }
            .overlay(alignment: .topLeading) { topControls(viewport: geo.size) }
            .overlay(alignment: .bottomLeading) { zoomControls(viewport: geo.size) }
            .clipped()
            .contentShape(Rectangle())
            // Drop images from Finder right where the mouse is released.
            .onDrop(of: [UTType.fileURL], delegate: CanvasDropDelegate(
                folderId: folderId,
                toContent: { p in CGPoint(x: (p.x - pan.width) / effScale, y: (p.y - pan.height) / effScale) },
                place: { id, c in positions[id] = c; persist() }
            ))
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($magLive) { v, s, _ in s = v }
                    .onEnded { v in scale = min(max(scale * v, 0.25), 4); persist() }
            )
            .onAppear { viewport = geo.size; loadLayout(in: geo.size); startMonitors() }
            .onChange(of: geo.size) { viewport = $0 }
            .onDisappear { persist(); stopMonitors() }
        }
    }

    // ⌥-drag duplicates: leave a copy at the original spot.
    private func duplicateImage(_ ss: Screenshot) {
        let id = ss.id.uuidString
        guard let img = FileStorageManager.shared.load(fileName: ss.fileName),
              let newName = FileStorageManager.shared.save(image: img) else { return }
        let copy = Screenshot(fileName: newName, createdAt: Date(), folderId: ss.folderId, name: ss.name)
        let nid = copy.id.uuidString
        positions[nid] = positions[id]
        sizes[nid] = sizes[id]
        rotations[nid] = rotations[id]
        aspects[nid] = aspects[id]
        DataStore.shared.addScreenshot(copy)
        persist()
    }

    private func duplicateText(_ t: CanvasTextItem) {
        var copy = t
        copy.id = UUID()
        texts.append(copy)
        persist()
    }

    // Batch resize: capture base widths of all selected images, then scale them
    // together by the drag factor.
    private func beginResize(_ id: String) {
        if !selected.contains(id) { selected = [id] }
        resizeBaseSizes = [:]
        for sid in selected where !sid.hasPrefix("t:") {
            resizeBaseSizes[sid] = sizes[sid] ?? defaultW
        }
    }

    private func applyResize(_ factor: CGFloat) {
        for (sid, base) in resizeBaseSizes {
            sizes[sid] = max(40, base * factor)
        }
    }

    private func rotateSelectedOrSelf(id: String, toAngle: CGFloat) {
        if !selected.contains(id) { selected = [id] }
        let delta = toAngle - (rotations[id] ?? 0)
        for ss in screenshots where selected.contains(ss.id.uuidString) {
            rotations[ss.id.uuidString] = (rotations[ss.id.uuidString] ?? 0) + delta
        }
    }

    // MARK: Layers / lock / group

    private var allKeys: [String] {
        screenshots.map { $0.id.uuidString } + texts.map { textKey($0) }
    }
    /// Persisted order with stale keys dropped and any new keys appended (on top).
    private var displayOrder: [String] {
        let valid = Set(allKeys)
        var result = order.filter { valid.contains($0) }
        let present = Set(result)
        for k in allKeys where !present.contains(k) { result.append(k) }
        return result
    }
    private func materializeOrder() { order = displayOrder }

    private func selectItem(_ key: String) {
        if let g = groups.first(where: { $0.contains(key) }) { selected = Set(g) }
        else { selected = [key] }
    }
    private func selectIfNeeded(_ key: String) { if !selected.contains(key) { selectItem(key) } }

    private func bringToFront() {
        materializeOrder(); let sel = order.filter { selected.contains($0) }
        order.removeAll { selected.contains($0) }; order.append(contentsOf: sel); persist()
    }
    private func sendToBack() {
        materializeOrder(); let sel = order.filter { selected.contains($0) }
        order.removeAll { selected.contains($0) }; order.insert(contentsOf: sel, at: 0); persist()
    }
    private func moveForward() {
        materializeOrder(); var a = order
        if a.count >= 2 { for i in stride(from: a.count - 2, through: 0, by: -1)
            where selected.contains(a[i]) && !selected.contains(a[i+1]) { a.swapAt(i, i+1) } }
        order = a; persist()
    }
    private func moveBackward() {
        materializeOrder(); var a = order
        if a.count >= 2 { for i in 1..<a.count
            where selected.contains(a[i]) && !selected.contains(a[i-1]) { a.swapAt(i, i-1) } }
        order = a; persist()
    }

    private func toggleLock(_ key: String) {
        let keys = selected.contains(key) ? selected : [key]
        if keys.allSatisfy({ locked.contains($0) }) { locked.subtract(keys) } else { locked.formUnion(keys) }
        persist()
    }
    private func groupSelected() {
        guard selected.count >= 2 else { return }
        groups.removeAll { !Set($0).isDisjoint(with: selected) }
        groups.append(Array(selected)); persist()
    }
    private func ungroup(_ key: String) { groups.removeAll { $0.contains(key) }; persist() }

    private func deleteKey(_ key: String) {
        if key.hasPrefix("t:") {
            texts.removeAll { textKey($0) == key }
        } else if let ss = screenshots.first(where: { $0.id.uuidString == key }) {
            DataStore.shared.delete(ss)
        }
        order.removeAll { $0 == key }
        locked.remove(key)
        groups = groups.map { $0.filter { $0 != key } }.filter { $0.count >= 2 }
        selected.remove(key)
        persist()
    }

    @ViewBuilder private func layerLockGroupMenu(_ key: String) -> some View {
        Button("置于顶层") { selectIfNeeded(key); bringToFront() }
        Button("置于底层") { selectIfNeeded(key); sendToBack() }
        Button("上移一层") { selectIfNeeded(key); moveForward() }
        Button("下移一层") { selectIfNeeded(key); moveBackward() }
        Divider()
        Button(locked.contains(key) ? "解锁" : "锁定") { toggleLock(key) }
        Button("编组") { groupSelected() }.disabled(selected.count < 2)
        Button("解组") { ungroup(key) }.disabled(!groups.contains { $0.contains(key) })
    }

    // MARK: Selection / group move

    /// Mark the canvas as actively moving (suppresses shadows for smoothness) and
    /// schedule a reset — used by scroll/trackpad pan, which has no gesture end.
    private func markInteracting() {
        isInteracting = true
        interactClear?.cancel()
        let work = DispatchWorkItem { isInteracting = false }
        interactClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func beginGroupDrag(_ id: String) {
        if !selected.contains(id) { selectItem(id) }
        groupActive = true
        isInteracting = true
    }

    private func commitGroupDrag() {
        guard groupActive else { return }
        let dx = groupDelta.width / effScale, dy = groupDelta.height / effScale
        for ss in screenshots where selected.contains(ss.id.uuidString) {
            var p = positions[ss.id.uuidString] ?? .zero
            p.x += dx; p.y += dy
            positions[ss.id.uuidString] = p
        }
        for i in texts.indices where selected.contains(textKey(texts[i])) {
            texts[i].x += dx; texts[i].y += dy
        }
        groupActive = false; groupDelta = .zero
        isInteracting = false
        persist()
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { v in
                let r = CGRect(x: min(v.startLocation.x, v.location.x),
                               y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x),
                               height: abs(v.location.y - v.startLocation.y))
                marquee = r
                selectInMarquee(r)
            }
            .onEnded { _ in marquee = nil }
    }

    private func selectInMarquee(_ r: CGRect) {
        var sel = Set<String>()
        for ss in screenshots {
            let id = ss.id.uuidString
            let c = center(id), w = imgW(id) * effScale, h = imgH(id) * effScale
            if CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h).intersects(r) { sel.insert(id) }
        }
        for t in texts {
            let c = textCenter(t)
            let w = CGFloat(max(t.text.count, 1)) * 16 * effScale * 0.6, h = 24 * effScale
            if CGRect(x: c.x - 6, y: c.y - h / 2, width: max(w, 16), height: h).intersects(r) { sel.insert(textKey(t)) }
        }
        selected = sel
    }

    // MARK: Controls

    private var gridOverlay: some View {
        Canvas { ctx, size in
            let step = max(8, 40 * effScale)
            var sx = pan.width.truncatingRemainder(dividingBy: step); if sx > 0 { sx -= step }
            var sy = pan.height.truncatingRemainder(dividingBy: step); if sy > 0 { sy -= step }
            if gridStyle == "dots" {
                var y = sy
                while y <= size.height {
                    var x = sx
                    while x <= size.width {
                        let r: CGFloat = 1.2
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(.gray.opacity(0.4)))
                        x += step
                    }
                    y += step
                }
            } else {
                var x = sx
                while x <= size.width {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
                    x += step
                }
                var y = sy
                while y <= size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
                    y += step
                }
            }
        }
        .allowsHitTesting(false)
    }

    // Top-left: text, background colour + eyedropper, grid/dots, export.
    private func topControls(viewport: CGSize) -> some View {
        HStack(spacing: 10) {
            Button { addText(viewport: viewport) } label: { Image(systemName: "textbox") }
                .help("添加文本")
            Divider().frame(height: 16)
            ColorPicker("", selection: $bgColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24)
                .onChange(of: bgColor) { _ in persist() }
                .help("画布底色")
            Button { sampleColor() } label: { Image(systemName: "eyedropper") }
                .help("吸管：从屏幕取色作为底色")
            // Background pattern, tiled inline
            Picker("", selection: $gridStyle) {
                Image(systemName: "slash.circle").tag("none")
                Image(systemName: "grid").tag("grid")
                Image(systemName: "circle.grid.2x2").tag("dots")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: gridStyle) { _ in persist() }
            .help("背景：无 / 网格 / 点阵")
            Divider().frame(height: 16)
            // Render quality: lower = smaller thumbnails = smoother with many images.
            Picker("", selection: $renderQuality) {
                Text("低").tag(0); Text("中").tag(1); Text("高").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: renderQuality) { _ in styledCache.removeAll(); styledAspectCache.removeAll() }
            .help("渲染质量：低更流畅 / 高更清晰")
            Divider().frame(height: 16)
            Menu {
                Button("当前视图范围（150dpi）") { exportViewport() }
                Button("1245 × 1660") { beginExportFrame(CGSize(width: 1245, height: 1660), viewport: viewport) }
                Button("自定义尺寸…") { promptCustomSize(viewport: viewport) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuIndicator(.hidden).fixedSize()
            .help("导出画布")
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    // Bottom-left: zoom / fit / reset.
    private func zoomControls(viewport: CGSize) -> some View {
        HStack(spacing: 8) {
            Button { zoom(1 / 1.25, viewport: viewport) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(scale * 100))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { zoom(1.25, viewport: viewport) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { fitToContent(viewport: viewport) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("一键全屏展示全部内容")
            Button { resetView(viewport: viewport) } label: { Image(systemName: "arrow.counterclockwise") }
                .foregroundColor(.red)
                .help("复原默认排列")
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func sampleColor() {
        NSColorSampler().show { picked in
            if let c = picked { bgColor = Color(nsColor: c); persist() }
        }
    }

    // Export frame: aspect-locked rectangle the user moves/resizes, then confirms.
    @ViewBuilder private func exportFrameOverlay(viewport: CGSize) -> some View {
        if let r = exportRect, let target = exportTarget {
            let sr = CGRect(x: pan.width + r.minX * effScale, y: pan.height + r.minY * effScale,
                            width: r.width * effScale, height: r.height * effScale)
            let aspect = target.width / target.height
            ZStack {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])))
                    .frame(width: sr.width, height: sr.height)
                    .position(x: sr.midX, y: sr.midY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if exportDragStart == nil { exportDragStart = exportRect }
                                if let base = exportDragStart {
                                    exportRect = CGRect(x: base.minX + v.translation.width / effScale,
                                                        y: base.minY + v.translation.height / effScale,
                                                        width: base.width, height: base.height)
                                }
                            }
                            .onEnded { _ in exportDragStart = nil }
                    )
                // resize handle (bottom-right), keeps target aspect
                Circle().fill(Color.accentColor).frame(width: 16, height: 16)
                    .position(x: sr.maxX, y: sr.maxY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if exportDragStart == nil { exportDragStart = exportRect }
                                if let base = exportDragStart {
                                    let newW = max(40, base.width + v.translation.width / effScale)
                                    exportRect = CGRect(x: base.minX, y: base.minY, width: newW, height: newW / aspect)
                                }
                            }
                            .onEnded { _ in exportDragStart = nil }
                    )
                // confirm / cancel
                HStack(spacing: 8) {
                    Button { confirmExport() } label: { Label("导出", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { exportRect = nil; exportTarget = nil } label: { Text("取消") }
                        .buttonStyle(.bordered)
                }
                .position(x: sr.midX, y: max(20, sr.minY - 20))
            }
        }
    }

    // MARK: Export

    private func contentBoundingBox() -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var any = false
        for ss in screenshots {
            let id = ss.id.uuidString, p = positions[id] ?? .zero
            let w = imgW(id), h = imgH(id)
            minX = min(minX, p.x - w/2); maxX = max(maxX, p.x + w/2)
            minY = min(minY, p.y - h/2); maxY = max(maxY, p.y + h/2); any = true
        }
        for t in texts where !t.text.isEmpty {
            minX = min(minX, t.x - 4); maxX = max(maxX, t.x + CGFloat(max(t.text.count, 1)) * 10)
            minY = min(minY, t.y - 12); maxY = max(maxY, t.y + 12); any = true
        }
        guard any, maxX > minX, maxY > minY else { return nil }
        let pad: CGFloat = 24
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad*2, height: maxY - minY + pad*2)
    }

    /// Render a region of the board (in content points) to an image.
    /// `target` nil → render at `dpi`; otherwise output exactly `target` px
    /// (the caller keeps `rect` locked to `target`'s aspect, so no letterbox).
    private func renderCanvas(contentRect rect: CGRect, target: CGSize?, dpi: CGFloat = 150) -> NSImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let drawScale: CGFloat
        let outW: Int, outH: Int
        if let t = target {
            drawScale = t.width / rect.width
            outW = Int(t.width.rounded()); outH = Int(t.height.rounded())
        } else {
            drawScale = dpi / 72.0
            outW = Int((rect.width * drawScale).rounded()); outH = Int((rect.height * drawScale).rounded())
        }
        guard outW > 0, outH > 0,
              let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Work in CONTENT POINTS, y-down, origin at rect.minX/minY — same flip
        // convention as the (verified-correct) CaptureCoordinator.crop().
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: drawScale, y: -drawScale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        (NSColor(bgColor).usingColorSpace(.sRGB) ?? .white).setFill()
        NSBezierPath(rect: rect).fill()

        if gridStyle != "none" {
            let step: CGFloat = 40
            let x0 = (rect.minX / step).rounded(.down) * step
            let y0 = (rect.minY / step).rounded(.down) * step
            if gridStyle == "dots" {
                NSColor.gray.withAlphaComponent(0.4).setFill()
                let r: CGFloat = 1.2
                var y = y0
                while y <= rect.maxY { var x = x0; while x <= rect.maxX { NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r*2, height: r*2)).fill(); x += step }; y += step }
            } else {
                NSColor.gray.withAlphaComponent(0.18).setStroke()
                let p = NSBezierPath(); p.lineWidth = 0.5
                var x = x0; while x <= rect.maxX { p.move(to: NSPoint(x: x, y: rect.minY)); p.line(to: NSPoint(x: x, y: rect.maxY)); x += step }
                var y = y0; while y <= rect.maxY { p.move(to: NSPoint(x: rect.minX, y: y)); p.line(to: NSPoint(x: rect.maxX, y: y)); y += step }
                p.stroke()
            }
        }

        // Draw in z-order so images & texts interleave the same as on-canvas.
        for key in displayOrder {
            if key.hasPrefix("t:") {
                guard let t = texts.first(where: { textKey($0) == key }), !t.text.isEmpty else { continue }
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
                let sz = (t.text as NSString).size(withAttributes: attrs)
                (t.text as NSString).draw(at: NSPoint(x: t.x - sz.width/2, y: t.y - sz.height/2), withAttributes: attrs)
            } else if let ss = screenshots.first(where: { $0.id.uuidString == key }),
                      let raw = FileStorageManager.shared.load(fileName: ss.fileName) {
                let img = ImageStyler.styled(raw, whiteEdge: whiteEdge.contains(key), polaroid: polaroid.contains(key))
                let w = imgW(key), h = imgH(key), p = positions[key] ?? .zero
                NSGraphicsContext.saveGraphicsState()
                let xf = NSAffineTransform()
                xf.translateX(by: p.x, yBy: p.y)
                if let rot = rotations[key], rot != 0 { xf.rotate(byDegrees: rot) }
                xf.concat()
                img.draw(in: NSRect(x: -w/2, y: -h/2, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        NSGraphicsContext.current = prev
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: outW, height: outH))
    }

    private func savePNG(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "canvas.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation,
              let bm = NSBitmapImageRep(data: tiff),
              let png = bm.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The current visible viewport, in content coords.
    private func viewportContentRect() -> CGRect {
        CGRect(x: -pan.width / effScale, y: -pan.height / effScale,
               width: viewport.width / effScale, height: viewport.height / effScale)
    }

    private func exportViewport() {
        if let img = renderCanvas(contentRect: viewportContentRect(), target: nil, dpi: 150) { savePNG(img) }
    }

    // Show an aspect-locked export frame over the canvas; user adjusts then confirms.
    private func beginExportFrame(_ target: CGSize, viewport: CGSize) {
        exportTarget = target
        let aspect = target.width / target.height
        let base = contentBoundingBox() ?? viewportContentRect()
        var w = base.width, h = w / aspect
        if h < base.height { h = base.height; w = h * aspect }
        exportRect = CGRect(x: base.midX - w/2, y: base.midY - h/2, width: w, height: h)
    }

    private func confirmExport() {
        guard let rect = exportRect, let target = exportTarget else { return }
        if let img = renderCanvas(contentRect: rect, target: target) { savePNG(img) }
        exportRect = nil; exportTarget = nil
    }

    private func promptCustomSize(viewport: CGSize) {
        let alert = NSAlert()
        alert.messageText = "自定义导出尺寸"
        alert.informativeText = "输入像素尺寸，例如 1000x1400"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        tf.stringValue = "1200x1200"
        alert.accessoryView = tf
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = tf.stringValue.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
        if parts.count == 2,
           let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let h = Double(parts[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0 {
            beginExportFrame(CGSize(width: w, height: h), viewport: viewport)
        }
    }

    private func addText(viewport: CGSize) {
        let c = CGPoint(x: (viewport.width / 2 - pan.width) / effScale,
                        y: (viewport.height / 2 - pan.height) / effScale)
        texts.append(CanvasTextItem(text: "", x: c.x, y: c.y))
        persist()
    }

    private func zoom(_ factor: CGFloat, viewport: CGSize) {
        let newScale = min(max(scale * factor, 0.25), 4)
        let f = newScale / scale
        pan.width = viewport.width / 2 - (viewport.width / 2 - pan.width) * f
        pan.height = viewport.height / 2 - (viewport.height / 2 - pan.height) * f
        scale = newScale
        persist()
    }

    /// Fit all content into the viewport (one-tap "show everything").
    private func fitToContent(viewport: CGSize) {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for ss in screenshots {
            let id = ss.id.uuidString, p = positions[id] ?? .zero
            let w = imgW(id), h = imgH(id)
            minX = min(minX, p.x - w/2); maxX = max(maxX, p.x + w/2)
            minY = min(minY, p.y - h/2); maxY = max(maxY, p.y + h/2)
        }
        for t in texts {
            minX = min(minX, t.x); maxX = max(maxX, t.x + 120)
            minY = min(minY, t.y); maxY = max(maxY, t.y + 24)
        }
        let cw = maxX - minX, ch = maxY - minY
        guard cw > 0, ch > 0 else { return }
        let margin: CGFloat = 48
        scale = max(0.25, min((viewport.width - margin*2) / cw, (viewport.height - margin*2) / ch, 4))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        pan = CGSize(width: viewport.width/2 - cx * scale, height: viewport.height/2 - cy * scale)
        persist()
    }

    private func resetView(viewport: CGSize) {
        scale = 1; pan = .zero
        sizes.removeAll()
        rotations.removeAll()
        layout(in: viewport, force: true)
        persist()
    }

    // MARK: Layout & persistence

    private func defaultPosition(_ index: Int, canvasWidth: CGFloat) -> CGPoint {
        let cols = max(1, Int((canvasWidth - gap) / (defaultW + gap)))
        let col = index % cols, row = index / cols
        return CGPoint(x: gap + defaultW / 2 + CGFloat(col) * (defaultW + gap),
                       y: gap + 60 + CGFloat(row) * (defaultW + gap))
    }

    private func layout(in size: CGSize, force: Bool = false) {
        for (i, ss) in screenshots.enumerated() where force || positions[ss.id.uuidString] == nil {
            positions[ss.id.uuidString] = defaultPosition(i, canvasWidth: size.width)
        }
    }

    private func loadLayout(in size: CGSize) {
        guard !loaded else { return }
        loaded = true
        let l = DataStore.shared.loadCanvasLayout(folderId: folderId)
        positions = l.positions
        sizes = l.sizes
        rotations = l.rotations
        texts = l.texts
        pan = CGSize(width: l.panX, height: l.panY)
        scale = l.scale == 0 ? 1 : l.scale
        if let bg = l.background { bgColor = Color(hexString: bg) }
        gridStyle = l.gridStyle
        order = l.order
        locked = Set(l.locked)
        groups = l.groups
        whiteEdge = Set(l.whiteEdge)
        polaroid = Set(l.polaroid)
        noShadow = Set(l.noShadow)
        for ss in screenshots {
            if let img = FileStorageManager.shared.thumbnail(fileName: ss.fileName) {
                aspects[ss.id.uuidString] = img.size.width / max(img.size.height, 1)
            }
        }
        layout(in: size)
        order = displayOrder   // materialize (append any new keys)
    }

    private func persist() {
        DataStore.shared.saveCanvasLayout(
            CanvasLayout(positions: positions, sizes: sizes, rotations: rotations, texts: texts,
                         panX: pan.width, panY: pan.height, scale: scale,
                         background: bgColor.toHexString(), gridStyle: gridStyle,
                         order: displayOrder, locked: Array(locked), groups: groups,
                         whiteEdge: Array(whiteEdge), polaroid: Array(polaroid), noShadow: Array(noShadow)),
            folderId: folderId
        )
    }

    private func startMonitors() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            markInteracting()
            if e.modifierFlags.contains(.option) {
                // ⌥ + scroll up = zoom in, down = zoom out
                if e.scrollingDeltaY > 0 { zoom(1.04, viewport: viewport) }
                else if e.scrollingDeltaY < 0 { zoom(1 / 1.04, viewport: viewport) }
            } else {
                pan.width += e.scrollingDeltaX; pan.height += e.scrollingDeltaY
            }
            return e
        }
        // Middle-button (scroll-wheel press) drag pans the canvas.
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDragged) { e in
            markInteracting()
            pan.width += e.deltaX; pan.height += e.deltaY; return e
        }
        // ⌘C copies the selected canvas images; Delete removes the selection.
        copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if NSApp.keyWindow?.firstResponder is NSText { return e }   // editing a text note
            // ⌘C copy
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               e.charactersIgnoringModifiers == "c" {
                let ids = selected.filter { !$0.hasPrefix("t:") }
                let imgs = screenshots
                    .filter { ids.contains($0.id.uuidString) }
                    .compactMap { FileStorageManager.shared.load(fileName: $0.fileName) }
                guard !imgs.isEmpty else { return e }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(imgs)
                return nil
            }
            // Delete / Backspace removes selected images & texts
            if e.keyCode == 51 || e.keyCode == 117, !selected.isEmpty {
                let keys = selected
                for ss in screenshots where keys.contains(ss.id.uuidString) {
                    DataStore.shared.delete(ss)
                }
                texts.removeAll { keys.contains(textKey($0)) }
                order.removeAll { keys.contains($0) }
                locked.subtract(keys)
                groups = groups.map { $0.filter { !keys.contains($0) } }.filter { $0.count >= 2 }
                selected.removeAll()
                persist()
                return nil
            }
            return e
        }
    }

    private func stopMonitors() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = panMonitor { NSEvent.removeMonitor(m); panMonitor = nil }
        if let m = copyMonitor { NSEvent.removeMonitor(m); copyMonitor = nil }
    }
}

/// A canvas image: click to select (shows resize handle), drag to move (moves the
/// whole selection), drag the corner handle to resize.
struct CanvasItemView: View {
    let screenshot: Screenshot
    var image: NSImage? = nil
    var noShadow: Bool = false
    var interacting: Bool = false   // pan/zoom/drag in progress → skip shadow for smoothness
    let center: CGPoint
    let width: CGFloat
    let height: CGFloat
    let selected: Bool
    var locked: Bool = false
    var onSelect: () -> Void
    var onMove: (CGSize) -> Void
    var onMoveEnded: () -> Void
    var onResizeBegan: () -> Void = {}
    var onResize: (CGFloat) -> Void       // scale factor relative to resize start
    var onResizeEnded: () -> Void = {}
    var rotation: CGFloat = 0
    var onRotate: (CGFloat) -> Void = { _ in }
    var onRotateEnded: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var menu: () -> AnyView
    var frameButtons: () -> AnyView = { AnyView(EmptyView()) }
    @State private var resizeBase: CGFloat = 0
    @State private var didDuplicate = false

    var body: some View {
        let img = image ?? FileStorageManager.shared.thumbnail(fileName: screenshot.fileName, maxPixel: 640)
        return Group {
            if let img {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: width, height: height)
        .cornerRadius(6)   // also clips (scaledToFit never overflows, so no separate .clipped() needed)
        .shadow(color: (noShadow || interacting) ? .clear : .black.opacity(0.25),
                radius: (noShadow || interacting) ? 0 : 4, y: (noShadow || interacting) ? 0 : 2)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        // Lock badge (top-right, clear of the frame button row)
        .overlay(alignment: .topTrailing) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    .padding(3).background(Circle().fill(Color.black.opacity(0.5)))
                    .padding(4)
            }
        }
        // Frame-style toolbar (white edge / Polaroid / shadow) to the right of the frame,
        // vertically centered. Hidden when locked (unlock via right-click).
        .overlay(alignment: .trailing) {
            if selected && !locked {
                frameButtons().offset(x: 34)
            }
        }
        // Resize handle (bottom-right)
        .overlay(alignment: .bottomTrailing) {
            if selected && !locked {
                Circle().fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .overlay(Image(systemName: "arrow.down.right").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
                    .offset(x: 6, y: 6)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if resizeBase == 0 { resizeBase = width; onResizeBegan() }
                                onResize(max(0.1, (resizeBase + v.translation.width) / resizeBase))
                            }
                            .onEnded { _ in resizeBase = 0; onResizeEnded() }
                    )
            }
        }
        // Rotation handle (top-center)
        .overlay(alignment: .top) {
            if selected && !locked {
                Circle().fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .overlay(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
                    .offset(y: -26)
                    .gesture(
                        DragGesture(coordinateSpace: .named("canvas"))
                            .onChanged { v in
                                let ang = atan2(v.location.y - center.y, v.location.x - center.x) * 180 / .pi + 90
                                onRotate(ang)
                            }
                            .onEnded { _ in onRotateEnded() }
                    )
            }
        }
        .rotationEffect(.degrees(rotation))
        .position(x: center.x, y: center.y)
        .onTapGesture { onSelect() }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if !didDuplicate && NSEvent.modifierFlags.contains(.option) { onDuplicate(); didDuplicate = true }
                    onMove(v.translation)
                }
                .onEnded { _ in didDuplicate = false; onMoveEnded() },
            including: locked ? .subviews : .all   // locked → no move
        )
        .contextMenu { menu() }
    }
}

/// Drop images from Finder onto the canvas at the cursor position.
struct CanvasDropDelegate: DropDelegate {
    let folderId: UUID?
    let toContent: (CGPoint) -> CGPoint
    let place: (String, CGPoint) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        let base = toContent(info.location)
        var i = 0
        for p in info.itemProviders(for: [UTType.fileURL.identifier]) {
            let spot = CGPoint(x: base.x + CGFloat(i) * 24, y: base.y + CGFloat(i) * 24)
            i += 1
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                guard let fileURL = url,
                      let img = NSImage(contentsOf: fileURL),
                      let name = FileStorageManager.shared.save(image: img) else { return }
                DispatchQueue.main.async {
                    let ss = Screenshot(fileName: name, createdAt: Date(), folderId: folderId)
                    DataStore.shared.addScreenshot(ss)
                    place(ss.id.uuidString, spot)
                }
            }
        }
        return true
    }
}

/// A draggable text note on the canvas: black text on a transparent background.
/// The editing box hugs the text; Return / ✓ / clicking empty space confirm;
/// ⌘Return inserts a line break; double-click to edit again; drag to move.
struct CanvasTextView: View {
    @Binding var item: CanvasTextItem
    let pan: CGSize
    let scale: CGFloat
    var groupOffset: CGSize = .zero
    var selected: Bool = false
    var locked: Bool = false
    var onSelect: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var extraMenu: () -> AnyView = { AnyView(EmptyView()) }
    var onCommit: () -> Void
    var onDelete: () -> Void

    @GestureState private var drag: CGSize = .zero
    @State private var editing = false
    @State private var didDuplicate = false

    private var font: Font { .system(size: 16 * scale) }   // fixed size 16

    private func finish() {
        editing = false
        if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDelete() }
        else { onCommit() }
    }

    var body: some View {
        content
            .position(x: pan.width + item.x * scale + drag.width + groupOffset.width,
                      y: pan.height + item.y * scale + drag.height + groupOffset.height)
            // Disable the move-drag while editing so the editor gets the clicks.
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onChanged { _ in
                        if !didDuplicate && NSEvent.modifierFlags.contains(.option) { onDuplicate(); didDuplicate = true }
                    }
                    .onEnded { v in
                        didDuplicate = false
                        item.x += v.translation.width / scale
                        item.y += v.translation.height / scale
                        onCommit()
                    },
                including: (editing || locked) ? .subviews : .all
            )
            .onAppear { if item.text.isEmpty { editing = true } }
    }

    @ViewBuilder private var content: some View {
        if editing {
            HStack(alignment: .top, spacing: 6 * scale) {
                CanvasTextEditor(text: $item.text, fontSize: 16 * scale, onConfirm: finish)
                    .fixedSize()        // size to the text, not the available space

                // ✓ confirm — bigger, finish editing
                Button { finish() } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24 * scale))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(6 * scale)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
        } else {
            Text(item.text.isEmpty ? " " : item.text)
                .font(font)
                .foregroundColor(.black)
                .fixedSize()
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white).padding(2).background(Circle().fill(Color.black.opacity(0.5)))
                            .offset(x: -6, y: -6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if !locked { editing = true } }
                .onTapGesture { onSelect() }
                .contextMenu {
                    Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
                    Divider()
                    extraMenu()
                }
        }
    }
}

/// An auto-sizing NSTextView editor: transparent, black text, width hugs the
/// content. Return (or losing focus) confirms; ⌘Return inserts a newline.
struct CanvasTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onConfirm: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CanvasKeyTextView {
        let tv = CanvasKeyTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textColor = .black
        tv.insertionPointColor = .black
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.onConfirm = onConfirm
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return tv
    }

    func updateNSView(_ tv: CanvasKeyTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.font = .systemFont(ofSize: fontSize)
        tv.onConfirm = onConfirm
        tv.invalidateIntrinsicContentSize()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CanvasTextEditor
        init(_ p: CanvasTextEditor) { parent = p }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? CanvasKeyTextView else { return }
            parent.text = tv.string
            tv.invalidateIntrinsicContentSize()
        }
        func textDidEndEditing(_ note: Notification) { parent.onConfirm() }
    }
}

final class CanvasKeyTextView: NSTextView {
    var onConfirm: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).size
        return NSSize(width: used.width + textContainerInset.width * 2 + 6,
                      height: used.height + textContainerInset.height * 2)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 {                              // Return
            if event.modifierFlags.contains(.command) {
                insertNewline(nil)                            // ⌘Return → line break
            } else {
                onConfirm?()                                  // Return → confirm
            }
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Color <-> hex

extension Color {
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    func toHexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

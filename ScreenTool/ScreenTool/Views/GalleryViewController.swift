import UIKit
import Photos

class GalleryViewController: UIViewController {

    private let dataStore = DataStore.shared
    private var currentFolderId: UUID?
    private var isSelecting = false
    private var selectedIds: Set<UUID> = []

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .systemGroupedBackground
        cv.register(ScreenshotCell.self, forCellWithReuseIdentifier: ScreenshotCell.reuseId)
        cv.delegate = self
        cv.dataSource = self
        cv.allowsMultipleSelection = false
        return cv
    }()

    private lazy var sidebarTable: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "FolderCell")
        tv.delegate = self
        tv.dataSource = self
        return tv
    }()

    private var splitContainer: UISplitView!
    private var selectBarButton: UIBarButtonItem!
    private var exportBarButton: UIBarButtonItem!
    private var addFolderButton: UIBarButtonItem!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "截图库"
        view.backgroundColor = .systemGroupedBackground
        setupLayout()
        setupNavBar()
        bindDataStore()
    }

    private func setupLayout() {
        let sidebar = UIView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        sidebarTable.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebarTable)
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            sidebarTable.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            sidebarTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarTable.widthAnchor.constraint(equalToConstant: 220),
            sidebarTable.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: sidebarTable.trailingAnchor, constant: 1),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupNavBar() {
        selectBarButton = UIBarButtonItem(title: "选择", style: .plain, target: self, action: #selector(toggleSelect))
        exportBarButton = UIBarButtonItem(title: "保存到相册", style: .plain, target: self, action: #selector(exportSelected))
        addFolderButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addFolder))
        exportBarButton.isEnabled = false
        navigationItem.rightBarButtonItems = [selectBarButton, exportBarButton]
        navigationItem.leftBarButtonItem = addFolderButton
    }

    private func bindDataStore() {
        NotificationCenter.default.addObserver(forName: .init("DataStoreUpdated"), object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    private func reload() {
        collectionView.reloadData()
        sidebarTable.reloadData()
    }

    @objc private func toggleSelect() {
        isSelecting.toggle()
        selectedIds.removeAll()
        selectBarButton.title = isSelecting ? "完成" : "选择"
        exportBarButton.isEnabled = false
        collectionView.reloadData()
    }

    @objc private func addFolder() {
        let alert = UIAlertController(title: "新建文件夹", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "文件夹名称" }
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self?.dataStore.addFolder(name: name)
            self?.sidebarTable.reloadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func exportSelected() {
        let toExport = dataStore.screenshots.filter { selectedIds.contains($0.id) }
        let images = toExport.compactMap { FileStorageManager.shared.load(fileName: $0.fileName) }
        guard !images.isEmpty else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.showAlert("需要相册权限", message: "请在设置中允许访问相册。")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for img in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.showAlert("保存成功", message: "已将 \(images.count) 张截图保存到相册。")
                        self.toggleSelect()
                    } else {
                        self.showAlert("保存失败", message: error?.localizedDescription ?? "未知错误")
                    }
                }
            }
        }
    }

    private func showAlert(_ title: String, message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default))
        present(a, animated: true)
    }

    var currentScreenshots: [Screenshot] {
        dataStore.screenshots(in: currentFolderId)
    }
}

// MARK: - UICollectionView

extension GalleryViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        currentScreenshots.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: ScreenshotCell.reuseId, for: indexPath) as! ScreenshotCell
        let item = currentScreenshots[indexPath.item]
        cell.configure(with: item, selected: selectedIds.contains(item.id))
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = cv.bounds.width - 32 - 16
        let size = available / 3
        return CGSize(width: size, height: size)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = currentScreenshots[indexPath.item]
        if isSelecting {
            if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
            else { selectedIds.insert(item.id) }
            exportBarButton.isEnabled = !selectedIds.isEmpty
            cv.reloadItems(at: [indexPath])
        } else {
            let vc = ScreenshotDetailViewController(screenshot: item)
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = currentScreenshots[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }
            let delete = UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.dataStore.deleteScreenshot(item)
                self.collectionView.reloadData()
            }
            let move = UIAction(title: "移动到文件夹", image: UIImage(systemName: "folder")) { _ in
                self.showMovePicker(for: item)
            }
            let export = UIAction(title: "保存到相册", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self.exportSingle(item)
            }
            return UIMenu(title: "", children: [export, move, delete])
        }
    }

    private func showMovePicker(for screenshot: Screenshot) {
        let alert = UIAlertController(title: "移动到文件夹", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "未分类", style: .default) { [weak self] _ in
            self?.dataStore.moveScreenshot(screenshot, to: nil)
            self?.collectionView.reloadData()
        })
        for folder in dataStore.folders {
            alert.addAction(UIAlertAction(title: folder.name, style: .default) { [weak self] _ in
                self?.dataStore.moveScreenshot(screenshot, to: folder.id)
                self?.collectionView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func exportSingle(_ screenshot: Screenshot) {
        guard let img = FileStorageManager.shared.load(fileName: screenshot.fileName) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }) { success, _ in
                DispatchQueue.main.async {
                    if success { self.showAlert("已保存", message: "截图已保存到相册") }
                }
            }
        }
    }
}

// MARK: - UITableView (Sidebar folders)

extension GalleryViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        dataStore.folders.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            config.text = "全部截图"
            config.image = UIImage(systemName: "photo.on.rectangle.angled")
        } else {
            let folder = dataStore.folders[indexPath.row - 1]
            config.text = folder.name
            config.image = UIImage(systemName: "folder")
        }
        cell.contentConfiguration = config
        cell.accessoryType = (indexPath.row == 0 ? currentFolderId == nil : currentFolderId == dataStore.folders[indexPath.row - 1].id) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            currentFolderId = nil
        } else {
            currentFolderId = dataStore.folders[indexPath.row - 1].id
        }
        tableView.reloadData()
        collectionView.reloadData()
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row > 0 else { return }
        let folder = dataStore.folders[indexPath.row - 1]
        if currentFolderId == folder.id { currentFolderId = nil }
        dataStore.deleteFolder(folder)
        tableView.reloadData()
        collectionView.reloadData()
    }

    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        indexPath.row == 0 ? nil : "删除"
    }
}

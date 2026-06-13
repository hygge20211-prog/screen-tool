import UIKit
import Photos

class ScreenshotDetailViewController: UIViewController {

    private let screenshot: Screenshot
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(screenshot: Screenshot) {
        self.screenshot = screenshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = DateFormatter.localizedString(from: screenshot.createdAt, dateStyle: .medium, timeStyle: .short)

        let saveButton = UIBarButtonItem(title: "保存到相册", style: .plain, target: self, action: #selector(saveToAlbum))
        let deleteButton = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(deleteScreenshot))
        deleteButton.tintColor = .systemRed
        navigationItem.rightBarButtonItems = [saveButton, deleteButton]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = self
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.image = FileStorageManager.shared.load(fileName: screenshot.fileName)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
    }

    @objc private func saveToAlbum() {
        guard let img = imageView.image else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }) { success, _ in
                DispatchQueue.main.async {
                    let a = UIAlertController(title: success ? "已保存" : "保存失败", message: nil, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "确定", style: .default))
                    self.present(a, animated: true)
                }
            }
        }
    }

    @objc private func deleteScreenshot() {
        let alert = UIAlertController(title: "删除截图", message: "确认删除此截图？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            DataStore.shared.deleteScreenshot(self.screenshot)
            self.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

extension ScreenshotDetailViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

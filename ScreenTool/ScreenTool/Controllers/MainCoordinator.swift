import UIKit
import PhotosUI

/// Floating button → pick image from Photos → lasso crop → save in app
class MainCoordinator: NSObject {

    private var floatingWindow: FloatingButtonWindow?
    private weak var mainWindow: UIWindow?
    private var pendingImage: UIImage?

    func start(in scene: UIWindowScene, mainWindow: UIWindow) {
        self.mainWindow = mainWindow
        let fw = FloatingButtonWindow(windowScene: scene)
        fw.isHidden = false
        fw.floatingButton.onTap = { [weak self] in
            self?.presentPhotoPicker()
        }
        self.floatingWindow = fw
    }

    // MARK: - Step 1: Pick from Photos

    func importFromPhotos(presentingVC: UIViewController? = nil) {
        presentingViewController = presentingVC
        presentPhotoPicker()
    }

    private weak var presentingViewController: UIViewController?

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presentModal(picker)
    }

    // MARK: - Step 2: Lasso overlay

    private func presentLasso(with image: UIImage) {
        pendingImage = image

        let lassoVC = LassoOverlayViewController()
        lassoVC.modalPresentationStyle = .overFullScreen
        lassoVC.modalTransitionStyle = .crossDissolve
        lassoVC.delegate = self

        // Show the imported image as background so user knows what they're selecting
        let bg = UIImageView(image: image)
        bg.frame = UIScreen.main.bounds
        bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bg.contentMode = .scaleAspectFit
        bg.backgroundColor = .black
        lassoVC.view.insertSubview(bg, at: 0)

        presentModal(lassoVC)
    }

    // MARK: - Helpers

    private func presentModal(_ vc: UIViewController) {
        if let explicit = presentingViewController {
            var top: UIViewController? = explicit
            while let presented = top?.presentedViewController { top = presented }
            top?.present(vc, animated: true)
            return
        }
        guard let mainWindow = mainWindow else { return }
        var top = mainWindow.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(vc, animated: true)
    }

    private func showSavedFeedback() {
        guard let window = mainWindow else { return }
        let label = UILabel()
        label.text = "截图已保存"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        label.textAlignment = .center
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            label.widthAnchor.constraint(equalToConstant: 140),
            label.heightAnchor.constraint(equalToConstant: 40)
        ])
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - PHPickerViewControllerDelegate

extension MainCoordinator: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                guard let image = object as? UIImage else { return }
                self?.presentLasso(with: image)
            }
        }
    }
}

// MARK: - LassoOverlayDelegate

extension MainCoordinator: LassoOverlayDelegate {
    func lassoDidConfirm(path: UIBezierPath, in size: CGSize) {
        guard let image = pendingImage else { return }

        // Adjust canvas size to account for aspectFit letterboxing
        let imgRatio = image.size.width / image.size.height
        let canvasRatio = size.width / size.height
        let effectiveCanvas: CGSize
        if imgRatio > canvasRatio {
            // letterbox top/bottom
            let h = size.width / imgRatio
            let offsetY = (size.height - h) / 2
            effectiveCanvas = CGSize(width: size.width, height: h)
            path.apply(CGAffineTransform(translationX: 0, y: -offsetY))
        } else {
            // pillarbox left/right
            let w = size.height * imgRatio
            let offsetX = (size.width - w) / 2
            effectiveCanvas = CGSize(width: w, height: size.height)
            path.apply(CGAffineTransform(translationX: -offsetX, y: 0))
        }

        let cropped = ScreenCaptureManager.shared.crop(image: image, to: path, in: effectiveCanvas)
        pendingImage = nil
        guard let cropped = cropped,
              let fileName = FileStorageManager.shared.save(image: cropped) else { return }

        let screenshot = Screenshot(fileName: fileName, createdAt: Date(), folderId: nil)
        DataStore.shared.addScreenshot(screenshot)
        NotificationCenter.default.post(name: .init("DataStoreUpdated"), object: nil)
        showSavedFeedback()
    }

    func lassoDidCancel() {
        pendingImage = nil
    }
}

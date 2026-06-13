import UIKit

/// Manages the floating button window and coordinates the screenshot capture flow.
class MainCoordinator {

    private var floatingWindow: FloatingButtonWindow?
    private weak var mainWindow: UIWindow?

    func start(in scene: UIWindowScene, mainWindow: UIWindow) {
        self.mainWindow = mainWindow
        let fw = FloatingButtonWindow(windowScene: scene)
        fw.isHidden = false
        fw.floatingButton.onTap = { [weak self] in
            self?.startCapture()
        }
        self.floatingWindow = fw
    }

    private func startCapture() {
        guard let mainWindow = mainWindow else { return }

        // 1. Hide the floating button briefly so it's not in the screenshot
        floatingWindow?.floatingButton.alpha = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            // 2. Capture the full screen
            let screenImage = ScreenCaptureManager.shared.captureScreen(in: mainWindow)

            // 3. Show floating button again
            UIView.animate(withDuration: 0.2) {
                self.floatingWindow?.floatingButton.alpha = 1
            }

            guard let screenImage = screenImage else { return }

            // 4. Present lasso overlay
            let lassoVC = LassoOverlayViewController()
            lassoVC.modalPresentationStyle = .overFullScreen
            lassoVC.modalTransitionStyle = .crossDissolve

            // Set a background snapshot so user can see what they're selecting
            let bg = UIImageView(image: screenImage)
            bg.frame = lassoVC.view.bounds
            bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            bg.contentMode = .scaleAspectFill
            lassoVC.view.insertSubview(bg, at: 0)

            lassoVC.delegate = self

            // Present from the topmost view controller
            var topVC = mainWindow.rootViewController
            while let presented = topVC?.presentedViewController { topVC = presented }
            topVC?.present(lassoVC, animated: true)

            // Store for later
            self.pendingScreenImage = screenImage
        }
    }

    private var pendingScreenImage: UIImage?
}

extension MainCoordinator: LassoOverlayDelegate {

    func lassoDidConfirm(path: UIBezierPath, in size: CGSize) {
        guard let image = pendingScreenImage else { return }
        let cropped = ScreenCaptureManager.shared.crop(image: image, to: path, in: size)
        guard let cropped = cropped else { return }

        guard let fileName = FileStorageManager.shared.save(image: cropped) else { return }
        let screenshot = Screenshot(fileName: fileName, createdAt: Date(), folderId: nil)
        DataStore.shared.addScreenshot(screenshot)
        NotificationCenter.default.post(name: .init("DataStoreUpdated"), object: nil)

        pendingScreenImage = nil
        showSavedFeedback()
    }

    func lassoDidCancel() {
        pendingScreenImage = nil
    }

    private func showSavedFeedback() {
        guard let window = mainWindow else { return }
        let label = UILabel()
        label.text = "截图已保存"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
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
        UIView.animate(withDuration: 0.3, delay: 1.2, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

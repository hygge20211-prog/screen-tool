import AppKit

class CaptureCoordinator: NSObject {

    private var overlayPanel: LassoOverlayPanel?
    private var capturedCGImage: CGImage?
    private var captureScale: CGFloat = 1.0

    /// Called when the capture flow ends (confirmed, cancelled, or permission denied),
    /// so the caller can restore any window it hid before capturing.
    var onCaptureFinished: (() -> Void)?

    // MARK: - Start

    func startCapture() {
        guard let screen = NSScreen.main else { return }

        // CGDisplayCreateImage does NOT fail when screen-recording permission is
        // missing — it silently returns a desktop-only image (no app windows).
        // So we must gate on the real permission state up front.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess() // adds us to the list / shows the system prompt
            showPermissionAlert()
            onCaptureFinished?()
            return
        }

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

        guard let img = CGDisplayCreateImage(displayID) else {
            showPermissionAlert()
            onCaptureFinished?()
            return
        }
        capturedCGImage = img
        captureScale = screen.backingScaleFactor

        // Small delay so any menu-close animation finishes before capture shows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.showOverlay(screen: screen)
        }
    }

    private func showOverlay(screen: NSScreen) {
        guard let cgImg = capturedCGImage else { return }
        let panel = LassoOverlayPanel(screen: screen, backgroundCGImage: cgImg)
        panel.lassoDelegate = self
        // Bring our app forward so the overlay receives mouse/keyboard events even
        // when capture was triggered while another app (e.g. the browser) was active.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        overlayPanel = panel
    }

    // MARK: - Permission guidance

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限才能截到窗口内容"
        alert.informativeText = """
        否则只会截到空桌面。请按以下步骤：

        1. 打开「系统设置 → 隐私与安全性 → 屏幕录制」
        2. 打开本 App（截图工具）的开关
        3. 关键：完全退出本 App（⌘Q）再重新打开，权限才会生效

        提示：用 Xcode 反复运行会让权限「认旧不认新」。建议把编译出的 .app 拖到「应用程序」文件夹，从那里启动，权限会更稳定。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Crop helper

    private func crop(cgImage: CGImage, path: NSBezierPath, scale: CGFloat) -> NSImage? {
        let widthPts  = CGFloat(cgImage.width)  / scale
        let heightPts = CGFloat(cgImage.height) / scale
        let nsSource  = NSImage(cgImage: cgImage, size: NSSize(width: widthPts, height: heightPts))

        let pb = path.bounds
        guard pb.width > 1, pb.height > 1 else { return nil }

        let result = NSImage(size: pb.size)
        result.lockFocusFlipped(true) // y-down, matches our flipped LassoView coords

        // Translate so that path.bounds.origin → (0,0)
        let adjusted = path.copy() as! NSBezierPath
        adjusted.transform(using: AffineTransform(translationByX: -pb.origin.x, byY: -pb.origin.y))
        adjusted.setClip()

        nsSource.draw(in: NSRect(x: -pb.origin.x, y: -pb.origin.y, width: widthPts, height: heightPts))

        result.unlockFocus()
        return result
    }
}

// MARK: - LassoOverlayDelegate

extension CaptureCoordinator: LassoOverlayDelegate {

    func lassoDidConfirm(path: NSBezierPath, canvasSize: NSSize, scale: CGFloat) {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        defer { onCaptureFinished?() } // always restore the hidden window

        guard let cgImg = capturedCGImage else { return }
        capturedCGImage = nil

        guard let cropped = crop(cgImage: cgImg, path: path, scale: scale),
              let fileName = FileStorageManager.shared.save(image: cropped) else { return }

        let screenshot = Screenshot(fileName: fileName, createdAt: Date(), folderId: nil)
        DataStore.shared.addScreenshot(screenshot)
        showToast("截图已保存")
    }

    func lassoDidCancel() {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        capturedCGImage = nil
        onCaptureFinished?()
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        guard let screen = NSScreen.main else { return }
        let toastSize = NSSize(width: 160, height: 44)
        let x = screen.frame.midX - toastSize.width / 2
        let y = screen.frame.maxY - 80

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: toastSize.width, height: toastSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces]

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor)
        ])

        panel.contentView = bg
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            panel.orderOut(nil)
        }
    }
}

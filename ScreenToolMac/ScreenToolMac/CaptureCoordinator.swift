import AppKit

/// How the user draws the selection region.
enum CaptureMode {
    case freeform    // click vertices and/or drag freehand (polygon + lasso) — the default
    case rectangle   // drag a rectangle
}

class CaptureCoordinator: NSObject {

    private var overlayPanel: LassoOverlayPanel?
    private var capturedCGImage: CGImage?
    private var captureScale: CGFloat = 1.0
    private var captureMode: CaptureMode = .freeform

    /// Called when the capture flow ends (confirmed, cancelled, or permission denied),
    /// so the caller can restore any window it hid before capturing.
    var onCaptureFinished: (() -> Void)?

    // MARK: - Start

    func startCapture(mode: CaptureMode = .freeform) {
        captureMode = mode
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
        let panel = LassoOverlayPanel(screen: screen, backgroundCGImage: cgImg, mode: captureMode)
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
        let pb = path.bounds
        guard pb.width > 1, pb.height > 1 else { return nil }

        // Render at PIXEL resolution. The path is in points; the captured image is
        // full Retina pixels. The old code drew into a 1x NSImage focus, throwing
        // away half the resolution on Retina (blurry result) — render to a
        // pixel-sized context instead so detail is preserved.
        let pxW = Int((pb.width  * scale).rounded())
        let pxH = Int((pb.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high

        // Map flipped screen-point coords (y-down, origin = screen top-left) into the
        // pixel context (y-up). After this the CTM speaks in points with y growing down.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -pb.minX, y: -pb.minY)

        // Clip to the lasso / polygon selection.
        ctx.addPath(path.cgPath)
        ctx.clip()

        // Draw the full-resolution screenshot, correctly oriented, via NSImage.
        let fullPtW = CGFloat(cgImage.width)  / scale
        let fullPtH = CGFloat(cgImage.height) / scale
        let nsSource = NSImage(cgImage: cgImage, size: NSSize(width: fullPtW, height: fullPtH))
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        nsSource.draw(in: NSRect(x: 0, y: 0, width: fullPtW, height: fullPtH))
        NSGraphicsContext.current = prev

        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: pb.size)
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

        let screenshot = Screenshot(fileName: fileName, createdAt: Date(),
                                    folderId: DataStore.shared.currentFolderId)
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

// MARK: - Re-crop an existing image (lasso / polygon) and save in place

private final class CropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the lasso/polygon overlay over an EXISTING image (aspect-fit on screen),
/// then overwrites the original file with the cropped result.
final class ImageCropController: NSObject {
    private var panel: CropPanel?
    private var onFinished: (() -> Void)?

    func begin(fileName: String, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        guard let screen = NSScreen.main,
              let nsImage = FileStorageManager.shared.load(fileName: fileName),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            onFinished(); return
        }
        let scale = screen.backingScaleFactor

        // Aspect-fit the image into the screen (in points), leaving room for the toolbar.
        let viewSize = screen.frame.size
        let avail = CGRect(x: 60, y: 96, width: viewSize.width - 120, height: viewSize.height - 200)
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        var w = avail.width, h = w / aspect
        if h > avail.height { h = avail.height; w = h * aspect }
        let fit = CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)

        let content = LassoContentView(backgroundCGImage: cg, scale: scale, mode: .freeform)
        content.imageRect = fit
        content.onConfirm = { [weak self] path in
            self?.finish(path: path, source: cg, fit: fit, fileName: fileName)
        }
        content.onCancel = { [weak self] in self?.close() }

        let panel = CropPanel(contentRect: screen.frame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func finish(path: NSBezierPath, source: CGImage, fit: NSRect, fileName: String) {
        panel?.orderOut(nil); panel = nil
        // Back up the original bytes so Cmd+Z can restore an accidental crop.
        let original = try? Data(contentsOf: FileStorageManager.shared.url(for: fileName))
        if let cropped = cropImage(source: source, path: path, imageRect: fit) {
            FileStorageManager.shared.overwrite(fileName: fileName, image: cropped)
            DataStore.shared.imageDidChange(fileName)
            registerCropUndo(fileName: fileName, original: original)
        }
        onFinished?(); onFinished = nil
    }

    /// Register a ⌘Z undo on the key window's undo manager that restores the
    /// pre-crop image bytes.
    private func registerCropUndo(fileName: String, original: Data?) {
        guard let original,
              let um = (NSApp.keyWindow ?? NSApp.mainWindow)?.undoManager else { return }
        um.registerUndo(withTarget: self) { _ in
            try? original.write(to: FileStorageManager.shared.url(for: fileName))
            FileStorageManager.shared.invalidateThumbnail(fileName: fileName)
            DataStore.shared.imageDidChange(fileName)
        }
        um.setActionName("裁剪图片")
    }

    private func close() {
        panel?.orderOut(nil); panel = nil
        onFinished?(); onFinished = nil
    }

    /// Crop `source` to `path`, where `path` is in view points and the image was
    /// displayed at `imageRect` (also view points). Output is full image resolution.
    private func cropImage(source: CGImage, path: NSBezierPath, imageRect: NSRect) -> NSImage? {
        let imgPxW = CGFloat(source.width), imgPxH = CGFloat(source.height)
        let sx = imgPxW / imageRect.width, sy = imgPxH / imageRect.height

        let p = path.copy() as! NSBezierPath
        p.transform(using: AffineTransform(translationByX: -imageRect.minX, byY: -imageRect.minY))
        p.transform(using: AffineTransform(scaleByX: sx, byY: sy))

        let pb = p.bounds
        guard pb.width > 1, pb.height > 1 else { return nil }
        let pxW = Int(pb.width.rounded()), pxH = Int(pb.height.rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -pb.minX, y: -pb.minY)
        ctx.addPath(p.cgPath)
        ctx.clip()

        let ns = NSImage(cgImage: source, size: NSSize(width: imgPxW, height: imgPxH))
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ns.draw(in: NSRect(x: 0, y: 0, width: imgPxW, height: imgPxH))
        NSGraphicsContext.current = prev

        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: pb.size)
    }
}

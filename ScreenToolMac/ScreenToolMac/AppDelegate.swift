import Cocoa
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    let coordinator = CaptureCoordinator()
    private let cropController = ImageCropController()
    private var galleryWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var floatingPanel: NSPanel?          // always-on-top quick-capture button
    private var floatingMenuItem: NSMenuItem?     // its menu toggle (reflects on/off)
    private var restoreGalleryAfterCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()   // standard app menu so ⌘Q / ⌘H / edit shortcuts work
        // Defer status-item creation one runloop tick: creating it too early in
        // launch can leave the menu-bar button blank on macOS 26 (item exists but
        // never composites). Creating it after activation renders reliably.
        DispatchQueue.main.async { [weak self] in self?.setupStatusItem() }
        // Restore hidden windows when capture finishes/cancels. Only re-raise the
        // gallery if it was actually open (so quick-capture from the floating button
        // doesn't pop the gallery up).
        coordinator.onCaptureFinished = { [weak self] in
            guard let self else { return }
            if self.restoreGalleryAfterCapture { self.galleryWindow?.makeKeyAndOrderFront(nil) }
            self.floatingPanel?.orderFront(nil)
        }
        // Global hotkey ⌃⌘5 — works from any app (browser etc.), no extra permission.
        // kVK_ANSI_5 = 0x17; Carbon mods cmdKey | controlKey.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_5),
                              modifiers: UInt32(cmdKey | controlKey))
        hotKey?.onFire = { [weak self] in
            DispatchQueue.main.async { self?.startCaptureHidingWindow(mode: .freeform) }
        }
        // Show the main window right away so the app is easy to find
        openGallery()
    }

    // Reopen the gallery window when the Dock icon is clicked
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openGallery() }
        return true
    }

    // Flush UserDefaults once on quit (we no longer synchronize on every edit).
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
    }

    // MARK: - Capture (hide window first so it isn't in the shot)

    func startCaptureHidingWindow(mode: CaptureMode) {
        restoreGalleryAfterCapture = galleryWindow?.isVisible ?? false
        galleryWindow?.orderOut(nil)
        floatingPanel?.orderOut(nil)   // keep the floating button out of the shot
        // Let the windows disappear before grabbing the screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.coordinator.startCapture(mode: mode)
        }
    }

    /// Capture WITHOUT hiding the app — so its own windows are in the shot.
    func startCaptureNoHide(mode: CaptureMode) {
        restoreGalleryAfterCapture = false
        coordinator.startCapture(mode: mode)
    }

    // Re-crop an existing image (lasso / polygon) and overwrite it in place.
    func recrop(_ ss: Screenshot) {
        cropController.begin(fileName: ss.fileName) { }
    }

    // MARK: - Floating quick-capture button (always on top)

    @objc func toggleFloatingButton() {
        if let panel = floatingPanel {
            panel.orderOut(nil)
            floatingPanel = nil
        } else {
            showFloatingButton()
        }
        floatingMenuItem?.state = floatingPanel == nil ? .off : .on
    }

    private func showFloatingButton() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false  // we handle drag vs click ourselves
        panel.hidesOnDeactivate = false            // stay visible when app loses focus
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Custom view distinguishes a click (→ capture) from a drag (→ move only).
        let container = FloatingButtonView()
        container.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        container.onClick = { [weak self] in self?.startCaptureHidingWindow(mode: .freeform) }
        let host = NSHostingView(rootView: FloatingCaptureButton())
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 84, y: vf.minY + 84))
        }
        panel.orderFront(nil)
        floatingPanel = panel
    }

    // MARK: - Main Menu

    /// Build the application menu bar in code (there's no MainMenu.xib).
    /// Without this, standard shortcuts like ⌘Q / ⌘H and text-field
    /// copy-paste have nothing to bind to and silently do nothing.
    private func setupMainMenu() {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        // App menu (its title is replaced by the app name automatically)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "关于\(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏\(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — gives text fields (e.g. the new-folder name box) the
        // standard cut/copy/paste/select-all via the responder chain.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切",  action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝",  action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴",  action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选",  action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Capture menu — reliable access to capture + the floating button toggle
        // (the menu-bar status icon doesn't render on macOS 26).
        let captureMenuItem = NSMenuItem()
        mainMenu.addItem(captureMenuItem)
        let captureMenu = NSMenu(title: "截图")
        captureMenuItem.submenu = captureMenu
        let cap = captureMenu.addItem(withTitle: "截图", action: #selector(menuCapture), keyEquivalent: "")
        cap.target = self
        let capNoHide = captureMenu.addItem(withTitle: "截图（不隐藏本应用）", action: #selector(menuCaptureNoHide), keyEquivalent: "")
        capNoHide.target = self
        captureMenu.addItem(.separator())
        let fb = captureMenu.addItem(withTitle: "悬浮截图按钮",
                                     action: #selector(toggleFloatingButton), keyEquivalent: "")
        fb.target = self
        floatingMenuItem = fb

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuCapture() { startCaptureHidingWindow(mode: .freeform) }
    @objc private func menuCaptureNoHide() { startCaptureNoHide(mode: .freeform) }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图工具") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "📷"
            }
            btn.toolTip = "左键单击：截图　右键单击：菜单"
            // Left-click = capture immediately, right-click = show menu
            btn.target = self
            btn.action = #selector(statusBarClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Built once, attached only on right-click (see statusBarClicked)
        let captureItem = NSMenuItem(title: "截取屏幕区域  (⌃⌘5)", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        statusMenu.addItem(captureItem)

        statusMenu.addItem(.separator())

        let galleryItem = NSMenuItem(title: "打开截图库…", action: #selector(openGallery), keyEquivalent: "g")
        galleryItem.keyEquivalentModifierMask = [.command, .shift]
        galleryItem.target = self
        statusMenu.addItem(galleryItem)

        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func statusBarClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            statusItem.menu = statusMenu            // temporarily attach
            statusItem.button?.performClick(nil)    // pop it up
            statusItem.menu = nil                   // detach so next left-click captures
        } else {
            startCaptureHidingWindow(mode: .freeform)
        }
    }

    @objc private func startCapture() {
        startCaptureHidingWindow(mode: .freeform)
    }

    @objc func openGallery() {
        if galleryWindow == nil {
            let view = GalleryView(onCapture: { [weak self] mode in self?.startCaptureHidingWindow(mode: mode) },
                                   onCaptureNoHide: { [weak self] mode in self?.startCaptureNoHide(mode: mode) },
                                   onRecrop: { [weak self] ss in self?.recrop(ss) })
                .environmentObject(DataStore.shared)
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "截图库"
            win.setContentSize(NSSize(width: 980, height: 660))
            win.center()
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.isReleasedWhenClosed = false
            galleryWindow = win
        }
        galleryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Floating capture button

/// Pure visual for the floating button (no Button — clicks are handled by the
/// hosting `FloatingButtonView` so we can tell a click apart from a drag).
struct FloatingCaptureButton: View {
    var body: some View {
        Image("CaptureIcon")
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(Circle())
    }
}

/// Hosts the floating button visual and routes mouse events: a click fires
/// `onClick`, a drag just moves the window (so dragging never triggers capture).
final class FloatingButtonView: NSView {
    var onClick: (() -> Void)?
    private var grabInWindow: NSPoint = .zero   // click point relative to the window
    private var downScreen: NSPoint = .zero      // mouse-down location on screen
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Claim every hit so the hosted SwiftUI visual doesn't swallow the events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        grabInWindow = event.locationInWindow
        downScreen = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - downScreen.x, now.y - downScreen.y) > 3 { didDrag = true }
        if didDrag {
            window.setFrameOrigin(NSPoint(x: now.x - grabInWindow.x, y: now.y - grabInWindow.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }   // a click (not a drag) triggers capture
        didDrag = false
    }
}

import Cocoa
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    let coordinator = CaptureCoordinator()
    private var galleryWindow: NSWindow?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // Restore the gallery window when capture finishes/cancels
        coordinator.onCaptureFinished = { [weak self] in
            self?.galleryWindow?.makeKeyAndOrderFront(nil)
        }
        // Global hotkey ⌃⌘5 — works from any app (browser etc.), no extra permission.
        // kVK_ANSI_5 = 0x17; Carbon mods cmdKey | controlKey.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_5),
                              modifiers: UInt32(cmdKey | controlKey))
        hotKey?.onFire = { [weak self] in
            DispatchQueue.main.async { self?.startCaptureHidingWindow() }
        }
        // Show the main window right away so the app is easy to find
        openGallery()
    }

    // Reopen the gallery window when the Dock icon is clicked
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openGallery() }
        return true
    }

    // MARK: - Capture (hide window first so it isn't in the shot)

    @objc func startCaptureHidingWindow() {
        galleryWindow?.orderOut(nil)
        // Let the window disappear before grabbing the screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.coordinator.startCapture()
        }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图工具")
            img?.isTemplate = true
            btn.image = img
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
            startCaptureHidingWindow()
        }
    }

    @objc private func startCapture() {
        startCaptureHidingWindow()
    }

    @objc func openGallery() {
        if galleryWindow == nil {
            let view = GalleryView(onCapture: { [weak self] in self?.startCaptureHidingWindow() })
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

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    let coordinator = CaptureCoordinator()
    private var galleryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // Trigger macOS Screen Recording permission prompt on first launch
        _ = CGDisplayCreateImage(CGMainDisplayID())
        // Restore the gallery window when capture finishes/cancels
        coordinator.onCaptureFinished = { [weak self] in
            self?.galleryWindow?.makeKeyAndOrderFront(nil)
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
        }

        let menu = NSMenu()

        let captureItem = NSMenuItem(title: "截取屏幕区域", action: #selector(startCapture), keyEquivalent: "5")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let galleryItem = NSMenuItem(title: "打开截图库…", action: #selector(openGallery), keyEquivalent: "g")
        galleryItem.keyEquivalentModifierMask = [.command, .shift]
        galleryItem.target = self
        menu.addItem(galleryItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
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

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
        coordinator.startCapture()
    }

    @objc func openGallery() {
        if galleryWindow == nil {
            let view = GalleryView().environmentObject(DataStore.shared)
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

import AppKit

NSApplication.shared.setActivationPolicy(.accessory) // hide from Dock
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

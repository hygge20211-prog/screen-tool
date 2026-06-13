import AppKit

NSApplication.shared.setActivationPolicy(.regular) // show in Dock + menu bar
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

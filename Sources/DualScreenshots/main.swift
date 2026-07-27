import AppKit

// LSUIElement is also set in Info.plist; setting the policy here means the app behaves
// as an accessory (no Dock icon, no menu bar app menu) even when run from the CLI.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

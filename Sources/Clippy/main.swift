import AppKit

// Menu-bar-only app: no Dock icon, no main window. The .accessory policy is
// what LSUIElement would do in a bundled build, set here so the bare
// executable behaves the same during development.
let app = NSApplication.shared
// AppDelegate is @MainActor; top-level code in main.swift already runs on the main thread.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

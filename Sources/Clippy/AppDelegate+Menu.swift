import AppKit
import Darwin
import Sparkle
import SwiftUI

extension AppDelegate {
    // MARK: - Main menu (restores Cmd+C/V/X/A/Z in all app windows)

    /// Assigns a minimal NSApp.mainMenu so standard editing key-equivalents can
    /// find a target through the responder chain. Without this the accessory-app
    /// activation mode leaves mainMenu nil and the system cannot dispatch Cmd+C
    /// etc. to the focused text field or text view.
    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App submenu (macOS requires the first item to be the app menu).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Clippy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit submenu: Undo, Redo, then the standard clipboard verbs. All
        // editing items leave target == nil so events flow up the responder chain
        // to the first object that can handle them (NSTextView, NSTextField, etc.).
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(selectAllItem)

        // Find submenu: routes Cmd+F/Cmd+G to the focused NSTextView's find
        // bar (usesFindBar). Key equivalents only dispatch through the main
        // menu, so without these items the editor's find bar is unreachable.
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        let findActions: [(String, String, NSTextFinder.Action)] = [
            ("Find...", "f", .showFindInterface),
            ("Find Next", "g", .nextMatch),
            ("Find Previous", "G", .previousMatch),
            ("Find and Replace...", "F", .showReplaceInterface)
        ]
        for (title, key, action) in findActions {
            let item = NSMenuItem(
                title: title,
                action: #selector(NSResponder.performTextFinderAction(_:)),
                keyEquivalent: key.lowercased()
            )
            if key.first?.isUppercase == true {
                item.keyEquivalentModifierMask = [.command, .shift]
            }
            item.tag = action.rawValue
            findMenu.addItem(item)
        }
        findItem.submenu = findMenu
        editMenu.addItem(findItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Help menu: reopens the first-run walkthrough.
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let welcomeItem = NSMenuItem(title: "Show Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        helpMenu.addItem(welcomeItem)
        let cliItem = NSMenuItem(title: "Command Line Tool\u{2026}", action: #selector(openAutomationSettings), keyEquivalent: "")
        cliItem.target = self
        helpMenu.addItem(cliItem)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    /// Help > Show Welcome: reopens the onboarding walkthrough.
    @objc func showWelcome() {
        panelController.hide()
        onboardingController.show()
    }

    // MARK: - Scripts

    @objc func runScriptFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let script = ScriptStore.shared.script(id: id) else { return }
        let input = script.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        Task { @MainActor in
            let result = await ScriptRunner.run(script, input: input, sandbox: ScriptSandboxPolicy().sandbox(for: script.id))
            self.presentScriptResult(script, result)
        }
    }

    @MainActor
    func presentScriptResult(_ script: Script, _ result: ScriptResult) {
        // Auto-offering output as a clip: just place it on the pasteboard, which
        // the monitor captures into history like any other copy.
        if script.outputToClipboard, result.succeeded, !result.stdout.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.stdout, forType: .string)
        }
        let alert = NSAlert()
        alert.messageText = result.timedOut
            ? "\(script.name) timed out"
            : "\(script.name) finished (exit \(result.exitCode))"
        let body = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n--- stderr ---\n")
        alert.informativeText = String(body.prefix(1500)).isEmpty ? "No output." : String(body.prefix(1500))
        alert.alertStyle = result.succeeded ? .informational : .warning
        // NSApp.activate(ignoringOtherApps:) deprecated in macOS 14; use activate().
        NSApp.activate()
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === scriptsMenu else { return }
        menu.removeAllItems()
        let scripts = ScriptStore.shared.scripts
        if scripts.isEmpty {
            let empty = NSMenuItem(title: "No scripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            let manage = NSMenuItem(title: "Manage in Settings...", action: #selector(openSettings), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
            return
        }
        for script in scripts {
            let item = NSMenuItem(title: script.name.isEmpty ? "Untitled" : script.name,
                                  action: #selector(runScriptFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script.id
            menu.addItem(item)
        }
    }
}


extension Notification.Name {
    /// Posted when the panel is asked to open while already visible; the panel
    /// UI should focus its search field instead of rebuilding (PNL-04).
    static let clippyFocusPanelSearch = Notification.Name("ClippyFocusPanelSearch")
}


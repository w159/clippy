import SwiftUI

/// MCP token rotation, sandbox status and capture-side guards (paste profiles, type blocklist).
struct SecurityAccessSection: View {
    @Environment(\.clippyTokens) private var tokens
    @Binding var notice: PaneNotice?
    @State private var confirmRotate = false
    @State private var tokenPresent: Bool?
    @State private var sandbox = SandboxRunner.preflight()
    @State private var blocklist = CapturePreferences.typeBlocklist
    @State private var newType = ""
    @State private var overrides = PasteProfiles.overrides

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    private var scriptSandboxCount: (enabled: Int, total: Int) {
        let flags = SandboxScriptFlags()
        let scripts = ScriptStore.shared.scripts
        return (scripts.filter { flags.isSandboxed($0.id) }.count, scripts.count)
    }

    var body: some View {
        Group {
            PaneSection("MCP token", footer: "The token authenticates local MCP clients. Rotating it disconnects every client until you reinstall or update its configuration.") {
                SettingsRow(title: "Bearer token", detail: Text(tokenPresent == nil ? "Checking\u{2026}" : (tokenPresent == true ? "Stored in the Keychain. Never shown here." : "Not created yet."))) {
                    Button("Rotate\u{2026}") { confirmRotate = true }
                }
            }
            PaneSection("Script sandbox", footer: "AI-generated code is always sandboxed. Your own scripts are sandboxed only when you turn it on per script.") {
                SettingsRow(title: "Sandbox availability", detail: Text(sandboxDetail)) {
                    Image(systemName: sandbox.isAvailable ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(sandbox.isAvailable ? tokens.success : tokens.warning)
                        .accessibilityLabel(sandbox.isAvailable ? "Available" : "Unavailable")
                }
                Divider()
                SettingsRow(title: "Sandboxed scripts", detail: Text("\(scriptSandboxCount.enabled) of \(scriptSandboxCount.total) scripts")) {
                    Button("Recheck") { SandboxRunner.resetCache(); sandbox = SandboxRunner.preflight() }
                }
            }
            pasteProfiles
            blocklistSection
        }
        .task { tokenPresent = await Task.detached { (try? McpTokenProvider.shared.token()) != nil }.value }
        .confirmationDialog("Rotate the MCP token?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate Token", role: .destructive) { rotate() }
        } message: {
            Text("Connected MCP clients stop working until they use the new token.")
        }
    }

    private var sandboxDetail: String {
        if case .unavailable(let reason) = sandbox { return reason }
        return "sandbox-exec is available."
    }

    private var pasteProfiles: some View {
        PaneSection("Paste profiles", footer: "Terminals and code editors paste plain text by default. Your overrides win over the built-in list.") {
            SettingsRow(title: "Built-in plain-text apps", detail: Text("\(PasteProfiles.builtInPlainTextBundleIDs.count) terminals and editors")) { EmptyView() }
            ForEach(overrides.sorted { $0.key < $1.key }, id: \.key) { key, mode in
                Divider()
                SettingsRow(title: LocalizedStringKey(key), detail: Text(mode == .plainText ? "Always plain text" : "Always rich text")) {
                    Button("Remove") { PasteProfiles.setMode(.automatic, forBundleID: key); overrides = PasteProfiles.overrides }
                }
            }
            if overrides.isEmpty {
                Divider()
                SettingsRow(title: "No custom overrides", detail: Text("Add per-app overrides from the panel's paste menu.")) { EmptyView() }
            }
        }
    }

    private var blocklistSection: some View {
        PaneSection("Type blocklist", footer: "Copies containing these pasteboard types are never captured. Enter a type identifier such as org.nspasteboard.ConcealedType.") {
            ForEach(blocklist, id: \.self) { type in
                SettingsRow(title: LocalizedStringKey(type)) {
                    Button("Remove") { blocklist.removeAll { $0 == type }; CapturePreferences.typeBlocklist = blocklist }
                }
                Divider()
            }
            SettingsRow(title: "Add type") {
                HStack {
                    TextField("com.example.type", text: $newType).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 200).onSubmit(addType)
                    Button("Add", action: addType).disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addType() {
        let clean = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(" "), !blocklist.contains(clean) else { notice = .info("Enter a new type identifier without spaces."); return }
        blocklist.append(clean)
        CapturePreferences.typeBlocklist = blocklist
        newType = ""
    }

    private func rotate() {
        Task {
            let rotated = await Task.detached { (try? McpTokenProvider.shared.rotate()) != nil }.value
            tokenPresent = rotated ? true : tokenPresent
            if rotated { AuditLog.shared.record(actor: "settings", action: "rotate-mcp-token", detail: "token rotated", clipIDs: []) }
            notice = rotated ? .success("MCP token rotated.") : .failure("Could not rotate the token. Check Keychain access.")
        }
    }
}

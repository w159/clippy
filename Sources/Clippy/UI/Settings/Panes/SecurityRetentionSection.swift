import SwiftUI

/// Retention rules editor with a counts-only preview and a confirmed run-now.
struct SecurityRetentionSection: View {
    @Binding var notice: PaneNotice?
    @State private var model = RetentionRuleEditorModel(rules: RetentionPreferences().rules)
    @State private var forgetDays = 30
    @State private var sensitiveHours = 24
    @State private var newKind = ClipContentKind.image
    @State private var newKindDays = 7
    @State private var newApp = ""
    @State private var newAppDays = 7
    @State private var previewText: String?
    @State private var working = false
    @State private var confirmRun = false

    private let preferences = RetentionPreferences()

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    private var forced: Bool { AppSettings.isForced(RetentionPreferences.rulesKey) }

    var body: some View {
        PaneSection("Retention", footer: "Clips in categories are kept unless you include them. Pinned clips are never removed. Deletions are recorded in the audit log without content.") {
            SettingsRow(title: "Apply retention rules", detail: forced ? Text("Set by your organization.") : Text("Runs hourly while Clippy is open."), enabled: !forced) {
                Toggle("Apply retention rules", isOn: Binding(get: { model.rules.isEnabled }, set: { value in edit { $0.setEnabled(value) } })).labelsHidden()
            }
            Group {
                Divider()
                optionalRow(title: "Forget after", unit: "day", value: $forgetDays, isOn: model.rules.forgetAfterDays != nil,
                            range: RetentionRuleEditorModel.dayRange) { model, enable in try model.setForgetAfter(days: enable ? forgetDays : nil) }
                Divider()
                optionalRow(title: "Auto-expire sensitive clips", unit: "hour", value: $sensitiveHours, isOn: model.rules.sensitiveTTLHours != nil,
                            range: RetentionRuleEditorModel.hourRange) { model, enable in try model.setSensitiveTTL(hours: enable ? sensitiveHours : nil) }
                Divider()
                SettingsRow(title: "Include categorized clips") {
                    Toggle("Include categorized clips", isOn: Binding(get: { model.rules.includeCategorized }, set: { value in edit { $0.setIncludeCategorized(value) } })).labelsHidden()
                }
                Divider()
                kindRules
                appRules
                actions
            }
            .disabled(forced)
        }
        .confirmationDialog("Delete expired clips now?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Delete Now", role: .destructive) { run() }
        } message: {
            Text("Clips matching the current rules are permanently deleted. Preview first to see how many.")
        }
    }

    private func optionalRow(title: LocalizedStringKey, unit: String, value: Binding<Int>, isOn: Bool, range: ClosedRange<Int>,
                             apply: @escaping (inout RetentionRuleEditorModel, Bool) throws -> Void) -> some View {
        SettingsRow(title: title, detail: Text(isOn ? "\(value.wrappedValue) \(unit)\(value.wrappedValue == 1 ? "" : "s")" : "Off")) {
            HStack {
                Stepper(title, value: value, in: range).labelsHidden().disabled(!isOn)
                    .onChange(of: value.wrappedValue) { _, _ in edit { try? apply(&$0, true) } }
                Toggle(title, isOn: Binding(get: { isOn }, set: { enable in edit { try? apply(&$0, enable) } })).labelsHidden()
            }
        }
    }

    private var kindRules: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.kindRows, id: \.key) { row in
                SettingsRow(title: LocalizedStringKey("\(row.key.capitalized) clips"), detail: Text("Forget after \(row.days) days")) {
                    Button("Remove") { edit { $0.removeKindRule(row.key) } }.accessibilityLabel("Remove \(row.key) rule")
                }
                Divider()
            }
            SettingsRow(title: "Add type rule") {
                HStack {
                    Picker("Type", selection: $newKind) {
                        ForEach([ClipContentKind.text, .image, .file], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.labelsHidden().frame(width: 90)
                    Stepper("\(newKindDays) d", value: $newKindDays, in: RetentionRuleEditorModel.dayRange)
                    Button("Add") { editThrowing({ try $0.addKindRule(kind: newKind, days: newKindDays) }) }
                }
            }
            Divider()
        }
    }

    private var appRules: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.appRows, id: \.key) { row in
                SettingsRow(title: LocalizedStringKey(row.key), detail: Text("Forget after \(row.days) days")) {
                    Button("Remove") { edit { $0.removeAppRule(row.key) } }.accessibilityLabel("Remove rule for \(row.key)")
                }
                Divider()
            }
            SettingsRow(title: "Add app rule") {
                HStack {
                    TextField("com.example.app", text: $newApp).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 170)
                    Stepper("\(newAppDays) d", value: $newAppDays, in: RetentionRuleEditorModel.dayRange)
                    Button("Add") {
                        editThrowing({ try $0.addAppRule(bundleID: newApp, days: newAppDays) }, onSuccess: { newApp = "" })
                    }
                }
            }
            Divider()
        }
    }

    private var actions: some View {
        SettingsRow(title: "Preview and run", detail: Text(previewText ?? "Preview shows how many clips would be deleted, without content.")) {
            HStack {
                Button("Preview") { preview() }.disabled(working || !model.hasAnyRule)
                Button("Run Now\u{2026}") { confirmRun = true }.disabled(working || !model.hasAnyRule)
            }
        }
    }

    private func edit(_ change: (inout RetentionRuleEditorModel) -> Void) {
        editThrowing({ change(&$0) })
    }

    private func editThrowing(_ change: (inout RetentionRuleEditorModel) throws -> Void, onSuccess: () -> Void = {}) {
        var next = model
        do {
            try change(&next)
            model = next
            preferences.rules = next.rules
            previewText = nil
            onSuccess()
        } catch let error as RetentionRuleEditorModel.EditError {
            notice = .failure(RetentionRuleEditorModel.message(for: error))
        } catch {
            notice = .failure("Could not update the rule.")
        }
    }

    private func preview() {
        working = true
        let rules = model.rules
        Task {
            let result = await Task.detached { () -> String in
                do {
                    let candidates = try RetentionService(database: ClipDatabase.shared).preview(rules: rules)
                    return RetentionPreviewSummary(candidates: candidates).description
                } catch { return "Preview failed." }
            }.value
            previewText = result
            working = false
        }
    }

    private func run() {
        working = true
        let rules = model.rules
        Task {
            let outcome = await Task.detached { () -> PaneNotice in
                do {
                    let result = try RetentionService(database: ClipDatabase.shared).apply(rules: rules, actor: "settings")
                    return result.failed.isEmpty ? .success("Deleted \(result.deleted.count) clips.")
                        : .failure("Deleted \(result.deleted.count) clips; \(result.failed.count) could not be deleted.")
                } catch { return .failure("Retention run failed.") }
            }.value
            notice = outcome
            previewText = nil
            working = false
        }
    }
}

import SwiftUI

struct AIProviderHeadersEditor: View {
    @ObservedObject var model: AIProviderManagerModel
    @Binding var draft: ProviderInstance
    let descriptor: ProviderDescriptor
    @State private var secretDrafts: [UUID: String] = [:]

    private var issues: [UUID: String] {
        AIProviderSettingsLogic.headerIssues(draft.headers) { id in
            model.store.secretHeaderValue(instance: draft.id, header: id) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Request headers").font(.headline)
            ForEach($draft.headers) { $header in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField("Name", text: $header.name)
                        if header.isSecret {
                            SecureField("Stored; type to replace", text: Binding(
                                get: { secretDrafts[header.id] ?? "" },
                                set: { secretDrafts[header.id] = $0 }
                            ))
                            Button("Save") {
                                header.value = secretDrafts[header.id] ?? ""
                                secretDrafts[header.id] = nil
                            }.disabled((secretDrafts[header.id] ?? "").isEmpty)
                        } else {
                            TextField("Value", text: $header.value)
                        }
                        Toggle("Secret", isOn: Binding(get: { header.isSecret }, set: { secret in
                            if !secret, header.value.isEmpty {
                                header.value = model.store.secretHeaderValue(instance: draft.id, header: header.id) ?? ""
                            }
                            header.isSecret = secret
                        }))
                        .toggleStyle(.checkbox).fixedSize()
                        Button {
                            draft.headers.removeAll { $0.id == header.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).help("Remove header").accessibilityLabel("Remove header")
                    }
                    if let issue = issues[header.id] { SettingsStatusLine(kind: .failure, text: issue) }
                }
            }
            Button("Add header") { draft.headers.append(HeaderEntry()) }
            ForEach(AIProviderSettingsLogic.unusedSuggestions(descriptor, headers: draft.headers), id: \.name) { hint in
                Button { draft.headers = AIProviderSettingsLogic.adding(hint, to: draft.headers) } label: {
                    Label(hint.name, systemImage: "plus")
                }
                .controlSize(.small).help("\(hint.purpose) \(hint.valueHint)")
            }
            SettingsNote("Secret values are stored in Keychain, not in preferences.")
        }
    }
}

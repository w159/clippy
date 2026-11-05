import SwiftUI

/// Editable KEY/value rows for script process environment overrides. Values are
/// local process settings; they are neither copied to the clipboard nor logged.
struct ScriptEnvironmentEditor: View {
    @Binding var environment: [String: String]
    @State private var rows: [Row]

    private struct Row: Identifiable, Equatable {
        var id = UUID()
        var key: String
        var value: String
    }

    init(environment: Binding<[String: String]>) {
        _environment = environment
        _rows = State(initialValue: environment.wrappedValue.keys.sorted().map {
            Row(key: $0, value: environment.wrappedValue[$0] ?? "")
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment").font(.headline)
                Spacer()
                Button { rows.append(Row(key: "", value: "")) } label: {
                    Label("Add row", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass).tint(nil)
                .accessibilityLabel("Add environment variable")
                .help("Add environment variable")
            }
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .accessibilityLabel("Environment variable name")
                    TextField("Value", text: $row.value)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .accessibilityLabel("Environment variable value")
                    Button(role: .destructive) { remove(row.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove environment variable")
                    .help("Remove row")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: row.key) { _, _ in sync() }
                .onChange(of: row.value) { _, _ in sync() }
            }
            if rows.isEmpty {
                Text("No environment overrides").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: rows) { _, _ in sync() }
    }

    private func remove(_ id: UUID) { rows.removeAll { $0.id == id }; sync() }

    private func sync() {
        var updated: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("=") else { continue }
            updated[key] = row.value
        }
        environment = updated
    }
}

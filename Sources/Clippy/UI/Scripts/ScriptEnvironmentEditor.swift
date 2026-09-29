import SwiftUI

/// Editable KEY/value rows for script process environment overrides. Values are
/// local process settings; they are neither copied to the clipboard nor logged.
struct ScriptEnvironmentEditor: View {
    @Environment(\.clippyTokens) private var tokens
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
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            HStack {
                Text("Environment").font(.caption).foregroundStyle(tokens.textSecondary)
                Spacer()
                Button { rows.append(Row(key: "", value: "")) } label: {
                    Label("Add row", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Add environment variable")
                .help("Add environment variable")
            }
            ForEach($rows) { $row in
                HStack(spacing: tokens.metrics.space.one) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityLabel("Environment variable name")
                    TextField("Value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityLabel("Environment variable value")
                    Button(role: .destructive) { remove(row.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove environment variable")
                    .help("Remove row")
                }
                .onChange(of: row.key) { _, _ in sync() }
                .onChange(of: row.value) { _, _ in sync() }
            }
            if rows.isEmpty {
                Text("No environment overrides").font(.caption).foregroundStyle(tokens.textTertiary)
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

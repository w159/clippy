import SwiftUI

/// Expanded item detail: loading, error, or sectioned field rows.
struct OnePasswordItemDetailPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let loading: Bool
    let error: String?
    let detail: OPItemDetail?
    let service: OnePasswordService
    let onAutoClear: () -> Void
    /// Reloads the item's fields after a failure.
    var onRetry: (() -> Void)?

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading fields...").font(.caption).foregroundStyle(tokens.textSecondary)
                }
                .padding(.horizontal, 8)
            } else if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tokens.danger)
                        .symbolEffect(.bounce, value: reduceMotion ? "" : error)
                    Text(error).font(.caption).foregroundStyle(tokens.textSecondary)
                    if let onRetry {
                        Button("Retry", action: onRetry).controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
            } else if let detail {
                fields(detail)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func fields(_ detail: OPItemDetail) -> some View {
        ForEach(Array(detail.sectionedFields.enumerated()), id: \.offset) { _, bucket in
            if let section = bucket.section {
                Text(section.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tokens.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            ForEach(bucket.fields) { field in
                OnePasswordFieldRow(field: field, itemID: detail.id, service: service,
                                    autoClear: settings.onePasswordAutoClearClipboard,
                                    autoClearSecs: settings.onePasswordAutoClearDelaySecs,
                                    onAutoClear: onAutoClear)
            }
        }
    }
}

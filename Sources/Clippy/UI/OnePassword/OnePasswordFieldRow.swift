import AppKit
import SwiftUI

// MARK: - FieldRow

/// One field in the expanded item detail. Handles concealed reveal toggle,
/// TOTP fetch-on-demand, copy-with-concealed-marker, and auto-clear scheduling.
struct OnePasswordFieldRow: View {
    let field: OPField
    let itemID: String
    let service: OnePasswordService
    let autoClear: Bool
    let autoClearSecs: Int
    let onAutoClear: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var designTokens
    private var tokens: ThemeTokens { settings.theme }

    @State private var copying = false
    @State private var copyError: String?
    @State private var otpCode: String?
    @State private var otpWindow: Int?
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    @State private var revealed = false
    @State private var revealing = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tokens.textSecondary)
                fieldContainer
            }
            copyButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 5))
        .onDisappear { revealed = false }
    }

    /// Value area. Masked (OTP / concealed) values sit in an inset field with the
    /// reveal eye on its trailing edge; copy stays a separate control after it.
    @ViewBuilder
    private var fieldContainer: some View {
        if field.type.isOTP || (field.type.isConcealed && field.value != nil) {
            HStack(spacing: 6) {
                fieldValueView.frame(maxWidth: .infinity, alignment: .leading)
                revealButton
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(designTokens.surfaceInset, in: RoundedRectangle(cornerRadius: designTokens.metrics.radius.sm, style: .continuous))
        } else {
            fieldValueView
        }
        if let err = copyError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(tokens.danger)
        }
    }

    private var maskedGlyphs: some View {
        Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(tokens.textSecondary)
            .accessibilityLabel(field.type.isOTP ? "Hidden one-time code" : "Hidden secret")
    }

    private var revealButton: some View {
        Button {
            if revealed {
                revealed = false
            } else if field.type.isOTP && otpCode == nil {
                fetchOTPForReveal()
            } else {
                revealed = true
            }
        } label: {
            if revealing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.textSecondary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .disabled(revealing)
        .accessibilityLabel(revealed ? "Hide \(field.label)" : "Reveal \(field.label)")
        .help(revealed ? "Hide value" : "Reveal value")
    }

    private func fetchOTPForReveal() {
        revealing = true
        copyError = nil
        Task {
            do {
                let code = try await service.fetchTOTP(itemID: itemID)
                await MainActor.run {
                    otpCode = code
                    otpWindow = TOTPCountdown.windowIndex(at: Date())
                    revealed = true
                    revealing = false
                }
            } catch {
                await MainActor.run {
                    copyError = error.localizedDescription
                    revealing = false
                }
            }
        }
    }

    @ViewBuilder
    private var fieldValueView: some View {
        if field.type.isOTP {
            if let liveCode = otpCode {
                // The timeline drives expiry: `body` itself does not re-run each second.
                TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                    if TOTPCountdown.windowIndex(at: timeline.date) == otpWindow {
                        if revealed {
                            OTPCodeDisplay(code: liveCode, date: timeline.date)
                        } else {
                            maskedGlyphs
                        }
                    } else {
                        Text("Code expired. Copy for a new one.")
                            .font(.caption)
                            .foregroundStyle(tokens.textSecondary)
                            .onAppear { otpCode = nil; otpWindow = nil; revealed = false }
                    }
                }
            } else {
                maskedGlyphs
            }
        } else if field.type.isConcealed {
            if let secret = field.value {
                if revealed {
                    Text(secret)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .privacySensitive()
                } else {
                    maskedGlyphs
                }
            } else {
                Label("Sensitive field", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }
        } else if let fieldValue = field.value {
            Text(fieldValue)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
        } else {
            Text("(empty)")
                .font(.caption)
                .foregroundStyle(tokens.textSecondary)
                .italic()
        }
    }

    private var copyButton: some View {
        Button {
            performCopy()
        } label: {
            if copying {
                ProgressView().controlSize(.mini)
            } else {
                Text(copied ? "Copied" : "Copy")
            }
        }
        .controlSize(.small)
        .frame(minWidth: 52)
        .accessibilityLabel("Copy \(field.label)")
        .disabled(copying || (field.value == nil && !field.type.isOTP))
        .help(field.value == nil && field.type.isConcealed ? "This field has no value stored in 1Password." : "")
    }

    private func flashCopied() {
        copied = true
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func performCopy() {
        guard !copying else { return }
        copying = true
        copyError = nil

        if field.type.isOTP {
            // TOTP: fetch on demand, never cache.
            Task {
                do {
                    let code = try await service.fetchTOTP(itemID: itemID)
                    await MainActor.run {
                        writeToPasteboard(code, concealed: true)
                        otpCode = code
                        otpWindow = TOTPCountdown.windowIndex(at: Date())
                        copying = false
                        flashCopied()
                    }
                } catch {
                    await MainActor.run {
                        copyError = error.localizedDescription
                        copying = false
                    }
                }
            }
        } else if field.type.isConcealed {
            // For concealed fields the value was fetched with the item detail
            // (op already prompted for auth). Copy directly.
            guard let fieldValue = field.value else { copying = false; return }
            writeToPasteboard(fieldValue, concealed: true)
            copying = false
            flashCopied()
        } else {
            guard let fieldValue = field.value else { copying = false; return }
            writeToPasteboard(fieldValue, concealed: false)
            copying = false
            flashCopied()
        }
    }

    /// Write to the pasteboard. Concealed writes include the ConcealedType
    /// marker so the clipboard monitor never records the value in history.
    /// If auto-clear is enabled, a task checks the changeCount after the delay
    /// and clears the pasteboard only if it still holds this exact write.
    private func writeToPasteboard(_ value: String, concealed: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        if concealed {
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }

        if concealed && autoClear {
            let changeCount = pb.changeCount
            let delay = autoClearSecs
            Task {
                try? await Task.sleep(for: .seconds(UInt64(max(0, delay))))
                await MainActor.run {
                    // Only clear if the pasteboard hasn't been written to since.
                    if NSPasteboard.general.changeCount == changeCount {
                        NSPasteboard.general.clearContents()
                        onAutoClear()
                    }
                }
            }
        }
    }
}


/// TOTP code with a live remaining-period ring.
private struct OTPCodeDisplay: View {
    @Environment(\.clippyTokens) private var designTokens
    let code: String
    let date: Date

    var body: some View {
        HStack(spacing: designTokens.metrics.space.two) {
            Text(TOTPCountdown.grouped(code))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(designTokens.textPrimary)
                .accessibilityLabel("One-time code")
            TOTPCountdownRing(date: date)
        }
    }
}

import SwiftUI

/// OCR recognition settings: level, languages, PDF page limit, document recognition.
struct OCRSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var notice: PaneNotice?
    @State private var level = OCRPreferences.level
    @State private var languages = OCRPreferences.languages
    @State private var pdfPages = OCRPreferences.pdfMaxPages
    @State private var documentRecognition = OCRPreferences.useDocumentRecognition
    @State private var supported: [OCRLanguage] = []
    @State private var indexEnabled = OCRIndexPreferences.isEnabled

    /// Creates the pane.
    init() {}

    var body: some View {
        PaneScroll(title: "OCR", notice: $notice) {
            PaneSection("Recognition", footer: "Accurate is slower but reads small or stylized text better. Everything runs on this Mac.") {
                SettingsRow(title: "Quality") {
                    Picker("Quality", selection: $level) {
                        Text("Fast").tag(OCRPreferences.Level.fast)
                        Text("Accurate").tag(OCRPreferences.Level.accurate)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    .onChange(of: level) { _, value in OCRPreferences.level = value }
                }
                Divider()
                SettingsRow(title: "Use document recognition", detail: Text("Reads paragraphs and tables when macOS provides it.")) {
                    Toggle("Use document recognition", isOn: $documentRecognition).labelsHidden()
                        .onChange(of: documentRecognition) { _, value in OCRPreferences.useDocumentRecognition = value }
                }
                Divider()
                SettingsRow(title: "PDF pages read", detail: Text("First \(pdfPages) page\(pdfPages == 1 ? "" : "s") of each PDF.")) {
                    Stepper("PDF pages read", value: $pdfPages, in: 1...OCRPreferences.maxPDFMaxPages).labelsHidden()
                        .onChange(of: pdfPages) { _, value in OCRPreferences.pdfMaxPages = value }
                }
            }
            PaneSection("Languages", footer: OCRLanguageList.summary(languages)) {
                SettingsRow(title: "Detect automatically") {
                    Toggle("Detect automatically", isOn: Binding(get: { languages.isEmpty }, set: { auto in setAutomatic(auto) })).labelsHidden()
                }
                if !languages.isEmpty || !supported.isEmpty {
                    languageList
                }
            }
            PaneSection("Warm-up and index", footer: Self.warmupNote) {
                SettingsRow(title: "Search text inside images", detail: Text(indexEnabled ? Self.indexOnNote : Self.indexOffNote)) {
                    Image(systemName: indexEnabled ? "checkmark.circle.fill" : "circle").foregroundStyle(indexEnabled ? tokens.success : tokens.textSecondary)
                        .accessibilityLabel(indexEnabled ? "Indexing on" : "Indexing off")
                }
            }
        }
        .task { supported = OCRLanguageList.supported() }
        .onAppear { indexEnabled = OCRIndexPreferences.isEnabled }
    }

    private static let warmupNote = "Vision loads its models on first use, so the first recognition after launch can be slow. "
        + "Clippy warms them up when the panel opens, and background indexing waits until they are ready."
    private static let indexOnNote = "Indexing is on. Change it in Data \u{203A} OCR text index."
    private static let indexOffNote = "Off. Turn it on in Data \u{203A} OCR text index."

    private var languageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(supported) { language in
                Divider()
                Toggle(isOn: Binding(get: { languages.contains(language.code) }, set: { _ in toggle(language.code) })) {
                    HStack {
                        Text(language.name).foregroundStyle(tokens.textPrimary)
                        Text(language.code).font(.caption).foregroundStyle(tokens.textSecondary)
                    }
                }
                .disabled(languages.isEmpty)
                .frame(minHeight: 32)
            }
        }
    }

    private func setAutomatic(_ auto: Bool) {
        languages = auto ? [] : Array(supported.prefix(1).map(\.code))
        OCRPreferences.languages = languages
    }

    private func toggle(_ code: String) {
        let next = OCRLanguageList.toggled(code, in: languages)
        guard !next.isEmpty else { notice = .info("Keep at least one language, or switch on automatic detection."); return }
        languages = next
        OCRPreferences.languages = next
    }
}

#Preview("OCR settings") {
    OCRSettingsPane().frame(width: 560, height: 620)
}

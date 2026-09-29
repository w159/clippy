import AppKit
import SwiftUI

// The Capture settings pane (monitoring, images, files, sounds, ignored apps).
// Launch capture, blocklist, sensitive auto-clear and paste profiles live in CaptureSettingsTab+Policy.swift.

struct CaptureSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.clippyTokens) private var tokens
    @State private var soundVolumeSlider: Double = Double(AppSettings.shared.captureSoundVolume)

    /// Distinct catalog groups, in first-seen order, for the sectioned picker.
    private var soundGroups: [String] {
        var seen = Set<String>()
        return SoundCatalog.options.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                CaptureLaunchRow()
            }
            Section("Images and files") {
                Toggle("Capture copied images", isOn: $settings.captureImages).settingsManaged(AppSettings.Keys.captureImages)
                    .settingsRow("capture.images")
                sizePicker("Largest image to keep", selection: $settings.maxImageSizeMB, id: "capture.imageSize")
                SettingsNote("Bigger copies are ignored to keep the history database lean.")
                Toggle("Capture copied files", isOn: $settings.captureFiles).settingsManaged(AppSettings.Keys.captureFiles)
                    .settingsRow("capture.files")
                sizePicker("Store file contents up to", selection: $settings.maxFileSizeMB, id: "capture.fileSize")
                SettingsNote("Files at or below this size are kept locally so they can be pasted later even if the original moves. " +
                    "Larger files are stored as a location reference only. Avoid copying files with sensitive client data.")
            }
            soundsSection
            IgnoredAppsSection(bundleIDs: $settings.ignoredBundleIDs)
            CapturePolicySections()
            SettingsAdvanced(anchors: ["capture.polling"]) {
                LabeledContent("Polling interval: \(Int(settings.pollingIntervalMs)) ms") {
                    Slider(value: $settings.pollingIntervalMs, in: 100...1000, step: 50)
                }
                .settingsRow("capture.polling")
                SettingsNote("Lower is more responsive; higher uses less idle CPU.")
                SettingsNote("Concealed items (password managers) and transient clipboard writes are always skipped.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.captureSoundVolume) { _, newValue in
            if Double(newValue) != soundVolumeSlider { soundVolumeSlider = Double(newValue) }
        }
    }

    /// Preset MB steps; a stored non-preset value stays selectable so it is never rewritten.
    private func sizePicker(_ title: String, selection: Binding<Int>, id: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(FileSizePresets.options(including: selection.wrappedValue), id: \.self) {
                Text(FileSizePresets.label(forMB: $0)).tag($0)
            }
        }
        .settingsRow(id)
    }

    private var soundsSection: some View {
        Section("Sounds") {
            Toggle("Play sound on capture", isOn: $settings.captureSoundEnabled).settingsRow("capture.sound")
            LabeledContent("Sound") {
                HStack(spacing: 8) {
                    Picker("Sound", selection: $settings.captureSoundID) {
                        ForEach(soundGroups, id: \.self) { group in
                            Section(group) {
                                ForEach(SoundCatalog.options.filter { $0.group == group }) { Text($0.label).tag($0.id) }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: settings.captureSoundID) { _, id in
                        SoundPlayer.play(id: id, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
                    }
                    Button {
                        SoundPlayer.play(id: settings.captureSoundID, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
                    } label: { Image(systemName: "play.circle").symbolRenderingMode(.hierarchical) }
                        .buttonStyle(.plain)
                        .help("Preview selected sound")
                        .accessibilityLabel("Preview selected sound")
                }
            }
            .disabled(!settings.captureSoundEnabled)
            LabeledContent("Volume: \(Int(soundVolumeSlider))%") {
                Slider(value: $soundVolumeSlider, in: 0...100, step: 1, onEditingChanged: { editing in
                    guard !editing else { return }
                    settings.captureSoundVolume = Int(soundVolumeSlider)
                    SoundPlayer.play(id: settings.captureSoundID, volume: SoundPlayer.sliderToVolume(settings.captureSoundVolume))
                })
            }
            .disabled(!settings.captureSoundEnabled)
        }
    }
}

#Preview("Capture") { CaptureSettingsTab().clippyDesignSystem().frame(width: 640, height: 700) }

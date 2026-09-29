import AppKit
import SwiftUI

// MARK: - Image
/// Working image plus undo registration for transforms (EDT-08). A class so
/// `UndoManager` can target it.
@MainActor
final class ImageEditModel: ObservableObject {
    @Published private(set) var working: NSImage?
    /// A rotate/flip/crop was applied since the editor opened.
    @Published private(set) var isEdited = false
    /// Pixel size and alpha of `working`, recomputed only when the image changes.
    @Published private(set) var info: ImageInfo

    init(image: NSImage?) {
        working = image
        info = ImageInfo(image: image)
    }

    /// Applies a transform result, registering the inverse with the undo manager.
    func replace(with image: NSImage?, edited: Bool, undoManager: UndoManager?, actionName: String) {
        let previousImage = working
        let previousEdited = isEdited
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replace(with: previousImage, edited: previousEdited, undoManager: undoManager, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
        working = image
        info = ImageInfo(image: image)
        isEdited = edited
    }

    func markSaved() { isEdited = false }
}

/// What a canvas drag started on, decided once at drag start.
enum ImageCropDragMode: Equatable {
    case create
    case move(CGRect)
    case resize(CropHandle, CGRect)
}

struct ImageClipEditor: View {
    let clip: Clip
    let store: ClipStore
    let dirtyBridge: EditorDirtyStateBridge?
    let onClose: () -> Void

    @ObservedObject var settings = AppSettings.shared
    @Environment(\.clippyTokens) var dsTokens
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var model: ImageEditModel
    @Environment(\.undoManager) var undoManager
    @State var title: String
    @State var baseTitle: String
    @State var cropping = false
    /// Committed crop selection in image pixels; live drags update it directly.
    @State var selection: CGRect?
    @State var cropAspect: CropAspect = .free
    @State var dragMode: ImageCropDragMode?
    @State var dragOrigin: CGPoint?
    /// nil follows zoom-to-fit; otherwise an explicit scale (100% is 1).
    @State var zoomScale: CGFloat?
    @State var saveError: String?
    @State var isSaving = false
    @State var canvasSize: CGSize = .zero
    @State var showingInfo = false
    /// Extract Text state (OCR-01/04): explicit action, result shown in a sheet, never written to the pasteboard implicitly.
    @State var ocrRunning = false
    @State var ocrResult: OCRPresenter.Result?
    @State var ocrNotice: OCRExtractOutcome?
    /// Cancel pressed while dirty: Save / Discard / Keep Editing.
    @State var showingDiscardPrompt = false

    var tokens: ThemeTokens { settings.theme }

    /// Unsaved edits exist: the image was transformed or the title changed.
    var isDirty: Bool { model.isEdited || title != baseTitle }

    init(clip: Clip, store: ClipStore, dirtyBridge: EditorDirtyStateBridge?, onClose: @escaping () -> Void) {
        self.clip = clip
        self.store = store
        self.dirtyBridge = dirtyBridge
        self.onClose = onClose
        _title = State(initialValue: clip.userTitle ?? "")
        _baseTitle = State(initialValue: clip.userTitle ?? "")
        _model = StateObject(wrappedValue: ImageEditModel(
            image: store.imageURL(for: clip).flatMap { NSImage(contentsOf: $0) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            toolbar
            Divider()
            if let ocrNotice { ocrBanner(ocrNotice) }
            canvas
            Divider()
            statusBar
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(tokens.cardSurface)
        .onAppear {
            // Wire the title-bar close button to the same dirty/save logic as
            // the Cancel button (see EditorWindowController.windowShouldClose).
            dirtyBridge?.isDirty = { isDirty }
            dirtyBridge?.save = { completion in save(completion: completion) }
            dirtyBridge?.isImage = true
        }
        .onChange(of: isDirty) { _, dirty in dirtyBridge?.onDirtyChange(dirty) }
        .onDisappear { if ocrRunning { cancelExtractText() } }
        .sheet(item: $ocrResult) { result in
            OCRResultView(
                result: result,
                onCopy: { copyToPasteboard($0) },
                onSave: { saveOCRText($0) },
                onPaste: { copyToPasteboard($0) },
                onDismiss: { ocrResult = nil })
        }
        .confirmationDialog(
            "Save changes to this image?",
            isPresented: $showingDiscardPrompt
        ) {
            Button("Save") { save { if $0 { onClose() } } }
            Button("Discard Changes", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits will be lost if you don't save them.")
        }
    }

    var footer: some View {
        HStack {
            if let saveError {
                Text(saveError)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(dsTokens.danger)
                    .accessibilityLabel("Error: \(saveError)")
                    .lineLimit(2)
                    .layoutPriority(-1)
                    .help(saveError)
            }
            Button("Save a copy...") { saveCopy() }
                .fixedSize()
                .disabled(model.working == nil)
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) {
                if cropping {
                    // Esc / Cancel leaves the crop tool first, keeping the edits made so far.
                    setCropping(false)
                } else if isDirty {
                    showingDiscardPrompt = true
                } else {
                    onClose()
                }
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            Button("Save") { save { if $0 { onClose() } } }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .disabled(!isDirty || isSaving)
            Button("") { save { if $0 { onClose() } } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || isSaving)
                .hidden()
                .frame(width: 0, height: 0)
        }
        .padding(12)
    }

    // MARK: - Operations

    func transform(_ name: String, _ operation: (NSImage) -> NSImage?) {
        guard let working = model.working, let result = operation(working) else { return }
        model.replace(with: result, edited: true, undoManager: undoManager, actionName: name)
        resetSelection()
    }

    func applyCrop() {
        guard let working = model.working, let pixelRect = selection,
              let cropped = ImageEditing.cropped(working, to: pixelRect) else { return }
        model.replace(with: cropped, edited: true, undoManager: undoManager, actionName: "Crop")
        cropping = false
        resetSelection()
    }

    func resetSelection() {
        dragMode = nil
        dragOrigin = nil
        selection = nil
    }

    /// Persist the edits off the main thread, writing only what changed: a
    /// title-only change never encodes an image. `completion` runs on the main
    /// actor with whether everything landed; on failure the error shows inline.
    private func save(completion: @escaping (Bool) -> Void) {
        guard let id = clip.id, !isSaving else { completion(false); return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChanged = trimmedTitle != baseTitle
        let image = model.isEdited ? model.working : nil
        if model.isEdited, image == nil {
            saveError = "Could not encode the image."
            completion(false)
            return
        }
        isSaving = true
        let persistence = ClipEditorPersistence.live
        let payload = UncheckedSendable(image)
        Task {
            let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    var png: Data?
                    if let image = payload.value {
                        guard let data = ImageEditing.pngData(image) else { throw ImageSaveError.encodeFailed }
                        png = data
                    }
                    try persistence.saveImage(id: id, png: png, title: titleChanged ? trimmedTitle : nil)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            isSaving = false
            switch outcome {
            case .success:
                baseTitle = trimmedTitle
                title = trimmedTitle
                model.markSaved()
                dirtyBridge?.onTitleChange(trimmedTitle.isEmpty ? (clip.sourceAppName ?? "Edit Image") : trimmedTitle)
                saveError = nil
                completion(true)
            case .failure(let error):
                ClippyLog.error("image editor save failed: \(error)", category: ClippyLog.storage)
                saveError = (error as? ImageSaveError) == .encodeFailed
                    ? "Could not encode the image." : "Could not save your changes."
                completion(false)
            }
        }
    }

    private func saveCopy() {
        guard let working = model.working, let data = ImageEditing.pngData(working) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "clip.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            saveError = nil
        } catch {
            ClippyLog.error("image copy save failed: \(error)", category: ClippyLog.storage)
            saveError = "Could not save the copy."
        }
    }


}

enum ImageSaveError: Error { case encodeFailed }

/// Carries a non-Sendable value (an NSImage that is not mutated afterwards)
/// into the detached encode task.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

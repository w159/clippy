import AppKit
import SwiftUI

// Title bar, tool row and status bar of the image editor (EDT-08).
extension ImageClipEditor {
    var titleBar: some View {
        HStack(spacing: 8) {
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Clip title")
            if isDirty {
                HStack(spacing: 4) {
                    Circle().fill(dsTokens.accent).frame(width: 8, height: 8)
                    Text("unsaved").font(.caption).foregroundStyle(dsTokens.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Unsaved changes")
            }
        }
        .padding(10)
    }

    var toolbar: some View {
        let hasImage = model.working != nil
        return HStack(spacing: 4) {
            IconButton("rotate.left", label: "Rotate left", help: "Rotate left", state: hasImage ? .rest : .disabled) {
                transform("Rotate Left") { ImageEditing.rotated($0, byDegrees: -90) }
            }
            IconButton("rotate.right", label: "Rotate right", help: "Rotate right", state: hasImage ? .rest : .disabled) {
                transform("Rotate Right") { ImageEditing.rotated($0, byDegrees: 90) }
            }
            IconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip horizontal",
                       help: "Flip horizontal", state: hasImage ? .rest : .disabled) {
                transform("Flip Horizontal") { ImageEditing.flipped($0, horizontal: true) }
            }
            IconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip vertical",
                       help: "Flip vertical", state: hasImage ? .rest : .disabled) {
                transform("Flip Vertical") { ImageEditing.flipped($0, horizontal: false) }
            }
            Divider().frame(height: 16)
            IconButton("crop", label: "Crop", help: "Crop", state: hasImage ? (cropping ? .selected : .rest) : .disabled) {
                setCropping(!cropping)
            }
            .accessibilityValue(cropping ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            if cropping { cropControls }
            Divider().frame(height: 16)
            IconButton("arrow.uturn.backward", label: "Undo", help: "Undo (Cmd Z)",
                       state: (undoManager?.canUndo ?? false) ? .rest : .disabled) { undoManager?.undo() }
            IconButton("arrow.uturn.forward", label: "Redo", help: "Redo (Shift Cmd Z)",
                       state: (undoManager?.canRedo ?? false) ? .rest : .disabled) { undoManager?.redo() }
            Divider().frame(height: 16)
            Button { extractText() } label: {
                // Icon only while the crop controls need the room.
                if cropping { Image(systemName: "text.viewfinder") } else { Label("Extract Text", systemImage: "text.viewfinder") }
            }
                .accessibilityLabel("Extract text")
                .help("Recognize text in this image (does not change the clipboard)")
                .disabled(!hasImage || ocrRunning || clip.id == nil)
            Spacer()
            IconButton("info.circle", label: "Image info", help: "Image info", state: hasImage ? .rest : .disabled) {
                showingInfo.toggle()
            }
            .popover(isPresented: $showingInfo) {
                ImageInfoPopover(info: model.info, byteSize: fileByteSize, format: ImageInfoFormatter.formatName(for: store.imageURL(for: clip)),
                                 isEdited: model.isEdited)
                    .clippyTokens(dsTokens)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(dsTokens.surfaceElevated)
    }

    /// Aspect presets, Apply and Cancel while cropping.
    var cropControls: some View {
        HStack(spacing: 4) {
            Picker("Aspect", selection: Binding(get: { cropAspect }, set: { setAspect($0) })) {
                ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .accessibilityLabel("Crop aspect ratio")
            Button("Apply crop") { applyCrop() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(selection == nil)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Apply crop (Cmd Return)")
        }
    }

    /// Detail segments (format, size, selection) drop out before the zoom controls are squeezed.
    var statusBar: some View {
        ViewThatFits(in: .horizontal) {
            statusRow(showsDetail: true)
            statusRow(showsDetail: false)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(dsTokens.textSecondary)
        .buttonStyle(.borderless)
        .padding(.horizontal, dsTokens.metrics.space.four)
        .padding(.vertical, 2)
        .background(dsTokens.surfaceInset)
    }

    private func statusRow(showsDetail: Bool) -> some View {
        HStack(spacing: dsTokens.metrics.space.four) {
            Text(ImageInfoFormatter.dimensions(model.info.pixelSize) + " px")
            if showsDetail {
                if let format = store.imageURL(for: clip) { Text(ImageInfoFormatter.formatName(for: format)) }
                if let fileByteSize { Text(ImageInfoFormatter.byteSize(fileByteSize)) }
                if let selection { Text("Sel " + CropGeometry.description(of: selection)) }
            }
            Spacer(minLength: 0)
            Button("Fit") { zoomScale = nil }.help("Zoom to fit")
            Button("100%") { zoomScale = 1 }.help("Actual size")
            IconButton("minus.magnifyingglass", label: "Zoom out", help: "Zoom out") { zoomBy(out: true) }
            Text(ImageZoomMath.percentLabel(effectiveScale)).frame(minWidth: 40, alignment: .trailing)
            IconButton("plus.magnifyingglass", label: "Zoom in", help: "Zoom in") { zoomBy(out: false) }
        }
        .lineLimit(1)
    }

    /// Size in bytes of the stored image file, if readable.
    var fileByteSize: Int64? {
        guard let url = store.imageURL(for: clip),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    var effectiveScale: CGFloat {
        zoomScale ?? ImageZoomMath.fitScale(image: model.info.pixelSize, viewport: canvasViewport)
    }

    /// Canvas area minus its padding.
    var canvasViewport: CGSize { CGSize(width: max(0, canvasSize.width - 16), height: max(0, canvasSize.height - 16)) }

    func zoomBy(out: Bool) {
        let current = effectiveScale
        zoomScale = out ? ImageZoomMath.zoomedOut(from: current) : ImageZoomMath.zoomedIn(from: current)
    }

    func setCropping(_ enabled: Bool) {
        cropping = enabled
        guard enabled else { return }
        if selection == nil {
            selection = CropGeometry.initialRect(bounds: model.info.pixelSize, ratio: cropAspect.ratio(imageSize: model.info.pixelSize))
        }
        announceSelection()
    }

    func setAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        let bounds = model.info.pixelSize
        guard let current = selection else { return }
        selection = CropGeometry.applying(ratio: aspect.ratio(imageSize: bounds), to: current, bounds: bounds)
        announceSelection()
    }
}

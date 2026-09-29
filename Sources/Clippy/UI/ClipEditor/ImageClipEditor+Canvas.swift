import AppKit
import SwiftUI

// Canvas: checkerboard, image, crop overlay and the crop gesture (image-space, EDT-08).
extension ImageClipEditor {
    var canvas: some View {
        GeometryReader { geo in
            if let working = model.working {
                let pixels = model.info.pixelSize
                let scale = zoomScale ?? ImageZoomMath.fitScale(image: pixels, viewport: CGSize(width: max(0, geo.size.width - 16), height: max(0, geo.size.height - 16)))
                let display = ImageZoomMath.displaySize(image: pixels, scale: scale)
                ScrollView([.horizontal, .vertical]) {
                    imageStack(working, display: display, pixels: pixels)
                        .frame(width: max(display.width, geo.size.width - 16), height: max(display.height, geo.size.height - 16))
                }
                .scrollIndicators(.automatic)
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { canvasSize = geo.size }
            } else {
                imageLoadError.frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
        .background(dsTokens.surfaceInset)
        .overlay { if ocrRunning { ocrScrim } }
        .animation(ClippyMotion.animation(.quick, reduce: reduceMotion), value: ocrRunning)
    }

    @ViewBuilder
    private func imageStack(_ working: NSImage, display: CGSize, pixels: CGSize) -> some View {
        ZStack {
            if model.info.hasAlpha {
                PreviewCheckerboard { Color.clear }.frame(width: display.width, height: display.height)
            }
            Image(nsImage: working).resizable().interpolation(.high).frame(width: display.width, height: display.height)
            if cropping, let rect = selection {
                ImageCropOverlay(rect: CropSelection.viewRect(fromImage: rect, fitted: display, pixels: pixels), showsThirds: true)
                    .frame(width: display.width, height: display.height)
            }
        }
        .frame(width: display.width, height: display.height)
        .contentShape(Rectangle())
        .gesture(cropGesture(fitted: display, pixels: pixels), including: cropping ? .all : .subviews)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image canvas, \(ImageInfoFormatter.dimensions(pixels)) pixels")
        .accessibilityValue(selection.map { cropping ? "Selection \(CropGeometry.description(of: $0))" : "" } ?? "No selection")
        .accessibilityAction(named: "Select entire image") { selection = CGRect(origin: .zero, size: pixels); cropping = true; announceSelection() }
        .accessibilityAction(named: "Clear selection") { resetSelection() }
    }

    /// Error treatment shown when the clip's image file cannot be loaded.
    var imageLoadError: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(dsTokens.textSecondary)
            Text("Could not load the image. The file may have been moved or deleted. You can still rename the clip.")
                .font(PanelTypography.body(settings)).foregroundStyle(dsTokens.textSecondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    /// Chooses move / resize / create from where the drag began, then edits the image-space selection.
    func cropGesture(fitted: CGSize, pixels: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard cropping,
                      let start = CropSelection.imagePoint(fromView: value.startLocation, fitted: fitted, pixels: pixels),
                      let current = CropSelection.imagePoint(fromView: value.location, fitted: fitted, pixels: pixels) else { return }
                if dragMode == nil { beginDrag(at: value.startLocation, start: start, fitted: fitted, pixels: pixels) }
                let ratio = cropAspect.ratio(imageSize: pixels)
                switch dragMode {
                case .resize(let handle, let base):
                    selection = CropGeometry.resized(base, handle: handle, to: current, ratio: ratio, bounds: pixels)
                case .move(let base):
                    let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
                    selection = CropGeometry.moved(base, by: delta, bounds: pixels)
                default:
                    selection = CropGeometry.resized(CGRect(origin: start, size: .zero), handle: cornerHandle(from: start, to: current),
                                                     to: current, ratio: ratio, bounds: pixels)
                }
            }
            .onEnded { _ in
                dragMode = nil
                dragOrigin = nil
                announceSelection()
            }
    }

    private func beginDrag(at viewPoint: CGPoint, start: CGPoint, fitted: CGSize, pixels: CGSize) {
        dragOrigin = start
        guard let rect = selection else { dragMode = .create; return }
        let viewRect = CropSelection.viewRect(fromImage: rect, fitted: fitted, pixels: pixels)
        if let handle = CropGeometry.hitHandle(at: viewPoint, in: viewRect, tolerance: 12) {
            dragMode = .resize(handle, rect)
        } else if viewRect.contains(viewPoint) {
            dragMode = .move(rect)
        } else {
            dragMode = .create
        }
    }

    private func cornerHandle(from start: CGPoint, to end: CGPoint) -> CropHandle {
        switch (end.x >= start.x, end.y >= start.y) {
        case (true, true): return .bottomRight
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .topLeft
        }
    }

    /// VoiceOver announcement of the selection size after a change.
    func announceSelection() {
        guard cropping, let rect = selection else { return }
        let text = "Selection \(Int(rect.width.rounded())) by \(Int(rect.height.rounded())) pixels"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
}

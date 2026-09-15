import AVFoundation
import ChessfenKit
import CoreImage
import CoreMedia
import SwiftUI
import UIKit

/// The camera, built here rather than borrowed from VisionKit's document scanner
/// (docs/adr/0013).
///
/// Three things are wanted from a camera pointed at a chessboard, and the system scanner has no
/// way to express any of them: the shutter stays under the thumb instead of firing when a model
/// decides the frame is steady, the focus is aimed at what is being photographed, and the lens
/// it opens on is the one that can focus close. That last one is the reason for the other two —
/// a board is often small and looked at from twenty centimetres, which is *inside* the wide
/// lens's minimum focus distance, and a wide lens that cannot focus will hunt forever while an
/// automatic shutter waits for a steadiness that never arrives.
nonisolated final class BoardCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    /// Which of the back camera's lenses is looking.
    ///
    /// 微距 is the ultra-wide, which on every phone that has one focuses down to a couple of
    /// centimetres; 标准 is the wide, which is sharper and undistorted but gives up at roughly
    /// a hand's length. There is no third state and no "auto": the phone will still fall back
    /// between constituent lenses when focus demands it, but which one it opens on is a choice,
    /// and the choice is 微距.
    enum Lens: Sendable {
        case macro
        case standard
    }

    let session = AVCaptureSession()

    /// Every touch of the session or the device happens here. `AVCaptureSession.startRunning`
    /// takes long enough to drop frames from a screen that is presenting itself.
    private let queue = DispatchQueue(label: "com.sunfmin.chessfen.camera")
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?

    /// The live frames the board is looked for in, and the queue that looking happens on —
    /// its own, so that a frame taking a fifth of a second to answer never delays the shutter.
    private let frames = AVCaptureVideoDataOutput()
    private let looking = DispatchQueue(label: "com.sunfmin.chessfen.viewfinder")
    /// True while a frame is being looked at. Frames that arrive meanwhile are dropped rather
    /// than queued: a backlog of stale frames would draw the board where it *was*.
    private var busy = false

    /// The board's four corners as the viewfinder currently sees them, in the 0…1 coordinates
    /// the capture device counts in, or nil when there is no board in front of the lens.
    var onBoard: (@Sendable ([CGPoint]?) -> Void)?
    /// The zoom factor at which the wide lens takes over from the ultra-wide — 微距 is anything
    /// below it. Nil on a phone whose back camera is a single wide lens, which is also the
    /// phone that has no 微距 to offer.
    private var wideFactor: CGFloat?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    /// Captures in flight, held because nothing else does: `capturePhoto` does not keep its
    /// delegate alive, and a delegate that has been collected is a photograph that never
    /// arrives and a shutter that never comes back.
    private var captures: [Int64: Capture] = [:]

    /// Whether the camera may be used at all, asking the person if nobody has yet.
    static func authorised() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// What starting the camera found there: whether there is one at all, and whether 微距 is
    /// something this phone can be asked for.
    struct Ready: Sendable {
        var running = false
        var macro = false
    }

    /// Starts the session on `lens`.
    @discardableResult
    func start(lens: Lens) async -> Ready {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if device == nil { configure() }
                guard device != nil else {
                    continuation.resume(returning: Ready())
                    return
                }
                apply(lens)
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: Ready(running: true, macro: wideFactor != nil))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func use(_ lens: Lens) {
        queue.async { [self] in apply(lens) }
    }

    // ------------------------------------------------------------------ setting up

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        // Most to least capable. The virtual devices are asked for first because it is the
        // virtual device that owns the ultra-wide: a phone's macro lens is not a separate
        // camera you switch to, it is this device zoomed below the wide lens's switch-over
        // point, and asking for `.builtInUltraWideCamera` on its own would give up the phone's
        // own ability to fall back between them when focus needs it.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard let found = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: found),
              session.canAddInput(input), session.canAddOutput(output)
        else { return }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .quality

        // Left in the sensor's own landscape orientation on purpose: unrotated, a point in the
        // frame divided by the frame's size *is* the capture-device point the preview layer
        // knows how to place, and a chessboard is as recognisable on its side as upright.
        frames.alwaysDiscardsLateVideoFrames = true
        frames.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        frames.setSampleBufferDelegate(self, queue: looking)
        if session.canAddOutput(frames) { session.addOutput(frames) }

        device = found
        wideFactor = found.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) }
        rotation = AVCaptureDevice.RotationCoordinator(device: found, previewLayer: nil)
    }

    /// Everything about focus, in one place, because every one of these settings is undone by
    /// the next `lockForConfiguration` and they only mean anything together.
    private func apply(_ lens: Lens) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if let wideFactor {
            device.videoZoomFactor = lens == .macro ? device.minAvailableVideoZoomFactor : wideFactor
        }
        // Told where to look before being told to look: the near restriction stops the lens
        // sweeping out to infinity and back for a board that is thirty centimetres away, which
        // is the hunting that reads as "it won't focus".
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = lens == .macro ? .near : .none
        }
        // Smooth autofocus is for filming — it eases between distances so the footage does not
        // lurch. Here there is no footage, only the moment the shutter is pressed, so the fast
        // one is the right one.
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        // So that a focus locked onto one square by a tap lets go again once the phone is
        // pointed somewhere else.
        device.isSubjectAreaChangeMonitoringEnabled = true
    }

    /// Focuses and meters on one point of the picture, in the 0…1 coordinates the capture
    /// device counts in.
    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure)
            {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// Hands the preview layer the rotation coordinator, so that what is on screen stays level
    /// with the ground rather than with the phone.
    func attach(preview: AVCaptureVideoPreviewLayer) {
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device ?? AVCaptureDevice.default(for: .video)!, previewLayer: preview
        )
        rotation = coordinator
        previewObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            guard let connection = preview.connection,
                  connection.isVideoRotationAngleSupported(angle)
            else { return }
            connection.videoRotationAngle = angle
        }
    }

    // ------------------------------------------------------------------ the shutter

    /// Takes one photograph, now, because a thumb said so.
    func capture(_ finished: @escaping @Sendable (UIImage?) -> Void) {
        queue.async { [self] in
            let settings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
            )
            settings.photoQualityPrioritization = .quality
            // Level with the ground, from the accelerometer rather than from whichever way the
            // interface happens to be locked. A board photographed with the phone turned
            // sideways arrives the right way up.
            if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
               let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle)
            {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let capture = Capture { [weak self] image in
                finished(image)
                self?.queue.async { self?.captures[id] = nil }
            }
            captures[id] = capture
            output.capturePhoto(with: settings, delegate: capture)
        }
    }

    // ------------------------------------------------------------------ the viewfinder

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !busy, let buffer = sampleBuffer.imageBuffer else { return }
        busy = true
        look(at: buffer)
    }

    private func look(at buffer: CVPixelBuffer) {
        let source = CIImage(cvPixelBuffer: buffer)
        let longest = max(source.extent.width, source.extent.height)
        guard longest > 0 else { return }
        let scale = min(1, CGFloat(Imaging.viewfinderFrameSize) / longest)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = Imaging.renderContext.createCGImage(small, from: small.extent),
              let frame = RGBImage(cgImage: rendered)
        else { return }

        Task { [weak self] in
            let quad = await PerspectiveCorrection.located(in: frame)
            let corners = quad?.corners.map {
                CGPoint(x: $0.x / CGFloat(frame.width), y: $0.y / CGFloat(frame.height))
            }
            self?.onBoard?(corners)
            self?.looking.async { self?.busy = false }
        }
    }

    private final class Capture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let finished: @Sendable (UIImage?) -> Void

        init(finished: @escaping @Sendable (UIImage?) -> Void) {
            self.finished = finished
        }

        func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: (any Error)?
        ) {
            guard error == nil, let data = photo.fileDataRepresentation() else {
                finished(nil)
                return
            }
            finished(UIImage(data: data))
        }
    }
}

/// The live picture, the box drawn on the board in it, and the taps landing on both.
struct CameraPreview: UIViewRepresentable {
    let camera: BoardCamera
    /// Where the tap landed, in the view, and where that is on the sensor.
    let onFocus: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(preview: view.previewLayer)

        // The corners arrive on the queue that found them, and the layer that can place them is
        // the one inside this view — so the view travels to that queue in a box that says the
        // compiler is not to reason about it, and comes back to the main thread to be touched.
        let held = Held(view)
        camera.onBoard = { corners in
            DispatchQueue.main.async { held.view?.show(corners) }
        }

        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tapped)
        )
        view.addGestureRecognizer(tap)
        return view
    }

    private final class Held: @unchecked Sendable {
        weak var view: PreviewView?
        init(_ view: PreviewView) { self.view = view }
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onFocus = onFocus
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    final class Coordinator: NSObject {
        var onFocus: (CGPoint, CGPoint) -> Void

        init(onFocus: @escaping (CGPoint, CGPoint) -> Void) { self.onFocus = onFocus }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            onFocus(point, view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }
    }

    /// A view that *is* its preview layer, so the layer is laid out by the view system rather
    /// than by hand on every bounds change.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private let outline = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            outline.fillColor = UIColor(Palette.analysis).withAlphaComponent(0.16).cgColor
            outline.strokeColor = UIColor(Palette.analysis).cgColor
            outline.lineWidth = 2
            outline.lineJoin = .round
            layer.addSublayer(outline)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Draws the board where the viewfinder says it is, from corners in capture-device
        /// coordinates — the layer knows how the sensor maps onto itself, including the crop
        /// that `resizeAspectFill` takes out, which is not arithmetic worth repeating here.
        ///
        /// The path change animates by itself, and that is wanted: the search answers a couple
        /// of times a second, and without the layer easing between answers the box would
        /// snap around a board that is only being held slightly unsteadily.
        func show(_ corners: [CGPoint]?) {
            guard let corners, corners.count == 4 else {
                outline.path = nil
                return
            }
            let points = corners.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
            let path = UIBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.close()
            outline.path = path.cgPath
        }
    }
}

/// 拍棋盘: the viewfinder, a lens to choose, and a shutter that only a thumb presses.
struct BoardCameraScreen: View {
    let onCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var camera = BoardCamera()
    @State private var lens: BoardCamera.Lens = .macro
    @State private var ready = BoardCamera.Ready()
    @State private var trouble: String?
    /// Where the last tap landed, so the reticle can be drawn there and then fade.
    @State private var reticle: CGPoint?
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(camera: camera) { point, devicePoint in
                camera.focus(at: devicePoint)
                reticle = point
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    reticle = nil
                }
            }
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let reticle {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Palette.parchment, lineWidth: 1.5)
                        .frame(width: 74, height: 74)
                        .position(reticle)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }

            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(Palette.parchment)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }

            controls
        }
        .statusBarHidden()
        .task {
            guard await BoardCamera.authorised() else {
                trouble = localized("camera.denied")
                return
            }
            ready = await camera.start(lens: lens)
            if !ready.running {
                trouble = localized("camera.missing")
            }
        }
        .onDisappear { camera.stop() }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(Palette.parchment)
                        .padding(12)
                        .background(.black.opacity(0.35), in: Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 18) {
                // Only on a phone that has two lenses to choose between. On one that does not,
                // saying 微距 would be a promise about focus distance the hardware cannot keep.
                if ready.macro {
                    HStack(spacing: 0) {
                        lensChip(localized("camera.lens.macro"), .macro)
                        lensChip(localized("camera.lens.standard"), .standard)
                    }
                    .background(.black.opacity(0.35), in: Capsule())
                }

                Button {
                    take()
                } label: {
                    ZStack {
                        Circle().stroke(Palette.parchment, lineWidth: 3).frame(width: 74, height: 74)
                        Circle().fill(Palette.parchment).frame(width: 60, height: 60)
                    }
                }
                .disabled(isCapturing || !ready.running)
                .opacity(isCapturing ? 0.5 : 1)
            }
            .padding(.bottom, 28)
        }
    }

    private func lensChip(_ title: String, _ which: BoardCamera.Lens) -> some View {
        Button {
            guard lens != which else { return }
            lens = which
            camera.use(which)
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(lens == which ? Palette.ink : Palette.parchment)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(lens == which ? Palette.parchment : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func take() {
        isCapturing = true
        camera.capture { image in
            Task { @MainActor in
                isCapturing = false
                guard let image else { return }
                onCaptured(image)
                dismiss()
            }
        }
    }
}

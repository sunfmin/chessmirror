import AVFoundation
import Testing

@testable import Chessmirror

/// The camera with no camera behind it: the Simulator, or a phone where the discovery session
/// found none. Attaching the preview must leave the screen standing rather than
/// reach for a device that is not there.
@MainActor
@Suite
struct BoardCameraWithoutDevice {
    @Test func attachingThePreviewWithNoDeviceDoesNotCrash() {
        #expect(AVCaptureDevice.default(for: .video) == nil, "this test is for a host with no camera")
        let camera = BoardCamera()
        let preview = AVCaptureVideoPreviewLayer(session: camera.session)
        camera.attach(preview: preview)
        #expect(preview.session === camera.session)
    }
}

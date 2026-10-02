import AVFoundation
import Vision

/// Follows the listener's head turns through the camera.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Head yaw in degrees, positive when the head turns right, or nil when no face is in view.
    var onYaw: ((Double?) -> Void)?
    var onError: ((String) -> Void)?

    /// Camera frame rates the listener can choose; face detection costs CPU on every frame.
    static let frameRates = [15, 20, 30]

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "head-tracker")
    /// Queue only: the camera, once its input is attached.
    private var device: AVCaptureDevice?
    /// Queue only: frames per second asked of the camera.
    private var frameRate = 20
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    /// Starts or stops the camera; stopping turns off the camera indicator.
    func setRunning(_ on: Bool) {
        guard on else {
            queue.async { self.session.stopRunning() }
            return
        }
        queue.async {
            if self.device == nil {
                self.configure()
            }
            if self.device != nil {
                self.session.startRunning()
                // On macOS the session may configure the camera format again on start, which resets the frame duration.
                self.applyFrameRate()
            }
        }
    }

    func setFrameRate(_ rate: Int) {
        queue.async {
            self.frameRate = rate
            self.applyFrameRate()
        }
    }

    /// Skips a rate the camera's format doesn't offer; setting one raises an exception.
    private func applyFrameRate() {
        guard let device,
              device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                  $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate
              }),
              (try? device.lockForConfiguration()) != nil
        else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onError?(String(localized: "error.noCamera"))
            return
        }
        session.sessionPreset = .vga640x480
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        self.device = device
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let face = request.results?.max { $0.boundingBox.width < $1.boundingBox.width }
        // Vision reports yaw with the opposite sign to a right turn of the head.
        onYaw?(face?.yaw.map { -$0.doubleValue * 180 / .pi })
    }
}

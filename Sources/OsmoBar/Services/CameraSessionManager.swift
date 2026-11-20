import Foundation
@preconcurrency import AVFoundation
import Vision

/// Shared AVFoundation capture session powering both the live video preview(s)
/// and optional macOS Vision Face Follow (`VNDetectFaceRectanglesRequest`).
///
/// Only runs the capture session while at least one preview is mounted OR Face Follow is enabled.
public final class CameraSessionManager: NSObject, @unchecked Sendable {
    public let session = AVCaptureSession()

    public var onFaceDetected: (@Sendable (CGRect?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.osmobar.camera.session")
    private let visionQueue = DispatchQueue(label: "com.osmobar.camera.vision", qos: .userInitiated)
    private let stateLock = NSLock()

    private let videoOutput = AVCaptureVideoDataOutput()
    private var activeCameraID: String?
    private var previewConsumers = 0
    private var faceTrackingActive = false
    private var isProcessingFrame = false
    private var lastVisionTimestamp: TimeInterval = 0
    private var lastFaceSeenTimestamp: TimeInterval = 0

    public override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
    }

    public func setCamera(uniqueID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard uniqueID != self.activeCameraID else { return }
            self.activeCameraID = uniqueID

            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            if let uniqueID,
               let device = AVCaptureDevice(uniqueID: uniqueID),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if !self.session.outputs.contains(self.videoOutput),
               self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()
            self.updateRunningStateLocked()
        }
    }

    public func registerPreviewConsumer() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.previewConsumers += 1
            self.updateRunningStateLocked()
        }
    }

    public func unregisterPreviewConsumer() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.previewConsumers = max(0, self.previewConsumers - 1)
            self.updateRunningStateLocked()
        }
    }

    public func setFaceTrackingEnabled(_ enabled: Bool) {
        stateLock.lock()
        faceTrackingActive = enabled
        stateLock.unlock()

        if !enabled {
            onFaceDetected?(nil)
        }
        sessionQueue.async { [weak self] in
            self?.updateRunningStateLocked()
        }
    }

    private func updateRunningStateLocked() {
        stateLock.lock()
        let wantsTracking = faceTrackingActive
        stateLock.unlock()

        let shouldRun = (previewConsumers > 0 || wantsTracking) && !session.inputs.isEmpty
        if shouldRun && !session.isRunning {
            session.startRunning()
        } else if !shouldRun && session.isRunning {
            session.stopRunning()
        }
    }
}

extension CameraSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let active = faceTrackingActive
        let busy = isProcessingFrame
        let now = ProcessInfo.processInfo.systemUptime
        guard active, !busy, (now - lastVisionTimestamp) >= 0.09 else {
            stateLock.unlock()
            return
        }
        isProcessingFrame = true
        lastVisionTimestamp = now
        stateLock.unlock()

        defer {
            stateLock.lock()
            isProcessingFrame = false
            stateLock.unlock()
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            let faces = request.results ?? []
            // Pick the largest (closest / primary) face in frame
            if let primary = faces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }) {
                stateLock.lock()
                lastFaceSeenTimestamp = now
                stateLock.unlock()
                onFaceDetected?(primary.boundingBox)
            } else {
                stateLock.lock()
                let age = now - lastFaceSeenTimestamp
                stateLock.unlock()
                if age > 0.6 {
                    onFaceDetected?(nil)
                }
            }
        } catch {
            // Ignore transient frame errors
        }
    }
}

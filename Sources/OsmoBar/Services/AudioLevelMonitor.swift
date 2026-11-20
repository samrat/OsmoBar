import Foundation
@preconcurrency import AVFoundation

public enum AudioMeterState: Equatable, Sendable {
    case noDevice
    case permissionNotDetermined
    case permissionDenied
    case inactive
    case active(deviceName: String)
}

/// Lightweight real-time audio level meter for the connected DJI Osmo Pocket 3 USB audio input.
/// Uses `AVCaptureAudioDataOutput` channel metering (~20 Hz) with zero audio recording or disk I/O.
public final class AudioLevelMonitor: NSObject, @unchecked Sendable {
    public var onUpdate: (@Sendable (_ level: Double, _ peak: Double, _ decibels: Float, _ state: AudioMeterState) -> Void)?

    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.osmobar.audio.session")
    private let sampleQueue = DispatchQueue(label: "com.osmobar.audio.samples", qos: .userInteractive)
    private let lock = NSLock()

    private var activeDeviceID: String?
    private var activeDeviceName: String = ""
    private var enabled = true
    private var smoothedLevel: Double = 0
    private var peakHold: Double = 0
    private var lastPeakTime: TimeInterval = 0
    private var lastEmitTime: TimeInterval = 0

    public override init() {
        super.init()
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    public func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        enabled = isEnabled
        lock.unlock()
        refresh()
    }

    public func requestPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.refresh()
            }
        default:
            emit(level: 0, peak: 0, db: -60, state: .permissionDenied)
        }
    }

    public func refresh() {
        sessionQueue.async { [weak self] in
            self?.reconfigureOnSessionQueue()
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.emit(level: 0, peak: 0, db: -60, state: .inactive)
        }
    }

    // MARK: - Session Management

    private func reconfigureOnSessionQueue() {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()

        guard isEnabled else {
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .inactive)
            return
        }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .notDetermined:
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .permissionNotDetermined)
            return
        case .denied, .restricted:
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .permissionDenied)
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let target = findOsmoAudioDevice() else {
            activeDeviceID = nil
            activeDeviceName = ""
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .noDevice)
            return
        }

        if target.uniqueID != activeDeviceID {
            activeDeviceID = target.uniqueID
            activeDeviceName = target.localizedName

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            if let input = try? AVCaptureDeviceInput(device: target),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if !session.outputs.contains(audioOutput),
               session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
            session.commitConfiguration()
        }

        if !session.inputs.isEmpty && !session.isRunning {
            session.startRunning()
        }
        emit(level: smoothedLevel, peak: peakHold, db: -60, state: .active(deviceName: activeDeviceName))
    }

    private func findOsmoAudioDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first { dev in
            let lower = dev.localizedName.lowercased()
            return lower.contains("osmo") || lower.contains("pocket") || lower.contains("dji")
        }
    }

    private func emit(level: Double, peak: Double, db: Float, state: AudioMeterState) {
        onUpdate?(level, peak, db, state)
    }
}

extension AudioLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard now - lastEmitTime >= 0.045 else {
            lock.unlock()
            return
        }
        lastEmitTime = now
        let deviceName = activeDeviceName
        lock.unlock()

        let channels = connection.audioChannels
        let avgDb: Float
        if !channels.isEmpty {
            avgDb = channels.map(\.averagePowerLevel).max() ?? -60.0
        } else {
            avgDb = -60.0
        }

        // Normalize -55 dB ... 0 dB onto 0.0 ... 1.0 with slight perceptual lift
        let clampedDb = max(-60.0, min(0.0, avgDb))
        let linear = Double((clampedDb + 55.0) / 55.0)
        let normalized = max(0.0, min(1.0, linear))

        lock.lock()
        // Fast attack, smooth release
        if normalized > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.35 + normalized * 0.65
        } else {
            smoothedLevel = smoothedLevel * 0.78 + normalized * 0.22
        }

        if normalized >= peakHold || (now - lastPeakTime) > 0.9 {
            peakHold = max(normalized, smoothedLevel)
            lastPeakTime = now
        } else {
            peakHold = max(smoothedLevel, peakHold - 0.015)
        }

        let outLevel = smoothedLevel
        let outPeak = peakHold
        lock.unlock()

        emit(level: outLevel, peak: outPeak, db: clampedDb, state: .active(deviceName: deviceName))
    }
}

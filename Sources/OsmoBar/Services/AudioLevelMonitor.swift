import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import OsmoCore

public enum AudioMeterState: Equatable, Sendable {
    case noDevice
    case permissionNotDetermined
    case permissionDenied
    case inactive
    case active(deviceName: String)
}

/// Lightweight real-time audio level meter & DJI Mic source detector for the
/// connected DJI Osmo Pocket 3 (or direct USB DJI Mic receiver).
///
/// Inspects stereo L/R channel coherence on audible PCM frames to detect when
/// a mono DJI Mic transmitter is paired to the Pocket 3 vs. the built-in stereo mic array.
public final class AudioLevelMonitor: NSObject, @unchecked Sendable {
    public var onUpdate: (@Sendable (_ level: Double, _ peak: Double, _ decibels: Float, _ state: AudioMeterState, _ source: DetectedMicSource) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.osmobar.audio.session")
    private let sampleQueue = DispatchQueue(label: "com.osmobar.audio.samples", qos: .userInteractive)
    private let lock = NSLock()

    private var activeDeviceID: String?
    private var activeDeviceName: String = ""
    private var isDirectDJIMicReceiver = false
    private var enabled = true
    private var permissionRequested = false
    private var smoothedLevel: Double = 0
    private var peakHold: Double = 0
    private var lastPeakTime: TimeInterval = 0
    private var lastEmitTime: TimeInterval = 0
    private var classifier = StereoMicSourceClassifier(confirmFramesRequired: 8)

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
            lock.lock()
            let alreadyRequested = permissionRequested
            permissionRequested = true
            lock.unlock()
            guard !alreadyRequested else { return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.refresh()
            }
        default:
            emit(level: 0, peak: 0, db: -60, state: .permissionDenied, source: .unknown)
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
            self.emit(level: 0, peak: 0, db: -60, state: .inactive, source: .unknown)
        }
    }

    // MARK: - Session Management

    private func reconfigureOnSessionQueue() {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()

        guard isEnabled else {
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .inactive, source: .unknown)
            return
        }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .notDetermined:
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .permissionNotDetermined, source: .unknown)
            return
        case .denied, .restricted:
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .permissionDenied, source: .unknown)
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let (target, isDirectMic) = findPreferredDJIAudioDevice() else {
            lock.lock()
            activeDeviceID = nil
            activeDeviceName = ""
            isDirectDJIMicReceiver = false
            classifier.reset()
            lock.unlock()
            if session.isRunning { session.stopRunning() }
            emit(level: 0, peak: 0, db: -60, state: .noDevice, source: .unknown)
            return
        }

        if target.uniqueID != activeDeviceID {
            lock.lock()
            activeDeviceID = target.uniqueID
            activeDeviceName = target.localizedName
            isDirectDJIMicReceiver = isDirectMic
            classifier.reset()
            lock.unlock()

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

        let initialSource: DetectedMicSource = isDirectMic
            ? .djiMicUSBReceiver(name: target.localizedName)
            : currentDetectedSource
        emit(level: smoothedLevel, peak: peakHold, db: -60, state: .active(deviceName: target.localizedName), source: initialSource)
    }

    /// Prefers a direct USB DJI Mic receiver if plugged into the Mac, otherwise uses the Osmo Pocket 3 USB audio input.
    private func findPreferredDJIAudioDevice() -> (AVCaptureDevice, Bool)? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        if let directMic = discovery.devices.first(where: { dev in
            let lower = dev.localizedName.lowercased()
            return lower.contains("dji mic") || lower.contains("mic 2") || lower.contains("mic mini")
        }) {
            return (directMic, true)
        }
        if let pocket = discovery.devices.first(where: { dev in
            let lower = dev.localizedName.lowercased()
            return lower.contains("osmo") || lower.contains("pocket") || lower.contains("dji")
        }) {
            return (pocket, false)
        }
        return nil
    }

    private var currentDetectedSource: DetectedMicSource {
        lock.lock()
        defer { lock.unlock() }
        if isDirectDJIMicReceiver {
            return .djiMicUSBReceiver(name: activeDeviceName)
        }
        return classifier.detectedSource
    }

    private func emit(level: Double, peak: Double, db: Float, state: AudioMeterState, source: DetectedMicSource) {
        onUpdate?(level, peak, db, state, source)
    }
}

extension AudioLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Run stereo L/R coherence classification on the Pocket 3 USB audio stream
        lock.lock()
        let directMic = isDirectDJIMicReceiver
        let deviceName = activeDeviceName
        lock.unlock()

        if !directMic, let (left, right) = extractStereoSamples(from: sampleBuffer) {
            lock.lock()
            let transition = classifier.ingest(left: left, right: right)
            let metrics = classifier.lastMetrics
            lock.unlock()

            if let transition {
                if let m = metrics {
                    onLog?(String(
                        format: "Audio: source -> %@ (corr=%.4f, S/M=%.3f)",
                        transition.badgeTitle, m.correlation, m.sideToMidRatio
                    ))
                } else {
                    onLog?("Audio: source -> \(transition.badgeTitle)")
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard now - lastEmitTime >= 0.045 else {
            lock.unlock()
            return
        }
        lastEmitTime = now
        let source: DetectedMicSource = directMic
            ? .djiMicUSBReceiver(name: deviceName)
            : classifier.detectedSource
        lock.unlock()

        let channels = connection.audioChannels
        let avgDb: Float
        if !channels.isEmpty {
            avgDb = channels.map(\.averagePowerLevel).max() ?? -60.0
        } else {
            avgDb = -60.0
        }

        let clampedDb = max(-60.0, min(0.0, avgDb))
        let linear = Double((clampedDb + 55.0) / 55.0)
        let normalized = max(0.0, min(1.0, linear))

        lock.lock()
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

        emit(level: outLevel, peak: outPeak, db: clampedDb, state: .active(deviceName: deviceName), source: source)
    }

    /// Extracts normalized Float32 stereo (L, R) samples from a CoreMedia linear PCM sample buffer.
    private func extractStereoSamples(from sampleBuffer: CMSampleBuffer) -> ([Float], [Float])? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == 2 else {
            return nil
        }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let listSize = MemoryLayout<AudioBufferList>.size + (isNonInterleaved ? MemoryLayout<AudioBuffer>.size : 0)
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let ablPtr = rawList.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(numFrames)
        right.reserveCapacity(numFrames)

        if isNonInterleaved && buffers.count >= 2,
           let ptrL = buffers[0].mData, let ptrR = buffers[1].mData {
            if isFloat && asbd.mBitsPerChannel == 32 {
                let fL = ptrL.assumingMemoryBound(to: Float.self)
                let fR = ptrR.assumingMemoryBound(to: Float.self)
                for i in 0..<numFrames { left.append(fL[i]); right.append(fR[i]) }
                return (left, right)
            } else if isSignedInt && asbd.mBitsPerChannel == 16 {
                let sL = ptrL.assumingMemoryBound(to: Int16.self)
                let sR = ptrR.assumingMemoryBound(to: Int16.self)
                let scale: Float = 1.0 / 32768.0
                for i in 0..<numFrames { left.append(Float(sL[i]) * scale); right.append(Float(sR[i]) * scale) }
                return (left, right)
            }
        } else if !isNonInterleaved && buffers.count >= 1, let ptr = buffers[0].mData {
            if isFloat && asbd.mBitsPerChannel == 32 {
                let f = ptr.assumingMemoryBound(to: Float.self)
                for i in 0..<numFrames { left.append(f[i * 2]); right.append(f[i * 2 + 1]) }
                return (left, right)
            } else if isSignedInt && asbd.mBitsPerChannel == 16 {
                let s = ptr.assumingMemoryBound(to: Int16.self)
                let scale: Float = 1.0 / 32768.0
                for i in 0..<numFrames { left.append(Float(s[i * 2]) * scale); right.append(Float(s[i * 2 + 1]) * scale) }
                return (left, right)
            } else if isSignedInt && asbd.mBitsPerChannel == 32 {
                let s = ptr.assumingMemoryBound(to: Int32.self)
                let scale: Float = 1.0 / 2147483648.0
                for i in 0..<numFrames { left.append(Float(s[i * 2]) * scale); right.append(Float(s[i * 2 + 1]) * scale) }
                return (left, right)
            }
        }

        return nil
    }
}

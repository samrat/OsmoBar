import Foundation
import Combine
@preconcurrency import AVFoundation
import AppKit
import OsmoCore

@MainActor
public final class OsmoControllerViewModel: ObservableObject {
    // MARK: - Discovered & Connected Devices
    @Published public private(set) var cameras: [DiscoveredCamera] = []
    @Published public var selectedCameraID: String?
    @Published public private(set) var uvcConnected = false
    @Published public private(set) var uvcError: String?
    @Published public private(set) var uvcCapabilities = UVCCapabilitiesSnapshot()

    @Published public private(set) var bleState: BLEConnectionState = .disconnected
    @Published public private(set) var udpState: UDPDatalinkState = .disconnected

    // MARK: - Telemetry & Audio Meter
    @Published public private(set) var attitude: GimbalAttitude?
    @Published public private(set) var battery: BatteryStatus?
    @Published public private(set) var readback = CameraReadbackState()
    @Published public private(set) var wifiSSID: String = ""

    @Published public var audioMeterEnabled: Bool = true
    @Published public private(set) var audioMeterState: AudioMeterState = .noDevice
    @Published public private(set) var detectedMicSource: DetectedMicSource = .unknown
    @Published public private(set) var audioLevel: Double = 0
    @Published public private(set) var audioPeak: Double = 0
    @Published public private(set) var audioDecibels: Float = -60

    // MARK: - Gimbal Controls State
    @Published public var gimbalSpeedScale: Double = 0.65
    @Published public var isGimbalLocked = false
    @Published public var faceFollowEnabled = false
    @Published public var invertFollowPan = false
    @Published public private(set) var trackedFaceRect: CGRect?
    @Published public var uvcPanDeg: Double = 0
    @Published public var uvcTiltDeg: Double = 0
    @Published public var uvcZoomValue: Double = 100
    @Published public var presets: [GimbalPreset] = []
    @Published public private(set) var activePresetMoveName: String?

    // MARK: - Image & Exposure Controls State
    @Published public var exposureAuto: Bool = true
    @Published public var evThirdStops: Int = 0
    @Published public var manualISO: Pocket3Commands.ManualISO = .auto
    @Published public var isoMax: Pocket3Commands.ISOMax = .iso1600
    @Published public var manualShutter: Pocket3Commands.ManualShutter = .s1_60
    @Published public var uvcExposureTime: Double = 100

    @Published public var whiteBalanceAuto: Bool = true
    @Published public var whiteBalanceKelvin: Double = 5600

    @Published public var brightness: Double = 0
    @Published public var contrast: Double = 0
    @Published public var saturation: Double = 0
    @Published public var sharpness: Double = 0
    @Published public var gain: Double = 0
    @Published public var backlight: Double = 0

    @Published public var colorProfile: Pocket3Commands.ColorProfile = .normal
    @Published public var focusMode: Pocket3Commands.FocusMode = .continuous
    @Published public var productShowcase: Bool = false
    @Published public var proModeEnabled: Bool = true
    @Published public var uvcFocusAuto: Bool = true
    @Published public var uvcFocusAbsolute: Double = 0

    // MARK: - UI State
    @Published public var showLivePreview: Bool = true
    @Published public var mirrorPreview: Bool = true
    @Published public var showFramingGrid: Bool = false
    @Published public var alwaysOnTop: Bool = false
    @Published public private(set) var logs: [DiagnosticLogEntry] = []

    // MARK: - Transports & Shared Capture
    public let cameraSession = CameraSessionManager()
    private let audioMonitor = AudioLevelMonitor()
    private let uvc = UVCController()
    private let ble = Pocket3BLETransport()
    private let udp = Pocket3UDPTransport()

    private var joystickTimer: Timer?
    private var currentJoystickVector: CGPoint = .zero
    private var presetMoveTask: Task<Void, Never>?
    private var lastFaceTrackCommandTime: TimeInterval = 0
    nonisolated(unsafe) private var deviceObservers: [NSObjectProtocol] = []

    public init() {
        presets = GimbalPresetStore.load()
        configureTransports()
        configureFaceTracking()
        configureAudioMonitor()
        registerDeviceNotifications()
        refreshCameras(autoConnect: true)
    }

    deinit {
        for obs in deviceObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Computed Route Indicators

    public var activeGimbalRoute: ControlRoute {
        if udpState.isConnected { return .udpDUML }
        if uvcCapabilities.panTiltAbsolute != nil || uvcCapabilities.supportsPanTiltRelative { return .usbUVC }
        if bleState.isConnected { return .bleDUML }
        return .unavailable
    }

    public var activeImageRoute: ControlRoute {
        if udpState.isConnected { return .udpDUML }
        if hasAnyUVCImageControl { return .usbUVC }
        if bleState.isConnected { return .bleDUML }
        return .unavailable
    }

    public var hasAnyUVCImageControl: Bool {
        uvcCapabilities.exposureAutoSupported
            || uvcCapabilities.exposureTimeAbsolute != nil
            || uvcCapabilities.whiteBalanceAutoSupported
            || uvcCapabilities.whiteBalanceTemperature != nil
            || uvcCapabilities.brightness != nil
            || uvcCapabilities.contrast != nil
            || uvcCapabilities.saturation != nil
            || uvcCapabilities.sharpness != nil
            || uvcCapabilities.gain != nil
    }

    public var selectedCamera: DiscoveredCamera? {
        cameras.first { $0.id == selectedCameraID }
    }

    public var zoomMultiplierDisplay: String {
        guard let z = uvcCapabilities.zoomAbsolute, z.max > z.min else {
            return "1.0×"
        }
        let normalized = (uvcZoomValue - Double(z.min)) / Double(z.max - z.min)
        let factor = 1.0 + normalized * 3.0 // Pocket 3 supports 1x–4x in 1080p UVC
        return String(format: "%.1f×", factor)
    }

    // MARK: - Camera & Transport Discovery

    public func refreshCameras(autoConnect: Bool = false) {
        cameras = UVCController.discoverCameras()
        appendLog("USB: discovered \(cameras.count) camera(s): \(cameras.map(\.name).joined(separator: ", "))")

        if let existing = selectedCameraID, cameras.contains(where: { $0.id == existing }) {
            if autoConnect && !uvcConnected, let cam = cameras.first(where: { $0.id == existing }) {
                connectUVC(to: cam)
            }
            return
        }

        if let preferred = cameras.first(where: \.isDJI) ?? cameras.first {
            selectedCameraID = preferred.id
            cameraSession.setCamera(uniqueID: preferred.id)
            if autoConnect {
                connectUVC(to: preferred)
            }
        } else {
            selectedCameraID = nil
            cameraSession.setCamera(uniqueID: nil)
            disconnectUVC()
        }
    }

    public func selectCamera(_ cameraID: String) {
        selectedCameraID = cameraID
        cameraSession.setCamera(uniqueID: cameraID)
        guard let camera = cameras.first(where: { $0.id == cameraID }) else { return }
        connectUVC(to: camera)
    }

    public func connectUVC(to camera: DiscoveredCamera) {
        uvcError = nil
        do {
            let caps = try uvc.connect(to: camera)
            uvcCapabilities = caps
            uvcConnected = true
            syncStateFromUVC(caps)
            let names = caps.supportedControlNames
            appendLog("UVC: connected to \(camera.name) (CT=\(caps.descriptor?.cameraTerminalID ?? -1), PU=\(caps.descriptor?.processingUnitID ?? -1)) — controls: \(names.isEmpty ? "none exposed" : names.joined(separator: ", "))")
        } catch {
            uvcConnected = false
            uvcCapabilities = UVCCapabilitiesSnapshot()
            uvcError = "\(error)"
            appendLog("UVC: \(camera.name) — \(error)")
        }
    }

    public func disconnectUVC() {
        uvc.disconnect()
        uvcConnected = false
        uvcCapabilities = UVCCapabilitiesSnapshot()
    }

    public func toggleBLE() {
        if bleState.isConnected || bleState == .scanning || bleState == .connecting || bleState == .awaitingApproval {
            ble.disconnect()
        } else {
            ble.connect()
        }
    }

    public func toggleUDP() {
        if udpState.isConnected || udpState == .connecting {
            udp.disconnect()
        } else {
            udp.connect()
        }
    }

    public func requestPocketWiFiCredentials() {
        ble.requestWiFiCredentials()
    }

    // MARK: - Audio Meter Controls

    public func toggleAudioMeter() {
        audioMeterEnabled.toggle()
        audioMonitor.setEnabled(audioMeterEnabled)
    }

    public func requestMicrophonePermission() {
        audioMonitor.requestPermissionAndStart()
    }

    public var isFlippedUSB: Bool {
        abs(uvcPanDeg) >= 90.0
    }

    // MARK: - Gimbal Actions

    /// Called continuously while dragging the 2D gimbal pad (`x`: -1...1 right, `y`: -1...1 up).
    public func updateJoystick(_ vector: CGPoint) {
        cancelPresetMove()
        if faceFollowEnabled {
            setFaceFollowEnabled(false)
        }
        let wasIdle = (currentJoystickVector == .zero && joystickTimer == nil)
        currentJoystickVector = vector

        if hypot(vector.x, vector.y) < 0.06 {
            if !wasIdle {
                stopJoystick()
            }
            return
        }

        if udpState.isConnected {
            let range = Double(Pocket3Commands.gimbalLinearRange) * gimbalSpeedScale
            let yaw = Pocket3Commands.gimbalNeutral + Int((Double(vector.x) * range).rounded())
            let pitch = Pocket3Commands.gimbalNeutral + Int((Double(vector.y) * range).rounded())
            udp.setJoystickVelocity(pitch: pitch, yaw: yaw)
            return
        }

        // Sync fresh hardware position on drag start so we don't jump from a stale cached angle
        if wasIdle, uvcCapabilities.panTiltAbsolute != nil, let live = uvc.readPanTiltAbsolute() {
            uvcPanDeg = live.panDeg
            uvcTiltDeg = live.tiltDeg
        }

        // Always drive on .common RunLoop mode so the 20 Hz timer fires smoothly DURING mouse drags on macOS!
        if joystickTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stepJoystickTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            joystickTimer = timer
            stepJoystickTick()
        }
    }

    public func stopJoystick() {
        joystickTimer?.invalidate()
        joystickTimer = nil
        currentJoystickVector = .zero

        if udpState.isConnected {
            udp.releaseJoystick()
        }
        // Hold fresh UVC hardware position on release so the Pocket 3 stops immediately instead of coasting
        if uvcCapabilities.panTiltAbsolute != nil, let observed = uvc.readPanTiltAbsolute() {
            uvcPanDeg = observed.panDeg
            uvcTiltDeg = observed.tiltDeg
            _ = uvc.setPanTiltAbsolute(panDeg: observed.panDeg, tiltDeg: observed.tiltDeg)
        }
        if bleState.isConnected && !udpState.isConnected {
            _ = ble.send(Pocket3Commands.gimbalVelocity(
                pitch: Pocket3Commands.gimbalNeutral,
                yaw: Pocket3Commands.gimbalNeutral
            ))
        }
    }

    public func nudgeGimbal(dx: Double, dy: Double) {
        cancelPresetMove()
        if let pt = uvcCapabilities.panTiltAbsolute {
            if let live = uvc.readPanTiltAbsolute() {
                uvcPanDeg = live.panDeg
                uvcTiltDeg = live.tiltDeg
            }
            let step = max(2.0, 8.0 * gimbalSpeedScale)
            let newPan = max(pt.panMinDeg, min(pt.panMaxDeg, uvcPanDeg + dx * step))
            let newTilt = max(pt.tiltMinDeg, min(pt.tiltMaxDeg, uvcTiltDeg + dy * step))
            setUVCPanTilt(panDeg: newPan, tiltDeg: newTilt)
            return
        }

        // Pulse velocity for 180 ms over UDP or BLE DUML
        let range = Double(Pocket3Commands.gimbalLinearRange) * max(0.35, gimbalSpeedScale)
        let yaw = Pocket3Commands.gimbalNeutral + Int((dx * range).rounded())
        let pitch = Pocket3Commands.gimbalNeutral + Int((dy * range).rounded())

        if udpState.isConnected {
            udp.setJoystickVelocity(pitch: pitch, yaw: yaw)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.udp.releaseJoystick()
            }
        } else if bleState.isConnected {
            _ = ble.send(Pocket3Commands.gimbalVelocity(pitch: pitch, yaw: yaw))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                _ = self?.ble.send(Pocket3Commands.gimbalVelocity(
                    pitch: Pocket3Commands.gimbalNeutral,
                    yaw: Pocket3Commands.gimbalNeutral
                ))
            }
        }
    }

    public func setUVCPanTilt(panDeg: Double, tiltDeg: Double) {
        uvcPanDeg = panDeg
        uvcTiltDeg = tiltDeg
        _ = uvc.setPanTiltAbsolute(panDeg: panDeg, tiltDeg: tiltDeg)
    }

    public func recenterGimbal() {
        cancelPresetMove()
        if faceFollowEnabled { setFaceFollowEnabled(false) }
        if udpState.isConnected {
            sendDumlCommand(Pocket3Commands.gimbalRecenter())
            return
        }
        if let pt = uvcCapabilities.panTiltAbsolute {
            startUVCSmoothMove(
                label: "Recenter",
                targetPan: pt.panDefaultDeg,
                targetTilt: pt.tiltDefaultDeg
            )
            return
        }
        sendDumlCommand(Pocket3Commands.gimbalRecenter())
    }

    public func flipCamera() {
        cancelPresetMove()
        if faceFollowEnabled { setFaceFollowEnabled(false) }
        if udpState.isConnected {
            sendDumlCommand(Pocket3Commands.gimbalSelfieFlip())
            return
        }
        // Over USB UVC on Osmo Pocket 3, pan range spans -35°...+215° (or ±180°).
        // Continuously approaching pan = +180° <-> 0° physically rotates the camera front/back!
        if let pt = uvcCapabilities.panTiltAbsolute {
            if let live = uvc.readPanTiltAbsolute() {
                uvcPanDeg = live.panDeg
                uvcTiltDeg = live.tiltDeg
            }
            let flipTargetPan: Double
            if abs(uvcPanDeg) >= 90.0 {
                flipTargetPan = pt.panDefaultDeg // back to 0° (Front)
            } else if pt.panMaxDeg >= 170.0 {
                flipTargetPan = min(180.0, pt.panMaxDeg)
            } else if pt.panMinDeg <= -170.0 {
                flipTargetPan = max(-180.0, pt.panMinDeg)
            } else {
                // Fallback to whichever extreme is farthest if firmware reports a narrower range
                flipTargetPan = abs(pt.panMaxDeg) >= abs(pt.panMinDeg) ? pt.panMaxDeg : pt.panMinDeg
            }
            appendLog(String(format: "UVC: Flip camera %.1f° → %.1f°", uvcPanDeg, flipTargetPan))
            startUVCSmoothMove(
                label: flipTargetPan == pt.panDefaultDeg ? "Front" : "Flip 180°",
                targetPan: flipTargetPan,
                targetTilt: pt.tiltDefaultDeg
            )
            return
        }
        sendDumlCommand(Pocket3Commands.gimbalSelfieFlip())
    }

    public func setFaceFollowEnabled(_ enabled: Bool) {
        guard faceFollowEnabled != enabled else { return }
        faceFollowEnabled = enabled
        cameraSession.setFaceTrackingEnabled(enabled)
        if enabled {
            cancelPresetMove()
            if uvcCapabilities.panTiltAbsolute != nil, let live = uvc.readPanTiltAbsolute() {
                uvcPanDeg = live.panDeg
                uvcTiltDeg = live.tiltDeg
            }
            appendLog("Face Follow: enabled (macOS Vision tracking)")
        } else {
            trackedFaceRect = nil
            if udpState.isConnected {
                udp.releaseJoystick()
            } else if uvcCapabilities.panTiltAbsolute != nil, let live = uvc.readPanTiltAbsolute() {
                uvcPanDeg = live.panDeg
                uvcTiltDeg = live.tiltDeg
                _ = uvc.setPanTiltAbsolute(panDeg: live.panDeg, tiltDeg: live.tiltDeg)
            }
            appendLog("Face Follow: disabled")
        }
    }

    public func setGimbalLocked(_ locked: Bool) {
        guard udpState.isConnected else {
            appendLog("Hardware Gimbal Lock requires Pocket 3 Wi-Fi Datalink (UDP 192.168.2.1)")
            return
        }
        isGimbalLocked = locked
        sendDumlCommand(Pocket3Commands.gimbalLock(locked))
    }

    // MARK: - Presets

    public func saveCurrentAsPreset(name: String, symbolName: String = "viewfinder") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = GimbalPreset(
            name: trimmed,
            symbolName: symbolName,
            uvcPanDeg: uvcCapabilities.panTiltAbsolute != nil ? uvcPanDeg : nil,
            uvcTiltDeg: uvcCapabilities.panTiltAbsolute != nil ? uvcTiltDeg : nil,
            uvcZoom: uvcCapabilities.zoomAbsolute != nil ? Int(uvcZoomValue.rounded()) : nil,
            dumlPitchDeg: attitude?.pitchDeg,
            dumlYawDeg: attitude?.continuousYawDeg
        )
        presets.append(preset)
        GimbalPresetStore.save(presets)
        appendLog("Preset saved: \"\(trimmed)\"")
    }

    public func deletePreset(_ preset: GimbalPreset) {
        presets.removeAll { $0.id == preset.id }
        GimbalPresetStore.save(presets)
    }

    public func applyPreset(_ preset: GimbalPreset) {
        cancelPresetMove()
        appendLog("Preset recalled: \"\(preset.name)\"")

        if let zoom = preset.uvcZoom, uvcCapabilities.zoomAbsolute != nil {
            setZoom(Double(zoom))
        }
        if let pan = preset.uvcPanDeg, let tilt = preset.uvcTiltDeg, uvcCapabilities.panTiltAbsolute != nil {
            startUVCSmoothMove(label: preset.name, targetPan: pan, targetTilt: tilt)
            return
        }

        // Closed-loop smooth DUML glide when UDP datalink + live 04/05 telemetry are available
        if udpState.isConnected,
           let targetPitch = preset.dumlPitchDeg,
           let targetYaw = preset.dumlYawDeg,
           attitude != nil {
            activePresetMoveName = preset.name
            presetMoveTask = Task { [weak self] in
                await self?.runClosedLoopMove(targetPitch: targetPitch, targetYaw: targetYaw)
            }
        }
    }

    public func cancelPresetMove() {
        presetMoveTask?.cancel()
        presetMoveTask = nil
        if activePresetMoveName != nil {
            activePresetMoveName = nil
            if udpState.isConnected {
                udp.releaseJoystick()
            }
            if uvcCapabilities.panTiltAbsolute != nil, let observed = uvc.readPanTiltAbsolute() {
                uvcPanDeg = observed.panDeg
                uvcTiltDeg = observed.tiltDeg
                _ = uvc.setPanTiltAbsolute(panDeg: observed.panDeg, tiltDeg: observed.tiltDeg)
            }
        }
    }

    // MARK: - Zoom & Image Controls

    public func setZoom(_ rawValue: Double) {
        uvcZoomValue = rawValue
        _ = uvc.setZoomAbsolute(Int(rawValue.rounded()))
    }

    public func setZoomFactor(_ factor: Double) {
        guard let z = uvcCapabilities.zoomAbsolute, z.max > z.min else { return }
        let clamped = max(1.0, min(4.0, factor))
        let normalized = (clamped - 1.0) / 3.0
        let raw = Double(z.min) + normalized * Double(z.max - z.min)
        setZoom(raw)
    }

    public func setExposureAuto(_ auto: Bool) {
        exposureAuto = auto
        if uvcCapabilities.exposureAutoSupported {
            _ = uvc.setExposureAuto(auto)
        }
        sendDumlCommand(Pocket3Commands.exposureMode(auto ? .auto : .manual))
    }

    public func setEVThirdStops(_ stops: Int) {
        let clamped = max(-9, min(9, stops))
        evThirdStops = clamped
        if let cmd = Pocket3Commands.autoEV(thirdStops: clamped) {
            sendDumlCommand(cmd)
        }
    }

    public func setManualISO(_ iso: Pocket3Commands.ManualISO) {
        manualISO = iso
        sendDumlCommand(Pocket3Commands.manualISO(iso))
    }

    public func setISOMax(_ maxISO: Pocket3Commands.ISOMax) {
        isoMax = maxISO
        sendDumlCommand(Pocket3Commands.isoMax(maxISO))
    }

    public func setManualShutter(_ shutter: Pocket3Commands.ManualShutter) {
        manualShutter = shutter
        sendDumlCommand(Pocket3Commands.manualShutter(shutter))
    }

    public func setUVCExposureTime(_ value: Double) {
        uvcExposureTime = value
        if exposureAuto && uvcCapabilities.exposureAutoSupported {
            exposureAuto = false
            _ = uvc.setExposureAuto(false)
        }
        _ = uvc.setExposureTimeAbsolute(Int(value.rounded()))
    }

    public func setWhiteBalanceAuto(_ auto: Bool) {
        whiteBalanceAuto = auto
        if uvcCapabilities.whiteBalanceAutoSupported {
            _ = uvc.setWhiteBalanceAuto(auto)
        }
        if auto, let cmd = Pocket3Commands.whiteBalance(.auto) {
            sendDumlCommand(cmd)
        } else if !auto, let cmd = Pocket3Commands.whiteBalance(.customKelvin(Int(whiteBalanceKelvin))) {
            sendDumlCommand(cmd)
        }
    }

    public func setWhiteBalanceKelvin(_ kelvin: Double) {
        let snapped = (kelvin / 100.0).rounded() * 100.0
        whiteBalanceKelvin = max(2000, min(10_000, snapped))
        if whiteBalanceAuto {
            whiteBalanceAuto = false
            if uvcCapabilities.whiteBalanceAutoSupported {
                _ = uvc.setWhiteBalanceAuto(false)
            }
        }
        if uvcCapabilities.whiteBalanceTemperature != nil {
            _ = uvc.setWhiteBalanceTemperature(Int(whiteBalanceKelvin))
        }
        if let cmd = Pocket3Commands.whiteBalance(.customKelvin(Int(whiteBalanceKelvin))) {
            sendDumlCommand(cmd)
        }
    }

    public func setBrightness(_ value: Double) {
        brightness = value
        _ = uvc.setBrightness(Int(value.rounded()))
    }

    public func setContrast(_ value: Double) {
        contrast = value
        _ = uvc.setContrast(Int(value.rounded()))
    }

    public func setSaturation(_ value: Double) {
        saturation = value
        _ = uvc.setSaturation(Int(value.rounded()))
    }

    public func setSharpness(_ value: Double) {
        sharpness = value
        _ = uvc.setSharpness(Int(value.rounded()))
    }

    public func setGain(_ value: Double) {
        gain = value
        _ = uvc.setGain(Int(value.rounded()))
    }

    public func setBacklight(_ value: Double) {
        backlight = value
        _ = uvc.setBacklightCompensation(Int(value.rounded()))
    }

    public func setUVCFocusAuto(_ auto: Bool) {
        uvcFocusAuto = auto
        _ = uvc.setFocusAuto(auto)
    }

    public func setUVCFocusAbsolute(_ value: Double) {
        uvcFocusAbsolute = value
        if uvcFocusAuto {
            uvcFocusAuto = false
            _ = uvc.setFocusAuto(false)
        }
        _ = uvc.setFocusAbsolute(Int(value.rounded()))
    }

    public func setColorProfile(_ profile: Pocket3Commands.ColorProfile) {
        colorProfile = profile
        sendDumlCommand(Pocket3Commands.colorProfile(profile))
    }

    public func setFocusMode(_ mode: Pocket3Commands.FocusMode) {
        focusMode = mode
        sendDumlCommand(Pocket3Commands.focusMode(mode))
    }

    public func setProductShowcase(_ enabled: Bool) {
        productShowcase = enabled
        sendDumlCommand(Pocket3Commands.productShowcaseEnabled(enabled))
    }

    public func setProMode(_ enabled: Bool) {
        proModeEnabled = enabled
        sendDumlCommand(Pocket3Commands.proEnabled(enabled))
    }

    public func resetAllImageControls() {
        if let b = uvcCapabilities.brightness { setBrightness(Double(b.defaultValue)) }
        if let c = uvcCapabilities.contrast { setContrast(Double(c.defaultValue)) }
        if let s = uvcCapabilities.saturation { setSaturation(Double(s.defaultValue)) }
        if let sh = uvcCapabilities.sharpness { setSharpness(Double(sh.defaultValue)) }
        if let g = uvcCapabilities.gain { setGain(Double(g.defaultValue)) }
        if let bl = uvcCapabilities.backlightCompensation { setBacklight(Double(bl.defaultValue)) }
        if let z = uvcCapabilities.zoomAbsolute { setZoom(Double(z.defaultValue)) }
        setExposureAuto(true)
        setEVThirdStops(0)
        setWhiteBalanceAuto(true)
        appendLog("Reset image controls to defaults")
    }

    public func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Private Transport Wiring

    private func configureTransports() {
        ble.onStateChange = { [weak self] newState in
            self?.bleState = newState
        }
        ble.onGimbalAttitude = { [weak self] att in
            guard let self, !self.udpState.isConnected else { return }
            self.attitude = att
            self.isGimbalLocked = att.isLockedObserved
        }
        ble.onBatteryStatus = { [weak self] bat in
            self?.battery = bat
        }
        ble.onCameraPropertyPush = { [weak self] payload in
            self?.applyReadbackPush(payload)
        }
        ble.onWiFiCredentials = { [weak self] ssid, _ in
            self?.wifiSSID = ssid
        }
        ble.onLog = { [weak self] msg in
            self?.appendLog(msg)
        }

        udp.onStateChange = { [weak self] newState in
            Task { @MainActor in self?.udpState = newState }
        }
        udp.onGimbalAttitude = { [weak self] att in
            Task { @MainActor in
                self?.attitude = att
                self?.isGimbalLocked = att.isLockedObserved
            }
        }
        udp.onBatteryStatus = { [weak self] bat in
            Task { @MainActor in self?.battery = bat }
        }
        udp.onCameraPropertyPush = { [weak self] payload in
            Task { @MainActor in self?.applyReadbackPush(payload) }
        }
        udp.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
    }

    private func configureFaceTracking() {
        cameraSession.onFaceDetected = { [weak self] rect in
            Task { @MainActor [weak self] in
                self?.handleTrackedFace(rect)
            }
        }
    }

    private func handleTrackedFace(_ rect: CGRect?) {
        trackedFaceRect = rect
        guard faceFollowEnabled else { return }

        guard let rect else {
            if udpState.isConnected {
                udp.releaseJoystick()
            }
            return
        }

        // Vision rect is normalized bottom-left origin: (0,0)=bottom-left, (1,1)=top-right.
        // Aim face center slightly above vertical midpoint (0.54) for natural webcam headroom.
        let targetX = 0.50
        let targetY = 0.54
        let rawErrX = Double(rect.midX) - targetX
        let errX = invertFollowPan ? -rawErrX : rawErrX
        let errY = Double(rect.midY) - targetY

        let deadbandX = 0.08
        let deadbandY = 0.07
        let activeErrX = abs(errX) > deadbandX ? errX : 0.0
        let activeErrY = abs(errY) > deadbandY ? errY : 0.0

        if activeErrX == 0 && activeErrY == 0 {
            if udpState.isConnected {
                udp.releaseJoystick()
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFaceTrackCommandTime >= 0.09 else { return }
        lastFaceTrackCommandTime = now

        if udpState.isConnected {
            let maxOff = Double(Pocket3Commands.gimbalLinearRange) * 0.75 * gimbalSpeedScale
            let yawOff = Int((max(-1.0, min(1.0, activeErrX * 2.4)) * maxOff).rounded())
            let pitchOff = Int((max(-1.0, min(1.0, activeErrY * 2.4)) * maxOff).rounded())
            udp.setJoystickVelocity(
                pitch: Pocket3Commands.gimbalNeutral + pitchOff,
                yaw: Pocket3Commands.gimbalNeutral + yawOff
            )
            return
        }

        if let pt = uvcCapabilities.panTiltAbsolute {
            let observed = uvc.readPanTiltAbsolute() ?? (uvcPanDeg, uvcTiltDeg)
            // Damped proportional step: up to ~4° per tick at edge of frame, scaled by speed slider
            let gainDeg = 14.0 * max(0.35, gimbalSpeedScale)
            let deltaPan = max(-4.5, min(4.5, activeErrX * gainDeg))
            let deltaTilt = max(-3.5, min(3.5, activeErrY * gainDeg))

            let nextPan = max(pt.panMinDeg, min(pt.panMaxDeg, observed.panDeg + deltaPan))
            let nextTilt = max(pt.tiltMinDeg, min(pt.tiltMaxDeg, observed.tiltDeg + deltaTilt))
            setUVCPanTilt(panDeg: nextPan, tiltDeg: nextTilt)
        }
    }

    private func configureAudioMonitor() {
        audioMonitor.onUpdate = { [weak self] level, peak, db, state, source in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioLevel = level
                self.audioPeak = peak
                self.audioDecibels = db
                self.audioMeterState = state
                self.detectedMicSource = source
            }
        }
        audioMonitor.onLog = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.appendLog(msg)
            }
        }
        audioMonitor.requestPermissionAndStart()
    }

    private func registerDeviceNotifications() {
        let nc = NotificationCenter.default
        let c1 = nc.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCameras(autoConnect: true)
                self?.audioMonitor.refresh()
            }
        }
        let c2 = nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCameras(autoConnect: true)
                self?.audioMonitor.refresh()
            }
        }
        deviceObservers = [c1, c2]
    }

    private func syncStateFromUVC(_ caps: UVCCapabilitiesSnapshot) {
        if let pt = caps.panTiltAbsolute {
            uvcPanDeg = pt.panDeg
            uvcTiltDeg = pt.tiltDeg
        }
        if let z = caps.zoomAbsolute { uvcZoomValue = Double(z.current) }
        if caps.exposureAutoSupported { exposureAuto = caps.exposureAuto }
        if let exp = caps.exposureTimeAbsolute { uvcExposureTime = Double(exp.current) }
        if caps.whiteBalanceAutoSupported { whiteBalanceAuto = caps.whiteBalanceAuto }
        if let wb = caps.whiteBalanceTemperature { whiteBalanceKelvin = Double(wb.current) }
        if let b = caps.brightness { brightness = Double(b.current) }
        if let c = caps.contrast { contrast = Double(c.current) }
        if let s = caps.saturation { saturation = Double(s.current) }
        if let sh = caps.sharpness { sharpness = Double(sh.current) }
        if let g = caps.gain { gain = Double(g.current) }
        if let bl = caps.backlightCompensation { backlight = Double(bl.current) }
        if caps.focusAutoSupported { uvcFocusAuto = caps.focusAuto }
        if let f = caps.focusAbsolute { uvcFocusAbsolute = Double(f.current) }
    }

    private func applyReadbackPush(_ payload: Data) {
        guard readback.applyPropertyPush(payload) else { return }
        if let mode = readback.exposureMode { exposureAuto = (mode == .auto) }
        if let ev = readback.evThirdStops { evThirdStops = ev }
        if let wb = readback.whiteBalance {
            switch wb {
            case .auto:
                whiteBalanceAuto = true
            case .customKelvin(let k):
                whiteBalanceAuto = false
                whiteBalanceKelvin = Double(k)
            }
        }
        if let profile = readback.colorProfile { colorProfile = profile }
        if let focus = readback.focusMode { focusMode = focus }
    }

    private func sendDumlCommand(_ command: Pocket3Command) {
        if udpState.isConnected {
            udp.enqueue(command)
            appendLog("UDP TX: \(command.label)")
        } else if bleState.isConnected {
            let ok = ble.send(command)
            appendLog("BLE TX: \(command.label) (\(ok ? "sent" : "failed"))")
        } else {
            appendLog("Skipped DUML (\(command.label)) — connect BLE or Wi-Fi Datalink")
        }
    }

    private func stepJoystickTick() {
        let v = currentJoystickVector
        guard hypot(v.x, v.y) >= 0.06 else { return }

        if let pt = uvcCapabilities.panTiltAbsolute {
            let observed = uvc.readPanTiltAbsolute() ?? (uvcPanDeg, uvcTiltDeg)
            // Bounded-lead step: up to ~3.5° per 50 ms tick (~70°/sec max), clamped within ±12° of observed hardware position
            let maxLeadDeg = 12.0
            let stepPerTick = 3.5 * gimbalSpeedScale
            let rawNextPan = uvcPanDeg + Double(v.x) * stepPerTick
            let rawNextTilt = uvcTiltDeg + Double(v.y) * stepPerTick

            let leadPan = max(observed.panDeg - maxLeadDeg, min(observed.panDeg + maxLeadDeg, rawNextPan))
            let leadTilt = max(observed.tiltDeg - maxLeadDeg, min(observed.tiltDeg + maxLeadDeg, rawNextTilt))

            let nextPan = max(pt.panMinDeg, min(pt.panMaxDeg, leadPan))
            let nextTilt = max(pt.tiltMinDeg, min(pt.tiltMaxDeg, leadTilt))
            setUVCPanTilt(panDeg: nextPan, tiltDeg: nextTilt)
        } else if bleState.isConnected {
            let range = Double(Pocket3Commands.gimbalLinearRange) * gimbalSpeedScale
            let yaw = Pocket3Commands.gimbalNeutral + Int((Double(v.x) * range).rounded())
            let pitch = Pocket3Commands.gimbalNeutral + Int((Double(v.y) * range).rounded())
            _ = ble.send(Pocket3Commands.gimbalVelocity(pitch: pitch, yaw: yaw))
        }
    }

    /// Continuously approaches a UVC absolute Pan/Tilt target using bounded-lead increments.
    /// Pocket 3 firmware ignores or drops huge single-shot jumps like 0° -> 180°; stepping with a
    /// bounded lead relative to hardware GET_CUR reaches 180° (Flip) and 0° (Recenter) reliably.
    private func startUVCSmoothMove(label: String, targetPan: Double, targetTilt: Double) {
        guard let pt = uvcCapabilities.panTiltAbsolute else { return }
        let clampedPan = max(pt.panMinDeg, min(pt.panMaxDeg, targetPan))
        let clampedTilt = max(pt.tiltMinDeg, min(pt.tiltMaxDeg, targetTilt))

        activePresetMoveName = label
        presetMoveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activePresetMoveName = nil }

            let deadline = Date().addingTimeInterval(8.0)
            let maxLeadDeg = 18.0
            var stableTicks = 0

            while !Task.isCancelled && Date() < deadline {
                let observed = self.uvc.readPanTiltAbsolute() ?? (self.uvcPanDeg, self.uvcTiltDeg)
                self.uvcPanDeg = observed.panDeg
                self.uvcTiltDeg = observed.tiltDeg

                let panErr = clampedPan - observed.panDeg
                let tiltErr = clampedTilt - observed.tiltDeg
                let dist = hypot(panErr, tiltErr)

                if dist <= 1.2 {
                    _ = self.uvc.setPanTiltAbsolute(panDeg: clampedPan, tiltDeg: clampedTilt)
                    self.uvcPanDeg = clampedPan
                    self.uvcTiltDeg = clampedTilt
                    stableTicks += 1
                    if stableTicks >= 2 { break }
                } else {
                    stableTicks = 0
                    let stepScale = min(1.0, maxLeadDeg / dist)
                    let nextPan = observed.panDeg + panErr * stepScale
                    let nextTilt = observed.tiltDeg + tiltErr * stepScale
                    _ = self.uvc.setPanTiltAbsolute(panDeg: nextPan, tiltDeg: nextTilt)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func runClosedLoopMove(targetPitch: Double, targetYaw: Double) async {
        defer {
            udp.releaseJoystick()
            activePresetMoveName = nil
        }
        let deadline = Date().addingTimeInterval(8.0)
        var settled = 0

        while !Task.isCancelled && Date() < deadline && udpState.isConnected {
            guard let att = attitude else {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            let pitchErr = targetPitch - att.pitchDeg
            let yawErr = targetYaw - att.continuousYawDeg
            if abs(pitchErr) < 0.8 && abs(yawErr) < 0.8 {
                settled += 1
                udp.releaseJoystick()
                if settled >= 3 { break }
            } else {
                settled = 0
                let pOff = proportionalOffset(errorDeg: pitchErr)
                let yOff = proportionalOffset(errorDeg: yawErr)
                udp.setJoystickVelocity(
                    pitch: Pocket3Commands.gimbalNeutral + pOff,
                    yaw: Pocket3Commands.gimbalNeutral + yOff
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func proportionalOffset(errorDeg: Double) -> Int {
        guard abs(errorDeg) >= 0.8 else { return 0 }
        let mag = min(380.0, max(48.0, abs(errorDeg) * 6.0))
        return Int((errorDeg >= 0 ? mag : -mag).rounded())
    }

    private func appendLog(_ message: String) {
        logs.append(DiagnosticLogEntry(message: message))
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }
}

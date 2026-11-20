import SwiftUI
import AppKit
import OsmoCore

private enum ControlTab: String, CaseIterable, Identifiable {
    case gimbal = "Gimbal & Presets"
    case image = "Image & Exposure"
    case diagnostics = "Transports"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .gimbal: return "gyroscope"
        case .image: return "slider.horizontal.3"
        case .diagnostics: return "antenna.radiowaves.left.and.right"
        }
    }
}

struct ControlWindowView: View {
    @ObservedObject var vm: OsmoControllerViewModel
    @State private var selectedTab: ControlTab = .gimbal
    @State private var newPresetName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                StatusHeaderView(vm: vm)

                Divider().frame(height: 18)

                Toggle(isOn: $vm.showLivePreview) {
                    Label("Preview", systemImage: "video")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Toggle(isOn: $vm.alwaysOnTop) {
                    Image(systemName: vm.alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Keep window floating above other apps")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Live preview right at the top of the Studio Window (with mirror & grid overlays)
            if vm.showLivePreview {
                ZStack(alignment: .bottomTrailing) {
                    CameraPreviewView(
                        sessionManager: vm.cameraSession,
                        hasCamera: vm.selectedCameraID != nil,
                        mirrored: vm.mirrorPreview,
                        showGrid: vm.showFramingGrid,
                        trackedFaceRect: vm.faceFollowEnabled ? vm.trackedFaceRect : nil
                    )
                    .frame(height: 230)

                    HStack(spacing: 6) {
                        Button {
                            vm.mirrorPreview.toggle()
                        } label: {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(vm.mirrorPreview ? Color.accentColor : .white)
                        }
                        .buttonStyle(.plain)
                        .help(vm.mirrorPreview ? "Mirror preview: On" : "Mirror preview: Off")

                        Button {
                            vm.showFramingGrid.toggle()
                        } label: {
                            Image(systemName: "grid")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(vm.showFramingGrid ? Color.accentColor : .white)
                        }
                        .buttonStyle(.plain)
                        .help("Toggle rule-of-thirds grid")
                    }
                    .padding(8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Live Osmo Pocket 3 USB audio level meter + DJI Mic detection
            AudioLevelBarView(
                state: vm.audioMeterState,
                micSource: vm.detectedMicSource,
                level: vm.audioLevel,
                peak: vm.audioPeak,
                decibels: vm.audioDecibels,
                isEnabled: vm.audioMeterEnabled,
                onToggleEnabled: { vm.toggleAudioMeter() },
                onRequestPermission: { vm.requestMicrophonePermission() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Tab selector
            Picker("", selection: $selectedTab) {
                ForEach(ControlTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Main content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .gimbal:
                        gimbalTab
                    case .image:
                        imageTab
                    case .diagnostics:
                        diagnosticsTab
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 580)
        .background(WindowLevelConfigurator(floating: vm.alwaysOnTop))
        .onKeyPress(.upArrow) { vm.nudgeGimbal(dx: 0, dy: 1); return .handled }
        .onKeyPress(.downArrow) { vm.nudgeGimbal(dx: 0, dy: -1); return .handled }
        .onKeyPress(.leftArrow) { vm.nudgeGimbal(dx: -1, dy: 0); return .handled }
        .onKeyPress(.rightArrow) { vm.nudgeGimbal(dx: 1, dy: 0); return .handled }
    }

    // MARK: - Tab 1: Gimbal & Presets

    private var gimbalTab: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                // Left: Interactive Gimbal Pad
                VStack(spacing: 16) {
                    HStack {
                        Text("Gimbal Steering")
                            .font(.headline)
                        Spacer()
                        RouteBadge(
                            route: vm.activeGimbalRoute.rawValue,
                            isActive: vm.activeGimbalRoute != .unavailable
                        )
                    }

                    GimbalPadView(
                        size: 196,
                        pitchDeg: vm.attitude?.pitchDeg ?? (vm.uvcCapabilities.panTiltAbsolute != nil ? vm.uvcTiltDeg : nil),
                        yawDeg: vm.attitude?.wrappedYawDeg ?? (vm.uvcCapabilities.panTiltAbsolute != nil ? vm.uvcPanDeg : nil),
                        isEnabled: vm.activeGimbalRoute != .unavailable,
                        onVectorChange: { vm.updateJoystick($0) },
                        onRelease: { vm.stopJoystick() },
                        onNudge: { dx, dy in vm.nudgeGimbal(dx: dx, dy: dy) }
                    )
                    .padding(.vertical, 4)

                    ControlSliderRow(
                        title: "Steering Speed",
                        valueText: "\(Int((vm.gimbalSpeedScale * 100).rounded()))%",
                        value: $vm.gimbalSpeedScale,
                        range: 0.2...1.0,
                        defaultValue: 0.65,
                        onEditingValue: { _ in }
                    )
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)

                // Right: Actions, Zoom & UVC Pan/Tilt Sliders
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Actions")
                        .font(.headline)

                    HStack(spacing: 8) {
                        actionTile("Recenter", icon: "scope") {
                            vm.recenterGimbal()
                        }
                        actionTile(
                            vm.isFlippedUSB ? "Front" : "Flip 180°",
                            icon: "arrow.triangle.2.circlepath.camera",
                            highlighted: vm.isFlippedUSB
                        ) {
                            vm.flipCamera()
                        }
                        actionTile(
                            vm.faceFollowEnabled ? "Following" : "Face Follow",
                            icon: vm.faceFollowEnabled ? "person.crop.rectangle.fill" : "person.crop.rectangle",
                            highlighted: vm.faceFollowEnabled
                        ) {
                            vm.setFaceFollowEnabled(!vm.faceFollowEnabled)
                        }
                    }

                    if vm.faceFollowEnabled {
                        Toggle("Invert Face Follow Pan", isOn: $vm.invertFollowPan)
                            .controlSize(.small)
                            .font(.system(size: 11))
                    }

                    if vm.udpState.isConnected {
                        Toggle("Hardware Gimbal Lock (DUML)", isOn: Binding(
                            get: { vm.isGimbalLocked },
                            set: { vm.setGimbalLocked($0) }
                        ))
                        .controlSize(.small)
                        .font(.system(size: 11))
                    }

                    Divider()

                    // Zoom Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Zoom")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(vm.zoomMultiplierDisplay)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if let z = vm.uvcCapabilities.zoomAbsolute, z.max > z.min {
                            Slider(
                                value: Binding(
                                    get: { vm.uvcZoomValue },
                                    set: { vm.setZoom($0) }
                                ),
                                in: Double(z.min)...Double(z.max),
                                step: Double(z.step)
                            )
                            .controlSize(.small)

                            HStack(spacing: 6) {
                                ForEach([1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { f in
                                    Button(String(format: f == floor(f) ? "%.0f×" : "%.1f×", f)) {
                                        vm.setZoomFactor(f)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        } else {
                            Text("Plug in Osmo Pocket 3 in Webcam mode for hardware UVC zoom.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Absolute Pan/Tilt sliders when UVC exposes CT_PANTILT_ABSOLUTE
                    if let pt = vm.uvcCapabilities.panTiltAbsolute {
                        Divider()
                        ControlSliderRow(
                            title: "Pan (UVC)",
                            valueText: String(format: "%+.1f°", vm.uvcPanDeg),
                            value: $vm.uvcPanDeg,
                            range: pt.panMinDeg...pt.panMaxDeg,
                            defaultValue: pt.panDefaultDeg,
                            onEditingValue: { vm.setUVCPanTilt(panDeg: $0, tiltDeg: vm.uvcTiltDeg) }
                        )
                        ControlSliderRow(
                            title: "Tilt (UVC)",
                            valueText: String(format: "%+.1f°", vm.uvcTiltDeg),
                            value: $vm.uvcTiltDeg,
                            range: pt.tiltMinDeg...pt.tiltMaxDeg,
                            defaultValue: pt.tiltDefaultDeg,
                            onEditingValue: { vm.setUVCPanTilt(panDeg: vm.uvcPanDeg, tiltDeg: $0) }
                        )
                    }

                    if let att = vm.attitude {
                        Divider()
                        HStack {
                            telemetryPill("Pitch", String(format: "%+.1f°", att.pitchDeg))
                            telemetryPill("Roll", String(format: "%+.1f°", att.rollDeg))
                            telemetryPill("Yaw", String(format: "%+.1f°", att.wrappedYawDeg))
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)
            }

            // Saved Angle Presets Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Angle Presets")
                        .font(.headline)
                    Spacer()
                    if let moving = vm.activePresetMoveName {
                        Button("Stop Moving (\(moving))") {
                            vm.cancelPresetMove()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                    ForEach(vm.presets) { preset in
                        HStack(spacing: 6) {
                            Button {
                                vm.applyPreset(preset)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.symbolName)
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(preset.name)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(presetSummary(preset))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                vm.deletePreset(preset)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete preset")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            vm.activePresetMoveName == preset.name
                                ? Color.accentColor.opacity(0.18)
                                : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }

                HStack(spacing: 8) {
                    TextField("New preset name (e.g. Whiteboard)", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Save Current Angle") {
                        vm.saveCurrentAsPreset(name: newPresetName)
                        newPresetName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Tab 2: Image & Exposure

    private var imageTab: some View {
        VStack(spacing: 14) {
            // Exposure Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Exposure")
                        .font(.headline)
                    Spacer()
                    RouteBadge(
                        route: vm.activeImageRoute.rawValue,
                        isActive: vm.activeImageRoute != .unavailable
                    )
                    Toggle("Auto", isOn: Binding(
                        get: { vm.exposureAuto },
                        set: { vm.setExposureAuto($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if vm.exposureAuto {
                    ControlSliderRow(
                        title: "EV Compensation (DUML)",
                        valueText: String(format: "%+.1f EV", Double(vm.evThirdStops) / 3.0),
                        value: Binding(
                            get: { Double(vm.evThirdStops) },
                            set: { vm.setEVThirdStops(Int($0.rounded())) }
                        ),
                        range: -9...9,
                        step: 1,
                        defaultValue: 0,
                        isDisabled: !(vm.udpState.isConnected || vm.bleState.isConnected),
                        onEditingValue: { vm.setEVThirdStops(Int($0.rounded())) }
                    )

                    HStack {
                        Text("ISO Max (DUML)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.isoMax },
                            set: { vm.setISOMax($0) }
                        )) {
                            ForEach(Pocket3Commands.ISOMax.allCases) { iso in
                                Text(iso.displayName).tag(iso)
                            }
                        }
                        .frame(width: 110)
                        .controlSize(.small)
                        .disabled(!(vm.udpState.isConnected || vm.bleState.isConnected))
                    }
                } else {
                    if let exp = vm.uvcCapabilities.exposureTimeAbsolute, exp.max > exp.min {
                        ControlSliderRow(
                            title: "Exposure Time (UVC)",
                            valueText: "\(Int(vm.uvcExposureTime))",
                            value: $vm.uvcExposureTime,
                            range: Double(exp.min)...Double(exp.max),
                            step: Double(exp.step),
                            defaultValue: Double(exp.defaultValue),
                            onEditingValue: { vm.setUVCExposureTime($0) }
                        )
                    }

                    HStack(spacing: 14) {
                        HStack {
                            Text("ISO")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.manualISO },
                                set: { vm.setManualISO($0) }
                            )) {
                                ForEach(Pocket3Commands.ManualISO.allCases) { iso in
                                    Text(iso.displayName).tag(iso)
                                }
                            }
                            .frame(width: 96)
                            .controlSize(.small)
                        }
                        HStack {
                            Text("Shutter")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.manualShutter },
                                set: { vm.setManualShutter($0) }
                            )) {
                                ForEach(Pocket3Commands.ManualShutter.allCases) { sh in
                                    Text(sh.displayName).tag(sh)
                                }
                            }
                            .frame(width: 96)
                            .controlSize(.small)
                        }
                    }
                    .disabled(!(vm.udpState.isConnected || vm.bleState.isConnected))
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            // White Balance Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("White Balance")
                        .font(.headline)
                    Spacer()
                    Toggle("Auto", isOn: Binding(
                        get: { vm.whiteBalanceAuto },
                        set: { vm.setWhiteBalanceAuto($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                // Warm-to-cool Kelvin indicator bar
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.65, blue: 0.30),
                        Color(red: 1.0, green: 0.96, blue: 0.90),
                        Color(red: 0.65, green: 0.82, blue: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 5)
                .clipShape(Capsule())
                .opacity(vm.whiteBalanceAuto ? 0.35 : 0.9)

                ControlSliderRow(
                    title: "Color Temperature",
                    valueText: "\(Int(vm.whiteBalanceKelvin))K",
                    value: $vm.whiteBalanceKelvin,
                    range: wbRange,
                    step: 100,
                    defaultValue: 5600,
                    isDisabled: vm.whiteBalanceAuto,
                    onEditingValue: { vm.setWhiteBalanceKelvin($0) }
                )

                HStack(spacing: 6) {
                    ForEach([("Tungsten", 3200.0), ("Neutral", 4500.0), ("Daylight", 5600.0), ("Cloudy", 6500.0)], id: \.0) { label, kelvin in
                        Button("\(label) \(Int(kelvin))K") {
                            vm.setWhiteBalanceKelvin(kelvin)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            // Brightness, Color & Focus Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Brightness, Color & Focus")
                        .font(.headline)
                    Spacer()
                    Button("Reset All") {
                        vm.resetAllImageControls()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let b = vm.uvcCapabilities.brightness, b.max > b.min {
                    ControlSliderRow(
                        title: "Brightness (UVC)",
                        valueText: "\(Int(vm.brightness))",
                        value: $vm.brightness,
                        range: Double(b.min)...Double(b.max),
                        step: Double(b.step),
                        defaultValue: Double(b.defaultValue),
                        onEditingValue: { vm.setBrightness($0) }
                    )
                }
                if let c = vm.uvcCapabilities.contrast, c.max > c.min {
                    ControlSliderRow(
                        title: "Contrast (UVC)",
                        valueText: "\(Int(vm.contrast))",
                        value: $vm.contrast,
                        range: Double(c.min)...Double(c.max),
                        step: Double(c.step),
                        defaultValue: Double(c.defaultValue),
                        onEditingValue: { vm.setContrast($0) }
                    )
                }
                if let s = vm.uvcCapabilities.saturation, s.max > s.min {
                    ControlSliderRow(
                        title: "Saturation (UVC)",
                        valueText: "\(Int(vm.saturation))",
                        value: $vm.saturation,
                        range: Double(s.min)...Double(s.max),
                        step: Double(s.step),
                        defaultValue: Double(s.defaultValue),
                        onEditingValue: { vm.setSaturation($0) }
                    )
                }
                if let sh = vm.uvcCapabilities.sharpness, sh.max > sh.min {
                    ControlSliderRow(
                        title: "Sharpness (UVC)",
                        valueText: "\(Int(vm.sharpness))",
                        value: $vm.sharpness,
                        range: Double(sh.min)...Double(sh.max),
                        step: Double(sh.step),
                        defaultValue: Double(sh.defaultValue),
                        onEditingValue: { vm.setSharpness($0) }
                    )
                }
                if let g = vm.uvcCapabilities.gain, g.max > g.min {
                    ControlSliderRow(
                        title: "Gain (UVC)",
                        valueText: "\(Int(vm.gain))",
                        value: $vm.gain,
                        range: Double(g.min)...Double(g.max),
                        step: Double(g.step),
                        defaultValue: Double(g.defaultValue),
                        onEditingValue: { vm.setGain($0) }
                    )
                }

                Divider()

                HStack(spacing: 16) {
                    HStack {
                        Text("Color Profile")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.colorProfile },
                            set: { vm.setColorProfile($0) }
                        )) {
                            ForEach(Pocket3Commands.ColorProfile.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .frame(width: 110)
                        .controlSize(.small)
                    }

                    HStack {
                        Text("Focus Mode")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.focusMode },
                            set: { vm.setFocusMode($0) }
                        )) {
                            ForEach(Pocket3Commands.FocusMode.allCases) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .frame(width: 115)
                        .controlSize(.small)
                    }
                }
                .disabled(!(vm.udpState.isConnected || vm.bleState.isConnected))

                Toggle("Product Showcase Focus Mode (DUML)", isOn: Binding(
                    get: { vm.productShowcase },
                    set: { vm.setProductShowcase($0) }
                ))
                .controlSize(.small)
                .disabled(!(vm.udpState.isConnected || vm.bleState.isConnected))
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Tab 3: Transports & Diagnostics

    private var diagnosticsTab: some View {
        VStack(spacing: 14) {
            // Transport Cards
            VStack(alignment: .leading, spacing: 10) {
                Text("Active Transports")
                    .font(.headline)

                transportRow(
                    title: "USB UVC Webcam Control",
                    subtitle: vm.uvcConnected
                        ? "Connected · \(vm.uvcCapabilities.supportedControlNames.joined(separator: ", "))"
                        : (vm.uvcError ?? "Plug in Pocket 3 via USB-C and tap Webcam on its screen"),
                    isConnected: vm.uvcConnected,
                    buttonTitle: "Refresh",
                    action: { vm.refreshCameras(autoConnect: true) }
                )

                Divider()

                transportRow(
                    title: "Bluetooth LE (DUML FFF0 / FFF4 / FFF5)",
                    subtitle: "Status: \(vm.bleState.label) · Streams battery & gimbal attitude",
                    isConnected: vm.bleState.isConnected,
                    buttonTitle: vm.bleState.isConnected ? "Disconnect" : "Connect BLE",
                    action: { vm.toggleBLE() }
                )

                Divider()

                transportRow(
                    title: "Pocket 3 Wi-Fi Datalink (UDP 192.168.2.1:9004)",
                    subtitle: vm.udpState.isConnected
                        ? "Full DUML Pro camera & 20 Hz gimbal motor control active"
                        : "Optional: unlocks full Pro exposure/WB & BLE-restricted gimbal motor commands. Status: \(vm.udpState.label)",
                    isConnected: vm.udpState.isConnected,
                    buttonTitle: vm.udpState.isConnected ? "Disconnect" : "Connect UDP",
                    action: { vm.toggleUDP() }
                )

                if vm.bleState.isConnected {
                    HStack {
                        Button("Wake Pocket 3 Wi-Fi AP via BLE (53/10)") {
                            vm.requestPocketWiFiCredentials()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !vm.wifiSSID.isEmpty {
                            Text("SSID: \(vm.wifiSSID)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            // Protocol Log
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Protocol & Hardware Log")
                        .font(.headline)
                    Spacer()
                    Button("Clear") {
                        vm.clearLogs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.logs.reversed()) { entry in
                            Text("[\(entry.timestamp.formatted(date: .omitted, time: .standard))] \(entry.message)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Helper Views

    private var wbRange: ClosedRange<Double> {
        if let r = vm.uvcCapabilities.whiteBalanceTemperature, r.max > r.min {
            return Double(r.min)...Double(r.max)
        }
        return 2000...10_000
    }

    private func actionTile(_ title: String, icon: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                highlighted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .foregroundStyle(highlighted ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func telemetryPill(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func transportRow(
        title: String,
        subtitle: String,
        isConnected: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func presetSummary(_ preset: GimbalPreset) -> String {
        if let p = preset.uvcPanDeg, let t = preset.uvcTiltDeg {
            return String(format: "Pan %+.0f° · Tilt %+.0f°", p, t)
        }
        if let p = preset.dumlPitchDeg, let y = preset.dumlYawDeg {
            return String(format: "P %+.0f° · Y %+.0f°", p, y)
        }
        return "Saved"
    }
}

/// Configures the hosting NSWindow's floating level for "Always on Top".
private struct WindowLevelConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.level = floating ? .floating : .normal
        }
    }
}

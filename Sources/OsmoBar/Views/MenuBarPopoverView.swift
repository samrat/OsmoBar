import SwiftUI
import OsmoCore

struct MenuBarPopoverView: View {
    @ObservedObject var vm: OsmoControllerViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                StatusHeaderView(vm: vm, compact: true)
                Button {
                    vm.showLivePreview.toggle()
                } label: {
                    Image(systemName: vm.showLivePreview ? "video.fill" : "video.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(vm.showLivePreview ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 22)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(vm.showLivePreview ? "Hide Video Preview" : "Show Video Preview")
            }

            // Live webcam preview directly in the popover
            if vm.showLivePreview {
                CameraPreviewView(
                    sessionManager: vm.cameraSession,
                    hasCamera: vm.selectedCameraID != nil,
                    mirrored: vm.mirrorPreview,
                    showGrid: vm.showFramingGrid,
                    trackedFaceRect: vm.faceFollowEnabled ? vm.trackedFaceRect : nil
                )
                .frame(height: 174)
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

            if case .awaitingApproval = vm.bleState {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(.orange)
                    Text("Tap Accept on the Pocket 3 screen to pair Bluetooth.")
                        .font(.system(size: 11))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            // Gimbal Quick Pad + Actions
            HStack(spacing: 12) {
                GimbalPadView(
                    size: 138,
                    pitchDeg: vm.attitude?.pitchDeg ?? (vm.uvcCapabilities.panTiltAbsolute != nil ? vm.uvcTiltDeg : nil),
                    yawDeg: vm.attitude?.wrappedYawDeg ?? (vm.uvcCapabilities.panTiltAbsolute != nil ? vm.uvcPanDeg : nil),
                    isEnabled: vm.activeGimbalRoute != .unavailable,
                    onVectorChange: { vm.updateJoystick($0) },
                    onRelease: { vm.stopJoystick() },
                    onNudge: { dx, dy in vm.nudgeGimbal(dx: dx, dy: dy) }
                )

                VStack(spacing: 7) {
                    RouteBadge(
                        route: vm.activeGimbalRoute.rawValue,
                        isActive: vm.activeGimbalRoute != .unavailable
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    quickActionButton("Recenter", icon: "scope") {
                        vm.recenterGimbal()
                    }
                    quickActionButton(
                        vm.isFlippedUSB ? "Front (0°)" : "Flip 180°",
                        icon: "arrow.triangle.2.circlepath.camera",
                        active: vm.isFlippedUSB
                    ) {
                        vm.flipCamera()
                    }
                    quickActionButton(
                        vm.faceFollowEnabled ? "Following" : "Face Follow",
                        icon: vm.faceFollowEnabled ? "person.crop.rectangle.fill" : "person.crop.rectangle",
                        active: vm.faceFollowEnabled
                    ) {
                        vm.setFaceFollowEnabled(!vm.faceFollowEnabled)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Presets Strip
            if !vm.presets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Presets")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(vm.presets) { preset in
                                Button {
                                    vm.applyPreset(preset)
                                } label: {
                                    Label(preset.name, systemImage: preset.symbolName)
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(
                                            vm.activePresetMoveName == preset.name
                                                ? Color.accentColor.opacity(0.22)
                                                : Color.secondary.opacity(0.12),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Divider()

            // Quick Image Controls
            VStack(spacing: 10) {
                if let z = vm.uvcCapabilities.zoomAbsolute, z.max > z.min {
                    VStack(spacing: 6) {
                        ControlSliderRow(
                            title: "Zoom",
                            valueText: vm.zoomMultiplierDisplay,
                            value: $vm.uvcZoomValue,
                            range: Double(z.min)...Double(z.max),
                            step: Double(z.step),
                            defaultValue: Double(z.defaultValue),
                            onEditingValue: { vm.setZoom($0) }
                        )
                        HStack(spacing: 5) {
                            ForEach([1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { factor in
                                Button(String(format: factor == floor(factor) ? "%.0f×" : "%.1f×", factor)) {
                                    vm.setZoomFactor(factor)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                // Exposure EV (DUML) or UVC Brightness
                if let b = vm.uvcCapabilities.brightness, b.max > b.min {
                    ControlSliderRow(
                        title: "Brightness",
                        valueText: "\(Int(vm.brightness.rounded()))",
                        value: $vm.brightness,
                        range: Double(b.min)...Double(b.max),
                        step: Double(b.step),
                        defaultValue: Double(b.defaultValue),
                        onEditingValue: { vm.setBrightness($0) }
                    )
                } else {
                    ControlSliderRow(
                        title: "Exposure EV",
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
                }

                // White Balance quick row
                HStack {
                    Text("White Balance")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Auto", isOn: Binding(
                        get: { vm.whiteBalanceAuto },
                        set: { vm.setWhiteBalanceAuto($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                if !vm.whiteBalanceAuto {
                    ControlSliderRow(
                        title: "Temperature",
                        valueText: "\(Int(vm.whiteBalanceKelvin))K",
                        value: $vm.whiteBalanceKelvin,
                        range: wbRange,
                        step: 100,
                        defaultValue: 5600,
                        onEditingValue: { vm.setWhiteBalanceKelvin($0) }
                    )
                }
            }

            Divider()

            // Footer
            HStack {
                Button {
                    openWindow(id: "control-window")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Studio Window", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quit OsmoBar")
            }
        }
        .padding(14)
        .frame(width: 336)
    }

    private var wbRange: ClosedRange<Double> {
        if let r = vm.uvcCapabilities.whiteBalanceTemperature, r.max > r.min {
            return Double(r.min)...Double(r.max)
        }
        return 2000...10_000
    }

    private func quickActionButton(
        _ title: String,
        icon: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

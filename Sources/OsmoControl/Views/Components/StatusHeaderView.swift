import SwiftUI
import OsmoCore

struct StatusHeaderView: View {
    @ObservedObject var vm: OsmoControllerViewModel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Camera selector pill
            Menu {
                if vm.cameras.isEmpty {
                    Text("No USB cameras detected")
                } else {
                    ForEach(vm.cameras) { cam in
                        Button {
                            vm.selectCamera(cam.id)
                        } label: {
                            HStack {
                                Text(cam.name)
                                if cam.id == vm.selectedCameraID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Refresh Cameras") {
                    vm.refreshCameras(autoConnect: true)
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(vm.uvcConnected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(vm.selectedCamera?.name ?? "No Camera")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 4)

            // Battery readout (from BLE or UDP DUML 0D/02)
            if let battery = vm.battery {
                HStack(spacing: 3) {
                    Image(systemName: batteryIcon(battery))
                        .font(.system(size: 11))
                        .foregroundStyle(battery.percent <= 20 ? .red : .green)
                    Text("\(battery.percent)%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }

            // BLE Quick Toggle
            Button {
                vm.toggleBLE()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: bleSymbol)
                        .font(.system(size: 10, weight: .semibold))
                    if !compact {
                        Text(vm.bleState.isConnected ? "BLE" : "Connect BLE")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    vm.bleState.isConnected ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(vm.bleState.isConnected ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help("BLE: \(vm.bleState.label)")
        }
    }

    private var bleSymbol: String {
        switch vm.bleState {
        case .connected: return "dot.radiowaves.left.and.right"
        case .scanning, .connecting, .awaitingApproval: return "antenna.radiowaves.left.and.right"
        default: return "wave.3.right"
        }
    }

    private func batteryIcon(_ b: BatteryStatus) -> String {
        if b.isCharging == true { return "battery.100.bolt" }
        switch b.percent {
        case 80...100: return "battery.100"
        case 55..<80: return "battery.75"
        case 30..<55: return "battery.50"
        case 15..<30: return "battery.25"
        default: return "battery.0"
        }
    }
}

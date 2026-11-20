import SwiftUI

/// Compact real-time audio level meter for the Osmo Pocket 3 USB audio input.
struct AudioLevelBarView: View {
    let state: AudioMeterState
    let level: Double
    let peak: Double
    let decibels: Float
    let isEnabled: Bool
    let onToggleEnabled: () -> Void
    let onRequestPermission: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleEnabled) {
                Image(systemName: micIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(micIconColor)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isEnabled ? "Pause audio level meter" : "Resume audio level meter")

            switch state {
            case .active(let deviceName):
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(deviceName)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(decibels <= -58 ? "−∞ dB" : String(format: "%.0f dB", decibels))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(decibels > -3 ? .red : .secondary)
                    }
                    meterTrack
                }

            case .permissionNotDetermined:
                Text("Pocket 3 Audio Meter")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable Mic Meter", action: onRequestPermission)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

            case .permissionDenied:
                Text("Mic permission denied in System Settings")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                Spacer()

            case .noDevice:
                Text("No Osmo USB audio input detected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()

            case .inactive:
                Text("Audio meter paused")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var meterTrack: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let activeWidth = max(0, min(w, w * level))
            let peakX = max(2, min(w - 2, w * peak))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0.0),
                                .init(color: .green, location: 0.68),
                                .init(color: .yellow, location: 0.84),
                                .init(color: .red, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: activeWidth)
                    .animation(.linear(duration: 0.05), value: level)

                if peak > 0.03 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(peak > 0.88 ? Color.red : Color.primary.opacity(0.65))
                        .frame(width: 2, height: 6)
                        .offset(x: peakX - 1)
                }
            }
        }
        .frame(height: 6)
    }

    private var micIcon: String {
        if !isEnabled { return "mic.slash" }
        switch state {
        case .active: return level > 0.06 ? "mic.fill" : "mic"
        case .permissionDenied: return "mic.slash.fill"
        default: return "mic"
        }
    }

    private var micIconColor: Color {
        if !isEnabled { return .secondary }
        switch state {
        case .active:
            if decibels > -3 { return .red }
            return level > 0.06 ? .green : .secondary
        case .permissionDenied:
            return .orange
        default:
            return .secondary
        }
    }
}

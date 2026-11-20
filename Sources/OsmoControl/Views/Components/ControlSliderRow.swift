import SwiftUI

struct ControlSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var defaultValue: Double? = nil
    var isDisabled: Bool = false
    var onEditingValue: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        if let defaultValue, !isDisabled {
                            value = defaultValue
                            onEditingValue(defaultValue)
                        }
                    }
                    .help(defaultValue != nil ? "Double-click to reset" : "")
            }

            if let step {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { newVal in
                            value = newVal
                            onEditingValue(newVal)
                        }
                    ),
                    in: range,
                    step: step
                )
                .controlSize(.small)
                .disabled(isDisabled)
            } else {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { newVal in
                            value = newVal
                            onEditingValue(newVal)
                        }
                    ),
                    in: range
                )
                .controlSize(.small)
                .disabled(isDisabled)
            }
        }
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

struct RouteBadge: View {
    let route: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(route)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (isActive ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12)),
            in: Capsule()
        )
        .foregroundStyle(isActive ? .primary : .secondary)
    }
}

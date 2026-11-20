import SwiftUI
import AppKit

/// Interactive 2D circular gimbal joystick pad backed by an AppKit mouse-tracking NSView.
/// Guarantees smooth dragging inside both MenuBarExtra popovers and standard windows,
/// with reliable spring-return and release even if the pointer leaves the pad bounds.
struct GimbalPadView: View {
    let size: CGFloat
    let pitchDeg: Double?
    let yawDeg: Double?
    let isEnabled: Bool
    let onVectorChange: (CGPoint) -> Void
    let onRelease: () -> Void
    let onNudge: (Double, Double) -> Void

    @State private var thumbOffset: CGSize = .zero
    @State private var isDragging = false

    private var padDiameter: CGFloat { max(88, size - 44) }
    private var padRadius: CGFloat { padDiameter / 2 }
    private var maxTravel: CGFloat { max(16, padRadius - 18) }

    var body: some View {
        VStack(spacing: 4) {
            // Up nudge
            nudgeButton(systemName: "chevron.up", dx: 0, dy: 1)

            HStack(spacing: 4) {
                // Left nudge
                nudgeButton(systemName: "chevron.left", dx: -1, dy: 0)

                // Dedicated circular joystick drag pad
                ZStack {
                    Circle()
                        .fill(.quaternary.opacity(0.45))
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isDragging ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.15),
                                    lineWidth: isDragging ? 1.5 : 1
                                )
                        )

                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        .frame(width: padDiameter * 0.62, height: padDiameter * 0.62)

                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        .frame(width: padDiameter * 0.30, height: padDiameter * 0.30)

                    Path { path in
                        path.move(to: CGPoint(x: padRadius, y: 10))
                        path.addLine(to: CGPoint(x: padRadius, y: padDiameter - 10))
                        path.move(to: CGPoint(x: 10, y: padRadius))
                        path.addLine(to: CGPoint(x: padDiameter - 10, y: padRadius))
                    }
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    if isDragging {
                        Path { path in
                            path.move(to: CGPoint(x: padRadius, y: padRadius))
                            path.addLine(to: CGPoint(x: padRadius + thumbOffset.width, y: padRadius + thumbOffset.height))
                        }
                        .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }

                    Circle()
                        .fill(isDragging ? Color.accentColor : Color.primary.opacity(0.84))
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.25), radius: isDragging ? 6 : 3, y: 2)
                        .overlay(
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                                .frame(width: 8, height: 8)
                        )
                        .offset(thumbOffset)
                }
                .frame(width: padDiameter, height: padDiameter)
                .overlay(
                    JoystickTrackingSurface(
                        isEnabled: isEnabled,
                        maxTravel: maxTravel,
                        onUpdate: { offset, normalized in
                            isDragging = true
                            thumbOffset = offset
                            onVectorChange(normalized)
                        },
                        onEnd: {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                                thumbOffset = .zero
                            }
                            isDragging = false
                            onRelease()
                        }
                    )
                )

                // Right nudge
                nudgeButton(systemName: "chevron.right", dx: 1, dy: 0)
            }

            // Down nudge
            nudgeButton(systemName: "chevron.down", dx: 0, dy: -1)

            if let pitchDeg, let yawDeg {
                Text(String(format: "Pan %+.1f° · Tilt %+.1f°", yawDeg, pitchDeg))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }

    private func nudgeButton(systemName: String, dx: Double, dy: Double) -> some View {
        Button {
            onNudge(dx, dy)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// AppKit NSView mouse tracker so mouseDown/mouseDragged/mouseUp never drop in MenuBarExtra popovers.
private struct JoystickTrackingSurface: NSViewRepresentable {
    let isEnabled: Bool
    let maxTravel: CGFloat
    let onUpdate: (CGSize, CGPoint) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.isEnabled = isEnabled
        view.maxTravel = maxTravel
        view.onUpdate = onUpdate
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.maxTravel = maxTravel
        nsView.onUpdate = onUpdate
        nsView.onEnd = onEnd
    }

    static func dismantleNSView(_ nsView: TrackingNSView, coordinator: ()) {
        nsView.finishDragIfNeeded()
    }

    @MainActor
    final class TrackingNSView: NSView {
        var isEnabled = true
        var maxTravel: CGFloat = 40
        var onUpdate: ((CGSize, CGPoint) -> Void)?
        var onEnd: (() -> Void)?
        private var dragging = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isEnabled ? .openHand : .arrow)
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            dragging = true
            NSCursor.closedHand.push()
            emitVector(for: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging, isEnabled else { return }
            emitVector(for: event)
        }

        override func mouseUp(with event: NSEvent) {
            finishDragIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                finishDragIfNeeded()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func finishDragIfNeeded() {
            guard dragging else { return }
            dragging = false
            NSCursor.pop()
            onEnd?()
        }

        private func emitVector(for event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let dx = p.x - bounds.midX
            let dy = p.y - bounds.midY
            let dist = hypot(dx, dy)
            let clamped = min(dist, maxTravel)
            let angle = atan2(dy, dx)
            let cx = cos(angle) * clamped
            let cy = sin(angle) * clamped
            let normX = max(-1.0, min(1.0, cx / max(1, maxTravel)))
            let normY = max(-1.0, min(1.0, -cy / max(1, maxTravel))) // screen up -> positive tilt
            onUpdate?(CGSize(width: cx, height: cy), CGPoint(x: normX, y: normY))
        }
    }
}

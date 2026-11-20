import SwiftUI
@preconcurrency import AVFoundation

/// Live video preview attached to the shared `CameraSessionManager`.
/// Renders an optional rule-of-thirds grid and a live face-tracking reticle when Face Follow is active.
struct CameraPreviewView: View {
    let sessionManager: CameraSessionManager
    let hasCamera: Bool
    var mirrored: Bool = true
    var showGrid: Bool = false
    var trackedFaceRect: CGRect? = nil

    @State private var authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.92))

            if !hasCamera {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("Osmo Not Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if authStatus == .authorized {
                SharedSessionPreviewLayerView(sessionManager: sessionManager, mirrored: mirrored)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if showGrid {
                    RuleOfThirdsGrid()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                }

                if let face = trackedFaceRect {
                    FaceTrackingOverlay(normalizedVisionRect: face, mirrored: mirrored)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                }
            } else if authStatus == .notDetermined {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Allow camera access to show live preview")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Enable Video Preview") {
                        requestCameraPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.orange)
                    Text("Camera permission denied in System Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if hasCamera && authStatus == .notDetermined {
                requestCameraPermission()
            }
        }
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                authStatus = granted ? .authorized : .denied
            }
        }
    }
}

private struct FaceTrackingOverlay: View {
    let normalizedVisionRect: CGRect
    let mirrored: Bool

    var body: some View {
        GeometryReader { geo in
            // Vision uses bottom-left origin; SwiftUI uses top-left origin.
            let x = mirrored
                ? (1.0 - normalizedVisionRect.maxX) * geo.size.width
                : normalizedVisionRect.minX * geo.size.width
            let y = (1.0 - normalizedVisionRect.maxY) * geo.size.height
            let w = normalizedVisionRect.width * geo.size.width
            let h = normalizedVisionRect.height * geo.size.height

            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.green.opacity(0.9), lineWidth: 2)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: max(16, w), height: max(16, h))
                .position(x: x + w / 2, y: y + h / 2)
                .animation(.easeOut(duration: 0.10), value: normalizedVisionRect)
        }
    }
}

private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
        }
    }
}

private struct SharedSessionPreviewLayerView: NSViewRepresentable {
    let sessionManager: CameraSessionManager
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView(sessionManager: sessionManager)
        view.setMirrored(mirrored)
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.setMirrored(mirrored)
    }

    static func dismantleNSView(_ nsView: PreviewHostView, coordinator: ()) {
        nsView.detach()
    }
}

final class PreviewHostView: NSView {
    private let sessionManager: CameraSessionManager
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var detached = false
    private var isRegisteredConsumer = false
    private var isMirrored = true
    private var visibilityObservation: NSKeyValueObservation?
    private var windowObservers: [NSObjectProtocol] = []
    private var sessionStartObserver: NSObjectProtocol?

    init(sessionManager: CameraSessionManager) {
        self.sessionManager = sessionManager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        sessionStartObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: sessionManager.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyMirroring()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearWindowObservers()

        if let win = window {
            visibilityObservation = win.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateConsumerRegistration()
                }
            }

            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ]
            for name in names {
                let obs = nc.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateConsumerRegistration()
                    }
                }
                windowObservers.append(obs)
            }
        }

        updateConsumerRegistration()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        applyMirroring()
    }

    func setMirrored(_ mirrored: Bool) {
        isMirrored = mirrored
        applyMirroring()
    }

    func detach() {
        guard !detached else { return }
        detached = true
        clearWindowObservers()
        if let obs = sessionStartObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionStartObserver = nil
        }
        updateConsumerRegistration()
    }

    private func applyMirroring() {
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = isMirrored
        }
    }

    private func clearWindowObservers() {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowObservers.removeAll()
    }

    private func updateConsumerRegistration() {
        let shouldConsume = !detached
            && window != nil
            && (window?.isVisible == true)
            && (window?.isMiniaturized == false)

        if shouldConsume && !isRegisteredConsumer {
            isRegisteredConsumer = true
            previewLayer.session = sessionManager.session
            sessionManager.registerPreviewConsumer()
            applyMirroring()
        } else if !shouldConsume && isRegisteredConsumer {
            isRegisteredConsumer = false
            previewLayer.session = nil
            sessionManager.unregisterPreviewConsumer()
        }
    }
}

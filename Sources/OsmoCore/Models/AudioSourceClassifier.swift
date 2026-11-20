import Foundation

/// Detected microphone source feeding the Osmo Pocket 3 USB audio stream.
public enum DetectedMicSource: Equatable, Sendable {
    case unknown
    case cameraMic
    case djiMicWireless
    case djiMicUSBReceiver(name: String)

    public var badgeTitle: String {
        switch self {
        case .unknown: return "Detecting…"
        case .cameraMic: return "Camera Mic"
        case .djiMicWireless: return "DJI Mic"
        case .djiMicUSBReceiver: return "DJI Mic (USB)"
        }
    }

    public var isDJIMic: Bool {
        switch self {
        case .djiMicWireless, .djiMicUSBReceiver: return true
        case .unknown, .cameraMic: return false
        }
    }
}

/// Distinguishes a mono DJI Mic transmitter paired wirelessly to the Osmo Pocket 3
/// from the Pocket 3's built-in stereo microphone array by analyzing L/R channel
/// coherence on audible frames.
///
/// When a single DJI Mic transmitter is paired to the Pocket 3, the camera duplicates
/// its mono signal across both L and R channels of the USB stereo stream (side/mid ≈ 0,
/// correlation ≈ 1.0). The Pocket 3's built-in stereo mic array produces distinct L/R
/// channels with measurable stereo difference whenever sound is present.
public struct StereoMicSourceClassifier: Sendable {
    public struct FrameMetrics: Equatable, Sendable {
        public let midRMS: Double
        public let sideRMS: Double
        public let sideToMidRatio: Double
        public let correlation: Double
    }

    public private(set) var detectedSource: DetectedMicSource = .unknown
    public private(set) var lastMetrics: FrameMetrics?

    private var monoStreak = 0
    private var stereoStreak = 0

    // Minimum mid-channel RMS (~-46 dBFS) required so silence doesn't trigger false mono detection.
    private let minAudibleRMS: Double = 0.005
    // Thresholds: mono duplicate has S/M ~ 0.000 and corr ~ 1.000; stereo mics have S/M > 0.05.
    private let monoSideToMidMax: Double = 0.015
    private let monoCorrelationMin: Double = 0.9985
    private let stereoSideToMidMin: Double = 0.04
    private let confirmFramesRequired: Int

    public init(confirmFramesRequired: Int = 8) {
        self.confirmFramesRequired = max(1, confirmFramesRequired)
    }

    public mutating func reset() {
        detectedSource = .unknown
        lastMetrics = nil
        monoStreak = 0
        stereoStreak = 0
    }

    /// Analyzes one stereo frame (equal-length L and R normalized float samples in -1...1).
    /// Returns the newly confirmed `DetectedMicSource` if a state transition occurred.
    @discardableResult
    public mutating func ingest(left: [Float], right: [Float]) -> DetectedMicSource? {
        let count = min(left.count, right.count)
        guard count > 0 else { return nil }

        var sumMidSq = 0.0
        var sumSideSq = 0.0
        var sumLSq = 0.0
        var sumRSq = 0.0
        var dotLR = 0.0

        for i in 0..<count {
            let l = Double(left[i])
            let r = Double(right[i])
            let mid = 0.5 * (l + r)
            let side = 0.5 * (l - r)
            sumMidSq += mid * mid
            sumSideSq += side * side
            sumLSq += l * l
            sumRSq += r * r
            dotLR += l * r
        }

        let invN = 1.0 / Double(count)
        let midRMS = sqrt(sumMidSq * invN)
        let sideRMS = sqrt(sumSideSq * invN)

        guard midRMS >= minAudibleRMS else {
            return nil
        }

        let sideToMid = sideRMS / max(midRMS, 1e-9)
        let denom = sqrt(sumLSq * sumRSq)
        let corr = denom > 1e-12 ? (dotLR / denom) : 0.0
        lastMetrics = FrameMetrics(
            midRMS: midRMS,
            sideRMS: sideRMS,
            sideToMidRatio: sideToMid,
            correlation: corr
        )

        let previous = detectedSource
        if sideToMid <= monoSideToMidMax && corr >= monoCorrelationMin {
            monoStreak += 1
            stereoStreak = 0
            if monoStreak >= confirmFramesRequired {
                detectedSource = .djiMicWireless
            }
        } else if sideToMid >= stereoSideToMidMin || corr < 0.99 {
            stereoStreak += 1
            monoStreak = 0
            if stereoStreak >= confirmFramesRequired {
                detectedSource = .cameraMic
            }
        }

        return detectedSource != previous ? detectedSource : nil
    }
}

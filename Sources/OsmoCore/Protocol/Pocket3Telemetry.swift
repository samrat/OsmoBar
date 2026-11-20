import Foundation

/// Decoded live gimbal attitude from DUML `04/05`.
public struct GimbalAttitude: Equatable, Sendable {
    public let pitchDeg: Double
    public let rollDeg: Double
    public let wrappedYawDeg: Double
    public let continuousYawDeg: Double
    public let modeByte: UInt8?
    public let limitFlags: UInt8?

    public var isLockedObserved: Bool {
        modeByte == 0x00
    }
}

/// Decoded battery telemetry from DUML `0D/02`.
public struct BatteryStatus: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool?
}

/// Tracks continuous unwrapped yaw across the +180/-180 wrap boundary.
public struct ContinuousYawReducer: Sendable {
    private var lastWrappedDeg: Double?
    private var accumulatedDeg: Double = 0

    public init() {}

    public mutating func reset() {
        lastWrappedDeg = nil
        accumulatedDeg = 0
    }

    public mutating func update(wrappedYawDeg: Double) -> Double {
        guard let previous = lastWrappedDeg else {
            lastWrappedDeg = wrappedYawDeg
            accumulatedDeg = wrappedYawDeg
            return accumulatedDeg
        }
        var delta = wrappedYawDeg - previous
        while delta > 180.0 { delta -= 360.0 }
        while delta < -180.0 { delta += 360.0 }
        accumulatedDeg += delta
        lastWrappedDeg = wrappedYawDeg
        return accumulatedDeg
    }
}

/// Named-property readback decoded from DUML `00/99` pushes.
public struct CameraReadbackState: Equatable, Sendable {
    public var exposureMode: Pocket3Commands.ExposureMode?
    public var evThirdStops: Int?
    public var effectiveISO: UInt32?
    public var whiteBalance: Pocket3Commands.WhiteBalance?
    public var colorProfile: Pocket3Commands.ColorProfile?
    public var focusMode: Pocket3Commands.FocusMode?
    public var receivedProperties: Set<String> = []

    public init() {}

    @discardableResult
    public mutating func applyPropertyPush(_ payload: Data) -> Bool {
        guard let record = Pocket3TelemetryParser.parseNamedPropertyPush(payload) else {
            return false
        }
        var recognized = true
        switch record.name {
        case "cam_expo_param":
            guard record.value.count >= 20 else { return false }
            let evCode = Int(record.value[6])
            evThirdStops = (0x07...0x19).contains(evCode) ? evCode - 0x10 : nil
            exposureMode = Pocket3Commands.ExposureMode(rawValue: record.value[7])
            effectiveISO = u32le(record.value, 16)
        case "cam_image_effect":
            guard record.value.count >= 6 else { return false }
            colorProfile = Pocket3Commands.ColorProfile(rawValue: record.value[2])
            switch record.value[4] {
            case 0x00:
                whiteBalance = .auto
            case 0x06:
                whiteBalance = .customKelvin(Int(record.value[5]) * 100)
            default:
                whiteBalance = nil
            }
        case "cam_lens_state":
            guard let focusByte = record.value.first else { return false }
            switch focusByte {
            case 0xB1: focusMode = .single
            case 0xB2: focusMode = .continuous
            default: focusMode = nil
            }
        default:
            recognized = false
        }
        if recognized {
            receivedProperties.insert(record.name)
        }
        return recognized
    }

    private func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

public struct NamedPropertyRecord: Equatable, Sendable {
    public let transactionID: UInt32
    public let name: String
    public let value: Data
}

public enum Pocket3TelemetryParser {
    public static let readbackPropertyNames = [
        "cam_expo_param",
        "cam_image_effect",
        "cam_lens_state",
        "cam_video_param_v2"
    ]

    /// Parses DUML `04/05` gimbal telemetry.
    public static func parseGimbalAttitude(
        payload: Data,
        yawReducer: inout ContinuousYawReducer
    ) -> GimbalAttitude? {
        guard payload.count >= 6 else { return nil }
        let pitchRaw = Int16(bitPattern: u16le(payload, 0))
        let rollRaw = Int16(bitPattern: u16le(payload, 2))
        let yawRaw = Int16(bitPattern: u16le(payload, 4))

        let pitchDeg = Double(pitchRaw) / 10.0
        let rollDeg = Double(rollRaw) / 10.0
        let wrappedYawDeg = Double(yawRaw) / 10.0
        let continuousYawDeg = yawReducer.update(wrappedYawDeg: wrappedYawDeg)

        let modeByte: UInt8? = payload.count >= 7 ? payload[6] : nil
        let limitFlags: UInt8? = payload.count >= 11 ? payload[10] : nil

        return GimbalAttitude(
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            wrappedYawDeg: wrappedYawDeg,
            continuousYawDeg: continuousYawDeg,
            modeByte: modeByte,
            limitFlags: limitFlags
        )
    }

    /// Parses DUML `0D/02` battery telemetry (`payload[20]` = percent, `payload[32]` = charging).
    public static func parseBattery(payload: Data) -> BatteryStatus? {
        guard payload.count >= 21 else { return nil }
        let percent = Int(payload[20])
        guard (0...100).contains(percent) else { return nil }
        let charging: Bool?
        if payload.count >= 33 {
            switch payload[32] {
            case 0x00: charging = false
            case 0x01: charging = true
            default: charging = nil
            }
        } else {
            charging = nil
        }
        return BatteryStatus(percent: percent, isCharging: charging)
    }

    /// Parses DUML `00/99` named-property push (operation `0x06`).
    public static func parseNamedPropertyPush(_ payload: Data) -> NamedPropertyRecord? {
        guard payload.count >= 23,
              payload[0] == 0x02,
              payload[1] == 0x06,
              payload[2] == 0x00,
              payload[3] == 0x00 else {
            return nil
        }
        let txId = u32le(payload, 4)
        let nameLen = Int(u16le(payload, 13))
        let nameStart = 15
        let nameEnd = nameStart + nameLen
        guard nameLen > 0, nameEnd + 8 <= payload.count else { return nil }
        guard let name = String(data: payload[nameStart..<nameEnd], encoding: .ascii) else {
            return nil
        }
        let valLenOffset = nameEnd + 6
        let valLen = Int(u16le(payload, valLenOffset))
        let valStart = valLenOffset + 2
        let valEnd = valStart + valLen
        guard valEnd <= payload.count else { return nil }
        return NamedPropertyRecord(
            transactionID: txId,
            name: name,
            value: Data(payload[valStart..<valEnd])
        )
    }

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

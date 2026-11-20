import Foundation

/// A typed Pocket 3 DUML command descriptor ready for BLE or UDP transport.
public struct Pocket3Command: Equatable, Sendable {
    public let cmdSet: UInt8
    public let cmdId: UInt8
    public let payload: Data
    public let receiverType: Int
    public let receiverId: Int
    public let cmdType: Int
    public let label: String

    public init(
        cmdSet: UInt8,
        cmdId: UInt8,
        payload: Data = Data(),
        receiverType: Int = 0x01,
        receiverId: Int = 0,
        cmdType: Int = 2,
        label: String
    ) {
        self.cmdSet = cmdSet
        self.cmdId = cmdId
        self.payload = payload
        self.receiverType = receiverType
        self.receiverId = receiverId
        self.cmdType = cmdType
        self.label = label
    }

    /// Packed 16-bit DUML target word (App=0x02 -> receiver).
    public var target: UInt16 {
        UInt16(0x02 | (((receiverId << 5) | receiverType) << 8))
    }

    public var flags: UInt8 {
        UInt8((cmdType << 5) & 0xFF)
    }

    public func encodeDuml(id: UInt16) -> Data {
        DumlMessage(
            target: target,
            id: id,
            flags: flags,
            cmdSet: cmdSet,
            cmdId: cmdId,
            payload: payload
        ).encode()
    }
}

/// Verified DJI Osmo Pocket 3 BLE, Gimbal, and Camera DUML command builders.
public enum Pocket3Commands {
    public static let targetAppToWiFi: UInt16 = 0x0702
    public static let targetAppToSession: UInt16 = 0xF002
    public static let targetAppTo1C: UInt16 = 0x1C02
    public static let targetAppToGimbal: UInt16 = 0x0402

    public static let pairMessageID: UInt16 = 0x8092
    public static let defaultIdentifier = "284ae5b8d76b3375a04a6417ad71bea3"

    public static let gimbalNeutral: Int = 1024
    public static let gimbalLinearRange: Int = 330
    public static let gimbalMaxRange: Int = 550

    public static let sessionWakePayload = Data([0x04, 0x00])
    public static let sessionKeepalivePayload = Data([0x01, 0x01])

    public static let appDeviceInfoPayload: Data = {
        var out = Data([0x00, 0x41, 0x50, 0x50])
        out.append(contentsOf: Array(repeating: UInt8(0), count: 37))
        out.append(0x02)
        out.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        out.append(contentsOf: [0x02, 0x08])
        out.append(contentsOf: Array(repeating: UInt8(0), count: 10))
        return out
    }()

    public static let appPresencePayload = Data([
        0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02
    ])
    public static let gimbalInitPayload = Data([0x05, 0xFF, 0xFF, 0xFF, 0xFF])
    public static let gimbalHeartbeatPayload = Data([0x01, 0x04, 0x05])

    public static func packString(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        precondition(utf8.count <= 255)
        var out = Data([UInt8(utf8.count)])
        out.append(utf8)
        return out
    }

    // MARK: - BLE Session & Pairing

    public static func sessionPing(_ payload: Data, id: UInt16 = 0x802B) -> Data {
        DumlMessage(
            target: targetAppToSession,
            id: id,
            flags: 0x40,
            cmdSet: 0x00,
            cmdId: 0x2B,
            payload: payload
        ).encode()
    }

    public static func setPairingPin(
        _ pin: String = "osmo",
        id: UInt16 = pairMessageID,
        identifier: String = defaultIdentifier
    ) -> Data {
        var payload = packString(identifier)
        payload.append(packString(pin))
        return DumlMessage(
            target: targetAppToWiFi,
            id: id,
            type: 0x450740,
            payload: payload
        ).encode()
    }

    public static func wakeWiFiAP(id: UInt16 = 0x8053) -> Data {
        DumlMessage(
            target: targetAppTo1C,
            id: id,
            flags: 0x40,
            cmdSet: 0x53,
            cmdId: 0x10,
            payload: Data([0x00, 0x00, 0x00, 0x00])
        ).encode()
    }

    public static func queryWiFiSSID(id: UInt16 = 0x8007) -> Data {
        DumlMessage(
            target: targetAppToWiFi,
            id: id,
            flags: 0x40,
            cmdSet: 0x07,
            cmdId: 0x07
        ).encode()
    }

    public static func queryWiFiPassword(id: UInt16 = 0x800E) -> Data {
        DumlMessage(
            target: targetAppToWiFi,
            id: id,
            flags: 0x40,
            cmdSet: 0x07,
            cmdId: 0x0E
        ).encode()
    }

    // MARK: - Gimbal Commands (CmdSet 0x04)

    /// Virtual joystick velocity command (`04/01`).
    /// - Parameters:
    ///   - pitch: 1024 = neutral; >1024 = up; <1024 = down.
    ///   - yaw: 1024 = neutral; >1024 = right; <1024 = left.
    public static func gimbalVelocity(pitch: Int, yaw: Int) -> Pocket3Command {
        let clampedPitch = UInt16(max(363, min(1685, pitch)))
        let clampedYaw = UInt16(max(363, min(1685, yaw)))
        let payload = Data([
            UInt8(clampedPitch & 0xFF),
            UInt8((clampedPitch >> 8) & 0xFF),
            0x00, 0x00,
            UInt8(clampedYaw & 0xFF),
            UInt8((clampedYaw >> 8) & 0xFF),
            0x00, 0x80, 0x22, 0x00
        ])
        return Pocket3Command(
            cmdSet: 0x04,
            cmdId: 0x01,
            payload: payload,
            receiverType: 0x04,
            receiverId: 0,
            cmdType: 0,
            label: "Gimbal Velocity (\(clampedPitch), \(clampedYaw))"
        )
    }

    /// Confirmed Pocket 3 RECENTER command (`04/4C FE 08`).
    public static func gimbalRecenter() -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x04,
            cmdId: 0x4C,
            payload: Data([0xFE, 0x08]),
            receiverType: 0x04,
            receiverId: 0,
            cmdType: 2,
            label: "Recenter Gimbal"
        )
    }

    /// Pocket 3 Selfie / Forward flip toggle (`04/4C FE 09`).
    public static func gimbalSelfieFlip() -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x04,
            cmdId: 0x4C,
            payload: Data([0xFE, 0x09]),
            receiverType: 0x04,
            receiverId: 0,
            cmdType: 2,
            label: "Flip Camera (Selfie/Forward)"
        )
    }

    /// Software gimbal lock (`04/4C 00 00`) or unlock/follow (`04/4C 01 00`).
    public static func gimbalLock(_ locked: Bool) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x04,
            cmdId: 0x4C,
            payload: Data([locked ? 0x00 : 0x01, 0x00]),
            receiverType: 0x04,
            receiverId: 0,
            cmdType: 2,
            label: locked ? "Lock Gimbal" : "Unlock Gimbal (Follow)"
        )
    }

    // MARK: - Camera Exposure, White Balance & Image Commands (CmdSet 0x02)

    public enum ExposureMode: UInt8, CaseIterable, Identifiable, Sendable {
        case auto = 0x01
        case manual = 0x04

        public var id: UInt8 { rawValue }
        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .manual: return "Manual"
            }
        }
    }

    public enum ManualISO: UInt8, CaseIterable, Identifiable, Sendable {
        case auto = 0x00
        case iso50 = 0x02
        case iso100 = 0x03
        case iso200 = 0x04
        case iso400 = 0x05
        case iso800 = 0x06
        case iso1600 = 0x07
        case iso3200 = 0x08
        case iso6400 = 0x09

        public var id: UInt8 { rawValue }
        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .iso50: return "50"
            case .iso100: return "100"
            case .iso200: return "200"
            case .iso400: return "400"
            case .iso800: return "800"
            case .iso1600: return "1600"
            case .iso3200: return "3200"
            case .iso6400: return "6400"
            }
        }
    }

    public enum ISOMax: UInt8, CaseIterable, Identifiable, Sendable {
        case iso100 = 0x01
        case iso200 = 0x02
        case iso400 = 0x03
        case iso800 = 0x04
        case iso1600 = 0x05
        case iso3200 = 0x06
        case iso6400 = 0x07

        public var id: UInt8 { rawValue }
        public var displayName: String {
            switch self {
            case .iso100: return "100"
            case .iso200: return "200"
            case .iso400: return "400"
            case .iso800: return "800"
            case .iso1600: return "1600"
            case .iso3200: return "3200"
            case .iso6400: return "6400"
            }
        }
    }

    public enum ManualShutter: Int, CaseIterable, Identifiable, Sendable {
        case s1_25 = 25
        case s1_30 = 30
        case s1_40 = 40
        case s1_50 = 50
        case s1_60 = 60
        case s1_80 = 80
        case s1_100 = 100
        case s1_120 = 120
        case s1_160 = 160
        case s1_200 = 200
        case s1_240 = 240
        case s1_320 = 320
        case s1_500 = 500
        case s1_1000 = 1000
        case s1_2000 = 2000
        case s1_4000 = 4000
        case s1_8000 = 8000

        public var id: Int { rawValue }
        public var displayName: String { "1/\(rawValue)" }

        public var payload: Data {
            let encoded = UInt16(0x8000) | UInt16(rawValue)
            return Data([
                0x01,
                UInt8(encoded & 0xFF),
                UInt8((encoded >> 8) & 0xFF),
                0x00, 0x00, 0x00, 0x40
            ])
        }
    }

    public enum WhiteBalance: Equatable, Sendable {
        case auto
        case customKelvin(Int)
    }

    public enum ColorProfile: UInt8, CaseIterable, Identifiable, Sendable {
        case normal = 0x00
        case hlg = 0x3C
        case dLogM = 0x3D

        public var id: UInt8 { rawValue }
        public var displayName: String {
            switch self {
            case .normal: return "Normal"
            case .hlg: return "HLG"
            case .dLogM: return "D-Log M"
            }
        }
    }

    public enum FocusMode: UInt8, CaseIterable, Identifiable, Sendable {
        case single = 0x01
        case continuous = 0x02

        public var id: UInt8 { rawValue }
        public var displayName: String {
            switch self {
            case .single: return "Single"
            case .continuous: return "Continuous"
            }
        }
    }

    public static func proEnabled(_ enabled: Bool) -> Pocket3Command {
        keyedParameter(pid: 0x0000, value: Data([enabled ? 0x01 : 0x00]), label: "Pro Mode")
    }

    public static func exposureMode(_ mode: ExposureMode) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x1E,
            payload: Data([mode.rawValue, 0x00]),
            label: "Exposure Mode \(mode.displayName)"
        )
    }

    /// Auto EV compensation in 1/3-stop steps (`-9...9` -> `-3.0...+3.0 EV`). Center is `0x10`.
    public static func autoEV(thirdStops: Int) -> Pocket3Command? {
        guard (-9...9).contains(thirdStops) else { return nil }
        let code = UInt8(0x10 + thirdStops)
        return Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x2E,
            payload: Data([code]),
            label: String(format: "EV %+.1f", Double(thirdStops) / 3.0)
        )
    }

    public static func manualISO(_ iso: ManualISO) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x2A,
            payload: Data([iso.rawValue]),
            label: "ISO \(iso.displayName)"
        )
    }

    public static func isoMax(_ isoMax: ISOMax) -> Pocket3Command {
        keyedParameter(pid: 0x000F, value: Data([isoMax.rawValue]), label: "ISO Max \(isoMax.displayName)")
    }

    public static func manualShutter(_ shutter: ManualShutter) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x28,
            payload: shutter.payload,
            label: "Shutter \(shutter.displayName)"
        )
    }

    public static func whiteBalance(_ wb: WhiteBalance) -> Pocket3Command? {
        switch wb {
        case .auto:
            return Pocket3Command(
                cmdSet: 0x02,
                cmdId: 0x2C,
                payload: Data([0x00, 0x00, 0x00, 0x00, 0x00]),
                label: "White Balance Auto"
            )
        case .customKelvin(let kelvin):
            let snapped = max(2000, min(10_000, (kelvin / 100) * 100))
            let encoded = UInt8(snapped / 100)
            return Pocket3Command(
                cmdSet: 0x02,
                cmdId: 0x2C,
                payload: Data([0x06, encoded, 0x00, 0x00, 0x00]),
                label: "White Balance \(snapped)K"
            )
        }
    }

    public static func colorProfile(_ profile: ColorProfile) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x42,
            payload: Data([profile.rawValue]),
            label: "Color Profile \(profile.displayName)"
        )
    }

    public static func focusMode(_ mode: FocusMode) -> Pocket3Command {
        Pocket3Command(
            cmdSet: 0x02,
            cmdId: 0x24,
            payload: Data([mode.rawValue]),
            label: "Focus Mode \(mode.displayName)"
        )
    }

    public static func productShowcaseEnabled(_ enabled: Bool) -> Pocket3Command {
        keyedParameter(
            pid: 0x003B,
            value: Data([0x01, enabled ? 0x01 : 0x00]),
            label: "Product Showcase"
        )
    }

    public static func keyedParameter(pid: UInt16, value: Data, label: String) -> Pocket3Command {
        precondition(value.count <= 255)
        var payload = Data([
            0x01, 0x01,
            UInt8(pid & 0xFF),
            UInt8((pid >> 8) & 0xFF),
            UInt8(value.count)
        ])
        payload.append(value)
        return Pocket3Command(cmdSet: 0x02, cmdId: 0x8E, payload: payload, label: label)
    }

    /// Subscribes to a named camera property on the `00/99` readback bus.
    public static func subscribeCameraProperty(name: String, transactionID: UInt32) -> Pocket3Command? {
        guard let nameData = name.data(using: .ascii), nameData.count <= Int(UInt16.max) - 6 else {
            return nil
        }
        var payload = Data([0x02, 0x02, 0x00, 0x00])
        appendLE32(transactionID, to: &payload)
        payload.append(contentsOf: [0x00, 0x00, 0x00])
        appendLE16(UInt16(nameData.count + 6), to: &payload)
        appendLE16(UInt16(nameData.count), to: &payload)
        payload.append(nameData)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return Pocket3Command(
            cmdSet: 0x00,
            cmdId: 0x99,
            payload: payload,
            receiverType: 0x08,
            receiverId: 1,
            cmdType: 2,
            label: "Subscribe \(name)"
        )
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

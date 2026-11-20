import Foundation

public enum DumlError: Error, Equatable, CustomStringConvertible, Sendable {
    case tooShort
    case badSOF
    case badLength(expected: Int, actual: Int)
    case badVersion(UInt8)
    case badHeaderCRC(expected: UInt8, actual: UInt8)
    case badPayloadCRC(expected: UInt16, actual: UInt16)

    public var description: String {
        switch self {
        case .tooShort:
            return "DUML frame too short"
        case .badSOF:
            return "Bad DUML SOF byte (expected 0x55)"
        case .badLength(let expected, let actual):
            return "Bad DUML length: expected \(expected), actual \(actual)"
        case .badVersion(let v):
            return "Bad DUML version: \(v)"
        case .badHeaderCRC(let expected, let actual):
            return String(format: "Bad DUML header CRC8: expected 0x%02X, got 0x%02X", expected, actual)
        case .badPayloadCRC(let expected, let actual):
            return String(format: "Bad DUML payload CRC16: expected 0x%04X, got 0x%04X", expected, actual)
        }
    }
}

/// A DJI DUML binary protocol message.
///
/// Wire layout:
/// `[0x55] [len_lo] [ver<<2 | len_hi] [crc8] [target:2B LE] [id:2B LE] [flags:1B] [cmdSet:1B] [cmdId:1B] [payload:NB] [crc16:2B LE]`
public struct DumlMessage: Equatable, Sendable {
    public var target: UInt16
    public var id: UInt16
    public var type: UInt32
    public var payload: Data

    public var flags: UInt8 { UInt8(type & 0xFF) }
    public var cmdSet: UInt8 { UInt8((type >> 8) & 0xFF) }
    public var cmdId: UInt8 { UInt8((type >> 16) & 0xFF) }

    public init(target: UInt16, id: UInt16, type: UInt32, payload: Data = Data()) {
        self.target = target
        self.id = id
        self.type = type & 0x00FF_FFFF
        self.payload = payload
    }

    public init(
        target: UInt16,
        id: UInt16,
        flags: UInt8 = 0x40,
        cmdSet: UInt8,
        cmdId: UInt8,
        payload: Data = Data()
    ) {
        let packedType = UInt32(flags) | (UInt32(cmdSet) << 8) | (UInt32(cmdId) << 16)
        self.init(target: target, id: id, type: packedType, payload: payload)
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { throw DumlError.tooShort }
        guard bytes[0] == 0x55 else { throw DumlError.badSOF }

        let packedLen = Int(bytes[1]) | (Int(bytes[2] & 0x03) << 8)
        let version = bytes[2] >> 2
        guard version == 1 else { throw DumlError.badVersion(version) }
        guard packedLen == bytes.count else {
            throw DumlError.badLength(expected: packedLen, actual: bytes.count)
        }

        let expectedHeaderCRC = DjiCRC.crc8(Data(bytes[0..<3]))
        guard bytes[3] == expectedHeaderCRC else {
            throw DumlError.badHeaderCRC(expected: expectedHeaderCRC, actual: bytes[3])
        }

        let target = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        let id = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let type = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16)

        let payloadEnd = bytes.count - 2
        let payload = payloadEnd > 11 ? Data(bytes[11..<payloadEnd]) : Data()

        let receivedCRC = UInt16(bytes[payloadEnd]) | (UInt16(bytes[payloadEnd + 1]) << 8)
        let calculatedCRC = DjiCRC.crc16(Data(bytes[0..<payloadEnd]))
        guard receivedCRC == calculatedCRC else {
            throw DumlError.badPayloadCRC(expected: calculatedCRC, actual: receivedCRC)
        }

        self.target = target
        self.id = id
        self.type = type
        self.payload = payload
    }

    public func encode() -> Data {
        let totalLength = 13 + payload.count
        precondition(totalLength <= 0x03FF, "DUML frame exceeds 10-bit length limit")

        var bytes = [UInt8]()
        bytes.reserveCapacity(totalLength)

        bytes.append(0x55)
        bytes.append(UInt8(totalLength & 0xFF))
        bytes.append(UInt8((1 << 2) | ((totalLength >> 8) & 0x03)))
        bytes.append(DjiCRC.crc8(Data(bytes)))

        bytes.append(UInt8(truncatingIfNeeded: target))
        bytes.append(UInt8(truncatingIfNeeded: target >> 8))

        bytes.append(UInt8(truncatingIfNeeded: id))
        bytes.append(UInt8(truncatingIfNeeded: id >> 8))

        bytes.append(UInt8(truncatingIfNeeded: type))
        bytes.append(UInt8(truncatingIfNeeded: type >> 8))
        bytes.append(UInt8(truncatingIfNeeded: type >> 16))

        bytes.append(contentsOf: payload)

        let crc = DjiCRC.crc16(Data(bytes))
        bytes.append(UInt8(truncatingIfNeeded: crc))
        bytes.append(UInt8(truncatingIfNeeded: crc >> 8))

        return Data(bytes)
    }

    /// Scans an arbitrary byte stream (e.g., UDP datagram or multi-frame BLE buffer)
    /// and extracts every CRC-valid DUML frame.
    public static func scanFrames(in raw: Data) -> [DumlMessage] {
        let bytes = [UInt8](raw)
        var frames: [DumlMessage] = []
        var index = 0

        while index + 13 <= bytes.count {
            guard bytes[index] == 0x55 else {
                index += 1
                continue
            }

            let packedLen = Int(bytes[index + 1]) | (Int(bytes[index + 2] & 0x03) << 8)
            let version = bytes[index + 2] >> 2
            guard version == 1, packedLen >= 13, index + packedLen <= bytes.count else {
                index += 1
                continue
            }

            let slice = Data(bytes[index..<(index + packedLen)])
            if let message = try? DumlMessage(data: slice) {
                frames.append(message)
            }
            index += 1
        }
        return frames
    }
}

public extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}

import Foundation

/// DJI DUML CRC-8 and CRC-16 checksum routines.
/// Verified against DJI Osmo Pocket 3 BLE and UDP wire captures.
public enum DjiCRC {
    /// Reflected CRC-8 (poly 0x31 reflected -> 0x8C, init 0x77 / 0xEE reflected).
    public static func crc8(
        _ data: Data,
        initial: UInt8 = 0x77,
        polynomial: UInt8 = 0x8C
    ) -> UInt8 {
        var crc = initial
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x01) != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// Reflected CRC-16 (poly 0x1021 reflected -> 0x8408, init 0x3692 / 0x496C reflected).
    public static func crc16(
        _ data: Data,
        initial: UInt16 = 0x3692,
        polynomial: UInt16 = 0x8408
    ) -> UInt16 {
        var crc = initial
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}

import XCTest
@testable import OsmoCore

final class OsmoCoreTests: XCTestCase {
    // MARK: - CRC8 & CRC16 (verified against DJI Osmo Pocket 3 wire vectors)

    func testDjiCRC8Vectors() throws {
        let wakeHeader = try XCTUnwrap(Data(hexString: "550F04"))
        XCTAssertEqual(DjiCRC.crc8(wakeHeader), 0xA2)

        let pairHeader = try XCTUnwrap(Data(hexString: "553304"))
        XCTAssertEqual(DjiCRC.crc8(pairHeader), 0xC2)
    }

    func testDjiCRC16Vectors() throws {
        let wakeBody = try XCTUnwrap(Data(hexString: "550F04A202F02B8040002B0400"))
        XCTAssertEqual(DjiCRC.crc16(wakeBody), 0x4024)

        let routingBody = try XCTUnwrap(Data(hexString: "550F04A202073412400D026162"))
        XCTAssertEqual(DjiCRC.crc16(routingBody), 0x339B)
    }

    // MARK: - DUML Framing

    func testSessionWakeFrameMatchesExactWireBytes() throws {
        let encoded = Pocket3Commands.sessionPing(Pocket3Commands.sessionWakePayload, id: 0x802B)
        XCTAssertEqual(encoded.hexString, "550F04A202F02B8040002B04002440")

        let decoded = try DumlMessage(data: encoded)
        XCTAssertEqual(decoded.target, 0xF002)
        XCTAssertEqual(decoded.id, 0x802B)
        XCTAssertEqual(decoded.flags, 0x40)
        XCTAssertEqual(decoded.cmdSet, 0x00)
        XCTAssertEqual(decoded.cmdId, 0x2B)
        XCTAssertEqual(decoded.payload, Data([0x04, 0x00]))
    }

    func testCorruptedFrameRejectedWithPayloadCRCError() throws {
        let corrupted = try XCTUnwrap(Data(hexString: "550F04A202F02B8040002B05002440"))
        XCTAssertThrowsError(try DumlMessage(data: corrupted)) { error in
            guard case DumlError.badPayloadCRC = error else {
                XCTFail("Expected badPayloadCRC, got \(error)")
                return
            }
        }
    }

    func testFrameScannerExtractsMultipleFramesAmidNoise() {
        let f1 = Pocket3Commands.sessionPing(Pocket3Commands.sessionWakePayload, id: 0x1001)
        let f2 = Pocket3Commands.gimbalRecenter().encodeDuml(id: 0x1002)
        var stream = Data([0x00, 0xFF, 0x55, 0x01])
        stream.append(f1)
        stream.append(Data([0xAA, 0xBB]))
        stream.append(f2)

        let scanned = DumlMessage.scanFrames(in: stream)
        XCTAssertEqual(scanned.count, 2)
        XCTAssertEqual(scanned[0].id, 0x1001)
        XCTAssertEqual(scanned[1].id, 0x1002)
        XCTAssertEqual(scanned[1].payload, Data([0xFE, 0x08]))
    }

    // MARK: - Gimbal & Camera Command Vectors

    func testGimbalVelocityVectors() {
        let neutral = Pocket3Commands.gimbalVelocity(pitch: 1024, yaw: 1024)
        XCTAssertEqual(neutral.cmdSet, 0x04)
        XCTAssertEqual(neutral.cmdId, 0x01)
        XCTAssertEqual(neutral.payload.hexString, "00040000000400802200")

        let upLeft = Pocket3Commands.gimbalVelocity(pitch: 1354, yaw: 694)
        XCTAssertEqual(upLeft.payload.hexString, "4A050000B60200802200")

        let downRight = Pocket3Commands.gimbalVelocity(pitch: 694, yaw: 1354)
        XCTAssertEqual(downRight.payload.hexString, "B60200004A0500802200")
    }

    func testGimbalRecenterFlipAndLockCommands() {
        let recenter = Pocket3Commands.gimbalRecenter()
        XCTAssertEqual(recenter.cmdSet, 0x04)
        XCTAssertEqual(recenter.cmdId, 0x4C)
        XCTAssertEqual(recenter.payload.hexString, "FE08")

        let flip = Pocket3Commands.gimbalSelfieFlip()
        XCTAssertEqual(flip.payload.hexString, "FE09")

        XCTAssertEqual(Pocket3Commands.gimbalLock(true).payload.hexString, "0000")
        XCTAssertEqual(Pocket3Commands.gimbalLock(false).payload.hexString, "0100")
    }

    func testCameraSettingsCommandVectors() {
        XCTAssertEqual(Pocket3Commands.manualISO(.auto).payload.hexString, "00")
        XCTAssertEqual(Pocket3Commands.manualISO(.iso100).payload.hexString, "03")
        XCTAssertEqual(Pocket3Commands.manualISO(.iso6400).payload.hexString, "09")

        XCTAssertEqual(Pocket3Commands.isoMax(.iso100).payload.hexString, "01010F000101")
        XCTAssertEqual(Pocket3Commands.isoMax(.iso6400).payload.hexString, "01010F000107")

        XCTAssertEqual(Pocket3Commands.autoEV(thirdStops: 0)?.payload.hexString, "10")
        XCTAssertEqual(Pocket3Commands.autoEV(thirdStops: -3)?.payload.hexString, "0D")
        XCTAssertEqual(Pocket3Commands.autoEV(thirdStops: 3)?.payload.hexString, "13")

        XCTAssertEqual(Pocket3Commands.whiteBalance(.auto)?.payload.hexString, "0000000000")
        XCTAssertEqual(Pocket3Commands.whiteBalance(.customKelvin(5600))?.payload.hexString, "0638000000")
        XCTAssertEqual(Pocket3Commands.colorProfile(.dLogM).payload.hexString, "3D")
    }

    // MARK: - Telemetry & Continuous Yaw

    func testContinuousYawUnwrapsAcrossBoundary() {
        var reducer = ContinuousYawReducer()
        XCTAssertEqual(reducer.update(wrappedYawDeg: 179.0), 179.0, accuracy: 0.001)
        XCTAssertEqual(reducer.update(wrappedYawDeg: -179.0), 181.0, accuracy: 0.001)
        XCTAssertEqual(reducer.update(wrappedYawDeg: 179.0), 179.0, accuracy: 0.001)
    }

    func testBatteryStatusParser() {
        var payload = Data(repeating: 0x00, count: 33)
        payload[20] = 84
        payload[32] = 0x01
        let status = Pocket3TelemetryParser.parseBattery(payload: payload)
        XCTAssertEqual(status, BatteryStatus(percent: 84, isCharging: true))

        payload[20] = 105 // invalid > 100
        XCTAssertNil(Pocket3TelemetryParser.parseBattery(payload: payload))
    }

    // MARK: - UVC Descriptor & Pan/Tilt Arcseconds

    func testUVCDescriptorParserExtractsUnits() {
        // Synthetic USB configuration descriptor containing VideoControl interface 0,
        // Camera Input Terminal ID=1 (ITT_CAMERA 0x0201), Processing Unit ID=2, Extension Unit ID=4
        let raw: [UInt8] = [
            // Config descriptor (9 bytes, wTotalLength = 42)
            0x09, 0x02, 42, 0x00, 0x02, 0x01, 0x00, 0x80, 0xFA,
            // Interface descriptor: Interface 0, Class 0x0E (Video), SubClass 0x01 (VideoControl)
            0x09, 0x04, 0x00, 0x00, 0x01, 0x0E, 0x01, 0x00, 0x00,
            // CS_INTERFACE VC_HEADER (13 bytes)
            0x0D, 0x24, 0x01, 0x00, 0x01, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01,
            // CS_INTERFACE INPUT_TERMINAL (6 bytes): ID=1, wTerminalType=0x0201
            0x06, 0x24, 0x02, 0x01, 0x01, 0x02,
            // CS_INTERFACE PROCESSING_UNIT (5 bytes): ID=2
            0x05, 0x24, 0x05, 0x02, 0x01
        ]
        let parsed = UVCDescriptorParser.parse(configDescriptorBytes: raw)
        XCTAssertEqual(parsed, UVCDescriptorInfo(interfaceNumber: 0, cameraTerminalID: 1, processingUnitID: 2))
    }

    func testUVCPanTiltArcsecondsRoundTripIncludesNegativeAngles() {
        let encoded = UVCPanTiltState.encodeArcseconds(panDeg: -45.5, tiltDeg: 22.25)
        XCTAssertEqual(encoded.count, 8)
        let decoded = UVCPanTiltState.decodeArcseconds(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.panDeg, -45.5, accuracy: 0.001)
        XCTAssertEqual(decoded!.tiltDeg, 22.25, accuracy: 0.001)
    }

    func testVendorProductModelIDParsing() {
        let parsed = UVCController.parseVendorProduct(fromModelID: "UVC Camera VendorID_11427 ProductID_35")
        XCTAssertEqual(parsed.vendorID, 0x2CA3)
        XCTAssertEqual(parsed.productID, 0x0023)
    }
}

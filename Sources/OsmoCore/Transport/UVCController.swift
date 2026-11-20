import Foundation
@preconcurrency import AVFoundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Parsed UVC VideoControl descriptor metadata.
public struct UVCDescriptorInfo: Equatable, Sendable {
    public let interfaceNumber: Int
    public let cameraTerminalID: Int
    public let processingUnitID: Int
    public let extensionUnitIDs: [Int]

    public init(
        interfaceNumber: Int,
        cameraTerminalID: Int,
        processingUnitID: Int,
        extensionUnitIDs: [Int] = []
    ) {
        self.interfaceNumber = interfaceNumber
        self.cameraTerminalID = cameraTerminalID
        self.processingUnitID = processingUnitID
        self.extensionUnitIDs = extensionUnitIDs
    }
}

/// Pure-Swift UVC configuration descriptor parser (no C bridging headers needed).
public enum UVCDescriptorParser {
    private static let usbDescriptorTypeInterface: UInt8 = 0x04
    private static let uvcClassVideo: UInt8 = 0x0E
    private static let uvcSubclassVideoControl: UInt8 = 0x01
    private static let uvcDescriptorTypeCSInterface: UInt8 = 0x24
    private static let uvcSubtypeVCHeader: UInt8 = 0x01
    private static let uvcSubtypeInputTerminal: UInt8 = 0x02
    private static let uvcSubtypeProcessingUnit: UInt8 = 0x05
    private static let uvcSubtypeExtensionUnit: UInt8 = 0x06

    public static func parse(configDescriptorBytes bytes: [UInt8]) -> UVCDescriptorInfo? {
        guard bytes.count >= 9 else { return nil }
        let totalLength = min(bytes.count, Int(bytes[2]) | (Int(bytes[3]) << 8))
        var offset = Int(bytes[0]) // skip config descriptor header

        var vcInterfaceNumber: Int?
        var cameraTerminalID = -1
        var processingUnitID = -1
        var extensionUnitIDs: [Int] = []
        var inVideoControlInterface = false

        while offset + 2 <= totalLength {
            let len = Int(bytes[offset])
            guard len >= 2, offset + len <= totalLength else { break }
            let descType = bytes[offset + 1]

            if descType == usbDescriptorTypeInterface, len >= 9 {
                let interfaceNumber = Int(bytes[offset + 2])
                let interfaceClass = bytes[offset + 5]
                let interfaceSubClass = bytes[offset + 6]
                if interfaceClass == uvcClassVideo && interfaceSubClass == uvcSubclassVideoControl {
                    vcInterfaceNumber = interfaceNumber
                    inVideoControlInterface = true
                } else if inVideoControlInterface {
                    break
                }
            } else if inVideoControlInterface && descType == uvcDescriptorTypeCSInterface && len >= 4 {
                let subType = bytes[offset + 2]
                switch subType {
                case uvcSubtypeVCHeader:
                    break
                case uvcSubtypeInputTerminal:
                    // Input Terminal descriptor: byte 3 = bTerminalID, bytes 4..5 = wTerminalType (0x0201 = ITT_CAMERA)
                    if len >= 6 {
                        let terminalType = UInt16(bytes[offset + 4]) | (UInt16(bytes[offset + 5]) << 8)
                        if terminalType == 0x0201 || cameraTerminalID == -1 {
                            cameraTerminalID = Int(bytes[offset + 3])
                        }
                    } else {
                        cameraTerminalID = Int(bytes[offset + 3])
                    }
                case uvcSubtypeProcessingUnit:
                    processingUnitID = Int(bytes[offset + 3])
                case uvcSubtypeExtensionUnit:
                    extensionUnitIDs.append(Int(bytes[offset + 3]))
                default:
                    break
                }
            }

            offset += len
        }

        guard let interfaceNumber = vcInterfaceNumber else { return nil }
        return UVCDescriptorInfo(
            interfaceNumber: interfaceNumber,
            cameraTerminalID: cameraTerminalID,
            processingUnitID: processingUnitID,
            extensionUnitIDs: extensionUnitIDs
        )
    }
}

/// Standard UVC numeric control range and current value.
public struct UVCControlRange: Equatable, Sendable {
    public let min: Int
    public let max: Int
    public let step: Int
    public let defaultValue: Int
    public var current: Int

    public init(min: Int, max: Int, step: Int, defaultValue: Int, current: Int) {
        self.min = min
        self.max = max
        self.step = Swift.max(1, step)
        self.defaultValue = defaultValue
        self.current = current
    }
}

/// Pan/Tilt absolute control range (in degrees, converted from UVC arcseconds / 3600).
public struct UVCPanTiltState: Equatable, Sendable {
    public let panMinDeg: Double
    public let panMaxDeg: Double
    public let panStepDeg: Double
    public let panDefaultDeg: Double
    public var panDeg: Double

    public let tiltMinDeg: Double
    public let tiltMaxDeg: Double
    public let tiltStepDeg: Double
    public let tiltDefaultDeg: Double
    public var tiltDeg: Double

    public init(
        panMinDeg: Double,
        panMaxDeg: Double,
        panStepDeg: Double,
        panDefaultDeg: Double,
        panDeg: Double,
        tiltMinDeg: Double,
        tiltMaxDeg: Double,
        tiltStepDeg: Double,
        tiltDefaultDeg: Double,
        tiltDeg: Double
    ) {
        self.panMinDeg = panMinDeg
        self.panMaxDeg = panMaxDeg
        self.panStepDeg = panStepDeg
        self.panDefaultDeg = panDefaultDeg
        self.panDeg = panDeg
        self.tiltMinDeg = tiltMinDeg
        self.tiltMaxDeg = tiltMaxDeg
        self.tiltStepDeg = tiltStepDeg
        self.tiltDefaultDeg = tiltDefaultDeg
        self.tiltDeg = tiltDeg
    }

    /// Encodes pan and tilt degrees into the 8-byte UVC `CT_PANTILT_ABSOLUTE_CONTROL` payload.
    public static func encodeArcseconds(panDeg: Double, tiltDeg: Double) -> Data {
        let panArcsec = Int32((panDeg * 3600.0).rounded())
        let tiltArcsec = Int32((tiltDeg * 3600.0).rounded())
        var bytes = [UInt8](repeating: 0, count: 8)
        let p = UInt32(bitPattern: panArcsec)
        let t = UInt32(bitPattern: tiltArcsec)
        bytes[0] = UInt8(p & 0xFF)
        bytes[1] = UInt8((p >> 8) & 0xFF)
        bytes[2] = UInt8((p >> 16) & 0xFF)
        bytes[3] = UInt8((p >> 24) & 0xFF)
        bytes[4] = UInt8(t & 0xFF)
        bytes[5] = UInt8((t >> 8) & 0xFF)
        bytes[6] = UInt8((t >> 16) & 0xFF)
        bytes[7] = UInt8((t >> 24) & 0xFF)
        return Data(bytes)
    }

    /// Decodes an 8-byte UVC `CT_PANTILT_ABSOLUTE_CONTROL` payload into (panDeg, tiltDeg).
    public static func decodeArcseconds(_ data: Data) -> (panDeg: Double, tiltDeg: Double)? {
        guard data.count >= 8 else { return nil }
        let p = UInt32(data[0])
            | (UInt32(data[1]) << 8)
            | (UInt32(data[2]) << 16)
            | (UInt32(data[3]) << 24)
        let t = UInt32(data[4])
            | (UInt32(data[5]) << 8)
            | (UInt32(data[6]) << 16)
            | (UInt32(data[7]) << 24)
        let pan = Int32(bitPattern: p)
        let tilt = Int32(bitPattern: t)
        return (Double(pan) / 3600.0, Double(tilt) / 3600.0)
    }
}

/// Snapshot of all probed UVC controls for a connected camera.
public struct UVCCapabilitiesSnapshot: Equatable, Sendable {
    public var descriptor: UVCDescriptorInfo?
    public var panTiltAbsolute: UVCPanTiltState?
    public var supportsPanTiltRelative: Bool = false
    public var zoomAbsolute: UVCControlRange?
    public var rollAbsolute: UVCControlRange?

    public var exposureAutoSupported: Bool = false
    public var exposureAuto: Bool = true
    public var exposureTimeAbsolute: UVCControlRange?

    public var whiteBalanceAutoSupported: Bool = false
    public var whiteBalanceAuto: Bool = true
    public var whiteBalanceTemperature: UVCControlRange?

    public var brightness: UVCControlRange?
    public var contrast: UVCControlRange?
    public var saturation: UVCControlRange?
    public var sharpness: UVCControlRange?
    public var gain: UVCControlRange?
    public var backlightCompensation: UVCControlRange?

    public var focusAutoSupported: Bool = false
    public var focusAuto: Bool = true
    public var focusAbsolute: UVCControlRange?

    public init() {}

    public var supportedControlNames: [String] {
        var list: [String] = []
        if panTiltAbsolute != nil { list.append("Pan/Tilt Abs") }
        if supportsPanTiltRelative { list.append("Pan/Tilt Rel") }
        if zoomAbsolute != nil { list.append("Zoom") }
        if rollAbsolute != nil { list.append("Roll") }
        if exposureAutoSupported { list.append("AE Mode") }
        if exposureTimeAbsolute != nil { list.append("Exposure Time") }
        if whiteBalanceAutoSupported { list.append("WB Auto") }
        if whiteBalanceTemperature != nil { list.append("WB Temp") }
        if brightness != nil { list.append("Brightness") }
        if contrast != nil { list.append("Contrast") }
        if saturation != nil { list.append("Saturation") }
        if sharpness != nil { list.append("Sharpness") }
        if gain != nil { list.append("Gain") }
        if backlightCompensation != nil { list.append("Backlight") }
        if focusAutoSupported { list.append("Auto Focus") }
        if focusAbsolute != nil { list.append("Focus Abs") }
        return list
    }
}

/// Metadata for a discovered macOS video capture camera.
public struct DiscoveredCamera: Identifiable, Equatable, Sendable {
    public let id: String          // AVCaptureDevice.uniqueID
    public let name: String        // localizedName
    public let modelID: String
    public let vendorID: Int?
    public let productID: Int?
    public let isDJI: Bool

    public static let djiVendorID = 0x2CA3 // 11427
}

public enum UVCError: Error, CustomStringConvertible, Sendable {
    case deviceNotFound
    case videoControlInterfaceNotFound
    case descriptorNotFound
    case requestFailed(Int32)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return "Matching USB device not found in IORegistry"
        case .videoControlInterfaceNotFound:
            return "USB VideoControl interface (0x0E/0x01) not found"
        case .descriptorNotFound:
            return "Unable to parse UVC configuration descriptor"
        case .requestFailed(let code):
            return String(format: "UVC control transfer failed (0x%08X)", code)
        }
    }
}

/// Native macOS IOKit UVC control-plane client.
/// Uses `IOUSBInterfaceInterface190.ControlRequest` on pipe 0 so it operates
/// concurrently while FaceTime, Zoom, Meet, or OBS streams from the webcam.
public final class UVCController: @unchecked Sendable {
    private typealias DeviceInterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>
    private typealias InterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface190>>
    private typealias PlugInPtr = UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>>

    // Standard IOKit USB UUIDs
    private static var kIOUSBDeviceUserClientTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            kCFAllocatorDefault,
            0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
            0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )!
    }
    private static var kIOUSBDeviceInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            kCFAllocatorDefault,
            0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
            0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )!
    }
    private static var kIOUSBInterfaceUserClientTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            kCFAllocatorDefault,
            0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
            0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )!
    }
    private static var kIOUSBInterfaceInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            kCFAllocatorDefault,
            0x73, 0xC9, 0x7A, 0xE8, 0x9E, 0xF3, 0x11, 0xD4,
            0xB1, 0xD0, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )!
    }
    private static var kIOCFPlugInInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            kCFAllocatorDefault,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
        )!
    }

    // UVC request codes
    private enum RequestCode: UInt8 {
        case setCur = 0x01
        case getCur = 0x81
        case getMin = 0x82
        case getMax = 0x83
        case getRes = 0x84
        case getInfo = 0x86
        case getDef = 0x87
    }

    // Camera Terminal selectors
    private enum CTSelector: UInt8 {
        case aeMode = 0x02
        case exposureTimeAbs = 0x04
        case focusAbs = 0x06
        case focusAuto = 0x08
        case zoomAbs = 0x0B
        case panTiltAbs = 0x0D
        case panTiltRel = 0x0E
        case rollAbs = 0x0F
    }

    // Processing Unit selectors
    private enum PUSelector: UInt8 {
        case backlightComp = 0x01
        case brightness = 0x02
        case contrast = 0x03
        case gain = 0x04
        case saturation = 0x07
        case sharpness = 0x08
        case whiteBalanceTemp = 0x0A
        case whiteBalanceTempAuto = 0x0B
    }

    private let lock = NSLock()
    private var usbInterface: InterfacePtr?
    private var descriptor: UVCDescriptorInfo?

    public init() {}

    deinit {
        disconnect()
    }

    // MARK: - Discovery

    public static func discoverCameras() -> [DiscoveredCamera] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { device in
            let parsed = parseVendorProduct(fromModelID: device.modelID)
            let lowerName = device.localizedName.lowercased()
            let isDJI = parsed.vendorID == DiscoveredCamera.djiVendorID
                || lowerName.contains("osmo")
                || lowerName.contains("pocket")
                || lowerName.contains("dji")
            return DiscoveredCamera(
                id: device.uniqueID,
                name: device.localizedName,
                modelID: device.modelID,
                vendorID: parsed.vendorID,
                productID: parsed.productID,
                isDJI: isDJI
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDJI != rhs.isDJI { return lhs.isDJI }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func parseVendorProduct(fromModelID modelID: String) -> (vendorID: Int?, productID: Int?) {
        func extract(_ prefix: String) -> Int? {
            guard let range = modelID.range(of: prefix) else { return nil }
            let rest = modelID[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            return Int(digits)
        }
        return (extract("VendorID_"), extract("ProductID_"))
    }

    // MARK: - Connection

    public func connect(to camera: DiscoveredCamera) throws -> UVCCapabilitiesSnapshot {
        disconnect()

        let service = try findUSBService(for: camera)
        defer { IOObjectRelease(service) }

        var interfaceRef: InterfacePtr?
        var parsedDescriptor: UVCDescriptorInfo?

        try withPlugIn(service: service, type: Self.kIOUSBDeviceUserClientTypeID) { plugIn in
            let devicePtr: DeviceInterfacePtr = try queryInterface(plugIn: plugIn, uuid: Self.kIOUSBDeviceInterfaceID)
            defer { _ = devicePtr.pointee.pointee.Release(devicePtr) }

            // Parse Configuration Descriptor 0
            var numConfigs: UInt8 = 0
            if devicePtr.pointee.pointee.GetNumberOfConfigurations(devicePtr, &numConfigs) == kIOReturnSuccess,
               numConfigs > 0 {
                var configDescPtr: IOUSBConfigurationDescriptorPtr?
                if devicePtr.pointee.pointee.GetConfigurationDescriptorPtr(devicePtr, 0, &configDescPtr) == kIOReturnSuccess,
                   let configDescPtr {
                    let totalLen = Int(configDescPtr.pointee.wTotalLength)
                    let rawPtr = UnsafeRawPointer(configDescPtr).assumingMemoryBound(to: UInt8.self)
                    let bytes = Array(UnsafeBufferPointer(start: rawPtr, count: totalLen))
                    parsedDescriptor = UVCDescriptorParser.parse(configDescriptorBytes: bytes)
                }
            }

            // Locate VideoControl interface (Class 0x0E, SubClass 0x01)
            var request = IOUSBFindInterfaceRequest(
                bInterfaceClass: 0x0E,
                bInterfaceSubClass: 0x01,
                bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare)
            )
            var iter: io_iterator_t = 0
            let iterErr = devicePtr.pointee.pointee.CreateInterfaceIterator(devicePtr, &request, &iter)
            guard iterErr == kIOReturnSuccess else {
                throw UVCError.videoControlInterfaceNotFound
            }
            defer { IOObjectRelease(iter) }

            let vcService = IOIteratorNext(iter)
            guard vcService != 0 else {
                throw UVCError.videoControlInterfaceNotFound
            }
            defer { IOObjectRelease(vcService) }

            try withPlugIn(service: vcService, type: Self.kIOUSBInterfaceUserClientTypeID) { ifPlugIn in
                interfaceRef = try queryInterface(plugIn: ifPlugIn, uuid: Self.kIOUSBInterfaceInterfaceID)
            }
        }

        guard let interfaceRef else {
            throw UVCError.videoControlInterfaceNotFound
        }
        guard let parsedDescriptor else {
            _ = interfaceRef.pointee.pointee.Release(interfaceRef)
            throw UVCError.descriptorNotFound
        }

        lock.lock()
        usbInterface = interfaceRef
        descriptor = parsedDescriptor
        lock.unlock()

        return probeCapabilities()
    }

    public func disconnect() {
        lock.lock()
        let iface = usbInterface
        usbInterface = nil
        descriptor = nil
        lock.unlock()

        if let iface {
            _ = iface.pointee.pointee.Release(iface)
        }
    }

    // MARK: - Probe Capabilities

    public func probeCapabilities() -> UVCCapabilitiesSnapshot {
        var snapshot = UVCCapabilitiesSnapshot()
        lock.lock()
        let desc = descriptor
        lock.unlock()
        guard let desc else { return snapshot }
        snapshot.descriptor = desc

        let ct = desc.cameraTerminalID
        let pu = desc.processingUnitID

        // Camera Terminal controls
        if ct >= 0 {
            snapshot.panTiltAbsolute = probePanTiltAbsolute(unit: ct)
            snapshot.supportsPanTiltRelative = isControlSupported(unit: ct, selector: CTSelector.panTiltRel.rawValue)
            snapshot.zoomAbsolute = probeUInt16Range(unit: ct, selector: CTSelector.zoomAbs.rawValue)
            snapshot.rollAbsolute = probeInt16Range(unit: ct, selector: CTSelector.rollAbs.rawValue)

            if isControlSupported(unit: ct, selector: CTSelector.aeMode.rawValue),
               let cur = readUInt8(unit: ct, selector: CTSelector.aeMode.rawValue, req: .getCur) {
                snapshot.exposureAutoSupported = true
                // Bit 1 (0x02) = Auto, Bit 3 (0x08) = Aperture Priority Auto
                snapshot.exposureAuto = (cur & 0x0A) != 0
            }
            snapshot.exposureTimeAbsolute = probeUInt32Range(unit: ct, selector: CTSelector.exposureTimeAbs.rawValue)

            if isControlSupported(unit: ct, selector: CTSelector.focusAuto.rawValue),
               let cur = readUInt8(unit: ct, selector: CTSelector.focusAuto.rawValue, req: .getCur) {
                snapshot.focusAutoSupported = true
                snapshot.focusAuto = cur != 0
            }
            snapshot.focusAbsolute = probeUInt16Range(unit: ct, selector: CTSelector.focusAbs.rawValue)
        }

        // Processing Unit controls
        if pu >= 0 {
            if isControlSupported(unit: pu, selector: PUSelector.whiteBalanceTempAuto.rawValue),
               let cur = readUInt8(unit: pu, selector: PUSelector.whiteBalanceTempAuto.rawValue, req: .getCur) {
                snapshot.whiteBalanceAutoSupported = true
                snapshot.whiteBalanceAuto = cur != 0
            }
            snapshot.whiteBalanceTemperature = probeUInt16Range(unit: pu, selector: PUSelector.whiteBalanceTemp.rawValue)
            snapshot.brightness = probeInt16Range(unit: pu, selector: PUSelector.brightness.rawValue)
            snapshot.contrast = probeUInt16Range(unit: pu, selector: PUSelector.contrast.rawValue)
            snapshot.saturation = probeUInt16Range(unit: pu, selector: PUSelector.saturation.rawValue)
            snapshot.sharpness = probeUInt16Range(unit: pu, selector: PUSelector.sharpness.rawValue)
            snapshot.gain = probeUInt16Range(unit: pu, selector: PUSelector.gain.rawValue)
            snapshot.backlightCompensation = probeUInt16Range(unit: pu, selector: PUSelector.backlightComp.rawValue)
        }

        return snapshot
    }

    // MARK: - Live Readers & Setters

    /// Reads current Pan/Tilt degrees directly from hardware (`GET_CUR` on `CT_PANTILT_ABSOLUTE_CONTROL`).
    public func readPanTiltAbsolute() -> (panDeg: Double, tiltDeg: Double)? {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return nil }
        guard let raw = readData(unit: ct, selector: CTSelector.panTiltAbs.rawValue, req: .getCur, length: 8) else {
            return nil
        }
        return UVCPanTiltState.decodeArcseconds(raw)
    }

    @discardableResult
    public func setPanTiltAbsolute(panDeg: Double, tiltDeg: Double) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        let data = UVCPanTiltState.encodeArcseconds(panDeg: panDeg, tiltDeg: tiltDeg)
        return writeData(unit: ct, selector: CTSelector.panTiltAbs.rawValue, data: data)
    }

    @discardableResult
    public func setPanTiltRelative(panDir: Int8, panSpeed: UInt8, tiltDir: Int8, tiltSpeed: UInt8) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        let data = Data([
            UInt8(bitPattern: panDir),
            panSpeed,
            UInt8(bitPattern: tiltDir),
            tiltSpeed
        ])
        return writeData(unit: ct, selector: CTSelector.panTiltRel.rawValue, data: data)
    }

    @discardableResult
    public func setZoomAbsolute(_ value: Int) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        return writeUInt16(unit: ct, selector: CTSelector.zoomAbs.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setRollAbsolute(_ value: Int) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        return writeInt16(unit: ct, selector: CTSelector.rollAbs.rawValue, value: Int16(clamping: value))
    }

    @discardableResult
    public func setExposureAuto(_ auto: Bool) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        // UVC AE Mode bitmap: 0x08 (Aperture Priority Auto) or 0x02 (Auto); 0x01 = Manual
        if auto {
            if writeUInt8(unit: ct, selector: CTSelector.aeMode.rawValue, value: 0x08) {
                return true
            }
            return writeUInt8(unit: ct, selector: CTSelector.aeMode.rawValue, value: 0x02)
        } else {
            return writeUInt8(unit: ct, selector: CTSelector.aeMode.rawValue, value: 0x01)
        }
    }

    @discardableResult
    public func setExposureTimeAbsolute(_ value: Int) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        return writeUInt32(unit: ct, selector: CTSelector.exposureTimeAbs.rawValue, value: UInt32(clamping: value))
    }

    @discardableResult
    public func setFocusAuto(_ auto: Bool) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        return writeUInt8(unit: ct, selector: CTSelector.focusAuto.rawValue, value: auto ? 1 : 0)
    }

    @discardableResult
    public func setFocusAbsolute(_ value: Int) -> Bool {
        guard let ct = currentDescriptor?.cameraTerminalID, ct >= 0 else { return false }
        return writeUInt16(unit: ct, selector: CTSelector.focusAbs.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setWhiteBalanceAuto(_ auto: Bool) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt8(unit: pu, selector: PUSelector.whiteBalanceTempAuto.rawValue, value: auto ? 1 : 0)
    }

    @discardableResult
    public func setWhiteBalanceTemperature(_ kelvin: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.whiteBalanceTemp.rawValue, value: UInt16(clamping: kelvin))
    }

    @discardableResult
    public func setBrightness(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeInt16(unit: pu, selector: PUSelector.brightness.rawValue, value: Int16(clamping: value))
    }

    @discardableResult
    public func setContrast(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.contrast.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setSaturation(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.saturation.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setSharpness(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.sharpness.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setGain(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.gain.rawValue, value: UInt16(clamping: value))
    }

    @discardableResult
    public func setBacklightCompensation(_ value: Int) -> Bool {
        guard let pu = currentDescriptor?.processingUnitID, pu >= 0 else { return false }
        return writeUInt16(unit: pu, selector: PUSelector.backlightComp.rawValue, value: UInt16(clamping: value))
    }

    // MARK: - Private Probe Helpers

    private var currentDescriptor: UVCDescriptorInfo? {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func isControlSupported(unit: Int, selector: UInt8) -> Bool {
        guard let info = readUInt8(unit: unit, selector: selector, req: .getInfo) else { return false }
        // Bit 0 = GET supported, Bit 1 = SET supported
        return (info & 0x03) != 0
    }

    private func probePanTiltAbsolute(unit: Int) -> UVCPanTiltState? {
        guard isControlSupported(unit: unit, selector: CTSelector.panTiltAbs.rawValue),
              let minRaw = readData(unit: unit, selector: CTSelector.panTiltAbs.rawValue, req: .getMin, length: 8),
              let maxRaw = readData(unit: unit, selector: CTSelector.panTiltAbs.rawValue, req: .getMax, length: 8),
              let curRaw = readData(unit: unit, selector: CTSelector.panTiltAbs.rawValue, req: .getCur, length: 8),
              let minPT = UVCPanTiltState.decodeArcseconds(minRaw),
              let maxPT = UVCPanTiltState.decodeArcseconds(maxRaw),
              let curPT = UVCPanTiltState.decodeArcseconds(curRaw) else {
            return nil
        }
        let resPT = readData(unit: unit, selector: CTSelector.panTiltAbs.rawValue, req: .getRes, length: 8)
            .flatMap(UVCPanTiltState.decodeArcseconds) ?? (1.0, 1.0)
        let defPT = readData(unit: unit, selector: CTSelector.panTiltAbs.rawValue, req: .getDef, length: 8)
            .flatMap(UVCPanTiltState.decodeArcseconds) ?? (0.0, 0.0)

        return UVCPanTiltState(
            panMinDeg: minPT.panDeg,
            panMaxDeg: maxPT.panDeg,
            panStepDeg: max(0.1, abs(resPT.panDeg)),
            panDefaultDeg: defPT.panDeg,
            panDeg: curPT.panDeg,
            tiltMinDeg: minPT.tiltDeg,
            tiltMaxDeg: maxPT.tiltDeg,
            tiltStepDeg: max(0.1, abs(resPT.tiltDeg)),
            tiltDefaultDeg: defPT.tiltDeg,
            tiltDeg: curPT.tiltDeg
        )
    }

    private func probeInt16Range(unit: Int, selector: UInt8) -> UVCControlRange? {
        guard isControlSupported(unit: unit, selector: selector),
              let minV = readInt16(unit: unit, selector: selector, req: .getMin),
              let maxV = readInt16(unit: unit, selector: selector, req: .getMax),
              let curV = readInt16(unit: unit, selector: selector, req: .getCur) else {
            return nil
        }
        let stepV = readInt16(unit: unit, selector: selector, req: .getRes).map { Int(abs($0)) } ?? 1
        let defV = readInt16(unit: unit, selector: selector, req: .getDef).map(Int.init) ?? Int(curV)
        return UVCControlRange(min: Int(minV), max: Int(maxV), step: stepV, defaultValue: defV, current: Int(curV))
    }

    private func probeUInt16Range(unit: Int, selector: UInt8) -> UVCControlRange? {
        guard isControlSupported(unit: unit, selector: selector),
              let minV = readUInt16(unit: unit, selector: selector, req: .getMin),
              let maxV = readUInt16(unit: unit, selector: selector, req: .getMax),
              let curV = readUInt16(unit: unit, selector: selector, req: .getCur) else {
            return nil
        }
        let stepV = readUInt16(unit: unit, selector: selector, req: .getRes).map(Int.init) ?? 1
        let defV = readUInt16(unit: unit, selector: selector, req: .getDef).map(Int.init) ?? Int(curV)
        return UVCControlRange(min: Int(minV), max: Int(maxV), step: stepV, defaultValue: defV, current: Int(curV))
    }

    private func probeUInt32Range(unit: Int, selector: UInt8) -> UVCControlRange? {
        guard isControlSupported(unit: unit, selector: selector),
              let minV = readUInt32(unit: unit, selector: selector, req: .getMin),
              let maxV = readUInt32(unit: unit, selector: selector, req: .getMax),
              let curV = readUInt32(unit: unit, selector: selector, req: .getCur) else {
            return nil
        }
        let stepV = readUInt32(unit: unit, selector: selector, req: .getRes).map(Int.init) ?? 1
        let defV = readUInt32(unit: unit, selector: selector, req: .getDef).map(Int.init) ?? Int(curV)
        return UVCControlRange(min: Int(minV), max: Int(maxV), step: stepV, defaultValue: defV, current: Int(curV))
    }

    // MARK: - Low-Level USB Control Pipe Transfers

    private func readUInt8(unit: Int, selector: UInt8, req: RequestCode) -> UInt8? {
        readData(unit: unit, selector: selector, req: req, length: 1)?.first
    }

    private func readUInt16(unit: Int, selector: UInt8, req: RequestCode) -> UInt16? {
        guard let d = readData(unit: unit, selector: selector, req: req, length: 2), d.count == 2 else { return nil }
        return UInt16(d[0]) | (UInt16(d[1]) << 8)
    }

    private func readInt16(unit: Int, selector: UInt8, req: RequestCode) -> Int16? {
        readUInt16(unit: unit, selector: selector, req: req).map(Int16.init(bitPattern:))
    }

    private func readUInt32(unit: Int, selector: UInt8, req: RequestCode) -> UInt32? {
        guard let d = readData(unit: unit, selector: selector, req: req, length: 4), d.count == 4 else { return nil }
        return UInt32(d[0]) | (UInt32(d[1]) << 8) | (UInt32(d[2]) << 16) | (UInt32(d[3]) << 24)
    }

    private func writeUInt8(unit: Int, selector: UInt8, value: UInt8) -> Bool {
        writeData(unit: unit, selector: selector, data: Data([value]))
    }

    private func writeUInt16(unit: Int, selector: UInt8, value: UInt16) -> Bool {
        writeData(unit: unit, selector: selector, data: Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]))
    }

    private func writeInt16(unit: Int, selector: UInt8, value: Int16) -> Bool {
        writeUInt16(unit: unit, selector: selector, value: UInt16(bitPattern: value))
    }

    private func writeUInt32(unit: Int, selector: UInt8, value: UInt32) -> Bool {
        writeData(
            unit: unit,
            selector: selector,
            data: Data([
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            ])
        )
    }

    private func readData(unit: Int, selector: UInt8, req: RequestCode, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let iface = usbInterface, let desc = descriptor else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        let requestType: UInt8 = 0xA1 // Device-to-Host | Class | Interface
        let status: IOReturn = buffer.withUnsafeMutableBytes { rawBuf in
            var devReq = IOUSBDevRequest(
                bmRequestType: requestType,
                bRequest: req.rawValue,
                wValue: UInt16(selector) << 8,
                wIndex: (UInt16(unit) << 8) | UInt16(desc.interfaceNumber),
                wLength: UInt16(length),
                pData: rawBuf.baseAddress,
                wLenDone: 0
            )
            return iface.pointee.pointee.ControlRequest(iface, 0, &devReq)
        }
        guard status == kIOReturnSuccess else { return nil }
        return Data(buffer)
    }

    private func writeData(unit: Int, selector: UInt8, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let iface = usbInterface, let desc = descriptor else { return false }

        var buffer = [UInt8](data)
        let requestType: UInt8 = 0x21 // Host-to-Device | Class | Interface
        let status: IOReturn = buffer.withUnsafeMutableBytes { rawBuf in
            var devReq = IOUSBDevRequest(
                bmRequestType: requestType,
                bRequest: RequestCode.setCur.rawValue,
                wValue: UInt16(selector) << 8,
                wIndex: (UInt16(unit) << 8) | UInt16(desc.interfaceNumber),
                wLength: UInt16(data.count),
                pData: rawBuf.baseAddress,
                wLenDone: 0
            )
            return iface.pointee.pointee.ControlRequest(iface, 0, &devReq)
        }
        return status == kIOReturnSuccess
    }

    // MARK: - IORegistry Matching Helpers

    private func findUSBService(for camera: DiscoveredCamera) throws -> io_service_t {
        let vendorID = camera.vendorID ?? (camera.isDJI ? DiscoveredCamera.djiVendorID : nil)
        guard let vendorID else {
            throw UVCError.deviceNotFound
        }

        let matching = IOServiceMatching("IOUSBDevice") as NSMutableDictionary
        matching["idVendor"] = vendorID
        if let productID = camera.productID {
            matching["idProduct"] = productID
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == kIOReturnSuccess else {
            throw UVCError.deviceNotFound
        }
        defer { IOObjectRelease(iter) }

        var firstMatch: io_service_t = 0
        var candidate = IOIteratorNext(iter)
        while candidate != 0 {
            if firstMatch == 0 {
                firstMatch = candidate
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(candidate, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = propsRef?.takeRetainedValue() as? [String: Any],
               let locationID = dict["locationID"] as? Int {
                let locationHex = "0x" + String(locationID, radix: 16)
                if camera.id.lowercased().hasPrefix(locationHex.lowercased()) {
                    if firstMatch != 0 && firstMatch != candidate {
                        IOObjectRelease(firstMatch)
                    }
                    return candidate
                }
            }
            if candidate != firstMatch {
                IOObjectRelease(candidate)
            }
            candidate = IOIteratorNext(iter)
        }

        if firstMatch != 0 {
            return firstMatch
        }
        throw UVCError.deviceNotFound
    }

    private func withPlugIn(service: io_service_t, type: CFUUID, body: (PlugInPtr) throws -> Void) throws {
        var ref: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, type, Self.kIOCFPlugInInterfaceID, &ref, &score)
        guard kr == kIOReturnSuccess, let ref else {
            throw UVCError.requestFailed(kr)
        }
        defer { _ = ref.pointee?.pointee.Release(ref) }
        try ref.withMemoryRebound(to: UnsafeMutablePointer<IOCFPlugInInterface>.self, capacity: 1) { rebound in
            try body(rebound)
        }
    }

    private func queryInterface<T>(plugIn: PlugInPtr, uuid: CFUUID) throws -> UnsafeMutablePointer<UnsafeMutablePointer<T>> {
        var rawPtr: LPVOID?
        let result = plugIn.pointee.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(uuid), &rawPtr)
        guard result == S_OK, let rawPtr else {
            throw UVCError.requestFailed(result)
        }
        return rawPtr.assumingMemoryBound(to: UnsafeMutablePointer<T>.self)
    }
}

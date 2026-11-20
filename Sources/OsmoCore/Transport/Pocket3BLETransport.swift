import Foundation
@preconcurrency import CoreBluetooth

public enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case awaitingApproval
    case connected(deviceName: String, rssi: Int)
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .awaitingApproval: return "Approve on Pocket 3"
        case .connected(let name, _): return name
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Native macOS CoreBluetooth DUML transport for DJI Osmo Pocket 3.
///
/// Implements the Pocket 3 BLE sequence:
/// 1. Scan for localName containing "Pocket"/"Osmo" OR DJI mfr ID (0x08AA / 0xF7AA, model 0x0020)
/// 2. Discover service `FFF0`, subscribe to `FFF4` (telemetry + responses) & `FFF5` (DUML TX)
/// 3. Write `[0x01, 0x00]` to `FFF4` with response to arm pairing
/// 4. Send `00/2B` `[04 00]` wake + `07/45` SetPairingPIN (`osmo`) on `FFF5` (`withoutResponse`)
/// 5. Answer incoming `0x40` requests (`07/46`, `00/81`) & maintain 1 Hz `00/2B` `[01 01]` keepalive
/// 6. Decode unsolicited `04/05` gimbal attitude, `0D/02` battery/charging, and `00/99` readback
@MainActor
public final class Pocket3BLETransport: NSObject {
    private static let serviceFFF0 = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private static let charFFF4 = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    private static let charFFF5 = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")

    public var onStateChange: ((BLEConnectionState) -> Void)?
    public var onGimbalAttitude: ((GimbalAttitude) -> Void)?
    public var onBatteryStatus: ((BatteryStatus) -> Void)?
    public var onCameraPropertyPush: ((Data) -> Void)?
    public var onWiFiCredentials: ((String, String) -> Void)?
    public var onLog: ((String) -> Void)?

    public private(set) var state: BLEConnectionState = .disconnected {
        didSet { onStateChange?(state) }
    }
    public private(set) var wifiSSID: String = ""
    public private(set) var wifiPassword: String = ""

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var discoveredName: String = "Osmo Pocket 3"
    private var discoveredRSSI: Int = 0
    private var fff4: CBCharacteristic?
    private var fff5: CBCharacteristic?

    private var fff4NotifyReady = false
    private var fff5NotifyReady = false
    private var armWriteIssued = false
    private var pairingStarted = false
    private var pairedFlowStarted = false
    private var connectRequested = false
    private var generation = 0
    private var seqID: UInt16 = 0x9000
    private var keepaliveTimer: Timer?
    private var queuedWrites: [Data] = []
    private var yawReducer = ContinuousYawReducer()

    public override init() {
        super.init()
    }

    public func connect() {
        generation += 1
        cleanupPeripheral()
        connectRequested = true
        yawReducer.reset()
        state = .scanning
        log("BLE: starting scan for DJI Osmo Pocket 3")

        _ = central
        if central.state == .poweredOn {
            startScan()
        } else {
            log("BLE: waiting for Bluetooth power-on (state=\(central.state.rawValue))")
        }
    }

    public func disconnect() {
        generation += 1
        connectRequested = false
        central.stopScan()
        cleanupPeripheral()
        state = .disconnected
        log("BLE: disconnected")
    }

    /// Sends a typed Pocket 3 DUML command over `FFF5` (`writeWithoutResponse`).
    @discardableResult
    public func send(_ command: Pocket3Command) -> Bool {
        seqID &+= 1
        let frame = command.encodeDuml(id: seqID)
        return writeRawDuml(frame)
    }

    /// Triggers Pocket 3 Wi-Fi AP wake (`53/10`) and queries SSID (`07/07`) & password (`07/0E`).
    public func requestWiFiCredentials() {
        guard pairedFlowStarted else {
            log("BLE: wait until paired before requesting Wi-Fi credentials")
            return
        }
        let gen = generation
        _ = writeRawDuml(Pocket3Commands.wakeWiFiAP())
        log("BLE: sent 53/10 Wi-Fi AP wake")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, gen == self.generation else { return }
            _ = self.writeRawDuml(Pocket3Commands.queryWiFiSSID())
            self.log("BLE: requested Pocket 3 Wi-Fi SSID (07/07)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, gen == self.generation else { return }
            _ = self.writeRawDuml(Pocket3Commands.queryWiFiPassword())
            self.log("BLE: requested Pocket 3 Wi-Fi password (07/0E)")
        }
    }

    // MARK: - Internal BLE Lifecycle

    private func cleanupPeripheral() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        if let p = peripheral {
            p.delegate = nil
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        fff4 = nil
        fff5 = nil
        fff4NotifyReady = false
        fff5NotifyReady = false
        armWriteIssued = false
        pairingStarted = false
        pairedFlowStarted = false
        queuedWrites.removeAll()
    }

    private func startScan() {
        guard connectRequested, central.state == .poweredOn else { return }
        state = .scanning
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, gen == self.generation, self.peripheral == nil, self.connectRequested else { return }
            self.central.stopScan()
            self.state = .error("Pocket 3 not found within 15s")
            self.log("BLE: scan timed out")
        }
    }

    private func isOsmoPocket3(peripheral: CBPeripheral, advertisementData: [String: Any]) -> (Bool, String) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "DJI Device"
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized.contains("pocket3") || normalized.contains("osmopocket") {
            return (true, name)
        }
        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfr.count >= 4 {
            let company = UInt16(mfr[0]) | (UInt16(mfr[1]) << 8)
            let model = UInt16(mfr[2]) | (UInt16(mfr[3]) << 8)
            if (company == 0x08AA || company == 0xF7AA) && model == 0x0020 {
                return (true, name)
            }
        }
        return (false, name)
    }

    private func armPairingIfReady() {
        guard fff4NotifyReady, fff5NotifyReady, !armWriteIssued else { return }
        guard let peripheral, let fff4 else { return }
        armWriteIssued = true
        log("BLE: writing [01 00] to FFF4 (arm pairing)")
        peripheral.writeValue(Data([0x01, 0x00]), for: fff4, type: .withResponse)
    }

    private func beginPairingHandshake() {
        _ = writeRawDuml(Pocket3Commands.sessionPing(Pocket3Commands.sessionWakePayload))
        log("BLE: sent 00/2B [04 00] wake")

        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, gen == self.generation, !self.pairingStarted else { return }
            self.pairingStarted = true
            _ = self.writeRawDuml(Pocket3Commands.setPairingPin("osmo"))
            self.log("BLE: sent 07/45 SetPairingPIN")
        }

        for retryDelay in [2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self, gen == self.generation, !self.pairedFlowStarted else { return }
                _ = self.writeRawDuml(Pocket3Commands.setPairingPin("osmo"))
                self.log("BLE: retrying 07/45 SetPairingPIN")
            }
        }
    }

    private func markPaired() {
        guard !pairedFlowStarted else { return }
        pairedFlowStarted = true
        state = .connected(deviceName: discoveredName, rssi: discoveredRSSI)
        log("BLE: paired and connected to \(discoveredName)")
        startKeepalive()
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        let gen = generation
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, self.connectRequested else { return }
                _ = self.writeRawDuml(Pocket3Commands.sessionPing(Pocket3Commands.sessionKeepalivePayload))
            }
        }
    }

    @discardableResult
    private func writeRawDuml(_ data: Data) -> Bool {
        guard let peripheral, let fff5 else { return false }
        let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= maxLen else {
            log("BLE ERROR: frame \(data.count)B exceeds MTU \(maxLen)B")
            return false
        }
        if peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(data, for: fff5, type: .withoutResponse)
            return true
        }
        queuedWrites.append(data)
        return true
    }

    private func drainWriteQueue() {
        guard let peripheral, let fff5 else { return }
        while peripheral.canSendWriteWithoutResponse, !queuedWrites.isEmpty {
            let next = queuedWrites.removeFirst()
            if next.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) {
                peripheral.writeValue(next, for: fff5, type: .withoutResponse)
            }
        }
    }

    private func handleIncomingFrame(_ data: Data) {
        let frames = DumlMessage.scanFrames(in: data)
        for msg in frames {
            // Answer incoming DJI requests (0x40)
            if msg.flags == 0x40 {
                let respTarget = ((msg.target & 0x00FF) << 8) | ((msg.target & 0xFF00) >> 8)
                let respType = (msg.type & 0x00FF_FF00) | 0xC0
                let respPayload = (msg.cmdSet == 0x00 && msg.cmdId == 0x81)
                    ? Pocket3Commands.appDeviceInfoPayload
                    : msg.payload
                let resp = DumlMessage(target: respTarget, id: msg.id, type: respType, payload: respPayload).encode()
                _ = writeRawDuml(resp)

                if msg.cmdSet == 0x07 && msg.cmdId == 0x46 {
                    log("BLE: pairing approved on Pocket 3")
                    markPaired()
                }
                continue
            }

            switch (msg.cmdSet, msg.cmdId) {
            case (0x04, 0x05):
                if let attitude = Pocket3TelemetryParser.parseGimbalAttitude(payload: msg.payload, yawReducer: &yawReducer) {
                    onGimbalAttitude?(attitude)
                }

            case (0x0D, 0x02):
                if let battery = Pocket3TelemetryParser.parseBattery(payload: msg.payload) {
                    onBatteryStatus?(battery)
                }

            case (0x00, 0x99):
                onCameraPropertyPush?(msg.payload)

            case (0x07, 0x45):
                let bytes = [UInt8](msg.payload)
                let statusByte = bytes.count > 1 ? bytes[1] : 0xFF
                if statusByte == 0x01 {
                    log("BLE: already paired")
                    markPaired()
                } else if statusByte == 0x02 {
                    state = .awaitingApproval
                    log("BLE: tap Accept on the Pocket 3 screen")
                }

            case (0x07, 0x46):
                markPaired()

            case (0x07, 0x07):
                if let ssid = parseStatusPackString(msg.payload), !ssid.isEmpty {
                    wifiSSID = ssid
                    log("BLE: retrieved Pocket 3 SSID \"\(ssid)\"")
                    if !wifiPassword.isEmpty { onWiFiCredentials?(wifiSSID, wifiPassword) }
                }

            case (0x07, 0x0E):
                if let pwd = parseStatusPackString(msg.payload), !pwd.isEmpty {
                    wifiPassword = pwd
                    log("BLE: retrieved Pocket 3 Wi-Fi password (\(pwd.count) chars)")
                    if !wifiSSID.isEmpty { onWiFiCredentials?(wifiSSID, wifiPassword) }
                }

            default:
                break
            }
        }
    }

    private func parseStatusPackString(_ payload: Data) -> String? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }
        let len = Int(bytes[1])
        guard 2 + len <= bytes.count else { return nil }
        return String(bytes: bytes[2..<(2 + len)], encoding: .ascii)
    }

    private func log(_ msg: String) {
        onLog?(msg)
    }
}

extension Pocket3BLETransport: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.connectRequested else { return }
            switch central.state {
            case .poweredOn:
                self.startScan()
            case .unauthorized:
                self.state = .error("Bluetooth permission denied")
            case .poweredOff:
                self.state = .error("Bluetooth is turned off")
            case .unsupported:
                self.state = .error("Bluetooth LE unavailable")
            default:
                break
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advCopy: [String: Any] = [
            CBAdvertisementDataLocalNameKey: advertisementData[CBAdvertisementDataLocalNameKey] as Any,
            CBAdvertisementDataManufacturerDataKey: advertisementData[CBAdvertisementDataManufacturerDataKey] as Any
        ]
        let rssiInt = RSSI.intValue
        Task { @MainActor in
            guard self.connectRequested, self.peripheral == nil else { return }
            let (matched, name) = self.isOsmoPocket3(peripheral: peripheral, advertisementData: advCopy)
            guard matched else { return }

            central.stopScan()
            self.discoveredName = name
            self.discoveredRSSI = rssiInt
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting
            self.log("BLE: found \(name) (RSSI \(rssiInt) dBm) — connecting")
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.log("BLE: connected — discovering FFF0 service")
            peripheral.discoverServices([Self.serviceFFF0])
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let msg = error?.localizedDescription ?? "Connection failed"
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.state = .error(msg)
            self.log("BLE: failed to connect: \(msg)")
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let msg = error?.localizedDescription
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.keepaliveTimer?.invalidate()
            self.keepaliveTimer = nil
            self.peripheral = nil
            self.fff4 = nil
            self.fff5 = nil
            self.pairedFlowStarted = false
            self.state = .disconnected
            self.log("BLE: disconnected\(msg.map { " (\($0))" } ?? "")")
        }
    }
}

extension Pocket3BLETransport: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let errDesc = error?.localizedDescription
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            if let errDesc {
                self.state = .error(errDesc)
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceFFF0 }) else {
                self.state = .error("FFF0 service missing")
                return
            }
            peripheral.discoverCharacteristics([Self.charFFF4, Self.charFFF5], for: service)
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let errDesc = error?.localizedDescription
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            if let errDesc {
                self.state = .error(errDesc)
                return
            }
            self.fff4 = service.characteristics?.first(where: { $0.uuid == Self.charFFF4 })
            self.fff5 = service.characteristics?.first(where: { $0.uuid == Self.charFFF5 })
            guard let fff4 = self.fff4, let fff5 = self.fff5 else {
                self.state = .error("FFF4/FFF5 characteristics missing")
                return
            }
            peripheral.setNotifyValue(true, for: fff4)
            peripheral.setNotifyValue(true, for: fff5)
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let errDesc = error?.localizedDescription
        let uuid = characteristic.uuid
        let isNotifying = characteristic.isNotifying
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            if let errDesc {
                self.state = .error(errDesc)
                return
            }
            if uuid == Self.charFFF4 { self.fff4NotifyReady = isNotifying }
            if uuid == Self.charFFF5 { self.fff5NotifyReady = isNotifying }
            self.armPairingIfReady()
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let errDesc = error?.localizedDescription
        let uuid = characteristic.uuid
        Task { @MainActor in
            guard self.peripheral === peripheral, uuid == Self.charFFF4 else { return }
            if let errDesc {
                self.state = .error(errDesc)
                return
            }
            self.beginPairingHandshake()
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.handleIncomingFrame(value)
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral === peripheral else { return }
            self.drainWriteQueue()
        }
    }
}

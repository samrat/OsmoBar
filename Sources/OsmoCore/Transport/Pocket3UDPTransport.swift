import Foundation
import Network

public enum UDPDatalinkState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public var isConnected: Bool { self == .connected }

    public var label: String {
        switch self {
        case .disconnected: return "Off"
        case .connecting: return "Connecting…"
        case .connected: return "192.168.2.1"
        case .error(let msg): return msg
        }
    }
}

/// Optional direct Pocket 3 DUML-over-UDP/9004 datalink (`192.168.2.1`).
///
/// When the Mac is also associated with the Pocket 3 Wi-Fi AP, this transport unlocks
/// full Pocket 3 DUML gimbal movement (`04/01`, `04/4C`) and Pro camera controls (`02/*`)
/// plus `00/99` live property readback.
public final class Pocket3UDPTransport: @unchecked Sendable {
    public static let defaultIP = "192.168.2.1"
    public static let udpPort: UInt16 = 9004
    public static let tcpPokePort: UInt16 = 7001

    public var onStateChange: (@Sendable (UDPDatalinkState) -> Void)?
    public var onGimbalAttitude: (@Sendable (GimbalAttitude) -> Void)?
    public var onBatteryStatus: (@Sendable (BatteryStatus) -> Void)?
    public var onCameraPropertyPush: (@Sendable (Data) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private let networkQueue = DispatchQueue(label: "com.osmocontrol.udp")

    private var connection: NWConnection?
    private var incoming: [Data] = []
    private var running = false
    private var sessionId = 0
    private var baseSeq = 0
    private var cameraChannel = 0
    private var udpSeq = 0
    private var dumlSeq: UInt16 = 0xA000
    private var cmdCounter = 0
    private var rxType2Seq = 0
    private var rxType3Seq = 0
    private var peerAckedTxSeq = 0
    private var lastTxSeq = 0
    private var seenType2 = false
    private var seenType3 = false

    private var commandQueue: [Pocket3Command] = []
    private var activeJoystick: (pitch: Int, yaw: Int)?
    private var forceNeutralPending = false
    private var yawReducer = ContinuousYawReducer()

    public init() {}

    public func connect(ip: String = Pocket3UDPTransport.defaultIP) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        commandQueue.removeAll()
        activeJoystick = nil
        forceNeutralPending = false
        yawReducer.reset()
        lock.unlock()

        onStateChange?(.connecting)
        log("UDP: bootstrapping \(ip):\(Self.udpPort)")

        Thread.detachNewThread { [weak self] in
            self?.runSession(ip: ip)
        }
    }

    public func disconnect() {
        lock.lock()
        let wasRunning = running
        running = false
        let conn = connection
        connection = nil
        incoming.removeAll()
        commandQueue.removeAll()
        activeJoystick = nil
        lock.unlock()

        conn?.cancel()
        if wasRunning {
            onStateChange?(.disconnected)
            log("UDP: disconnected")
        }
    }

    public func enqueue(_ command: Pocket3Command) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        commandQueue.append(command)
        lock.unlock()
    }

    /// Sets continuous 20 Hz virtual joystick velocity (`pitch`/`yaw` centered at 1024).
    /// Pass `nil` to release and immediately send explicit neutral.
    public func setJoystickVelocity(pitch: Int, yaw: Int) {
        lock.lock()
        activeJoystick = (pitch, yaw)
        lock.unlock()
    }

    public func releaseJoystick() {
        lock.lock()
        activeJoystick = nil
        forceNeutralPending = true
        lock.unlock()
    }

    // MARK: - Session Thread

    private func runSession(ip: String) {
        tcpPoke(ip: ip)
        guard isStillRunning else { return }

        guard openUDP(ip: ip) else {
            fail("Could not reach \(ip)")
            return
        }

        // Handshake (pktType 0x00)
        guard performHandshake() else {
            fail("UDP/9004 handshake timed out (join Pocket 3 Wi-Fi)")
            return
        }
        guard isStillRunning else { return }

        for _ in 0..<5 {
            _ = drainAndObserve(durationMs: 250)
            sendAck()
        }
        syncSeqToPeerChannel()

        // Register APP info (00/81), presence (00/88), gimbal init (03/DA), heartbeat (04/50)
        sendDuml(
            Pocket3Command(
                cmdSet: 0x00, cmdId: 0x81, payload: Pocket3Commands.appDeviceInfoPayload,
                receiverType: 0x08, receiverId: 2, cmdType: 4, label: "App Device Info"
            )
        )
        _ = drainAndObserve(durationMs: 300)
        sendAck()

        sendDuml(
            Pocket3Command(
                cmdSet: 0x00, cmdId: 0x88, payload: Pocket3Commands.appPresencePayload,
                receiverType: 0x08, receiverId: 1, cmdType: 2, label: "App Presence"
            )
        )
        _ = drainAndObserve(durationMs: 300)
        sendAck()

        sendDuml(
            Pocket3Command(
                cmdSet: 0x03, cmdId: 0xDA, payload: Pocket3Commands.gimbalInitPayload,
                receiverType: 0x03, receiverId: 0, cmdType: 2, label: "Gimbal Init"
            )
        )
        _ = drainAndObserve(durationMs: 300)
        sendAck()

        sendDuml(
            Pocket3Command(
                cmdSet: 0x04, cmdId: 0x50, payload: Pocket3Commands.gimbalHeartbeatPayload,
                receiverType: 0x04, receiverId: 0, cmdType: 2, label: "Gimbal Heartbeat"
            )
        )
        let hbDatagrams = drainAndObserve(durationMs: 600)
        sendAck()

        let gotHeartbeat = hbDatagrams.contains { datagram in
            DumlMessage.scanFrames(in: datagram).contains { $0.cmdSet == 0x04 && $0.cmdId == 0x50 }
        }
        guard gotHeartbeat else {
            fail("No 04/50 heartbeat from Pocket 3")
            return
        }

        // Subscribe to live camera properties on 00/99
        var txId: UInt32 = 0x0000_C900
        for name in Pocket3TelemetryParser.readbackPropertyNames {
            txId &+= 1
            if let sub = Pocket3Commands.subscribeCameraProperty(name: name, transactionID: txId) {
                sendDuml(sub)
            }
        }

        onStateChange?(.connected)
        log("UDP: Pocket 3 datalink ready")

        // Main 50 ms (~20 Hz) control + ACK + telemetry pump
        var lastPresenceNs = DispatchTime.now().uptimeNanoseconds
        var lastAckNs = lastPresenceNs

        while isStillRunning {
            let datagrams = drainAndObserve(durationMs: 16)
            for dg in datagrams {
                processInboundFrames(dg)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastAckNs >= 60_000_000 {
                sendAck()
                lastAckNs = now
            }

            if now - lastPresenceNs >= 1_000_000_000 {
                sendDuml(
                    Pocket3Command(
                        cmdSet: 0x00, cmdId: 0x88, payload: Pocket3Commands.appPresencePayload,
                        receiverType: 0x08, receiverId: 1, cmdType: 2, label: "Presence"
                    )
                )
                sendDuml(
                    Pocket3Command(
                        cmdSet: 0x04, cmdId: 0x50, payload: Pocket3Commands.gimbalHeartbeatPayload,
                        receiverType: 0x04, receiverId: 0, cmdType: 2, label: "Heartbeat"
                    )
                )
                lastPresenceNs = now
            }

            // Drain queued one-shot commands
            let pending: [Pocket3Command]
            let joystick: (pitch: Int, yaw: Int)?
            let sendNeutral: Bool
            lock.lock()
            pending = commandQueue
            commandQueue.removeAll(keepingCapacity: true)
            joystick = activeJoystick
            sendNeutral = forceNeutralPending
            forceNeutralPending = false
            lock.unlock()

            for cmd in pending {
                sendDuml(cmd)
            }
            if let joystick {
                sendDuml(Pocket3Commands.gimbalVelocity(pitch: joystick.pitch, yaw: joystick.yaw))
            } else if sendNeutral {
                sendDuml(Pocket3Commands.gimbalVelocity(pitch: Pocket3Commands.gimbalNeutral, yaw: Pocket3Commands.gimbalNeutral))
            }

            Thread.sleep(forTimeInterval: 0.030)
        }
    }

    private func tcpPoke(ip: String) {
        let sem = DispatchSemaphore(value: 0)
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: Self.tcpPokePort)!,
            using: .tcp
        )
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: networkQueue)
        _ = sem.wait(timeout: .now() + 1.5)
        conn.cancel()
    }

    private func openUDP(ip: String) -> Bool {
        sessionId = Int.random(in: 0x1000..<0xFFFE)
        baseSeq = Int.random(in: 0x1000..<0xF000) & 0xFFF8
        cameraChannel = baseSeq
        udpSeq = 0
        dumlSeq = 0xA000
        cmdCounter = 0
        rxType2Seq = baseSeq
        rxType3Seq = baseSeq
        peerAckedTxSeq = baseSeq
        lastTxSeq = baseSeq
        seenType2 = false
        seenType3 = false

        let sem = DispatchSemaphore(value: 0)
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: Self.udpPort)!,
            using: .udp
        )
        final class ReadyFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func setReady() { lock.lock(); value = true; lock.unlock() }
            var isReady: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let readyFlag = ReadyFlag()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyFlag.setReady()
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: networkQueue)
        _ = sem.wait(timeout: .now() + 4.0)
        guard readyFlag.isReady else {
            conn.cancel()
            return false
        }

        lock.lock()
        connection = conn
        lock.unlock()

        scheduleReceive(on: conn)
        return true
    }

    private func scheduleReceive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.lock.lock()
                if self.running {
                    self.incoming.append(content)
                }
                self.lock.unlock()
            }
            if error == nil && self.isStillRunning {
                self.scheduleReceive(on: conn)
            }
        }
    }

    private func performHandshake() -> Bool {
        var handshakePayload = Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        handshakePayload.append(UInt8(baseSeq & 0xFF))
        handshakePayload.append(UInt8((baseSeq >> 8) & 0xFF))
        handshakePayload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        for _ in 0..<12 {
            guard isStillRunning else { return false }
            let packet = encodeTransportHeader(pktType: 0x00, payloadLength: handshakePayload.count, sequence: udpSeq) + handshakePayload
            sendRaw(packet)
            udpSeq = (udpSeq + 8) & 0xFFFF

            let replies = drainAndObserve(durationMs: 300)
            if replies.contains(where: { $0.count >= 8 && $0[6] == 0x00 }) {
                return true
            }
        }
        return false
    }

    private func syncSeqToPeerChannel() {
        udpSeq = (cameraChannel + 8) & 0xFFFF
        lastTxSeq = cameraChannel
        peerAckedTxSeq = cameraChannel
    }

    private func sendAck() {
        var payload = Data()
        appendLE16(rxType2Seq, to: &payload)
        appendLE16(rxType2Seq, to: &payload)
        payload.append(contentsOf: [0, 0, 0, 0])
        appendLE16(rxType3Seq, to: &payload)
        appendLE16(rxType3Seq, to: &payload)
        payload.append(contentsOf: [0, 0, 0, 0])
        appendLE16(peerAckedTxSeq, to: &payload)
        appendLE16(lastTxSeq, to: &payload)
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0])

        let header = encodeTransportHeader(pktType: 0x04, payloadLength: payload.count, sequence: 0)
        sendRaw(header + payload)
    }

    private func sendDuml(_ command: Pocket3Command) {
        cmdCounter += 1
        dumlSeq &+= 1
        let duml = command.encodeDuml(id: dumlSeq)
        let routing = Data([
            UInt8(peerAckedTxSeq & 0xFF),
            UInt8((peerAckedTxSeq >> 8) & 0xFF),
            UInt8(udpSeq & 0xFF),
            UInt8((udpSeq >> 8) & 0xFF),
            0, 0, 0, 0,
            UInt8(cmdCounter & 0xFF),
            0x01, 0x00, 0x00
        ])
        let body = routing + duml
        let header = encodeTransportHeader(pktType: 0x05, payloadLength: body.count, sequence: udpSeq)
        let seqSent = udpSeq
        sendRaw(header + body)
        lastTxSeq = seqSent & 0xFFFF
        udpSeq = (udpSeq + 8) & 0xFFFF
    }

    private func encodeTransportHeader(pktType: UInt8, payloadLength: Int, sequence: Int) -> Data {
        let total = 8 + payloadLength
        let word0 = 0x8000 | (total & 0x3FFF)
        var bytes: [UInt8] = [
            UInt8(word0 & 0xFF),
            UInt8((word0 >> 8) & 0xFF),
            UInt8(sessionId & 0xFF),
            UInt8((sessionId >> 8) & 0xFF),
            UInt8(sequence & 0xFF),
            UInt8((sequence >> 8) & 0xFF),
            pktType
        ]
        bytes.append(bytes.reduce(UInt8(0), ^))
        return Data(bytes)
    }

    private func sendRaw(_ data: Data) {
        lock.lock()
        let conn = connection
        lock.unlock()
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func drainAndObserve(durationMs: Int) -> [Data] {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(durationMs) * 1_000_000
        var collected: [Data] = []
        while DispatchTime.now().uptimeNanoseconds < deadline && isStillRunning {
            let batch: [Data]
            lock.lock()
            batch = incoming
            incoming.removeAll(keepingCapacity: true)
            lock.unlock()

            if batch.isEmpty {
                Thread.sleep(forTimeInterval: 0.002)
            } else {
                for dg in batch where dg.count >= 8 {
                    let sid = Int(dg[2]) | (Int(dg[3]) << 8)
                    guard sid == sessionId else { continue }
                    observe(dg)
                    collected.append(dg)
                }
            }
        }
        return collected
    }

    private func observe(_ data: Data) {
        let pktType = data[6]
        let seq = Int(data[4]) | (Int(data[5]) << 8)

        if data.count >= 10 {
            let ch = Int(data[8]) | (Int(data[9]) << 8)
            if ch != 0 { cameraChannel = ch }
        }
        if seq != 0 {
            if pktType == 0x02 { rxType2Seq = seq; seenType2 = true }
            if pktType == 0x03 { rxType3Seq = seq; seenType3 = true }
        }
        if pktType == 0x01 && data.count >= 34 {
            let t2 = Int(data[10]) | (Int(data[11]) << 8)
            let t3 = Int(data[18]) | (Int(data[19]) << 8)
            let ackTx = Int(data[24]) | (Int(data[25]) << 8)
            if !seenType2 && t2 != 0 { rxType2Seq = t2 }
            if !seenType3 && t3 != 0 { rxType3Seq = t3 }
            if ackTx != 0 { peerAckedTxSeq = ackTx }
        }
    }

    private func processInboundFrames(_ datagram: Data) {
        for msg in DumlMessage.scanFrames(in: datagram) {
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
            default:
                break
            }
        }
    }

    private var isStillRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func fail(_ message: String) {
        lock.lock()
        running = false
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
        onStateChange?(.error(message))
        log("UDP ERROR: \(message)")
    }

    private func appendLE16(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func log(_ msg: String) {
        onLog?(msg)
    }
}

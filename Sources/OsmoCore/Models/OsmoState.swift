import Foundation

/// Active transport route indicator for UI clarity.
public enum ControlRoute: String, Equatable, Sendable {
    case usbUVC = "USB UVC"
    case udpDUML = "Wi-Fi DUML"
    case bleDUML = "BLE DUML"
    case unavailable = "Unavailable"
}

public struct DiagnosticLogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String

    public init(timestamp: Date = Date(), message: String) {
        self.timestamp = timestamp
        self.message = message
    }
}

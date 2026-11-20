import Foundation

/// A saved camera framing preset storing both USB UVC pan/tilt/zoom coordinates
/// and DUML gimbal attitude targets so presets work seamlessly on whichever transport is active.
public struct GimbalPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var symbolName: String
    public var uvcPanDeg: Double?
    public var uvcTiltDeg: Double?
    public var uvcZoom: Int?
    public var dumlPitchDeg: Double?
    public var dumlYawDeg: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "viewfinder",
        uvcPanDeg: Double? = nil,
        uvcTiltDeg: Double? = nil,
        uvcZoom: Int? = nil,
        dumlPitchDeg: Double? = nil,
        dumlYawDeg: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.uvcPanDeg = uvcPanDeg
        self.uvcTiltDeg = uvcTiltDeg
        self.uvcZoom = uvcZoom
        self.dumlPitchDeg = dumlPitchDeg
        self.dumlYawDeg = dumlYawDeg
    }

    public static let defaultPresets: [GimbalPreset] = [
        GimbalPreset(name: "Center", symbolName: "scope", uvcPanDeg: 0, uvcTiltDeg: 0, dumlPitchDeg: 0, dumlYawDeg: 0),
        GimbalPreset(name: "Desk", symbolName: "desktopcomputer", uvcPanDeg: 0, uvcTiltDeg: -15, dumlPitchDeg: -15, dumlYawDeg: 0),
        GimbalPreset(name: "Standing", symbolName: "figure.stand", uvcPanDeg: 0, uvcTiltDeg: 18, dumlPitchDeg: 18, dumlYawDeg: 0)
    ]
}

public enum GimbalPresetStore {
    private static let storageKey = "com.osmobar.gimbalPresets.v1"
    private static let legacyStorageKey = "com.osmocontrol.gimbalPresets.v1"

    public static func load() -> [GimbalPreset] {
        let data = UserDefaults.standard.data(forKey: storageKey)
            ?? UserDefaults.standard.data(forKey: legacyStorageKey)
        guard let data,
              let decoded = try? JSONDecoder().decode([GimbalPreset].self, from: data),
              !decoded.isEmpty else {
            return GimbalPreset.defaultPresets
        }
        return decoded
    }

    public static func save(_ presets: [GimbalPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

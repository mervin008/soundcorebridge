import Foundation

/// What a model is able to do. Anything not listed is hidden in the UI and
/// refused by the controller, so an unknown device can never be sent a write
/// that was only ever verified on a different model.
enum DeviceFeature: String, CaseIterable {
    case battery, firmware, soundMode, ancLevel, equaliser, customEQ, multipoint
}

/// A verified family of write commands. Read-only profiles deliberately have
/// no control protocol, even if their state blob can be partially decoded.
enum DeviceControlProtocol {
    case space2
}

/// Everything that varies between Soundcore models.
///
/// Profiles describe only behavior verified on real hardware. The current
/// device family shares the frame codec and RFCOMM transport, but a future
/// model may require a different transport or command codec as well as different
/// state offsets.
struct DeviceProfile {
    /// ASCII model code as reported inside the state blob, e.g. "1402".
    let modelCode: String
    /// Substrings matched against the Bluetooth name for first-guess detection.
    let nameMatches: [String]
    let displayName: String

    /// Verified RFCOMM control channels, in preference order. An empty list
    /// means discovery must rely on safe SDP candidates and the global fallback.
    let rfcommChannels: [UInt8]

    let minStateLength: Int
    let batteryOffset: Int
    /// Battery is reported 0–9 on the Apple accessory scale; percent is
    /// (level + 1) * 10.
    let batteryMax: Int
    let firmwareRange: ClosedRange<Int>
    let modelRange: ClosedRange<Int>

    let eqPresetOffset: Int?
    let eqBandsStart: Int?
    let eqBandCount: Int
    let ancModeOffset: Int?
    /// ANC level lives in the high nibble of this byte.
    let ancLevelOffset: Int?
    let hostCountOffset: Int?

    /// Per-model mapping of sound mode to its wire value.
    let soundModeValues: [UInt8: ANCMode]
    let features: Set<DeviceFeature>
    let controlProtocol: DeviceControlProtocol?

    func supports(_ f: DeviceFeature) -> Bool { features.contains(f) }
    var allowsWrites: Bool { controlProtocol != nil }
}

extension DeviceProfile {
    /// Soundcore Space 2 (D1402). Every offset here was confirmed against real
    /// hardware — see docs/protocol-map.md.
    static let space2 = DeviceProfile(
        modelCode: "1402",
        nameMatches: ["space 2", "space2"],
        displayName: "Soundcore Space 2",
        rfcommChannels: [30],
        minStateLength: 92,
        batteryOffset: 0,
        batteryMax: 9,
        firmwareRange: 2...6,
        modelRange: 7...10,
        eqPresetOffset: 23,
        eqBandsStart: 25,
        eqBandCount: 8,
        ancModeOffset: 71,
        ancLevelOffset: 72,
        hostCountOffset: 91,
        soundModeValues: [0x00: .noiseCancelling, 0x01: .transparency, 0x02: .normal],
        features: [.battery, .firmware, .soundMode, .ancLevel, .equaliser, .customEQ, .multipoint],
        controlProtocol: .space2
    )

    /// Fallback for a Soundcore device we have never verified.
    ///
    /// Deliberately read-only: battery and firmware sit at the same place on
    /// every model we have seen, but sound-mode and EQ offsets do not, and
    /// writing guessed offsets to unknown hardware is exactly how devices get
    /// put into strange states.
    static let unknown = DeviceProfile(
        modelCode: "",
        nameMatches: ["soundcore", "anker"],
        displayName: "Soundcore device",
        rfcommChannels: [],
        minStateLength: 12,
        batteryOffset: 0,
        batteryMax: 9,
        firmwareRange: 2...6,
        modelRange: 7...10,
        eqPresetOffset: nil,
        eqBandsStart: nil,
        eqBandCount: 0,
        ancModeOffset: nil,
        ancLevelOffset: nil,
        hostCountOffset: nil,
        soundModeValues: [:],
        features: [.battery, .firmware],
        controlProtocol: nil
    )
}

/// The set of models this build knows how to drive.
enum DeviceRegistry {
    static let all: [DeviceProfile] = [.space2]

    /// Preferred: the model code the device reports about itself.
    static func profile(modelCode: String) -> DeviceProfile? {
        all.first { $0.modelCode == modelCode }
    }

    /// Names that suggest a Soundcore product, used to pick a device out of the
    /// paired list before anything has been read from it.
    static func isLikelySoundcore(_ name: String) -> Bool {
        let n = name.lowercased()
        let hints = ["soundcore", "anker", "space", "liberty", "life ", "q30", "q45",
                     "q20", "a40", "p40", "p20", "r50", "sport", "motion", "aerofit"]
        return hints.contains { n.contains($0) }
    }

    /// First guess before any state has been read.
    static func profile(bluetoothName: String) -> DeviceProfile? {
        let n = bluetoothName.lowercased()
        return all.first { p in p.nameMatches.contains { n.contains($0) } }
    }

    /// Resolve against a state blob, falling back to the read-only profile.
    static func resolve(state: [UInt8], bluetoothName _: String) -> DeviceProfile {
        // A Bluetooth name is useful for discovery, but it is not sufficient
        // proof for enabling writes. Only the model code reported by the device
        // may resolve a write-capable profile.
        let identityRange = DeviceProfile.unknown.modelRange
        if state.count > identityRange.upperBound,
           let code = String(bytes: state[identityRange], encoding: .ascii),
           let exact = profile(modelCode: code) {
            return exact
        }
        return .unknown
    }
}

/// A state blob decoded through a profile. Optional fields are nil when the
/// model does not expose them.
struct DeviceState: Equatable {
    var battery: Int
    var batteryMax: Int
    var firmware: String
    var model: String
    var eqPreset: UInt8?
    var eqBands: [UInt8]
    var ancMode: UInt8?
    var ancLevel: Int?
    var hostCount: Int
}

func parseState(_ p: [UInt8], profile: DeviceProfile) -> DeviceState? {
    guard p.count >= profile.minStateLength else { return nil }

    func byte(_ i: Int?) -> UInt8? {
        guard let i, i < p.count else { return nil }
        return p[i]
    }
    func ascii(_ r: ClosedRange<Int>) -> String {
        guard r.upperBound < p.count else { return "?" }
        return String(bytes: p[r], encoding: .ascii) ?? "?"
    }

    var bands: [UInt8] = []
    if let start = profile.eqBandsStart, profile.eqBandCount > 0,
       start + profile.eqBandCount <= p.count {
        bands = Array(p[start..<(start + profile.eqBandCount)])
    }

    return DeviceState(
        battery: Int(byte(profile.batteryOffset) ?? 0),
        batteryMax: profile.batteryMax,
        firmware: ascii(profile.firmwareRange),
        model: ascii(profile.modelRange),
        eqPreset: byte(profile.eqPresetOffset),
        eqBands: bands,
        ancMode: byte(profile.ancModeOffset),
        ancLevel: byte(profile.ancLevelOffset).map { Int($0 >> 4) },
        hostCount: Int(byte(profile.hostCountOffset) ?? 1)
    )
}

/// Battery is reported on the Apple accessory scale (0–9), shown as
/// (level + 1) * 10 percent.
func batteryPercent(_ level: Int, max: Int = 9) -> Int {
    (Swift.max(0, Swift.min(max, level)) + 1) * (100 / (max + 1))
}

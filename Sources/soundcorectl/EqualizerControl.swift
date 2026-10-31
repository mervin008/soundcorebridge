import Foundation

/// A3957 has two ten-band channels and a separate, persistent HearID block.
/// Keep the wire bytes: rebuilding a calibration from the eight UI sliders
/// would lose the hidden bands, timestamp, genre, and channel availability.
struct Liberty5EqualizerState: Codable, Equatable {
    var configuration: [UInt8] // state[38...59]: UInt16 LE preset + 2 x 10 bands
    var hearID: [UInt8]        // state[61...108]: enabled, curves, time, type, genre
    var bothBudsConnected: Bool
    var immersiveAudio: UInt8

    var isValid: Bool {
        configuration.count == 22 && hearID.count == 48 && hearID[0] <= 1 && hearID[25] <= 2
    }
    var hearIDEnabled: Bool { hearID.first == 1 }
    var presetID: [UInt8] { Array(configuration.prefix(2)) }

    var displayedBands: [UInt8] {
        guard isValid else { return [] }
        let curves: [UInt8]
        if hearIDEnabled {
            // The genre-adjusted effective curve is not known; do not present
            // the initial calibration as though it were the active EQ.
            guard hearID[25] != 2 else { return [] }
            curves = hearID[25] == 1 ? Array(hearID[26...45]) : Array(hearID[1...20])
        } else {
            curves = Array(configuration.dropFirst(2))
        }
        for start in [0, 10] where curves[start] != 0xFF {
            return Array(curves[start..<(start + 8)])
        }
        return []
    }

    /// Until their interaction is verified, do not silently disable spatial
    /// audio or attempt to synthesize a genre-adjusted HearID curve.
    var writeBlockReason: String? {
        guard isValid else { return "Liberty 5 EQ/HearID state is incomplete or unsupported" }
        guard bothBudsConnected else { return "Connect both earbuds to change the Liberty 5 EQ" }
        guard immersiveAudio == 0 else { return "Turn off Dolby/immersive audio in the Soundcore app before changing EQ" }
        if hearIDEnabled && hearID[25] == 2 {
            return "Turn off genre-based HearID in the Soundcore app before changing EQ"
        }
        return nil
    }

    func selecting(id: [UInt8], bands: [UInt8]) throws -> Self {
        if let reason = writeBlockReason { throw ProbeError(reason) }
        let presets = eqPresets(for: .liberty5)
        guard id.count == 2, bands.count == 8, bands.allSatisfy({ (60...180).contains($0) }),
              id == eqCustomID || presets.values.contains(where: { $0.id == id && $0.bands == bands }) else {
            throw ProbeError("invalid Liberty 5 preset or eight-band curve (range −6…+6 dB)")
        }
        // Factory type-2 presets use [0 dB, -12 dB] in the hidden bands;
        // custom curves use [0 dB, 0 dB]. These are not Space 2 DSP coefficients.
        let channel = bands + (id == eqCustomID ? [120, 120] : [120, 0])
        var target = self
        target.configuration = id + channel + channel
        target.hearID[0] = 0 // Selecting an EQ disables HearID, retaining calibration.
        return target
    }

    func packet() throws -> [UInt8] {
        if let reason = writeBlockReason { throw ProbeError(reason) }
        let active: [UInt8]
        if hearIDEnabled {
            active = hearID[25] == 1 ? Array(hearID[26...45]) : Array(hearID[1...20])
        } else {
            active = Array(configuration.dropFirst(2))
        }
        var body = presetID + Array(hearID[46...47]) + Array(configuration.dropFirst(2))
        body += [0, 0] + Array(hearID[0...45])
        for value in active { body += [value, 0] }
        body += [0, 0]
        assert(body.count == 114)
        return Frame.encode(Command(0x03, 0x87), payload: body)
    }
}

/// Same visible type-2 curves, but Liberty 5 uses ordinal 0002 for Bass Booster;
/// Space 2's capture-derived 7E7E ID and 53-byte payload must stay model-specific.
func eqPresets(for profile: DeviceProfile) -> [String: (id: [UInt8], bands: [UInt8])] {
    guard profile.controlProtocol == .liberty5 else { return eqPresets }
    var result = eqPresets
    for (index, preset) in eqPresetOrder.enumerated() {
        result[preset.key]?.id = [UInt8(index), 0]
    }
    return result
}

func confirmsLiberty5EQ(_ actual: Liberty5EqualizerState, expected: Liberty5EqualizerState,
                       exact: Bool = false) -> Bool {
    guard actual.isValid, expected.isValid, actual.bothBudsConnected,
          actual.presetID == expected.presetID, actual.hearID == expected.hearID,
          actual.immersiveAudio == expected.immersiveAudio else { return false }
    if exact { return actual.configuration == expected.configuration }
    var availableChannels = 0
    for start in [2, 12] {
        let channel = Array(actual.configuration[start..<(start + 10)])
        // Firmware 03.90 can omit the right channel (all FF) even with TWS
        // connected. Never display those sentinels as +13.5 dB or claim both
        // channels were read back. Every available channel must match exactly.
        if channel == Array(repeating: 0xFF, count: 10) { continue }
        availableChannels += 1
        if channel != Array(expected.configuration[start..<(start + 10)]) { return false }
    }
    return availableChannels > 0
}

func setEQVerified(_ link: RFCOMMLink, profile: DeviceProfile,
                   id: [UInt8], bands: [UInt8]) throws -> DeviceState {
    let current = try readDeviceState(link, profile: profile)
    let packet = try eqWrite(profile: profile, id: id, bands: bands, currentState: current)
    let expected = try current.liberty5EQ?.selecting(id: id, bands: bands)
    try link.send(packet)
    pump(0.15)
    for _ in 0..<6 {
        if let state = try? readDeviceState(link, profile: profile, attempts: 1),
           state.model == profile.modelCode {
            if let expected, let actual = state.liberty5EQ {
                if confirmsLiberty5EQ(actual, expected: expected), state.soundModePayload == current.soundModePayload {
                    return state
                }
            } else if profile.controlProtocol == .space2,
                      state.eqPreset == id.first, state.eqBands == bands {
                return state
            }
        }
        pump(0.35)
    }
    throw ProbeError("EQ was not confirmed by the device; refresh to check its actual settings")
}

/// Explicit hardware tests use this to restore the entire original block,
/// including hidden bands and unavailable-channel sentinels, not just sliders.
func restoreLiberty5EQ(_ link: RFCOMMLink, original: Liberty5EqualizerState) throws -> DeviceState {
    let current = try readDeviceState(link, profile: .liberty5)
    guard let actual = current.liberty5EQ else { throw ProbeError("missing Liberty 5 EQ state") }
    if confirmsLiberty5EQ(actual, expected: original, exact: true) { return current }
    if let reason = actual.writeBlockReason { throw ProbeError(reason) }
    try link.send(original.packet())
    pump(0.15)
    for _ in 0..<6 {
        if let state = try? readDeviceState(link, profile: .liberty5, attempts: 1),
           let actual = state.liberty5EQ,
           confirmsLiberty5EQ(actual, expected: original, exact: true) { return state }
        pump(0.35)
    }
    throw ProbeError("could not confirm exact restoration of the original Liberty 5 EQ/HearID settings")
}

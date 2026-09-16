import Foundation

enum DeviceControlError: Error, CustomStringConvertible {
    case unidentifiedModel
    case unsupportedFeature(DeviceFeature, String)

    var description: String {
        switch self {
        case .unidentifiedModel:
            return "device model has not been verified for writes"
        case let .unsupportedFeature(feature, model):
            return "\(model) does not have verified \(feature.rawValue) support"
        }
    }
}

/// Performs only the write-unlock sequence verified for the resolved profile.
/// Callers must identify the device using a read-only state request first.
func handshake(_ link: RFCOMMLink, profile: DeviceProfile) throws {
    guard let controlProtocol = profile.controlProtocol else {
        throw DeviceControlError.unidentifiedModel
    }
    switch controlProtocol {
    case .space2:
        try link.send(Command(0x01, 0x01));               pump(0.4)
        try link.send(Command(0x05, 0x01), payload: [1]); pump(0.6)
        try link.send(Command(0x05, 0x81));               pump(0.2)
        try link.send(Command(0x05, 0x81));               pump(0.2)
        try link.send(Command(0x05, 0x81), payload: [1]); pump(0.3)
        try link.send(Command(0x05, 0x81));               pump(0.4)
        try link.send(Command(0x18, 0x85), payload: [1]); pump(0.4)
        try link.send(Command(0x02, 0x86), payload: [1]); pump(0.2)
    }
}

func ancWrite(profile: DeviceProfile, mode: ANCMode, level: UInt8) throws -> [UInt8] {
    guard let controlProtocol = profile.controlProtocol else {
        throw DeviceControlError.unidentifiedModel
    }
    guard profile.supports(.soundMode) else {
        throw DeviceControlError.unsupportedFeature(.soundMode, profile.displayName)
    }
    switch controlProtocol {
    case .space2:
        return Frame.encode(Command(0x06, 0x81), payload: ancPayload(mode, level: level))
    }
}

func eqWrite(profile: DeviceProfile, id: [UInt8], bands: [UInt8]) throws -> [UInt8] {
    guard let controlProtocol = profile.controlProtocol else {
        throw DeviceControlError.unidentifiedModel
    }
    guard profile.supports(.equaliser) else {
        throw DeviceControlError.unsupportedFeature(.equaliser, profile.displayName)
    }
    if id == eqCustomID, !profile.supports(.customEQ) {
        throw DeviceControlError.unsupportedFeature(.customEQ, profile.displayName)
    }
    switch controlProtocol {
    case .space2:
        return Frame.encode(Command(0x03, 0x87), payload: eqPayload(id: id, bands: bands))
    }
}

enum ANCMode: UInt8 {
    case noiseCancelling = 0x00
    case transparency    = 0x01
    case normal          = 0x02

    init?(_ s: String) {
        switch s.lowercased() {
        case "nc", "anc", "noisecancelling", "noise": self = .noiseCancelling
        case "transparency", "trans", "ambient":      self = .transparency
        case "normal", "off", "none":                 self = .normal
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .noiseCancelling: return "Noise Cancelling"
        case .transparency:    return "Transparency"
        case .normal:          return "Normal"
        }
    }
}

/// `06:81` payload: [mode, level, 02, 00, 00, 01].
/// The level byte packs the ANC intensity in its high nibble (5F = level 5).
/// Note byte 2 is 0x02 on writes even though the matching read returns 0xFF.
func ancPayload(_ mode: ANCMode, level: UInt8) -> [UInt8] {
    [mode.rawValue, (min(max(level, 1), 5) << 4) | 0x0F, 0x02, 0x00, 0x00, 0x01]
}

// MARK: - Equaliser (03:87)

/// 53-byte payload captured from the official app (preset 01, Acoustic).
/// Layout: [0:2] preset id, [2:4] zero, [4:13] nine band values, [13:42] a
/// fixed block, [42:51] the personalised curve, [51:53] trailing zeros.
/// Only the preset id, the eight user bands and the curve are varied.
/// Presets captured from the official Android app by selecting every entry and
/// reading the resulting `03:87` frame from its Bluetooth HCI trace. The Space
/// 2 exposes all 22 of these presets.
///
/// Most firmware presets use their ordinal as a little-endian 16-bit ID. Bass
/// Booster is an exception: the app writes its explicit-curve ID, `7E7E`.
let eqPresets: [String: (id: [UInt8], bands: [UInt8])] = [
    "signature":     (id: [0x00, 0x00], bands: [0x78, 0x78, 0x78, 0x78, 0x78, 0x78, 0x78, 0x78]),
    "acoustic":      (id: [0x01, 0x00], bands: [0xA0, 0x82, 0x8C, 0x8C, 0xA0, 0xA0, 0xA0, 0x8C]),
    "bassbooster":   (id: [0x7E, 0x7E], bands: [0xA0, 0x96, 0x82, 0x78, 0x78, 0x78, 0x78, 0x78]),
    "bassreducer":   (id: [0x03, 0x00], bands: [0x50, 0x5A, 0x6E, 0x78, 0x78, 0x78, 0x78, 0x78]),
    "classical":     (id: [0x04, 0x00], bands: [0x96, 0x96, 0x64, 0x64, 0x78, 0x8C, 0x96, 0xA0]),
    "podcast":       (id: [0x05, 0x00], bands: [0x5A, 0x8C, 0xA0, 0xA0, 0x96, 0x8C, 0x78, 0x64]),
    "dance":         (id: [0x06, 0x00], bands: [0x8C, 0x5A, 0x6E, 0x82, 0x8C, 0x8C, 0x82, 0x5A]),
    "deep":          (id: [0x07, 0x00], bands: [0x8C, 0x82, 0x96, 0x96, 0x8C, 0x64, 0x50, 0x46]),
    "electronic":    (id: [0x08, 0x00], bands: [0x96, 0x8C, 0x64, 0x8C, 0x82, 0x8C, 0x96, 0x96]),
    "flat":          (id: [0x09, 0x00], bands: [0x64, 0x64, 0x6E, 0x78, 0x78, 0x78, 0x64, 0x64]),
    "hiphop":        (id: [0x0A, 0x00], bands: [0x8C, 0x96, 0x6E, 0x6E, 0x8C, 0x6E, 0x8C, 0x96]),
    "jazz":          (id: [0x0B, 0x00], bands: [0x8C, 0x8C, 0x64, 0x64, 0x78, 0x8C, 0x96, 0xA0]),
    "latin":         (id: [0x0C, 0x00], bands: [0x78, 0x78, 0x64, 0x64, 0x64, 0x78, 0x96, 0xAA]),
    "lounge":        (id: [0x0D, 0x00], bands: [0x6E, 0x8C, 0xA0, 0x96, 0x78, 0x64, 0x8C, 0x82]),
    "piano":         (id: [0x0E, 0x00], bands: [0x78, 0x96, 0x96, 0x8C, 0xA0, 0xAA, 0x96, 0xA0]),
    "pop":           (id: [0x0F, 0x00], bands: [0x6E, 0x82, 0x96, 0x96, 0x82, 0x6E, 0x64, 0x5A]),
    "rnb":           (id: [0x10, 0x00], bands: [0xB4, 0x8C, 0x64, 0x64, 0x8C, 0x96, 0x96, 0xA0]),
    "rock":          (id: [0x11, 0x00], bands: [0x96, 0x8C, 0x6E, 0x6E, 0x82, 0x96, 0xA0, 0xAA]),
    "smallspeakers": (id: [0x12, 0x00], bands: [0xA0, 0x96, 0x82, 0x78, 0x64, 0x5A, 0x50, 0x50]),
    "spokenword":    (id: [0x13, 0x00], bands: [0x5A, 0x64, 0x82, 0x8C, 0x8C, 0x82, 0x78, 0x5A]),
    "treblebooster": (id: [0x14, 0x00], bands: [0x64, 0x64, 0x64, 0x6E, 0x82, 0x8C, 0x8C, 0xA0]),
    "treblereducer": (id: [0x15, 0x00], bands: [0x78, 0x78, 0x78, 0x64, 0x5A, 0x50, 0x50, 0x3C]),
]

/// Exact 53-byte `03:87` payloads for every factory preset, captured verbatim from
/// the official Soundcore Android app via Bluetooth HCI snoop trace.
///
/// Notice bytes 42..50 contain the DSP hardware filter compensation / pre-gain curve.
/// Overwriting these bytes with 0x78 neutralises the DSP filter and disables equalization.
let eqPresetPayloads: [String: [UInt8]] = [
    "signature":     parseHex("0000000078787878787878787800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007878787878787878780000")!,
    "acoustic":      parseHex("01000000A0828C8CA0A0A08C7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007D767B787C7A7C79780000")!,
    "bassbooster":   parseHex("7E7E0000A0968278787878787800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007B7A787878787878780000")!,
    "bassreducer":   parseHex("03000000505A6E78787878787800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007576787878787878780000")!,
    "classical":     parseHex("0400000096966464788C96A07800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007A7C7477787A797D780000")!,
    "podcast":       parseHex("050000005A8CA0A0968C78647800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF00747B7A7B797A7875780000")!,
    "dance":         parseHex("060000008C5A6E828C8C825A7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007C7378787A797B73780000")!,
    "deep":          parseHex("070000008C8296968C6450467800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007A777B797B767673780000")!,
    "electronic":    parseHex("08000000968C648C828C96967800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007A7B737D777A7A7B780000")!,
    "flat":          parseHex("0900000064646E78787864647800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007677777878797676780000")!,
    "hiphop":        parseHex("0A0000008C966E6E8C6E8C967800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF00797C76767D747B7B780000")!,
    "jazz":          parseHex("0B0000008C8C6464788C96A07800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF00797B7577787A797D780000")!,
    "latin":         parseHex("0C00000078786464647896AA7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007879767776787A7E780000")!,
    "lounge":        parseHex("0D0000006E8CA09678648C827800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF00767A7B7A78747C78780000")!,
    "piano":         parseHex("0E0000007896968CA0AA96A07800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF00777B7A787B7C787D780000")!,
    "pop":           parseHex("0F0000006E829696826E645A7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF0077797A7A79777775780000")!,
    "rnb":           parseHex("10000000B48C64648C9696A07800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007E7976757B7A797D780000")!,
    "rock":          parseHex("11000000968C6E6E8296A0AA7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007A7A7677797A7A7E780000")!,
    "smallspeakers": parseHex("12000000A0968278645A50507800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007B7A787976767574780000")!,
    "spokenword":    parseHex("130000005A64828C8C82785A7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF0076767A797A787974780000")!,
    "treblebooster": parseHex("140000006464646E828C8CA07800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF0076777777797A787D780000")!,
    "treblereducer": parseHex("15000000787878645A50503C7800FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007878797677757771780000")!,
]

/// Display order used by the official app and the menu-bar editor.
let eqPresetOrder: [(key: String, title: String)] = [
    ("signature", "Signature"), ("acoustic", "Acoustic"),
    ("bassbooster", "Bass Booster"), ("bassreducer", "Bass Reducer"),
    ("classical", "Classical"), ("podcast", "Podcast"), ("dance", "Dance"),
    ("deep", "Deep"), ("electronic", "Electronic"), ("flat", "Flat"),
    ("hiphop", "Hip-Hop"), ("jazz", "Jazz"), ("latin", "Latin"),
    ("lounge", "Lounge"), ("piano", "Piano"), ("pop", "Pop"),
    ("rnb", "R&B"), ("rock", "Rock"), ("smallspeakers", "Small Speakers"),
    ("spokenword", "Spoken Word"), ("treblebooster", "Treble Booster"),
    ("treblereducer", "Treble Reducer"),
]

/// The app uses FEFE — not Bass Booster's 7E7E — for a user Custom EQ curve.
let eqCustomID: [UInt8] = [0xFE, 0xFE]

/// A neutral Custom EQ write captured from the official app.
let eqCustomTemplate: [UInt8] = parseHex(
    "FEFE000078787878787878787878FFFF00FFFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFFFFFFFF007878787878787878780000"
)!

/// Band values are 0x78 (120) at 0 dB, 10 units per dB.
func eqByte(dB: Double) -> UInt8 {
    UInt8(clamping: Int((120 + dB * 10).rounded()))
}

func eqDecibels(_ b: UInt8) -> Double {
    (Double(b) - 120) / 10
}

/// Constant-Q filter compensation matrix derived from captured Android traces.
/// This calculates bytes 42..50 of the 53-byte payload, which the headset DSP uses
/// as hardware filter coefficients to prevent frequency overlap distortion.
func calculateEQTail(bands: [UInt8]) -> [UInt8] {
    precondition(bands.count == 8)
    let weights: [[Double]] = [
        [+0.120, -0.056, +0.019, -0.005, +0.003, -0.002, +0.005, -0.000, 0.0],
        [-0.057, +0.161, -0.076, +0.030, -0.006, +0.006, -0.012, +0.006, 0.0],
        [+0.020, -0.064, +0.162, -0.073, +0.015, -0.014, +0.004, -0.001, 0.0],
        [-0.010, +0.016, -0.065, +0.171, -0.077, +0.026, -0.005, -0.003, 0.0],
        [+0.008, -0.004, +0.027, -0.078, +0.183, -0.067, +0.028, -0.001, 0.0],
        [-0.004, -0.000, -0.015, +0.027, -0.073, +0.162, -0.077, +0.017, 0.0],
        [+0.012, +0.001, +0.002, -0.007, +0.022, -0.060, +0.170, -0.058, 0.0],
        [-0.006, -0.002, +0.005, +0.001, -0.009, +0.011, -0.056, +0.148, 0.0],
    ]
    var tail = Array(repeating: UInt8(0x78), count: 9)
    for j in 0..<8 {
        var sum = 0.0
        for i in 0..<8 {
            let delta = Double(Int(bands[i]) - 120)
            sum += delta * weights[i][j]
        }
        let clamped = min(max(Int(sum.rounded()), -30), 30)
        tail[j] = UInt8(clamping: 120 + clamped)
    }
    tail[8] = 0x78
    return tail
}

func eqPayload(id: [UInt8], bands: [UInt8]) -> [UInt8] {
    precondition(bands.count == 8)
    precondition(id.count == 2)
    // 1. If this matches a known factory preset with factory bands, return its exact verified payload
    for (key, preset) in eqPresets {
        if preset.id == id && preset.bands == bands, let payload = eqPresetPayloads[key] {
            return payload
        }
    }
    // 2. Custom EQ or custom band sliders: assemble template with computed DSP compensation tail
    var p = eqCustomTemplate
    p[0] = id[0]
    p[1] = id[1]
    for i in 0..<8 { p[4 + i] = bands[i] }
    p[12] = 0x78                                  // 9th band is always neutral
    let tail = calculateEQTail(bands: bands)
    for i in 0..<9 { p[42 + i] = tail[i] }
    return p
}

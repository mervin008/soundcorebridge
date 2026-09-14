import Foundation

/// Encoder/parser checks against packets documented for other Soundcore models.
/// If these pass, the framing and checksum implementation match known-good bytes.
func modeSelfTest() {
    let vectors: [(String, Command, [UInt8], String)] = [
        ("device info",   Command(0x01, 0x01), [],     "08EE00000001010A0002"),
        ("LDAC query",    Command(0x01, 0x7F), [],     "08EE000000017F0A0080"),
        ("LDAC enable",   Command(0x01, 0xFF), [0x01], "08EE00000001FF0B000102"),
        ("LDAC disable",  Command(0x01, 0xFF), [0x00], "08EE00000001FF0B000001"),
        ("multipoint on", Command(0x0B, 0x84), [0x01], "08EE0000000B840B000191"),
        ("multipoint off",Command(0x0B, 0x84), [0x00], "08EE0000000B840B000090"),
    ]

    var failures = 0
    log("encoder vectors")
    for (name, cmd, payload, expected) in vectors {
        let got = hex(Frame.encode(cmd, payload: payload), separator: "")
        let ok = got == expected
        if !ok { failures += 1 }
        log("  \(ok ? "PASS" : "FAIL")  \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(got)\(ok ? "" : "  expected \(expected)")")
    }

    // Parser: response magic, split across chunk boundaries, with trailing garbage.
    log("\nparser")
    var response = Frame.encode(Command(0x01, 0x01), payload: [0xDE, 0xAD, 0xBE, 0xEF])
    response[0] = 0x09; response[1] = 0xFF
    response[response.count - 1] = Frame.checksum(response.dropLast())

    let parser = FrameParser()
    var out = parser.feed(Array(response[0..<5]))
    out += parser.feed(Array(response[5...]))
    let split = out.count == 1 && out[0].payload == [0xDE, 0xAD, 0xBE, 0xEF]
        && out[0].checksumOK && out[0].isResponse
    if !split { failures += 1 }
    log("  \(split ? "PASS" : "FAIL")  reassembles a frame split across two chunks")

    let noisy = FrameParser()
    let withJunk = [0x00, 0xFF, 0x13] + response + [0x77]
    let recovered = noisy.feed(withJunk)
    let resync = recovered.count == 1 && recovered[0].checksumOK
    if !resync { failures += 1 }
    log("  \(resync ? "PASS" : "FAIL")  resyncs past leading garbage")

    var corrupt = response
    corrupt[10] ^= 0xFF
    let bad = FrameParser().feed(corrupt)
    let caught = bad.count == 1 && !bad[0].checksumOK
    if !caught { failures += 1 }
    log("  \(caught ? "PASS" : "FAIL")  flags a corrupted payload as bad checksum")

    // The complete Space 2 preset table is capture-derived, not guessed. Check
    // its size and the special IDs that are easy to accidentally conflate.
    let custom = eqPayload(id: eqCustomID, bands: Array(repeating: 0x78, count: 8))
    let acoustic = eqPayload(id: eqPresets["acoustic"]!.id, bands: eqPresets["acoustic"]!.bands)
    let bassreducer = eqPayload(id: eqPresets["bassreducer"]!.id, bands: eqPresets["bassreducer"]!.bands)
    let eqTable = eqPresets.count == 22 && eqPresetOrder.count == 22 && eqPresetPayloads.count == 22
        && eqPresets["bassbooster"]?.id == [0x7E, 0x7E]
        && eqCustomID == [0xFE, 0xFE]
        && custom.count == 53 && Array(custom[0..<2]) == eqCustomID
        && Array(custom[4..<13]) == Array(repeating: 0x78, count: 9)
        && acoustic.count == 53 && Array(acoustic[42..<51]) == [0x7D, 0x76, 0x7B, 0x78, 0x7C, 0x7A, 0x7C, 0x79, 0x78]
        && bassreducer.count == 53 && Array(bassreducer[42..<51]) == [0x75, 0x76, 0x78, 0x78, 0x78, 0x78, 0x78, 0x78, 0x78]
    if !eqTable { failures += 1 }
    log("  \(eqTable ? "PASS" : "FAIL")  keeps all 22 EQ presets with verified DSP filter curves and FEFE Custom EQ")

    // Device profiles
    log("\ndevice profiles")
    var profileOK = true
    for p in DeviceRegistry.all {
        if DeviceRegistry.profile(modelCode: p.modelCode)?.displayName != p.displayName { profileOK = false }
        if DeviceRegistry.profile(bluetoothName: p.nameMatches[0])?.modelCode != p.modelCode { profileOK = false }
    }
    if !profileOK { failures += 1 }
    log("  \(profileOK ? "PASS" : "FAIL")  \(DeviceRegistry.all.count) profile(s) resolve by model code and name")

    // An unknown device must fall back to read-only.
    let fallback = DeviceRegistry.resolve(state: Array(repeating: 0, count: 120), bluetoothName: "Some Other Headset")
    let readOnly = !fallback.supports(.soundMode) && !fallback.supports(.equaliser)
    if !readOnly { failures += 1 }
    log("  \(readOnly ? "PASS" : "FAIL")  unknown device falls back to a read-only profile")

    // Space 2 offsets still decode a real captured blob.
    let space2 = DeviceRegistry.resolve(state: sampleSpace2State(), bluetoothName: "soundcore Space 2")
    let decoded = parseState(sampleSpace2State(), profile: space2)
    let decodeOK = space2.modelCode == "1402" && decoded?.model == "1402" && decoded?.ancMode == 0x00
    if !decodeOK { failures += 1 }
    log("  \(decodeOK ? "PASS" : "FAIL")  Space 2 state blob decodes through its profile")

    log(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

/// A real 01:01 payload captured from a Space 2, used to check that the
/// profile offsets still decode known-good bytes.
func sampleSpace2State() -> [UInt8] {
    parseHex("040030312E3539313430323834394434424230373938460100A0828C8CA0A0A08C00001EFF00FFFFFFFFFFFFFFFF00000000000000FFFFFFFFFFFFFFFF00000000060407FF0705005FFF00000132000000010100010100005A000001000100000000FFFFFFFFFF") ?? []
}

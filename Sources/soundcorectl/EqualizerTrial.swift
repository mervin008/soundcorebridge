import Foundation

private struct EqualizerTrialStep: Codable {
    var requested: String
    var presetID: String
    var bandsDB: [Double]
    var rightChannelReadbackAvailable: Bool
    var hearIDCalibrationPreserved: Bool
    var soundModePreserved: Bool
}

private struct EqualizerTrialReport: Codable {
    var date: String
    var model: String
    var firmware: String
    var original: Liberty5EqualizerState
    var originalSoundMode: [UInt8]?
    var steps: [EqualizerTrialStep] = []
    var originalRestored = false
    var failure: String?
}

/// Opt-in test, with an on-disk recovery snapshot before any mutating command.
/// No serial number, Bluetooth name, or address is written to this report.
func modeEqualizerTrial() throws {
    let link = try connect()
    defer { link.close(); activeLink = nil }
    link.onPacket = nil
    let (profile, _) = try identify(link)
    guard profile.controlProtocol == .liberty5 else { throw ProbeError("eq-cycle-test requires Liberty 5 (A3957)") }
    let initial = try readDeviceState(link, profile: profile)
    guard let original = initial.liberty5EQ else { throw ProbeError("missing Liberty 5 EQ/HearID state") }
    if let reason = original.writeBlockReason { throw ProbeError(reason) }
    // Check restoration can be encoded before taking the first test step.
    _ = try original.packet()
    let url = URL(fileURLWithPath: args.str("out") ?? "build/liberty5-eq-test.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var report = EqualizerTrialReport(date: ISO8601DateFormatter().string(from: Date()),
                                      model: initial.model, firmware: initial.firmware,
                                      original: original, originalSoundMode: initial.soundModePayload)
    try encoder.encode(report).write(to: url, options: .withoutOverwriting)
    log("Original EQ/HearID saved before first write: \(url.path)")
    let presets = eqPresets(for: profile)
    let keys = args.bool("all-presets") ? eqPresetOrder.map(\.key) : ["rock", "bassbooster", "signature"]
    var steps: [(String, [UInt8], [UInt8])] = keys.map {
        ($0, presets[$0]!.id, presets[$0]!.bands)
    }
    steps.append(("custom", eqCustomID, [130, 110, 120, 120, 120, 120, 120, 120]))
    var testError: Error?
    do {
        for (name, id, bands) in steps {
            let actual = try setEQVerified(link, profile: profile, id: id, bands: bands)
            guard let eq = actual.liberty5EQ,
                  Array(eq.hearID.dropFirst()) == Array(original.hearID.dropFirst()),
                  actual.soundModePayload == initial.soundModePayload,
                  eq.immersiveAudio == original.immersiveAudio else {
                throw ProbeError("an unrelated sound setting or HearID calibration changed")
            }
            report.steps.append(EqualizerTrialStep(requested: name, presetID: hex(eq.presetID),
                bandsDB: actual.eqBands.map(eqDecibels),
                rightChannelReadbackAvailable: eq.configuration[12] != 0xFF,
                hearIDCalibrationPreserved: true, soundModePreserved: true))
            try encoder.encode(report).write(to: url, options: .atomic)
            log("PASS \(name) — device readback \(hex(actual.eqBands)); HearID calibration and sound mode unchanged")
            pump(0.5)
        }
    } catch {
        testError = error
        report.failure = String(describing: error)
    }
    do {
        let restored = try restoreLiberty5EQ(link, original: original)
        report.originalRestored = restored.liberty5EQ.map {
            confirmsLiberty5EQ($0, expected: original, exact: true)
        } == true && restored.soundModePayload == initial.soundModePayload
        guard report.originalRestored else { throw ProbeError("restored EQ but another sound setting differs") }
        log("RESTORED — exact original EQ (including hidden bands), HearID, and sound mode confirmed")
    } catch {
        report.failure = [report.failure, "Restoration: \(error)"].compactMap { $0 }.joined(separator: "; ")
        if testError == nil { testError = error }
    }
    try encoder.encode(report).write(to: url, options: .atomic)
    if let testError { throw testError }
    log("EQ hardware test passed. Report: \(url.path)")
}

/// Recovery path for an interrupted trial; restores the snapshot, not another
/// guessed factory curve. It deliberately does not change the listening mode.
func modeEqualizerRestore() throws {
    guard let path = args.str("from") else { throw ProbeError("usage: eq-restore --from <eq-cycle-test.json>") }
    let report = try JSONDecoder().decode(EqualizerTrialReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard report.model == "3957" else { throw ProbeError("snapshot is not for Liberty 5") }
    _ = try report.original.packet()
    let link = try connect()
    defer { link.close(); activeLink = nil }
    link.onPacket = nil
    let (profile, state) = try identify(link)
    guard profile.controlProtocol == .liberty5, state.firmware == report.firmware else {
        throw ProbeError("snapshot model/firmware does not match the connected device")
    }
    guard let current = state.liberty5EQ, current.isValid,
          Array(current.hearID.dropFirst()) == Array(report.original.hearID.dropFirst()) else {
        throw ProbeError("HearID calibration differs from this snapshot; refusing to overwrite another calibration")
    }
    _ = try restoreLiberty5EQ(link, original: report.original)
    log("RESTORED — exact original EQ/HearID confirmed; listening mode was not modified")
}

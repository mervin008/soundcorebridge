import Foundation

private struct SoundModeTrialStep: Codable {
    var requested: String
    var confirmed: String
    var soundSettings: String
    var otherSettingsPreserved: Bool
}

private struct SoundModeTrialReport: Codable {
    var date: String
    var model: String
    var firmware: String
    var macOS: String
    var originalSoundSettings: String
    var steps: [SoundModeTrialStep] = []
    var originalRestored = false
    var restoredSoundSettings: String?
    var failure: String?
}

/// Opt-in real-hardware test. Save the original block before the first write;
/// errors also pass through restoration. The report contains no device address.
func modeSoundModeTrial() throws {
    let link = try connect()
    defer { link.close(); activeLink = nil }
    // Avoid raw identity packets in the trial output or report.
    link.onPacket = nil
    let (profile, identity) = try identify(link)
    guard profile.controlProtocol == .liberty5 else {
        throw ProbeError("anc-cycle-test only supports an identified Liberty 5 (A3957)")
    }
    let initial = try readDeviceState(link, profile: profile)
    guard let original = initial.soundModePayload else {
        throw DeviceControlError.missingSoundModeState
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var report = SoundModeTrialReport(
        date: ISO8601DateFormatter().string(from: Date()), model: identity.model,
        firmware: identity.firmware, macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        originalSoundSettings: hex(original)
    )
    let url = URL(fileURLWithPath: args.str("out") ?? "build/liberty5-anc-test.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: url, options: .withoutOverwriting)
    log("saved original settings: \(hex(original))")

    var testError: Error?
    do {
        for mode in [ANCMode.transparency, .normal, .noiseCancelling] {
            let state = try setSoundModeVerified(link, profile: profile, mode: mode)
            guard let payload = state.soundModePayload,
                  Array(payload.dropFirst()) == Array(original.dropFirst()) else {
                throw ProbeError("unexpected change to another sound setting")
            }
            report.steps.append(SoundModeTrialStep(
                requested: mode.label, confirmed: ANCMode(rawValue: state.ancMode ?? 255)?.label ?? "Unknown",
                soundSettings: hex(payload), otherSettingsPreserved: true
            ))
            try encoder.encode(report).write(to: url, options: .atomic)
            log("PASS \(mode.label): \(hex(payload)) — confirmed by device")
            pump(0.6)
        }
    } catch {
        testError = error
        report.failure = String(describing: error)
    }

    do {
        let restored = try restoreLiberty5SoundModes(link, original: original)
        report.originalRestored = restored.soundModePayload == original
        report.restoredSoundSettings = restored.soundModePayload.map { hex($0) }
        log("RESTORED: \(hex(original)) — confirmed by device")
    } catch {
        report.failure = [report.failure, "Restoration: \(error)"].compactMap { $0 }.joined(separator: "; ")
        if testError == nil { testError = error }
    }
    try encoder.encode(report).write(to: url, options: .atomic)
    if let testError { throw testError }
    log("All three modes passed. Report: \(url.path)")
}

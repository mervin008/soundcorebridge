import Foundation

/// All functions in this file run on the thread that owns the RFCOMM run loop.
/// A successful asynchronous write is not proof that the device applied it.
func readDeviceState(_ link: RFCOMMLink, profile: DeviceProfile,
                     attempts: Int = 3) throws -> DeviceState {
    var result: DeviceState?
    let previous = link.onPacket
    link.onPacket = { packet in
        previous?(packet)
        guard packet.isResponse, packet.checksumOK,
              packet.cmd == Command(0x01, 0x01),
              DeviceRegistry.resolve(state: packet.payload, bluetoothName: "").modelCode == profile.modelCode,
              let state = parseState(packet.payload, profile: profile) else { return }
        result = state
    }
    defer { link.onPacket = previous }
    for _ in 0..<attempts {
        try link.send(Command(0x01, 0x01))
        pump(1.0) { result != nil }
        if let result { return result }
    }
    throw ProbeError("device did not return a valid state; mode is not confirmed")
}

func confirmsSoundMode(_ state: DeviceState, profile: DeviceProfile,
                       mode: ANCMode, level: UInt8,
                       expectedPayload: [UInt8]?) -> Bool {
    guard state.model == profile.modelCode, state.ancMode == mode.rawValue else { return false }
    if profile.controlProtocol == .liberty5 {
        return expectedPayload?.count == 7 && state.soundModePayload == expectedPayload
    }
    return mode != .noiseCancelling || state.ancLevel == Int(min(max(level, 1), 5))
}

/// Read current settings immediately before the write, then require device
/// readback. This also avoids encoding a queued click from stale UI state.
func setSoundModeVerified(_ link: RFCOMMLink, profile: DeviceProfile,
                          mode: ANCMode, level: UInt8 = 5) throws -> DeviceState {
    let current = try readDeviceState(link, profile: profile)
    let packet = try ancWrite(profile: profile, mode: mode, level: level, currentState: current)
    var expected = current.soundModePayload
    if expected != nil { expected?[0] = mode.rawValue }

    // Only the A3957 path ignores level: its strength is deliberately preserved.
    if profile.controlProtocol == .liberty5,
       confirmsSoundMode(current, profile: profile, mode: mode, level: level, expectedPayload: expected) {
        return current
    }

    try link.send(packet)
    pump(0.15)
    for _ in 0..<6 {
        if let state = try? readDeviceState(link, profile: profile, attempts: 1),
           confirmsSoundMode(state, profile: profile, mode: mode, level: level, expectedPayload: expected) {
            return state
        }
        pump(0.35)
    }
    throw ProbeError("\(mode.label) was not confirmed by the device; refresh to check its actual mode")
}

/// Used by the explicit hardware test to restore all seven original bytes.
func restoreLiberty5SoundModes(_ link: RFCOMMLink, original: [UInt8]) throws -> DeviceState {
    guard original.count == 7, let mode = ANCMode(rawValue: original[0]) else {
        throw DeviceControlError.missingSoundModeState
    }
    let current = try readDeviceState(link, profile: .liberty5)
    if current.soundModePayload == original { return current }
    try link.send(Command(0x06, 0x81), payload: original)
    pump(0.15)
    for _ in 0..<6 {
        if let state = try? readDeviceState(link, profile: .liberty5, attempts: 1),
           confirmsSoundMode(state, profile: .liberty5, mode: mode, level: 5, expectedPayload: original) {
            return state
        }
        pump(0.35)
    }
    throw ProbeError("could not confirm restoration of the original Liberty 5 sound settings")
}

import Foundation

func equalizerSelfTests() -> Int {
    var failures = 0
    func check(_ passed: Bool, _ name: String) {
        if !passed { failures += 1 }
        log("  \(passed ? "PASS" : "FAIL")  \(name)")
    }
    log("\nLiberty 5 equalizer")
    var payload = Array(repeating: UInt8(0), count: 154)
    payload[1] = 1
    payload.replaceSubrange(16...19, with: Array("3957".utf8))
    payload.replaceSubrange(40...49, with: Array(repeating: 120, count: 8) + [0, 0])
    payload.replaceSubrange(50...59, with: Array(repeating: 0xFF, count: 10))
    // Non-neutral calibration, nonzero timestamp, genre: none may be erased.
    payload.replaceSubrange(62...81, with: (0..<20).map { UInt8(100 + $0) })
    payload.replaceSubrange(82...85, with: [1, 2, 3, 4])
    payload.replaceSubrange(87...106, with: (0..<20).map { UInt8(120 + $0) })
    payload.replaceSubrange(107...108, with: [3, 0])
    let state = parseState(payload, profile: .liberty5)!
    let original = state.liberty5EQ!
    let presets = eqPresets(for: .liberty5)
    check(original.isValid && state.eqBands == Array(repeating: 120, count: 8)
          && original.configuration[12] == 0xFF, "decodes A3957 offsets and hides unavailable-channel sentinels")
    check(presets.count == 22 && presets["bassbooster"]?.id == [2, 0]
          && eqPresets(for: .space2)["bassbooster"]?.id == [0x7E, 0x7E], "uses model-specific preset IDs without changing Space 2")
    do {
        let rock = presets["rock"]!
        let target = try original.selecting(id: rock.id, bands: rock.bands)
        let frame = try eqWrite(profile: .liberty5, id: rock.id, bands: rock.bands, currentState: state)
        let decoded = FrameParser().feed(frame)
        let body = decoded.first?.payload ?? []
        // Independently assemble the 114-byte wire layout, in protocol order.
        let channel: [UInt8] = [150, 140, 110, 110, 130, 150, 160, 170, 120, 0]
        var expected: [UInt8] = [17, 0, 3, 0] + channel + channel + [0, 0, 0]
        expected += Array(original.hearID[1...45])
        for value in channel + channel { expected += [value, 0] }
        expected += [0, 0]
        check(frame.count == 124 && body == expected && decoded.first?.checksumOK == true,
              "encodes exact 114-byte two-channel Rock payload (not Space 2's 53 bytes)")
        check(Array(target.hearID.dropFirst()) == Array(original.hearID.dropFirst()) && !target.hearIDEnabled,
              "preserves calibration, timestamp, type and genre while selecting EQ")
        let custom = try original.selecting(id: eqCustomID, bands: [130, 110, 120, 120, 120, 120, 120, 120])
        check(custom.presetID == eqCustomID && Array(custom.configuration[10...11]) == [120, 120]
              && Array(custom.configuration[2...11]) == Array(custom.configuration[12...21]),
              "custom FEFE writes eight visible and two neutral hidden bands to both channels")
        var omittedRight = target
        omittedRight.configuration.replaceSubrange(12...21, with: Array(repeating: 255, count: 10))
        var stale = target; stale.configuration[2] = 120
        var changedCalibration = target; changedCalibration.hearID[2] ^= 1
        var wrongID = target; wrongID.configuration[1] = 1
        var wrongRight = target; wrongRight.configuration[12] ^= 1
        check(confirmsLiberty5EQ(target, expected: target)
              && confirmsLiberty5EQ(omittedRight, expected: target)
              && !confirmsLiberty5EQ(omittedRight, expected: target, exact: true)
              && !confirmsLiberty5EQ(stale, expected: target)
              && !confirmsLiberty5EQ(changedCalibration, expected: target)
              && !confirmsLiberty5EQ(wrongID, expected: target)
              && !confirmsLiberty5EQ(wrongRight, expected: target),
              "readback checks full preset ID, available channels, hidden bands and HearID metadata")
        let restore = FrameParser().feed(try original.packet()).first!.payload
        check(Array(restore[4...23]) == Array(original.configuration.dropFirst(2))
              && Array(restore[26...71]) == Array(original.hearID[0...45]),
              "restoration retains original hidden bands and absent-channel bytes exactly")
        for type: UInt8 in [0, 1] {
            var hearID = original; hearID.hearID[0] = 1; hearID.hearID[25] = type
            let body = FrameParser().feed(try hearID.packet()).first!.payload
            let curve = type == 1 ? Array(hearID.hearID[26...45]) : Array(hearID.hearID[1...20])
            let active = stride(from: 72, to: 112, by: 2).map { body[$0] }
            check(active == curve, "restores enabled HearID type \(type) using its original active curve")
        }
    } catch { check(false, "valid EQ encoding unexpectedly failed: \(error)") }

    func rejects(_ changed: Liberty5EqualizerState) -> Bool {
        (try? changed.selecting(id: eqCustomID, bands: Array(repeating: 120, count: 8))) == nil
    }
    var disconnected = original; disconnected.bothBudsConnected = false
    var malformed = original; malformed.hearID.removeLast()
    var unsupported = original; unsupported.hearID[25] = 255
    var genre = original; genre.hearID[0] = 1; genre.hearID[25] = 2
    var spatial = original; spatial.immersiveAudio = 1
    var wrongModel = state; wrongModel.model = "1402"
    check(rejects(disconnected) && rejects(malformed) && rejects(unsupported) && rejects(genre) && rejects(spatial)
          && (try? eqWrite(profile: .liberty5, id: eqCustomID, bands: Array(repeating: 120, count: 8), currentState: wrongModel)) == nil,
          "blocks missing TWS, malformed/unsupported state, unsafe HearID/spatial interaction and wrong model")
    check(genre.displayedBands.isEmpty, "does not pretend to know a genre-adjusted HearID curve")
    check((try? original.selecting(id: eqCustomID, bands: [120])) == nil
          && (try? original.selecting(id: [0xFE], bands: Array(repeating: 120, count: 8))) == nil
          && (try? original.selecting(id: [0x7E, 0x7E], bands: Array(repeating: 120, count: 8))) == nil
          && (try? original.selecting(id: eqCustomID, bands: Array(repeating: 181, count: 8))) == nil,
          "rejects wrong lengths, Space 2-only IDs and out-of-range curves before writing")
    var rightOnly = payload
    rightOnly.replaceSubrange(40...49, with: Array(repeating: 0xFF, count: 10))
    rightOnly.replaceSubrange(50...59, with: Array(repeating: 130, count: 10))
    check(parseState(rightOnly, profile: .liberty5)?.eqBands == Array(repeating: 130, count: 8),
          "uses available right-channel curve when left is absent")
    return failures
}

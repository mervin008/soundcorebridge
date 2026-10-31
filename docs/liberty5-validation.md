# Liberty 5 (A3957) validation

Real-device control/state tests were run on 2026-10-31 using a Liberty 5 with
firmware 03.90, Apple Silicon, macOS 26.6.2 and Swift 6.3.3. This report contains
no device address, serial number, private Bluetooth name or HearID calibration.

## Confirmed behavior

- Discover the vendor control service even when the earbuds have been renamed.
- Resolve the device from its own model identity, not its Bluetooth name.
- Switch Transparency, Normal and Noise Cancelling; require device readback.
- Preserve the other six sound-mode bytes, including existing ANC strength.
- Select all 22 factory EQ presets and a custom eight-band curve; verify full
  preset ID, the available ten-band channel and preserved HearID metadata.
- Retain HearID calibration, timestamp, type and favorite genre. Selecting EQ
  disables HearID without erasing the calibration.
- Restore the exact original EQ/HearID and listening mode after the tests,
  including original hidden-band and unavailable-channel bytes.
- Select Bass Booster through the live menu-bar app and confirm its displayed
  curve; change the first custom slider and confirm the device-reported curve.
- Repeat all three listening modes after the EQ tests and restore the original.

The custom hardware-test curve was `[+1, -1, 0, 0, 0, 0, 0, 0]` dB. Factory
presets were tested individually, not inferred from just one successful write.
The snapshot recovery path was exercised after GUI EQ changes.

## Verification limits

- Firmware 03.90 returns ten FF bytes for the right EQ channel even when both
  earbuds are connected. Packets include both channels, but the right channel's
  application has not been independently confirmed. FF is never displayed as gain.
- No listening test or acoustic measurement is claimed.
- Hardware tests started with HearID and Dolby/immersive audio disabled.
  Restoration of enabled initial/custom HearID has synthetic offline coverage
  only; genre-based HearID and enabled spatial-audio interactions remain blocked.
- ANC strength adjustment is not enabled for A3957; the existing value is retained.
- Battery display reports the left earbud only.
- Space 2 packet/profile regression vectors pass, but no new physical Space 2
  hardware test was performed for this change. Unknown models remain read-only.

## Reproduce offline checks

```sh
swift build
swift run --skip-build soundcorectl selftest
```

The built-in self-test covers framing, checksum handling, existing Space 2
vectors, A3957 state offsets, exact mode packets, the 114-byte EQ body, model-
specific preset IDs, factory/custom hidden bands, HearID preservation/restoration,
unavailable-channel sentinels, invalid inputs, blocked states and stale readback.
CI runs these checks without a Bluetooth device; CI is not a hardware test.

## Opt-in hardware checks

Quit other settings clients, including the menu-bar app, before running a CLI
test. Keep both earbuds connected for EQ. These commands intentionally change
settings temporarily, save a recovery snapshot before the first write, and
restore the original settings after success or failure:

```sh
swift run soundcorectl anc-cycle-test --out build/my-anc-test.json
swift run soundcorectl eq-cycle-test --all-presets --out build/my-eq-test.json
```

Output directories are created if needed. Existing reports are not overwritten.
After an interrupted EQ test, use that test's original snapshot:

```sh
swift run soundcorectl eq-restore --from build/my-eq-test.json
```

EQ snapshots contain personal HearID calibration even without a device address.
Keep snapshots private under the ignored `build/` directory. Never attach raw
identity packets, addresses, logs, captures or calibration to an issue or PR.

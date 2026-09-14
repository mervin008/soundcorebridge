# SoundcoreBridge

Native macOS control for Soundcore headphones — menu bar app and CLI. Talks to
the headset directly over its vendor Bluetooth RFCOMM channel. No companion
phone app, no cloud service, no audio proxy.

Anker ships companion apps for Android and iOS only. This fills the gap on the
Mac.

## Status

| | |
|---|---|
| **Verified hardware** | Soundcore Space 2 (D1402), firmware 01.59 |
| **Other Soundcore models** | Detected, battery + firmware only, read-only |
| **Platform** | macOS 13+ |

Every offset, command and EQ preset in this repository was confirmed against
real hardware — nothing is guessed. See [docs/protocol-map.md](docs/protocol-map.md).

Unknown models deliberately fall back to a **read-only profile**. Field offsets
differ between Soundcore models, and writing guessed offsets to unverified
hardware is how devices end up in strange states.

## Features

- Noise Cancelling / Transparency / Normal, with ANC strength 1–5
- All 22 factory EQ presets, plus an 8-band custom equaliser (±6 dB)
- Battery, firmware, model and multipoint host count
- Live EQ curve, tinted by the active listening mode
- A CLI for scripting and protocol work

## Build

Requires Swift 6 (Xcode 15+ or Command Line Tools).

```sh
swift build -c release          # CLI
./make-app.sh                   # menu bar app -> build/SoundcoreBridge.app
open build/SoundcoreBridge.app
```

## CLI

```sh
soundcorectl status                     # battery, firmware, ANC, EQ
soundcorectl anc nc --level 5           # nc | transparency | normal
soundcorectl eq rock                    # any of the 22 presets
soundcorectl eq "6,4,2,0,0,-2,-4,-6"    # custom curve, dB per band
soundcorectl selftest                   # offline codec + profile tests
```

Protocol investigation tools: `sdp`, `probe`, `sweep`, `watch`, `snap`, `diffs`, `send`.

## How it works

```
RFCOMM channel 30  ->  Frame codec (08EE/09FF + checksum)  ->  Device profile  ->  UI
```

The frame format is the same across Soundcore models. What differs per model is
where fields sit in the state blob, which value means which sound mode, and how
many EQ bands there are — so adding a model means adding a `DeviceProfile`, not
new protocol code.

Two things are non-obvious and cost real time to find:

- **Writes are ignored until a handshake runs.** The device answers reads
  happily and silently discards every write until the sequence in
  `Control.swift` completes.
- **The first `openRFCOMMChannelAsync` in a process always fails.** It primes
  IOBluetooth's run-loop source and the callback never arrives; a retry
  succeeds. Failed attempts must never be closed, or the close tears down the
  next channel.

## Adding a device model

1. Capture its traffic (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md))
2. Add a `DeviceProfile` in `Sources/soundcorectl/DeviceProfile.swift`
3. Register it in `DeviceRegistry.all`
4. `swift run soundcorectl selftest`

Only the profile changes. No protocol code.

## Safety

RFCOMM channels 12 (TOTA) and 13 (BESOTA) are firmware-flashing channels and
are hard-blocked in `RFCOMM.swift`. Do not remove that guard.

The headset accepts **one control client at a time**. If the phone app holds the
session, this app cannot connect — and iOS keeps the accessory link alive even
with the app force-closed.

## Licence

MIT — see [LICENSE](LICENSE).

## Credits

[OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30) is the reference
implementation for Soundcore protocols on Linux, Windows and Android, and its
capability-driven approach to device models informed the profile layer here.

**No code is copied from it.** OpenSCQ30 is GPL-3.0; this project is MIT.
Protocol facts are not copyrightable, but its source cannot be reused here
without relicensing this project as GPL-3.0.

<p align="center">
  <img src="assets/icon.png" width="104" alt="SoundcoreBridge">
</p>

<h1 align="center">SoundcoreBridge</h1>

<p align="center">
  <code>Soundcore headphones, controlled from macOS</code><br>
  <sub>Menu bar app and CLI · verified on D1402 · fw 01.59</sub>
</p>

<p align="center">
  <img src="docs/img/panel-anc.png" width="360" alt="The SoundcoreBridge menu bar panel">
</p>

---

Anker ships the Soundcore app for phones only. This talks to the headset
directly over its own Bluetooth protocol — every byte worked out by watching
real traffic, and checked by reading the value back off the hardware.

```
08 EE 00 00   00   06 81   10 00   00 5F 02 00 00 01   EF
└─ magic ─┘   seq  └cmd┘   └len┘   └───  payload  ──┘  sum
```

Sixteen bytes on RFCOMM channel 30 switch noise cancelling on. The headset
ignores every one of them until a handshake runs first.

## §01 · What it does

| | |
|---|---|
| **Noise control** <br> `06:81` | Noise Cancelling, Transparency and Normal, plus ANC strength 1–5 — which the official app reads back incorrectly, showing its own cached value instead of the headset's |
| **Equaliser** <br> `03:87` · 53-byte frame | All 22 factory presets and a custom 8-band curve at ±6 dB, including the DSP compensation tail the firmware expects |
| **Device state** <br> `01:01` · 103 bytes | Battery, firmware, model and multipoint host count, decoded through a per-model profile |
| **Command line** <br> `soundcorectl` | Scriptable control, plus the probe, sweep and diff tools used to map the protocol |
| **Safe by default** <br> ch 12 · ch 13 blocked | Firmware-flashing channels refused by service identity, so the guard holds on every device |

## §02 · The state blob

`01:01` returns 103 bytes describing the whole headset. Confirmed offsets:

| Offset | Field |
|---|---|
| `0` | Battery, 0–9 — percent is `(level + 1) × 10` |
| `2–6` | Firmware, ASCII |
| `7–10` | Model code, ASCII |
| `23` | EQ preset id |
| `25–32` | EQ bands, `120` = 0 dB, 10 units per dB |
| `71` | ANC mode — `00` NC, `01` Transparency, `02` Normal |
| `72` | ANC level, high nibble |
| `91` | Connected hosts |

Everything else is still unmapped. Full detail: [docs/protocol-map.md](docs/protocol-map.md).

## §03 · Install

```sh
brew tap mervin008/tap
brew trust mervin008/tap
brew install --cask --no-quarantine mervin008/tap/soundcorebridge
```

Homebrew refuses untrusted third-party casks, so the middle line is required.
The app is ad-hoc signed rather than notarised, which is what `--no-quarantine`
handles. macOS 13 or later. Or take the zip from
[releases](https://github.com/mervin008/soundcorebridge/releases/latest).

**Build it yourself**

```sh
git clone https://github.com/mervin008/soundcorebridge
cd soundcorebridge && ./make-app.sh
```

**Drive it from a script**

```sh
soundcorectl status                     # battery, firmware, ANC, EQ
soundcorectl anc nc --level 5
soundcorectl eq rock
soundcorectl eq "6,4,2,0,0,-2,-4,-6"    # custom curve, dB per band
soundcorectl selftest                   # offline, no headset needed
```

## §04 · Compatibility

| Device | Model | Status |
|---|---|---|
| Soundcore Space 2 | `D1402` | ✅ Verified — full control |
| Other Soundcore models | `—` | Detected — battery & firmware, read-only |

Unknown models stay read-only on purpose. Field offsets differ between models,
and writing guessed offsets to unverified hardware is how devices end up in
strange states.

Adding a device is a `DeviceProfile`, not new protocol code — the frame format
is identical across the range. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## §05 · Two things that cost a day each

**Writes are silently discarded until a handshake runs.** The device answers
reads happily and bins every write, with no error, until the sequence in
`Control.swift` completes.

**The first `openRFCOMMChannelAsync` in a process always fails.** It primes
IOBluetooth's run-loop source and the callback never arrives; a retry works.
Failed attempts must never be closed, or the close tears down the next channel.

## §06 · Credits

- **[SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge)** by AmitRajput-Dev — the model for what a native desktop bridge should be, and the project that proved macOS RFCOMM control was possible at all
- **[OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30)** by Oppzippy — the reference Soundcore implementation; its capability-driven device model shaped the profile layer here
- **[SoundcoreManager](https://github.com/gmallios/SoundcoreManager)** by gmallios — earlier desktop Soundcore client and protocol reference

---

<sub>Unofficial project, not affiliated with Anker or Soundcore. Firmware-update
channels are deliberately blocked, but this talks to your headphones over an
undocumented protocol — no warranty. <a href="LICENSE">MIT</a>.</sub>

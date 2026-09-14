<p align="center">
  <img src="assets/icon.png" width="128" alt="SoundcoreBridge">
</p>

<h1 align="center">SoundcoreBridge</h1>

<p align="center">
  Native macOS control for Soundcore headphones.<br>
  Menu bar app and CLI — no phone app, no cloud, no audio proxy.
</p>

<p align="center">
  <img src="docs/img/panel-anc.png" width="380" alt="The SoundcoreBridge menu bar panel">
</p>

---

## Why

Anker ships the Soundcore app for Android and iOS only. Plug the headphones
into a Mac and you lose ANC control, the equaliser, and any idea of the battery
level — even though the headset is perfectly happy to be told what to do over
Bluetooth.

SoundcoreBridge talks to it directly.

## ✨ Features

- **Noise control** — Noise Cancelling, Transparency, Normal, with ANC strength 1–5
- **Equaliser** — all 22 factory presets plus a custom 8-band curve (±6 dB)
- **Battery, firmware and multipoint** status at a glance
- **Live EQ curve**, tinted by the active listening mode
- **CLI** for scripting and protocol work

Everything here was confirmed against real hardware. Nothing is guessed.

## 🎧 Supported devices

| Device | Model | Status |
|---|---|---|
| Soundcore Space 2 | D1402 | ✅ Verified — full control |
| Other Soundcore models | — | 🔍 Detected — battery + firmware, read-only |

Unknown models stay read-only on purpose: field offsets differ between models,
and writing guessed offsets to unverified hardware is how devices end up in
strange states.

## 📥 Install

```sh
brew tap mervin008/tap
brew trust mervin008/tap
brew install --cask --no-quarantine mervin008/tap/soundcorebridge
```

Homebrew requires third-party casks to be trusted explicitly, hence the middle
step. The app is ad-hoc signed rather than notarised, which is what
`--no-quarantine` handles.

Or grab the zip from [releases](https://github.com/mervin008/soundcorebridge/releases/latest).
Requires macOS 13 or later.

### Build from source

```sh
git clone https://github.com/mervin008/soundcorebridge
cd soundcorebridge && ./make-app.sh
open build/SoundcoreBridge.app
```

## 🚀 CLI

```sh
soundcorectl status                     # battery, firmware, ANC, EQ
soundcorectl anc nc --level 5           # nc | transparency | normal
soundcorectl eq rock                    # any of the 22 presets
soundcorectl eq "6,4,2,0,0,-2,-4,-6"    # custom curve, dB per band
soundcorectl selftest                   # offline tests, no headset needed
```

Protocol tools: `sdp`, `probe`, `sweep`, `watch`, `snap`, `diffs`, `send`.

## 🔬 How it works

```
RFCOMM ch 30  ->  frame codec (08EE/09FF + checksum)  ->  device profile  ->  UI
```

The frame format is the same across Soundcore models. What changes per model is
where fields sit in the state blob, which value means which sound mode, and how
many EQ bands there are — so adding a device is a profile, not new protocol code.

Two things cost real time to discover:

- **Writes are silently ignored until a handshake runs.** The device answers
  reads happily and discards every write until the sequence in `Control.swift`
  completes.
- **The first `openRFCOMMChannelAsync` in a process always fails.** It primes
  IOBluetooth's run-loop source and the callback never arrives; a retry works.
  Failed attempts must never be closed, or the close kills the next channel.

Full map: [docs/protocol-map.md](docs/protocol-map.md).

## 🤝 Contributing

Got a Soundcore device that isn't supported? Capture it and it becomes a
profile — see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Issues and PRs welcome.

## 🙏 Credits

SoundcoreBridge stands on the work of:

- **[SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge)** by AmitRajput-Dev — the model for what a native desktop bridge should be, and the project that proved macOS RFCOMM control was possible at all
- **[OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30)** by Oppzippy — the reference Soundcore implementation; its capability-driven device model shaped the profile layer here
- **[SoundcoreManager](https://github.com/gmallios/SoundcoreManager)** by gmallios — earlier desktop Soundcore client and protocol reference

## ⚠️ Disclaimer

Unofficial project, not affiliated with Anker or Soundcore. Firmware-update
channels are deliberately blocked, but this talks to your headphones over an
undocumented protocol — no warranty.

## 📄 License

[MIT](LICENSE)

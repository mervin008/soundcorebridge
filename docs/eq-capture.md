# Space 2 full EQ capture — 2026-09-13

Source: Soundcore Android app (`com.oceanwing.soundcore`) controlling a paired
Space 2 (D1402). Each preset was selected once, then the host-to-headset
`03:87` frame was extracted from Android's Bluetooth HCI trace.

Band order: **100, 200, 400, 800 Hz, 1.6, 3.2, 6.4, 12.8 kHz**. `0x78` is 0 dB;
one dB is 10 units. This is the data used by `Control.swift` and the menu-bar
EQ editor.

| Preset | ID | Eight band bytes |
|---|---:|---|
| soundcore Signature | `0000` | `78 78 78 78 78 78 78 78` |
| Acoustic | `0100` | `A0 82 8C 8C A0 A0 A0 8C` |
| Bass Booster | `7E7E` | `A0 96 82 78 78 78 78 78` |
| Bass Reducer | `0300` | `50 5A 6E 78 78 78 78 78` |
| Classical | `0400` | `96 96 64 64 78 8C 96 A0` |
| Podcast | `0500` | `5A 8C A0 A0 96 8C 78 64` |
| Dance | `0600` | `8C 5A 6E 82 8C 8C 82 5A` |
| Deep | `0700` | `8C 82 96 96 8C 64 50 46` |
| Electronic | `0800` | `96 8C 64 8C 82 8C 96 96` |
| Flat | `0900` | `64 64 6E 78 78 78 64 64` |
| Hip-Hop | `0A00` | `8C 96 6E 6E 8C 6E 8C 96` |
| Jazz | `0B00` | `8C 8C 64 64 78 8C 96 A0` |
| Latin | `0C00` | `78 78 64 64 64 78 96 AA` |
| Lounge | `0D00` | `6E 8C A0 96 78 64 8C 82` |
| Piano | `0E00` | `78 96 96 8C A0 AA 96 A0` |
| Pop | `0F00` | `6E 82 96 96 82 6E 64 5A` |
| R&B | `1000` | `B4 8C 64 64 8C 96 96 A0` |
| Rock | `1100` | `96 8C 6E 6E 82 96 A0 AA` |
| Small Speakers | `1200` | `A0 96 82 78 64 5A 50 50` |
| Spoken Word | `1300` | `5A 64 82 8C 8C 82 78 5A` |
| Treble Booster | `1400` | `64 64 64 6E 82 8C 8C A0` |
| Treble Reducer | `1500` | `78 78 78 64 5A 50 50 3C` |

## Custom EQ

The app uses **`FEFE`** for Custom EQ. This is distinct from Bass Booster's
`7E7E`. A neutral custom curve was captured as a 53-byte `03:87` payload and is
the separate `eqCustomTemplate` in `Control.swift`; Space2Bar changes only its
eight user bands. The menu editor sends a change when a slider is released.

## Sound effects boundary

The capture observed `02:86 payload 01` while interacting with Sound Effects.
That does not prove its function or an `off` representation, so 3D Sound and
HearID controls remain deliberately unimplemented. They require a labelled,
one-setting-at-a-time capture before they can be added safely.

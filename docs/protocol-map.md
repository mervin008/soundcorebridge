# Soundcore Space 2 (D1402) — protocol map

Channel 30, UUID `0cf12d31-fac3-4553-bd80-d6832e7d1402`.
Framing verified in `space2ctl selftest`; all findings below reproduced live.

## Command addressing

Two bytes: `[category, code]`. Not a flat 16-bit command word.
Codes `00–7F` are reads; `80–FF` are writes (LDAC read `01:7F` / write `01:FF`).

## Reads that return data

| Command | Bytes | Meaning |
|---|---|---|
| `01:01` | 103 | Full state blob (see below) |
| `01:03` | 1 | Battery level, 0–9 (see byte[0]) |
| `01:04` | 1 | Battery charging flag |
| `01:7F` | 1 | LDAC enabled (`00` = off) |
| `02:01` | 20 | EQ: `[preset, 00, b1..b8, …]` |
| `02:06` | 1 | unknown |
| `05:01` | 166 | Large config blob, unmapped |
| `05:02` | 64 | Unmapped |
| `06:01` | 6 | Sound mode block = state bytes[71..76] |
| `06:02` | 1 | `07` = state byte[69] |
| `0B:01` | 42 | Paired device entry (ASCII name embedded) |
| `0B:02` | 42 | Paired device entry |
| `0B:07` | 1 | unknown |

Every other code in categories `01`–`0B` echoes back with an empty payload.

## The 103-byte state blob (`01:01`)

| Offset | Field | Confirmed by |
|---|---|---|
| 0 | Battery level **0–9**; percent = `(level+1)*10` | matches `01:03`; level 5 = 60% per macOS and the app |
| 2–6 | ASCII firmware `01.59` | — |
| 7–10 | ASCII model `1402` | — |
| 11–22 | ASCII own MAC `AABBCCDDEEFF` | — |
| **23** | **EQ preset ID** | Acoustic `01` → Rock `0F` |
| **25–32** | **EQ, 8 bands** | whole block moved on preset change |
| 69 | `07` | matches `06:02` |
| 70 | Number of ANC levels supported (constant `05`) | never changes |
| **71** | **ANC mode** | see table |
| **72** | **ANC level in the high nibble** (`5F`=5, `1F`=1) | set 3 → reads back 3 |
| 73–76 | `FF 00 00 01` | rest of the `06:01` block |
| 91 | Connected host count | `01` Mac only → `02` Mac + phone |

### ANC mode (byte 71)

| Value | Mode |
|---|---|
| `00` | Noise Cancelling |
| `01` | Transparency |
| `02` | Normal |

### EQ encoding (bytes 25–32)

Centred on `0x78` (120) = 0 dB, 10 units per dB, so `value = 120 + dB × 10`.

| Preset | Bytes |
|---|---|
| Acoustic (`01`) | `A0 82 8C 8C A0 A0 A0 8C` |
| Rock (`0F`) | `6E 82 96 96 82 6E 64 5A` |

`A0` = +4.0 dB, `5A` = −3.0 dB. Range consistent with the app's ±6 dB.

## Writes — solved

Writes are silently discarded until the client performs the handshake the
official app performs on connect. Sequence, taken verbatim from an Android HCI
capture:

```
01:01                    device info
05:01  payload 01        capability table (returns ~600 bytes across 4 frames)
05:81  (no payload)  x2
05:81  payload 01
05:81  (no payload)
18:85  payload 01
```

After that the device acks and applies writes.

### Sound mode — `06:81`

Payload: `[mode, level, 02, 00, 00, 01]`

| Byte | Meaning |
|---|---|
| 0 | `00` NC, `01` Transparency, `02` Normal |
| 1 | ANC intensity in the high nibble: `5F`=5 … `1F`=1 |
| 2 | **`02` on writes** — note the matching read returns `FF` here |

Echoing the read value back into byte 2 is silently ignored. This cost hours.

### Equaliser — `03:87`

53-byte payload. The complete verified preset table is in
[`2026-09-13-android-eq-capture.md`](2026-09-13-android-eq-capture.md).

| Offset | Field |
|---|---|
| 0–1 | Preset ID: `0000` Signature, `0100` Acoustic, `0300` Bass Reducer, `7E7E` Bass Booster, `FEFE` Custom EQ |
| 2–3 | Zero |
| 4–12 | Nine band values; the 9th is always `0x78` |
| 13–41 | App-managed block; capture it rather than assuming it is identical between presets |
| 42–50 | Personalised (HearID) curve; `0x78` throughout is neutral |
| 51–52 | Trailing zeros |

Band encoding is the same as the read side: `value = 120 + dB × 10`.

Also observed but not yet mapped: `02:86 payload 01`. It accompanies Sound
Effects UI activity, but the capture does not establish whether it toggles 3D
Sound or simply applies a setting, so Space2Bar intentionally does not send it.

## Quirks of the official app

The Soundcore Android app **does not trust the device for the ANC level**. On
reconnect it issues `06:01`, the headset answers with the true level, and the app
displays its own cached last-set value instead. Verified end to end:

```
Mac sets level 4  ->  device state byte[72] = 4F
phone reconnects  ->  app reads 06:01 -> 00 4F FF 00 00 01   (device: level 4)
                  ->  app displays level 2                    (its own last write)
```

So a level set from another host looks "wrong" in the app even though the
headset is correct. Levels set from this tool do persist across disconnects.

Confirmed by a labelled capture that the level nibble is not inverted:
app "1 (Min)" sends `00 1F ...`, app "5 (Max)" sends `00 5F ...` — identical to
what `space2ctl anc nc --level N` sends.

## Operational notes

- Only **one control client** at a time. The iPhone holds the slot even with the
  app force-closed; only turning the phone's Bluetooth off releases it.
- The first `openRFCOMMChannelAsync` in a process always fails — retry.
- Never close a failed attempt's channel; the close lands async and kills the
  next one.
- `01:01` intermittently answers with a bare ack instead of the blob. Re-ask.

## Liberty 5 (A3957): listening modes

The local Liberty 5 implementation was verified against firmware 03.90 on
macOS 26.6.2. The device advertises its vendor control service on RFCOMM
channel 15. A `01:01` response contains a 154-byte state payload.

- Identity: ASCII model at offsets 16...19, left firmware at 6...10.
- Sound-mode block: state offsets 119...125, exactly seven bytes.
- Mode byte: `00` Noise Cancelling, `01` Transparency, `02` Normal.
- Set command: `06:81` with the seven-byte sound-mode block as its payload.

Read the full current state immediately before encoding a mode change. Replace
only the first sound-mode byte and preserve the other six bytes, which include
strength and additional sound settings. A3957 does not receive the Space 2
handshake or six-byte Space 2 sound-mode payload. Request state again after the
write and require the mode and all preserved bytes to match.

The packet shape was cross-checked against OpenSCQ30's A3957 implementation;
all three modes were then confirmed by this physical device, with the original
settings restored. ANC-strength controls remain disabled for A3957; EQ is
implemented separately below.

The explicit `anc-cycle-test` CLI mode saves the original block before the
first write, exercises all three modes, then restores and verifies it. It writes
`build/liberty5-anc-test.json`, or a new path passed with `--out`. Quit the
menu-bar app before running that test so it releases the control connection.

## Liberty 5 (A3957): equalizer / HearID preservation

Verified on the same physical A3957, firmware 03.90, macOS 26.6.2.
Protocol reference: OpenSCQ30 upstream revision `0dc9b2b0`,
`lib/src/devices/soundcore/a3957/packets/{inbound/state_update.rs,outbound.rs}`
and `common/modules/equalizer.rs` (`common_settings_type_2`). The Swift encoder
is model-specific; it does not reuse Space 2's 53-byte payload or DSP matrix.

State offsets (zero-based, in the 154-byte `01:01` payload):

| Offsets | Meaning |
|---|---|
| 1 | Both earbuds connected (TWS) |
| 38...39 | Preset ID, UInt16 little-endian |
| 40...49 / 50...59 | Left / right ten-band EQ curves |
| 61 | HearID enabled |
| 62...81 | Initial HearID calibration, ten bands per channel |
| 82...85 | HearID timestamp, big-endian; preserved verbatim |
| 86 | HearID type (0 initial, 1 custom, 2 genre) |
| 87...106 | Custom HearID calibration, ten bands per channel |
| 107...108 | HearID favorite genre, little-endian; preserved verbatim |
| 136 | Dolby/immersive audio; do not change EQ while enabled |

`03:87` has a **114-byte** A3957 body:

| Offsets | Contents |
|---|---|
| 0...1 | Preset ID |
| 2...3 | Saved favorite genre |
| 4...23 | Two ten-band EQ curves |
| 24...25 | Zero |
| 26...71 | Saved state[61...106] (HearID enabled, initial curves, time, type, custom curves) |
| 72...111 | Active 20 curve bytes, each followed by zero |
| 112...113 | Zero |

Preset IDs are ordinal 0...21, notably Bass Booster **0002**, not Space 2's
7E7E. Custom is FEFE. Visible bands are 100 / 200 / 400 / 800 / 1600 / 3200 /
6400 / 12800 Hz, encoded as `120 + 10*dB`. Factory curves use hidden-band bytes
`[120, 0]`; custom curves use `[120, 120]`. Selecting EQ disables HearID and
retains every other calibration byte. Active bytes come from the selected EQ
when HearID is disabled, or the initial/custom HearID curves when restoring an
enabled initial/custom HearID snapshot. Genre-adjusted HearID is not synthesized.

Both earbuds must be connected. Reject unknown models, incomplete metadata,
invalid IDs/curves, enabled spatial audio, and enabled genre-based HearID before
writing. Read fresh state on the Bluetooth worker thread immediately before
each write, then require checksum-valid device readback before reporting success.

Firmware 03.90 reports the right curve as ten FF bytes even with both earbuds
connected. Writes include both curves; verification checks every available
channel and never treats FF as a gain value. The right channel's application
and audible output have not been independently verified. Exact restoration
also checks the original FF sentinels and original hidden bands (which can
differ from a freshly selected factory preset).

`eq-cycle-test --all-presets` verified all 22 presets plus custom EQ, preserved
HearID calibration and listening mode, then restored the exact original EQ/HearID.
Its recovery snapshot is saved before the first write. `eq-restore --from file`
can restore after interruption, rejecting mismatched model/firmware or a changed
HearID calibration. Keep these ignored local snapshots private. Unit fixtures
contain synthetic calibration only. Enabled HearID restoration has offline
coverage, not a live-hardware claim.

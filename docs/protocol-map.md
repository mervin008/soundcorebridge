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
| 11–22 | ASCII own MAC `849D4BB0798F` | — |
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

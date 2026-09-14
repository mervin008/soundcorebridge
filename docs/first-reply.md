# First successful reply — Space 2 (D1402), channel 30

Request `01:01` (device info):
```
08 EE 00 00 00 01 01 0A 00 02
```

Reply, 113 bytes total, 103-byte payload, checksum valid:
```
09 FF 00 00 01 01 01 71 00 05 00 30 31 2E 35 39 31 34 30 32 38 34 39 44 34 42
42 30 37 39 38 46 01 00 A0 82 8C 8C A0 A0 A0 8C 00 00 1E FF 00 FF FF FF FF FF
FF FF FF 00 00 00 00 00 00 00 FF FF FF FF FF FF FF FF 00 00 00 00 06 04 07 FF
07 05 00 5F FF 00 00 01 32 00 00 00 01 01 00 01 01 00 00 5A 00 00 01 00 01 00
00 00 00 FF FF FF FF FF C0
```

Payload, annotated so far:

| Offset | Bytes | Meaning |
|---|---|---|
| 0x02–0x06 | `30 31 2E 35 39` | ASCII `01.59` — firmware version |
| 0x07–0x0A | `31 34 30 32` | ASCII `1402` — model (D1402) |
| 0x0B–0x16 | `38 34 39 44 34 42 42 30 37 39 38 46` | ASCII `849D4BB0798F` — own MAC |
| 0x19–0x20 | `A0 82 8C 8C A0 A0 A0 8C` | 8 bytes, plausible EQ band values |
| rest | — | unmapped |

The 8-byte run at 0x19 is the strongest EQ candidate: eight values in a narrow
band around 0x8C-0xA0, matching an 8-band equaliser. Confirm by moving one
slider in the app and diffing with `space2ctl watch`.

# SoundcoreBridge — Developer Instructions & Workspace Guide

Welcome to the `soundcorectl` / `SoundcoreBridge` codebase. This document serves as the primary technical reference and architectural mandate for all AI and human developers working on this project. Always consult this guide before implementing new features, modifying the protocol engine, or changing the menu-bar interface.

---

## 1. Project Overview & Architecture

`SoundcoreBridge` provides native macOS menu-bar and command-line control for Soundcore headsets (initial target: **Soundcore Space 2 / D1402**, designed to be multi-model extensible). It communicates directly with the headset over a local vendor RFCOMM Bluetooth channel. No companion mobile apps, cloud APIs, or audio proxies are involved.

### Tech Stack
- **Languages**: Swift 6.0 (configured with Swift 5 language mode in `Package.swift`)
- **Frameworks**: SwiftUI (App/UI), IOBluetooth (Core Bluetooth / RFCOMM transport)
- **Target OS**: macOS 13.0+ (requires Bluetooth permissions)

### Directory Structure & Code Responsibilities
The project is split into a command-line interface (`soundcorectl`, alias `space2ctl`) and a windowed/menu-bar application (`SoundcoreBridge.app`). Both share the same underlying Swift codebase.

- **`Sources/soundcorectl/main.swift`**
  - CLI entry point. Parses command-line arguments using `Args`.
  - Automatically detects launch context: if launched inside a `.app` bundle, it switches to the SwiftUI menu-bar app (`SoundcoreBridgeApp.main()`).
- **`Sources/soundcorectl/Frame.swift`**
  - Defines `Command` (group and code) and `Packet` types.
  - Handles the custom Soundcore frame structure: header, length, direction, payload, and 8-bit checksum.
  - Implements `FrameParser` to reassemble split frames and resynchronize past leading stream noise or corrupt bytes.
- **`Sources/soundcorectl/Control.swift`**
  - Contains command payloads, ANC modes (`ANCMode`), and the 53-byte equalizer templates.
  - Implements profile-gated command encoders and the verified Space 2 handshake.
  - Contains exact verified payloads for all 22 factory EQ presets and custom EQ calculation using solved Constant-Q DSP compensation matrices.
- **`Sources/soundcorectl/RFCOMM.swift`**
  - Low-level wrapper for macOS `IOBluetoothDevice` and `IOBluetoothRFCOMMChannel`.
  - Manages asynchronous RFCOMM channel opening, retries, write confirmation, and thread run-loop polling.
  - Enforces the hard-blocking of risky firmware flashing channels.
- **`Sources/soundcorectl/MenuBar.swift`**
  - The modern macOS Control Center SwiftUI presentation layer.
  - Features real-time Bézier EQ frequency curve visualization (`EQCurveView`), dynamic device badge, and battery indicators.
  - Integrates the `DeviceController` background thread with reactive UI components using `SoundcoreBridgeAppDelegate` for safe Bluetooth initialization.
  - Hides controls that are not enabled by the resolved device profile.
- **`Sources/soundcorectl/DeviceProfile.swift`**
  - Defines verified model identities, readable state fields, capabilities, and the control-protocol family.
  - Keeps unidentified devices read-only; a Bluetooth display name alone never enables writes.
- **`Sources/soundcorectl/SelfTest.swift`**
  - Diagnostic suite. Runs mock encodings, parser tests, packet reassembly verifications, and preset integrity tests without requiring a real Bluetooth device connected.
- **`Sources/soundcorectl/Util.swift`**
  - Diagnostic output helpers (hexdump, hex formatter), argument parsing structure, and thread run-loop pumping utilities.

---

## 2. Technical Protocol & Commands Map

Soundcore commands are addressed using a two-byte structure: `[category, code]`.
- Reads are typically codes `00–7F`.
- Writes are typically codes `80–FF` (with the high bit set).

### The Handshake Requirement
The Space 2 ignores write commands such as ANC and EQ changes until its verified
handshake is completed. SoundcoreBridge first requests state using `01:01`,
checks the model code reported by the device, and only then selects a profile's
handshake. Unknown devices stay read-only and never receive this sequence.

The Space 2 sequence is:
1. Send `01:01` (device info)
2. Send `05:01` with payload `[01]` (capability table query)
3. Send `05:81` with no payload
4. Send `05:81` with no payload
5. Send `05:81` with payload `[01]`
6. Send `05:81` with no payload
7. Send `18:85` with payload `[01]`
8. Send `02:86` with payload `[01]`

### Read Commands (`01:01` State Blob Layout)
Querying `01:01` returns a 103-byte payload containing the complete state of the headset:

| Offset | Size | Meaning / Value Mapping |
|---|---|---|
| `0` | 1 | Battery level: `0` to `9`. Percent is calculated as `(level + 1) * 10`. |
| `2–6` | 5 | ASCII firmware version (e.g., `"01.59"`). |
| `7–10` | 4 | ASCII model number (e.g., `"1402"`). |
| `11–22` | 12 | ASCII own MAC address (e.g., `"AABBCCDDEEFF"`). |
| `23` | 1 | Active EQ preset ID (`01` = Acoustic, `03` = Bass Reducer, etc.). |
| `25–32` | 8 | EQ band bytes (8 bands, see EQ encoding). |
| `69` | 1 | Status indicator (constant `07`). |
| `70` | 1 | Maximum ANC levels supported (constant `05`). |
| `71` | 1 | **ANC Mode**: `00` = Noise Cancelling, `01` = Transparency, `02` = Normal. |
| `72` | 1 | **ANC Level**: Encoded in high nibble (`5F` = Level 5, `1F` = Level 1). |
| `73–76` | 4 | Sound mode trailers (`FF 00 00 01`). |
| `91` | 1 | Connected host count (`01` = Single device, `02` = Multipoint). |

### Write Commands
- **ANC / Sound Mode (`06:81`)**:
  - Payload: `[mode, level, 02, 00, 00, 01]`
  - Byte 0: `00` NC, `01` Transparency, `02` Normal.
  - Byte 1: High nibble level `(level << 4) | 0x0F` (Level 1–5).
  - Byte 2: Must be **`02`** for a write to succeed (note: matching read returns `FF`).
- **Equaliser Settings (`03:87`)**:
  - Payload size: **53 bytes**.
  - Layout: `[0:2]` Preset ID, `[2:4]` Zeros, `[4:12]` Nine band values, `[13]` Flags (`00` factory / `78` custom), `[14:42]` Fixed layout block, `[42:51]` **DSP filter compensation / pre-gain tail curve**, `[51:53]` Trailing zeros.
  - **CRITICAL HARDWARE FINDING**: Bytes 42..50 are NOT HearID curves. They are the active DSP filter compensation & pre-gain coefficients for the headset's internal audio processor. If wiped or set to neutral (`0x78`), the DSP audio filter is bypassed, producing no perceptible change in tone or volume.
  - **EQ Band Encoding**: Centered on `120` (`0x78`) = 0 dB. Scale is 10 units per dB.
    - Formula: `value = 120 + dB * 10`.
    - Range: `−6 dB` (`0x3C`/`60`) to `+6 dB` (`0xB4`/`180`).
    - The 9th band (offset 12) is always `0x78` (neutral).
    - Custom EQ preset ID: `FEFE`. Uses `calculateEQTail(bands:)` for DSP cross-talk compensation.

---

## 3. Safety Boundaries (DO NOT BYPASS)

The Space 2 implements highly sensitive OTA channels that pose a bricking risk if written to or analyzed unsafely.
- **Identify before writing**: Ordinary app and CLI controls must resolve the model code from a valid state response before running a handshake or encoding a write. Bluetooth names are discovery hints only.
- **Capability gate every write**: UI visibility is not a security boundary. All write encoders must reject profiles that lack the corresponding verified feature.
- **Blocked Channels**: RFCOMM channels **12** (TOTA) and **13** (BESOTA) are hard-blocked in `RFCOMM.swift` to prevent accidental firmware corruption. Do not remove this restriction.
- **Apple iAP2 channel**: RFCOMM channel **16** (IOSSPP) is blocked as it is incompatible with our raw frame protocol.
- **One Control Client Limit**: The headset accepts only one active RFCOMM control connection at a time. If the companion mobile app is open or holding the session, SoundcoreBridge will fail to bind. Releasing the socket on the other host (e.g., turning off Bluetooth on the phone) is required.

---

## 4. Development & Verification Workflows

### 1. Verification & Testing
Before making or committing any changes, run the offline self-test tool to verify structural frame serialization, packet reassembly, checksum formulas, EQ mapping logic, and the profile write boundary:
```bash
swift build
swift run soundcorectl selftest
```

### 2. Live Probing & Analysis
If investigating protocol behavior or testing connection quality, use the CLI diagnostic commands:
- **List Paired & SDP Records**: `swift run soundcorectl sdp`
- **One-Shot State Probe**: `swift run soundcorectl probe --cmd 01:01`
- **Apply Preset**: `swift run soundcorectl eq "Acoustic"`
- **Apply Custom EQ**: `swift run soundcorectl eq "4,1,2,2,4,4,4,2"`
- **State Polling and Live Diffs**: `swift run soundcorectl watch --interval 500`
- **Safe Command Sweep**: `swift run soundcorectl sweep --groups 01,02,06`

### 3. Packaging & Installation
To build the native macOS menu bar app (`SoundcoreBridge.app`):
```bash
./make-app.sh
```
The script compiles the release binary, creates `build/SoundcoreBridge.app`, embeds the `Info.plist` (`LSUIElement = true`), and code-signs the bundle.

To run the packaged app:
```bash
open build/SoundcoreBridge.app
```

### 4. Reading Runtime Logs
Diagnostics and Bluetooth lifecycle logs for the menu bar application are written directly to:
```bash
tail -f /tmp/soundcorebridge.log
```

---

## 5. Coding Style & Conventions

### Asynchronous Bluetooth Handling
- **Constraint**: `IOBluetooth` delegates deliver callbacks strictly onto the **run loop** of the thread that initiated the channel opening. Standard Swift `Task` blocks or GCD dispatch queues will not receive callbacks unless that specific thread's run loop is pumped.
- **App Lifecycle**: Always prime `IOBluetoothDevice.pairedDevices()` on the main thread inside `NSApplicationDelegate.applicationDidFinishLaunching(_:)` before spawning background worker threads, preventing deadlocks with macOS `tccd`.
- **Implementation**: We use the blocking run-loop helper `pump(seconds:until:)` inside our controller thread to cleanly process delegate callbacks while keeping the UI responsive.

### RFCOMM Socket Cleanup
- **SPP Slot Exhaustion**: If an RFCOMM channel is abandoned or leaked, the headset's limited SPP slots become exhausted. When this happens, the headset will accept new connections and immediately drop them until it is manually power-cycled.
- **Handling**: Always retain references to all opened channels inside `RFCOMMLink`'s `allChannels` registry, and ensure they are sequentially closed via `close()` on deinit, termination, or failure.

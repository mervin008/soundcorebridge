import Foundation
import IOBluetooth
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: probes are watched live

let usage = """
soundcorectl (SoundcoreBridge) — Soundcore control probe & CLI

USAGE
  soundcorectl <mode> [options]
  space2ctl <mode> [options]

MODES
  selftest               Verify the codec against known-good packets (no headset)
  sdp                    List paired devices and dump SDP service records
  probe                  Open the control channel, send device-info, dump replies
  sweep                  Read-only command sweep: find which commands answer
  watch                  Poll state and print byte-level diffs
  send <cmd> [payload]   Send one packet, e.g. `send 01:01`
  anc <mode> [--level n] Set ANC: nc | transparency | normal  (level 1-5 for nc)
  eq <preset|dB list>    Set EQ: flat|acoustic|bassbooster, or "6,4,2,0,0,-2,-4,-6"
  snap --label <name>    One-shot state read, saved for diffing (releases channel)
  diffs                  Show byte diffs between consecutive snapshots
  gatt                   Scan BLE / dump GATT services

OPTIONS
  --device <addr>        Bluetooth address (default: first paired Soundcore)
  --channel <n>          RFCOMM channel (default: safe auto-detection; allowlist \(defaultControlChannels))
  --duration <s>         probe: seconds to listen (default 8)
  --groups <hex,…>       sweep: command groups to scan (default 01)
  --timeout <ms>         sweep: wait per command (default 250)
  --interval <ms>        watch: poll interval (default 700)
  --cmd <gg:cc>          probe/watch/send: command word (default 01:01)
  --allow-writes         Permit commands with the high bit set (mutating)
  --any-channel          Bypass the channel allowlist (OTA channels stay blocked)
  --raw                  Also print raw stream chunks before reassembly

SAFETY
  Space 2 channels 12 (TOTA) and 13 (BESOTA) flash firmware and are hard-blocked.
"""

// Launched as a .app bundle with no arguments -> run the menu bar app.
if CommandLine.arguments.count == 1,
   CommandLine.arguments[0].contains(".app/Contents/MacOS/") {
    runMenuBar()
}

let args = Args(CommandLine.arguments)
let requestedChannel = args.str("channel").flatMap { UInt8($0) }
var channel = requestedChannel ?? defaultControlChannels[0]
let allowWrites = args.bool("allow-writes")
let showRaw = args.bool("raw")
var collected: [Packet] = []
var connectedDeviceName = ""

/// Ctrl-C must still tear the channels down — see RFCOMMLink.close().
var activeLink: RFCOMMLink?
signal(SIGINT) { _ in
    activeLink?.close()
    exit(130)
}

func connect() throws -> RFCOMMLink {
    let device = try RFCOMMLink.find(address: args.str("device"))
    connectedDeviceName = device.name ?? ""
    log("device   \(device.name ?? "?")  [\(device.addressString ?? "?")]")
    let link: RFCOMMLink
    if let requestedChannel {
        channel = requestedChannel
        link = RFCOMMLink(device: device)
        link.anyChannel = args.bool("any-channel")
        link.verbose = args.bool("verbose")
        try link.open(channelID: channel)
    } else {
        let preferred = DeviceRegistry.profile(bluetoothName: connectedDeviceName)?.rfcommChannels ?? []
        let opened = try RFCOMMLink.openControl(device: device,
                                                preferred: preferred,
                                                verbose: args.bool("verbose"))
        link = opened.link
        channel = opened.channel
    }
    log("channel  \(channel)")
    link.onPacket = { p in
        collected.append(p)
        log(describe(p))
    }
    if showRaw { link.onRaw = { log("   raw <- \(hex($0))") } }
    activeLink = link
    log("channel open  MTU=\(link.mtu)\n")
    return link
}

/// Identify a device using only the read-only state request. All ordinary CLI
/// control paths call this before selecting a profile-specific write handshake.
func identify(_ link: RFCOMMLink) throws -> (DeviceProfile, DeviceState) {
    var result: (DeviceProfile, DeviceState)?
    let previousHandler = link.onPacket
    link.onPacket = { packet in
        previousHandler?(packet)
        guard packet.cmd == Command(0x01, 0x01), packet.checksumOK else { return }
        let profile = DeviceRegistry.resolve(state: packet.payload, bluetoothName: connectedDeviceName)
        if let state = parseState(packet.payload, profile: profile) {
            result = (profile, state)
        }
    }
    for _ in 0..<5 {
        try? link.send(Command(0x01, 0x01))
        pump(1.2) { result != nil }
        if result != nil { break }
    }
    guard let result else { throw ProbeError("no valid device state returned") }
    return result
}

func modeSDP() throws {
    if args.str("device") == nil {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        log("paired devices (\(paired.count)):")
        for d in paired {
            let rf = ((d.services as? [IOBluetoothSDPServiceRecord]) ?? []).compactMap { r -> UInt8? in
                var c: BluetoothRFCOMMChannelID = 0
                return r.getRFCOMMChannelID(&c) == kIOReturnSuccess ? c : nil
            }
            log(String(format: "  %-24@ %-20@ connected=%@  rfcomm channels: %@",
                       (d.name ?? "(unnamed)") as NSString,
                       (d.addressString ?? "?") as NSString,
                       (d.isConnected() ? "yes" : "no") as NSString,
                       (rf.isEmpty ? "(none cached)" : rf.sorted().map(String.init).joined(separator: ", ")) as NSString))
        }
        log("")
    }
    let device = try RFCOMMLink.find(address: args.str("device"))
    log("=== \(device.name ?? "?")  [\(device.addressString ?? "?")]  connected=\(device.isConnected())")
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    let profileChannels = DeviceRegistry.profile(bluetoothName: device.name ?? "")?.rfcommChannels ?? []
    guard !records.isEmpty else {
        log("no cached SDP records — connect the headset once, then retry")
        return
    }
    for r in records {
        var ch: BluetoothRFCOMMChannelID = 0
        let hasRF = r.getRFCOMMChannelID(&ch) == kIOReturnSuccess
        var note = ""
        if hasRF, let why = blockedChannel(ch, device: device) { note = "  << BLOCKED: \(why)" }
        else if hasRF, allowedChannels.contains(ch) || profileChannels.contains(ch) {
            note = "  << candidate control channel"
        }
        var classes = "?"
        if let attrs = r.attributes as? [NSNumber: IOBluetoothSDPDataElement],
           let list = attrs[NSNumber(value: 1)] {
            classes = list.description.replacingOccurrences(of: "\n", with: " ")
                                      .replacingOccurrences(of: "  ", with: " ")
        }
        log(String(format: "  ch %-4@ %-22@ %@%@",
                   hasRF ? String(ch) as NSString : "-" as NSString,
                   (r.getServiceName() ?? "(unnamed)") as NSString,
                   classes.prefix(120) as NSString, note as NSString))
    }
}

func modeProbe() throws {
    let link = try connect()
    defer { link.close() }
    if args.bool("handshake") {
        let (profile, _) = try identify(link)
        log("handshake …")
        try handshake(link, profile: profile)
    }
    let cmd = Command(args.str("cmd") ?? "01:01") ?? Command(0x01, 0x01)
    let payload = args.str("payload").flatMap { parseHex($0) } ?? []
    let packet = Frame.encode(cmd, payload: payload)
    log("-> \(cmd)  \(hex(packet))")
    try link.send(packet)
    let seconds = Double(args.int("duration", 8))
    log("listening \(Int(seconds))s …\n")
    pump(seconds)

    log("\n--- result ---")
    if collected.isEmpty {
        log("NO REPLY on channel \(channel). Try --channel 17, or a different --cmd.")
    } else {
        log("\(collected.count) packet(s) decoded on channel \(channel).")
        let bad = collected.filter { !$0.checksumOK }.count
        log(bad == 0 ? "all checksums valid — framing confirmed on this model"
                     : "\(bad) checksum failure(s) — framing may differ here")
    }
    link.close()
}

func modeSweep() throws {
    let link = try connect()
    defer { link.close() }
    let groups: [UInt8] = (args.str("groups") ?? "01")
        .split(separator: ",")
        .compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
    let waitSec = Double(args.int("timeout", 250)) / 1000
    let maxCode: UInt8 = allowWrites ? 0xFF : 0x7F
    let from: UInt8 = args.str("from").flatMap { UInt8($0, radix: 16) } ?? 0x00
    // An "identity" payload — the values the device already holds — makes a
    // write-range sweep a no-op whichever command turns out to be the setter.
    let sweepPayload = args.str("payload").flatMap { parseHex($0) } ?? []
    if !sweepPayload.isEmpty { log("payload: \(hex(sweepPayload))") }
    if !allowWrites { log("sweeping read-only codes 00–7F (--allow-writes adds 80–FF)\n") }

    var answered: [(Command, Packet)] = []
    for g in groups {
        for c in 0...maxCode {
            let cmd = Command(g, c)
            if c < from { if c == maxCode { break }; continue }
            collected.removeAll()
            do { try link.send(cmd, payload: sweepPayload) } catch { warn("\(cmd): \(error)"); continue }
            pump(waitSec) { !collected.isEmpty }
            if let reply = collected.first { answered.append((cmd, reply)) }
            if c == maxCode { break }
        }
    }

    log("\n--- commands that answered ---")
    if answered.isEmpty { log("(none)") }
    for (cmd, reply) in answered {
        log("\(cmd) -> \(reply.cmd)  \(reply.payload.count)B  \(hex(Array(reply.payload.prefix(16))))")
    }
    link.close()
}

func modeWatch() throws {
    let link = try connect()
    defer { link.close() }
    let cmd = Command(args.str("cmd") ?? "01:01") ?? Command(0x01, 0x01)
    let interval = Double(args.int("interval", 700)) / 1000
    var lastByCmd: [Command: [UInt8]] = [:]

    link.onPacket = { p in
        guard let previous = lastByCmd[p.cmd] else {
            lastByCmd[p.cmd] = p.payload
            log("\(stamp()) baseline \(p.cmd)  \(p.payload.count)B")
            log(hexdump(p.payload))
            return
        }
        guard previous != p.payload else { return }
        lastByCmd[p.cmd] = p.payload
        log("\(stamp()) CHANGED \(p.cmd)")
        for line in diff(previous, p.payload) { log(line) }
    }

    log("""
    Polling \(cmd) every \(Int(interval * 1000))ms. Change ONE setting in the
    Soundcore app on your phone and watch which byte moves. Ctrl-C to stop.

    """)
    while true {
        do { try link.send(cmd) } catch { warn("\(error)"); break }
        pump(interval)
    }
    link.close()
}

func modeSend() throws {
    guard let raw = args.pos(0) ?? args.str("cmd"), let cmd = Command(raw) else {
        throw ProbeError("expected a command word, e.g. `send 01:01`")
    }
    let payload = args.pos(1).flatMap { parseHex($0) } ?? args.str("payload").flatMap { parseHex($0) } ?? []
    if cmd.isWrite && !allowWrites {
        throw ProbeError("\(cmd) looks like a write (code high bit set). Re-run with --allow-writes if you mean it.")
    }
    let link = try connect()
    let packet = Frame.encode(cmd, payload: payload)
    log("-> \(cmd)  \(hex(packet))")
    try link.send(packet)
    pump(Double(args.int("duration", 3)))
    link.close()
}


/// One-shot read: grab the channel, read state, release it immediately so the
/// phone app can reconnect. The Space 2 permits only one control client, so
/// live watching and using the app are mutually exclusive.
func modeSnap() throws {
    let label = args.str("label") ?? "snap"
    let link = try connect()
    defer { link.close() }

    var state: [UInt8]?
    link.onPacket = { p in
        if p.cmd == Command(0x01, 0x01), p.checksumOK, p.payload.count > 16, state == nil { state = p.payload }
    }
    // The device intermittently answers 01:01 with a bare ack instead of the
    // state blob; just ask again until it volunteers the real thing.
    for _ in 0..<6 {
        try? link.send(Command(0x01, 0x01))
        pump(2) { state != nil }
        if state != nil { break }
    }

    // open() sends its own 01:01 liveness probe, whose reply lands before this
    // handler is installed — fall back to whatever connect() already collected.
    if state == nil {
        state = collected.last(where: { $0.cmd == Command(0x01, 0x01) && $0.checksumOK && $0.payload.count > 16 })?.payload
    }
    guard let state else { throw ProbeError("no reply — headset may be busy with the app") }

    let dir = "captures"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/snapshots.tsv"
    let line = "\(label)\t\(hex(state, separator: ""))\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
    log("saved snapshot '\(label)' (\(state.count) bytes) -> \(path)")

    // Diff against the previous snapshot, if any.
    if let all = try? String(contentsOfFile: path, encoding: .utf8) {
        let rows = all.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
        if rows.count >= 2, rows[rows.count - 2].count == 2,
           let prev = parseHex(rows[rows.count - 2][1]) {
            let prevLabel = rows[rows.count - 2][0]
            log("\nvs '\(prevLabel)':")
            let d = diff(prev, state)
            if d.isEmpty { log("  (no change)") } else { for l in d { log(l) } }
        }
    }
}

/// Print byte diffs between every consecutive pair of saved snapshots.
func modeDiffs() throws {
    let path = "captures/snapshots.tsv"
    guard let all = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw ProbeError("no snapshots yet — run `space2ctl snap --label <name>` first")
    }
    let rows = all.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
                  .filter { $0.count == 2 }
    guard rows.count >= 2 else { log("need at least two snapshots"); return }
    for i in 1..<rows.count {
        guard let a = parseHex(rows[i-1][1]), let b = parseHex(rows[i][1]) else { continue }
        log("\n\(rows[i-1][0])  ->  \(rows[i][0])")
        let d = diff(a, b)
        if d.isEmpty { log("  (no change)") } else { for l in d { log(l) } }
    }
}


func modeANC() throws {
    guard let arg = args.pos(0), let mode = ANCMode(arg) else {
        throw ProbeError("usage: space2ctl anc <nc|transparency|normal> [--level 1-5]")
    }
    let level = UInt8(clamping: args.int("level", 5))
    let link = try connect()
    defer { link.close() }

    let (profile, _) = try identify(link)
    log("handshake …")
    try handshake(link, profile: profile)

    let packet = try ancWrite(profile: profile, mode: mode, level: level)
    let payload = ancPayload(mode, level: level)
    log("-> 06:81  \(hex(payload))   (\(mode.label)\(mode == .noiseCancelling ? ", level \(level)" : ""))")
    try link.send(packet)
    pump(1.5)

    // Read it back.
    var confirmed: UInt8?
    link.onPacket = { p in
        if p.cmd == Command(0x06, 0x01), p.payload.count >= 1 { confirmed = p.payload[0] }
        if p.cmd == Command(0x01, 0x01), p.payload.count > 71 { confirmed = p.payload[71] }
    }
    for _ in 0..<4 {
        try? link.send(Command(0x06, 0x01))
        pump(1.0) { confirmed != nil }
        if confirmed != nil { break }
    }
    if let c = confirmed {
        let ok = c == mode.rawValue
        log(ok ? "confirmed: byte[71] = 0x\(String(format: "%02X", c)) — \(mode.label)"
               : "NOT applied: device reports 0x\(String(format: "%02X", c))")
    } else {
        log("(device did not report state back; listen with `probe`)")
    }
}


func modeEQ() throws {
    guard let arg = args.pos(0) else {
        throw ProbeError("usage: soundcorectl eq <flat|acoustic|bassbooster|rock|...> | eq \"6,4,2,0,0,-2,-4,-6\"")
    }

    let id: [UInt8]
    let bands: [UInt8]
    let normalized = arg.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    if let preset = eqPresets[normalized] {
        id = preset.id
        bands = preset.bands
    } else {
        let dB = arg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard dB.count == 8 else {
            throw ProbeError("need 8 comma-separated dB values (range -6 to +6), got \(dB.count)")
        }
        guard dB.allSatisfy({ $0 >= -6 && $0 <= 6 }) else {
            throw ProbeError("dB values must be between -6 and +6")
        }
        id = eqCustomID
        bands = dB.map { eqByte(dB: $0) }
    }

    let link = try connect()
    defer { link.close() }
    let (profile, _) = try identify(link)
    log("handshake …")
    try handshake(link, profile: profile)

    let packet = try eqWrite(profile: profile, id: id, bands: bands)
    log("-> 03:87  preset \(hex(id, separator: "")) bands \(hex(bands))")
    log("   (\(bands.map { String(format: "%+.1f", eqDecibels($0)) }.joined(separator: " ")) dB)")
    try link.send(packet)
    pump(1.5)

    var got: [UInt8]?
    link.onPacket = { p in
        if p.cmd == Command(0x01, 0x01), p.payload.count > 32 { got = Array(p.payload[25...32]) }
    }
    for _ in 0..<5 {
        try? link.send(Command(0x01, 0x01))
        pump(1.0) { got != nil }
        if got != nil { break }
    }
    if let got {
        log(got == bands ? "confirmed: device reports \(hex(got))"
                         : "MISMATCH: device reports \(hex(got)), expected \(hex(bands))")
    } else {
        log("(no state read back)")
    }
}


func modeStatus() throws {
    let link = try connect()
    defer { link.close() }
    var st: DeviceState?
    let (_, initialState) = try identify(link)
    st = initialState
    link.onPacket = { p in
        if p.cmd == Command(0x01, 0x01),
           let s = parseState(p.payload, profile: DeviceRegistry.resolve(state: p.payload, bluetoothName: "")) { st = s }
    }
    for _ in 0..<6 {
        try? link.send(Command(0x01, 0x01))
        pump(1.2) { st != nil }
        if st != nil { break }
    }
    guard let s = st else { throw ProbeError("no state returned") }
    log("""
        battery    \(batteryPercent(s.battery, max: s.batteryMax))%  (raw level \(s.battery)/\(s.batteryMax))
        firmware   \(s.firmware)
        ANC mode   \(s.ancMode.map { String(format: "0x%02X (%@)", $0, ANCMode(rawValue: $0)?.label ?? "?") } ?? "n/a")
        ANC level  \(s.ancLevel.map { "\($0)/5" } ?? "n/a")
        EQ preset  \(s.eqPreset.map { String(format: "0x%02X", $0) } ?? "n/a")
        EQ bands   \(hex(s.eqBands))
                   \(s.eqBands.map { String(format: "%+.1f", eqDecibels($0)) }.joined(separator: " ")) dB
        hosts      \(s.hostCount)
        """)
}


/// Reproduces exactly what the menu bar app does: one link, handshake once,
/// then multiple writes over the persistent channel.
func modeAppTest() throws {
    let link = try connect()
    defer { link.close() }
    var st: DeviceState?
    let (profile, initialState) = try identify(link)
    st = initialState
    link.onPacket = { p in
        if p.cmd == Command(0x01, 0x01),
           let s = parseState(p.payload, profile: DeviceRegistry.resolve(state: p.payload, bluetoothName: "")) { st = s }
    }
    log("handshake …")
    try handshake(link, profile: profile)

    func readBack(_ what: String) {
        st = nil
        for _ in 0..<6 {
            try? link.send(Command(0x01, 0x01))
            pump(1.0) { st != nil }
            if st != nil { break }
        }
        if let s = st {
            log("  \(what): bands \(hex(s.eqBands))  anc \(s.ancMode.map { String(format: "0x%02X", $0) } ?? "-")  lvl \(s.ancLevel.map(String.init) ?? "-")")
        } else {
            log("  \(what): NO STATE")
        }
    }

    readBack("initial")

    log("send EQ bass")
    try link.send(eqWrite(profile: profile, id: eqPresets["bassbooster"]!.id, bands: eqPresets["bassbooster"]!.bands))
    pump(1.2); readBack("after bass")

    log("send EQ flat")
    try link.send(eqWrite(profile: profile, id: eqPresets["flat"]!.id, bands: eqPresets["flat"]!.bands))
    pump(1.2); readBack("after flat")

    log("send ANC transparency")
    try link.send(ancWrite(profile: profile, mode: .transparency, level: 5))
    pump(1.2); readBack("after transparency")
}


/// Renders the real menu bar panel to a PNG. This is the actual SwiftUI view
/// with representative state pushed into it — not a mock-up drawn by hand — so
/// the screenshots in the docs cannot drift from the shipping UI.
@MainActor
func modeScreenshot() throws {
    let path = args.str("out") ?? "docs/screenshot.png"
    let dev = DeviceController.shared
    dev.connected = true
    dev.deviceName = "soundcore Space 2"
    dev.profile = .space2
    dev.status = "Connected"
    let presetKey = args.str("preset") ?? "rock"
    let modeByte: UInt8 = {
        switch (args.str("mode") ?? "nc").lowercased() {
        case "transparency", "ambient": return 0x01
        case "normal", "off":           return 0x02
        default:                        return 0x00
        }
    }()
    dev.state = DeviceState(
        battery: 8, batteryMax: 9, firmware: "01.59", model: "1402",
        eqPreset: eqPresets[presetKey]?.id.first ?? 0x11,
        eqBands: eqPresets[presetKey]?.bands ?? eqPresets["rock"]!.bands,
        ancMode: modeByte, ancLevel: 4, hostCount: 2
    )

    let content = MenuContent(dev: dev)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw ProbeError("could not render the panel")
    }
    try png.write(to: URL(fileURLWithPath: path))
    log("wrote \(path)  \(Int(image.size.width))x\(Int(image.size.height)) pt")
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

do {
    switch args.mode {
    case "selftest": modeSelfTest()
    case "sdp":      try modeSDP()
    case "probe":    try modeProbe()
    case "sweep":    try modeSweep()
    case "watch":    try modeWatch()
    case "send":     try modeSend()
    case "menubar":  runMenuBar()
    case "screenshot": try MainActor.assumeIsolated { try modeScreenshot() }
    case "status":   try modeStatus()
    case "apptest":  try modeAppTest()
    case "anc":      try modeANC()
    case "eq":       try modeEQ()
    case "snap":     try modeSnap()
    case "diffs":    try modeDiffs()
    case "gatt":
        // CoreBluetooth delivers on the dispatch queue, so this path keeps the
        // Task + RunLoop.main.run() structure.
        Task { @MainActor in await modeGATT() }
        RunLoop.main.run()
    case "help", "--help", "-h": log(usage)
    default:
        log(usage)
        warn("unknown mode: \(args.mode)")
        exit(2)
    }
    exit(0)
} catch {
    warn("\(error)")
    exit(1)
}

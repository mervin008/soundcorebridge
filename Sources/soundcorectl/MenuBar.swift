import SwiftUI
import AppKit
import IOBluetooth

/// Diagnostics and Bluetooth lifecycle logs for SoundcoreBridge.
let appLogPath = "/tmp/soundcorebridge.log"
func applog(_ msg: String) {
    let line = "\(stamp()) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: appLogPath) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        try? line.write(toFile: appLogPath, atomically: true, encoding: .utf8)
    }
}


/// Pointer feedback for the popover's controls. macOS users expect a control to
/// acknowledge the cursor; none of these did. Honours the system's reduce-motion
/// setting rather than animating regardless.
private struct HoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var active: Bool

    func body(content: Content) -> some View {
        content
            .brightness(hovering && !active ? 0.06 : 0)
            .scaleEffect(hovering ? 1.015 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(active: Bool = false) -> some View {
        modifier(HoverHighlight(active: active))
    }
}

// MARK: - Battery presentation

func batterySymbol(percent: Int) -> String {
    switch percent {
    case ...20: return "battery.0percent"
    case ...40: return "battery.25percent"
    case ...60: return "battery.50percent"
    case ...80: return "battery.75percent"
    default:    return "battery.100percent"
    }
}

func batteryColor(percent: Int) -> Color {
    switch percent {
    case ...20: return .red
    case ...40: return .orange
    default:    return .green
    }
}

// MARK: - Controller

final class DeviceController: ObservableObject {
    static let shared = DeviceController()

    @Published var status = "Connecting…"
    @Published var connected = false
    @Published var state: DeviceState?
    @Published var deviceName = "Soundcore"
    /// Resolved from the device's own reported model code; until then the
    /// read-only fallback keeps us from writing guessed offsets.
    @Published var profile: DeviceProfile = .unknown
    @Published var busy = false
    @Published var requestedLevel = 5

    private var worker: Thread?
    private let lock = NSLock()
    private var outbox: [[UInt8]] = []
    private var running = true

    func start() {
        guard worker == nil else { return }
        applog("controller starting")
        let t = Thread { [weak self] in self?.loop() }
        t.name = "soundcorebridge.bluetooth"
        t.stackSize = 512 * 1024
        worker = t
        t.start()
    }

    func stop() {
        running = false
        ui { self.busy = false }
    }

    private func ui(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func enqueue(_ packet: [UInt8]) {
        lock.lock(); outbox.append(packet); lock.unlock()
        ui { self.busy = true }
    }

    private func drain() -> [[UInt8]] {
        lock.lock(); let p = outbox; outbox.removeAll(); lock.unlock()
        return p
    }

    // MARK: commands

    func setANC(_ mode: ANCMode, level: Int) {
        let packet: [UInt8]
        do {
            guard connected else { throw ProbeError("device is not connected") }
            packet = try ancWrite(profile: profile, mode: mode, level: UInt8(clamping: level))
        } catch {
            applog("refused ANC write: \(error)")
            return
        }
        ui {
            self.requestedLevel = level
            if var s = self.state {
                s.ancMode = mode.rawValue
                s.ancLevel = level
                self.state = s
            }
        }
        applog("setANC \(mode.label) level \(level)")
        enqueue(packet)
    }

    func setEQ(id: [UInt8], bands: [UInt8]) {
        let packet: [UInt8]
        do {
            guard connected else { throw ProbeError("device is not connected") }
            packet = try eqWrite(profile: profile, id: id, bands: bands)
        } catch {
            applog("refused EQ write: \(error)")
            return
        }
        ui {
            if var s = self.state {
                s.eqPreset = id.first
                s.eqBands = bands
                self.state = s
            }
        }
        applog("setEQ id \(hex(id)) bands \(hex(bands))")
        enqueue(packet)
    }

    func refresh() {
        enqueue(Frame.encode(Command(0x01, 0x01)))
    }

    // MARK: link lifecycle

    private func loop() {
        while running {
            guard let device = try? RFCOMMLink.find(address: nil) else {
                applog("no paired Soundcore device found")
                ui {
                    self.status = "No paired Soundcore device"
                    self.connected = false
                    self.busy = false
                }
                pump(5)
                continue
            }

            let rawName = device.name ?? "Soundcore Headset"
            ui {
                self.deviceName = rawName
                self.profile = .unknown
                self.state = nil
                self.connected = false
            }
            let link = RFCOMMLink(device: device)
            applog("opening channel 30 on \(device.addressString ?? "?") (\(rawName))")
            ui { self.status = "Connecting to \(rawName)…" }

            do {
                try link.open(channelID: 30)
            } catch {
                applog("OPEN FAILED: \(error)")
                ui {
                    self.connected = false
                    self.busy = false
                    self.status = "Channel busy — another device may hold it"
                }
                pump(6)
                continue
            }

            var identifiedProfile: DeviceProfile?
            link.onPacket = { [weak self] packet in
                guard let self else { return }
                if packet.cmd == Command(0x01, 0x01), packet.checksumOK {
                    let resolved = DeviceRegistry.resolve(state: packet.payload,
                                                          bluetoothName: rawName)
                    guard let s = parseState(packet.payload, profile: resolved) else { return }
                    identifiedProfile = resolved
                    if resolved.modelCode != self.profile.modelCode {
                        applog("device profile: \(resolved.displayName)")
                    }
                    self.ui { self.profile = resolved }
                    self.ui { self.state = s; self.busy = false }
                }
            }

            ui { self.status = "Identifying \(rawName)…" }
            for _ in 0..<4 {
                try? link.send(Command(0x01, 0x01))
                pump(1.2) { identifiedProfile != nil }
                if identifiedProfile != nil { break }
            }

            guard let identifiedProfile else {
                applog("IDENTIFICATION FAILED: no valid state response")
                link.close()
                ui {
                    self.connected = false
                    self.busy = false
                    self.status = "Could not identify this device"
                }
                pump(3)
                continue
            }

            if identifiedProfile.allowsWrites {
                applog("device identified — running verified handshake")
                do {
                    try handshake(link, profile: identifiedProfile)
                } catch {
                    applog("HANDSHAKE FAILED: \(error)")
                    link.close()
                    ui {
                        self.connected = false
                        self.busy = false
                        self.status = "Control handshake failed"
                    }
                    pump(3)
                    continue
                }
            } else {
                applog("unverified model — keeping connection read-only")
            }
            ui {
                self.connected = true
                self.status = identifiedProfile.allowsWrites ? "Connected" : "Connected — read only"
            }
            try? link.send(Command(0x01, 0x01))

            var lastPoll = Date()
            while running && !link.wasClosed {
                let packets = drain()
                if !packets.isEmpty {
                    for packet in packets {
                        do {
                            try link.send(packet)
                            applog("sent \(packet.count)B \(hex(Array(packet.prefix(7))))")
                        } catch {
                            applog("SEND FAILED: \(error)")
                        }
                        pump(0.4)
                        try? link.send(Command(0x01, 0x01))
                        pump(0.3)
                    }
                    ui { self.busy = false }
                }
                if Date().timeIntervalSince(lastPoll) > 6 {
                    try? link.send(Command(0x01, 0x01))
                    lastPoll = Date()
                }
                pump(0.3)
            }

            applog("link dropped (wasClosed=\(link.wasClosed)) — reconnecting")
            link.close()
            ui {
                self.connected = false
                self.busy = false
                self.profile = .unknown
                self.state = nil
                self.status = "Reconnecting…"
            }
            pump(2)
        }
    }
}

// MARK: - Live EQ Curve Visualizer

struct EQCurveView: View {
    let bands: [UInt8]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padX: CGFloat = 20
            let usableW = w - padX * 2
            let step = usableW / 7.0
            let zeroY = h / 2.0

            let points: [CGPoint] = (0..<8).map { i in
                let b = i < bands.count ? bands[i] : 120
                let dB = eqDecibels(b)
                let normalized = CGFloat(dB / 6.0)
                let y = zeroY - normalized * (h / 2.0 - 8)
                let x = padX + CGFloat(i) * step
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Background zero reference dashed line
                Path { path in
                    path.move(to: CGPoint(x: padX, y: zeroY))
                    path.addLine(to: CGPoint(x: w - padX, y: zeroY))
                }
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary.opacity(0.35))

                // Area under curve gradient
                smoothSplineAreaPath(points: points, baselineY: h)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Frequency response line
                smoothSplinePath(points: points)
                .stroke(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.65)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )

                // Frequency control points
                ForEach(0..<points.count, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5.5, height: 5.5)
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .position(points[i])
                }
            }
        }
        .frame(height: 64)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Modern UI View

struct MenuContent: View {
    @ObservedObject var dev: DeviceController
    var isDetached = false
    @State private var showAllPresets = false
    @State private var showCustomEQ = false
    @State private var editorBands = Array(repeating: UInt8(0x78), count: 8)
    @State private var isEditing = false

    private let presetColumns = [GridItem(.adaptive(minimum: 120, maximum: 190), spacing: 6)]
    private let bandLabels = ["100", "200", "400", "800", "1.6k", "3.2k", "6.4k", "12.8k"]

    /// Everything accented in the popover follows the active listening mode.
    private var tint: Color { modeTint(dev.state?.ancMode, connected: dev.connected) }

    var body: some View {
        VStack(spacing: 12) {
            headerCard

            if dev.profile.supports(.soundMode) {
                noiseControlCard
            }

            if dev.profile.supports(.equaliser) {
                equaliserCard
            }

            if dev.connected, dev.state != nil, !dev.profile.allowsWrites {
                readOnlyCard
            }

            footerActions
        }
        .padding(14)
        // Width is fixed; height follows the content, so revealing the strength
        // row or the EQ editor grows the popover instead of scrolling Quit away.
        .frame(width: 410)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { syncEditorBands() }
        .onChange(of: dev.state?.eqBands) { _ in
            if !isEditing { syncEditorBands() }
        }
    }

    private var readOnlyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Read-only device")
                    .font(.subheadline.weight(.semibold))
                Text("Battery and firmware are available. Controls stay locked until this exact model is verified on real hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 12) {
            // Battery as a ring around the headphones, tinted by the active
            // listening mode — the badge reads out state, not decoration.
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(dev.state.map { batteryPercent($0.battery, max: $0.batteryMax) } ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.45), value: dev.state?.battery)
                Image(systemName: dev.connected ? "headphones" : "headphones.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(dev.connected ? Color.primary : .secondary)
            }
            .frame(width: 40, height: 40)
            .shadow(color: tint.opacity(dev.connected ? 0.35 : 0), radius: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(dev.profile.modelCode.isEmpty ? dev.deviceName : dev.profile.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if dev.connected, let s = dev.state {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: batterySymbol(percent: batteryPercent(s.battery, max: s.batteryMax)))
                                .foregroundStyle(batteryColor(percent: batteryPercent(s.battery, max: s.batteryMax)))
                            Text("\(batteryPercent(s.battery, max: s.batteryMax))%")
                                .fontWeight(.semibold)
                        }

                        Text("·").foregroundStyle(.tertiary)

                        Text("Model \(s.model)")
                            .foregroundStyle(.secondary)

                        if s.hostCount > 1 {
                            Text("·").foregroundStyle(.tertiary)
                            HStack(spacing: 2) {
                                Image(systemName: "laptopcomputer.and.iphone")
                                Text("\(s.hostCount) devices")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                } else {
                    Text(dev.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if dev.busy {
                ProgressView().controlSize(.small)
            } else if dev.connected {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Online")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Noise Control Card

    private var noiseControlCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOISE CONTROL")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ancModeButton("Noise Cancelling", .noiseCancelling, icon: "ear.and.waveform")
                ancModeButton("Transparency", .transparency, icon: "person.wave.2")
                ancModeButton("Normal", .normal, icon: "headphones")
            }

            if dev.profile.supports(.ancLevel),
               dev.state?.ancMode == ANCMode.noiseCancelling.rawValue {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Strength Level")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Level \(dev.state?.ancLevel ?? dev.requestedLevel) of 5")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { level in
                            let active = (dev.state?.ancLevel ?? dev.requestedLevel) == level
                            Button {
                                dev.setANC(.noiseCancelling, level: level)
                            } label: {
                                Text("\(level)")
                                    .font(.system(size: 11, weight: active ? .bold : .regular))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 24)
                                    .background(active ? tint : Color.primary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(active ? .white : .primary)
                            .hoverHighlight(active: active)
                            .help("Noise cancelling strength \(level) of 5")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func ancModeButton(_ title: String, _ mode: ANCMode, icon: String) -> some View {
        let active = dev.state?.ancMode == mode.rawValue
        return Button {
            dev.setANC(mode, level: dev.state?.ancLevel ?? 5)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? tint : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .hoverHighlight(active: active)
        .help(title)
    }

    // MARK: - Equaliser Card

    private var equaliserCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("EQUALISER")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    showAllPresets.toggle()
                    if showAllPresets { showCustomEQ = false }
                } label: {
                    HStack(spacing: 3) {
                        Text(showAllPresets ? "Less" : "All 22 Presets")
                        Image(systemName: showAllPresets ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Real-time Visual EQ Curve
            if let bands = dev.state?.eqBands {
                EQCurveView(bands: bands, tint: tint)
            }

            // Quick Preset Bar
            if showAllPresets {
                Group {
                    LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 6) {
                        ForEach(eqPresetOrder, id: \.key) { preset in
                            let value = eqPresets[preset.key]!
                            let active = dev.state?.eqPreset == value.id[0]
                            Button {
                                dev.setEQ(id: value.id, bands: value.bands)
                            } label: {
                                HStack(spacing: 4) {
                                    if active {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    Text(preset.title)
                                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(active ? tint : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

            } else {
                HStack(spacing: 6) {
                    ForEach(["signature", "acoustic", "bassbooster", "bassreducer"], id: \.self) { key in
                        if let value = eqPresets[key] {
                            let title = eqPresetOrder.first(where: { $0.key == key })?.title ?? key.capitalized
                            let active = dev.state?.eqPreset == value.id[0]
                            Button {
                                dev.setEQ(id: value.id, bands: value.bands)
                            } label: {
                                Text(title)
                                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(active ? tint : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                .contentShape(Rectangle())
                                    .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Custom EQ Section Toggle
            HStack {
                Button {
                    syncEditorBands()
                    showCustomEQ.toggle()
                    if showCustomEQ { showAllPresets = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.vertical.3")
                        Text(showCustomEQ ? "Hide Custom EQ" : "Custom EQ")
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(showCustomEQ ? tint : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .foregroundStyle(showCustomEQ ? .white : .primary)
                }
                .buttonStyle(.plain)

                Spacer()

                if let bands = dev.state?.eqBands {
                    Text(bands.map { String(format: "%+.0f", eqDecibels($0)) }.joined(separator: " "))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if showCustomEQ {
                customEditorView
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Custom EQ Sliders

    private var customEditorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(editorBands.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        Text(String(format: "%+.1f", eqDecibels(editorBands[index])))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Slider(value: bandBinding(index), in: -6...6, step: 0.1) { editing in
                            isEditing = editing
                            if !editing { sendCustomEQ() }
                        }
                        .rotationEffect(.degrees(-90))
                        .frame(width: 110, height: 18)
                        .frame(width: 38, height: 110)

                        Text(bandLabels[index])
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            HStack {
                Button("Flat (Reset)") {
                    editorBands = Array(repeating: 0x78, count: 8)
                    sendCustomEQ()
                }
                .font(.caption2)

                Spacer()

                Text("Applies instantly to DSP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private func bandBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { eqDecibels(editorBands[index]) },
            set: { editorBands[index] = eqByte(dB: $0) }
        )
    }

    private func syncEditorBands() {
        if let bands = dev.state?.eqBands, bands.count == 8 { editorBands = bands }
    }

    private func sendCustomEQ() {
        dev.setEQ(id: eqCustomID, bands: editorBands)
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button {
                dev.refresh()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Standalone Window Manager

final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?

    func showWindow(dev: DeviceController) {}
}


// MARK: - App Entry Point

final class SoundcoreBridgeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applog("applicationDidFinishLaunching starting bluetooth")
        // Prime Bluetooth stack safely on the main thread now that run loop is fully initialized
        _ = IOBluetoothDevice.pairedDevices()
        DeviceController.shared.start()
    }
}

struct SoundcoreBridgeApp: App {
    @NSApplicationDelegateAdaptor(SoundcoreBridgeAppDelegate.self) var appDelegate
    @StateObject private var dev = DeviceController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(dev: dev)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "headphones")
                    .renderingMode(.template)
                Text(dev.connected && dev.state != nil
                     ? "\(batteryPercent(dev.state!.battery, max: dev.state!.batteryMax))%"
                     : "Soundcore")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

func runMenuBar() -> Never {
    SoundcoreBridgeApp.main()
    exit(0)
}

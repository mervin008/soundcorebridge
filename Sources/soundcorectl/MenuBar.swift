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

private struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PanelSurface: ViewModifier {
    let tint: Color
    var radius: CGFloat = 16
    var elevated = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.opacity(elevated ? 0.10 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), tint.opacity(0.16), Color.black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: tint.opacity(elevated ? 0.13 : 0.05), radius: elevated ? 18 : 8, y: 5)
    }
}

extension View {
    func hoverHighlight(active: Bool = false) -> some View {
        modifier(HoverHighlight(active: active))
    }

    func panelSurface(tint: Color = .clear, radius: CGFloat = 16, elevated: Bool = false) -> some View {
        modifier(PanelSurface(tint: tint, radius: radius, elevated: elevated))
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
    private static let preferredDeviceKey = "preferredSoundcoreDeviceAddress"

    @Published var status = "Connecting…"
    @Published var connected = false
    @Published var state: DeviceState?
    @Published var deviceName = "Soundcore"
    /// Resolved from the device's own reported model code; until then the
    /// read-only fallback keeps us from writing guessed offsets.
    @Published var profile: DeviceProfile = .unknown
    @Published var busy = false
    @Published var requestedLevel = 5
    @Published private(set) var availableDevices: [PairedSoundcoreDevice] = []
    @Published private(set) var selectedDeviceAddress: String?
    @Published private(set) var connectedChannel: UInt8?

    private var worker: Thread?
    private let lock = NSLock()
    private var outbox: [[UInt8]] = []
    private var running = true
    private var preferredAddress: String?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.preferredDeviceKey)
        preferredAddress = saved
        selectedDeviceAddress = saved
    }

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

    private func preferredDeviceAddress() -> String? {
        lock.lock(); defer { lock.unlock() }
        return preferredAddress
    }

    private func storePreferredDevice(_ address: String) {
        lock.lock(); preferredAddress = address; outbox.removeAll(); lock.unlock()
        UserDefaults.standard.set(address, forKey: Self.preferredDeviceKey)
    }

    func selectDevice(_ address: String) {
        guard preferredDeviceAddress() != address else { return }
        storePreferredDevice(address)
        ui {
            self.selectedDeviceAddress = address
            self.connected = false
            self.busy = false
            self.profile = .unknown
            self.state = nil
            self.status = "Switching device…"
        }
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
            let paired = RFCOMMLink.pairedSoundcoreDevices()
            ui { self.availableDevices = paired }
            guard !paired.isEmpty else {
                applog("no paired Soundcore device found")
                ui {
                    self.status = "No paired Soundcore device"
                    self.connected = false
                    self.busy = false
                }
                pump(5)
                continue
            }

            let requestedAddress = preferredDeviceAddress()
            let selected = paired.first(where: { $0.address == requestedAddress }) ?? paired[0]
            if requestedAddress != selected.address {
                storePreferredDevice(selected.address)
                ui { self.selectedDeviceAddress = selected.address }
            }
            guard let device = try? RFCOMMLink.find(address: selected.address) else {
                ui { self.status = "Could not access \(selected.name)" }
                pump(3)
                continue
            }

            let rawName = device.name ?? "Soundcore Headset"
            let currentAddress = selected.address
            ui {
                self.deviceName = rawName
                self.profile = .unknown
                self.state = nil
                self.connected = false
            }
            let preferredChannels = DeviceRegistry.profile(bluetoothName: rawName)?.rfcommChannels ?? []
            let link: RFCOMMLink
            let openedChannel: UInt8
            applog("opening control channel on \(currentAddress) (\(rawName))")
            ui { self.status = "Connecting to \(rawName)…" }

            do {
                let opened = try RFCOMMLink.openControl(device: device,
                                                        preferred: preferredChannels)
                link = opened.link
                openedChannel = opened.channel
            } catch {
                applog("OPEN FAILED: \(error)")
                ui {
                    self.connected = false
                    self.busy = false
                    self.status = "No control channel available"
                }
                pump(6)
                continue
            }
            applog("channel \(openedChannel) open")
            ui { self.connectedChannel = openedChannel }

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
            while running && !link.wasClosed && preferredDeviceAddress() == currentAddress {
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
            let isSwitching = preferredDeviceAddress() != currentAddress
            ui {
                self.connected = false
                self.busy = false
                self.profile = .unknown
                self.state = nil
                self.connectedChannel = nil
                self.status = isSwitching ? "Switching device…" : "Reconnecting…"
            }
            pump(2)
        }
    }
}

// MARK: - Live EQ Curve Visualizer

struct EQCurveView: View {
    let bands: [UInt8]
    var tint: Color = .accentColor
    private let labels = ["100", "200", "400", "800", "1.6k", "3.2k", "6.4k", "12.8k"]

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let padX: CGFloat = 18
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
                    ForEach([CGFloat(0.25), 0.5, 0.75], id: \.self) { fraction in
                        Path { path in
                            let y = h * fraction
                            path.move(to: CGPoint(x: padX, y: y))
                            path.addLine(to: CGPoint(x: w - padX, y: y))
                        }
                        .stroke(
                            fraction == 0.5 ? Color.secondary.opacity(0.28) : Color.secondary.opacity(0.10),
                            style: StrokeStyle(lineWidth: 1, dash: fraction == 0.5 ? [4, 4] : [])
                        )
                    }

                    smoothSplineAreaPath(points: points, baselineY: h)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.38), tint.opacity(0.015)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    smoothSplinePath(points: points)
                        .stroke(
                            LinearGradient(
                                colors: [tint.opacity(0.75), tint, tint.opacity(0.78)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: tint.opacity(0.35), radius: 5)

                    ForEach(0..<points.count, id: \.self) { i in
                        ZStack {
                            Circle().fill(tint).frame(width: 10, height: 10)
                            Circle().fill(Color.white).frame(width: 4, height: 4)
                        }
                        .shadow(color: tint.opacity(0.45), radius: 3)
                        .position(points[i])
                    }
                }
            }
            .frame(height: 72)

            HStack(spacing: 0) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.09), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(tint.opacity(0.13), lineWidth: 1))
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
    private var battery: Int? {
        dev.state.map { batteryPercent($0.battery, max: $0.batteryMax) }
    }
    private var activeModeTitle: String {
        guard let raw = dev.state?.ancMode, let mode = ANCMode(rawValue: raw) else { return "Identifying" }
        return mode.label
    }
    private var activePresetKey: String? {
        guard let id = dev.state?.eqPreset, id != eqCustomID.first else { return nil }
        return eqPresetOrder.first(where: { eqPresets[$0.key]?.id.first == id })?.key
    }
    private var activePresetTitle: String {
        guard let id = dev.state?.eqPreset else { return "Equaliser" }
        if id == eqCustomID.first { return "Custom EQ" }
        guard let key = activePresetKey else { return "Equaliser" }
        return eqPresetOrder.first(where: { $0.key == key })?.title ?? "Equaliser"
    }
    private var quickPresetKeys: [String] {
        var keys = ["signature", "acoustic", "bassbooster", "bassreducer"]
        if let activePresetKey, !keys.contains(activePresetKey) {
            keys[keys.count - 1] = activePresetKey
        }
        return keys
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            RadialGradient(
                colors: [tint.opacity(dev.connected ? 0.16 : 0.05), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )

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
        }
        // Width is fixed; height follows the content, so revealing the strength
        // row or the EQ editor grows the popover instead of scrolling Quit away.
        .frame(width: 424)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { syncEditorBands() }
        .onChange(of: dev.state?.eqBands) { _ in
            if !isEditing { syncEditorBands() }
        }
    }

    private var readOnlyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        .padding(14)
        .panelSurface(tint: tint, radius: 15)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: max(0.025, CGFloat(battery ?? 0) / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.45), value: battery)
                    Circle()
                        .fill(tint.opacity(dev.connected ? 0.12 : 0.04))
                        .padding(7)
                    Image(systemName: dev.connected ? "headphones" : "headphones.slash")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(dev.connected ? tint : Color.secondary)
                }
                .frame(width: 54, height: 54)
                .shadow(color: tint.opacity(dev.connected ? 0.28 : 0), radius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(dev.connected ? "ACTIVE DEVICE" : "SOUNDCOREBRIDGE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.25)
                        .foregroundStyle(tint.opacity(dev.connected ? 0.9 : 0.55))

                    Text(dev.profile.modelCode.isEmpty ? dev.deviceName : dev.profile.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .tracking(-0.25)
                        .lineLimit(1)

                    if let state = dev.state {
                        Text("D\(state.model)  ·  Firmware \(state.firmware)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(dev.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    if dev.busy {
                        ProgressView().controlSize(.small)
                    } else if let battery {
                        Text("\(battery)%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("BATTERY")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(batteryColor(percent: battery))
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 8, height: 8)
                    }
                }
            }

            if dev.connected, let state = dev.state {
                HStack(spacing: 7) {
                    infoChip(icon: "waveform", text: activeModeTitle, color: tint)
                    infoChip(icon: "slider.horizontal.3", text: activePresetTitle, color: tint)
                    if state.hostCount > 1 {
                        infoChip(icon: "laptopcomputer.and.iphone", text: "\(state.hostCount) hosts", color: .secondary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .panelSurface(tint: tint, radius: 18, elevated: true)
    }

    private func infoChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Noise Control Card

    private var noiseControlCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Noise control")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(activeModeTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }

            HStack(spacing: 8) {
                ancModeButton("Noise Cancelling", .noiseCancelling, icon: "ear.and.waveform")
                ancModeButton("Transparency", .transparency, icon: "person.wave.2")
                ancModeButton("Normal", .normal, icon: "headphones")
            }

            if dev.profile.supports(.ancLevel),
               dev.state?.ancMode == ANCMode.noiseCancelling.rawValue {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Cancellation strength")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(dev.state?.ancLevel ?? dev.requestedLevel) / 5")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tint)
                    }

                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { level in
                            let active = (dev.state?.ancLevel ?? dev.requestedLevel) == level
                            Button {
                                dev.setANC(.noiseCancelling, level: level)
                            } label: {
                                Text("\(level)")
                                    .font(.system(size: 11, weight: active ? .bold : .regular))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .background(
                                        active ? tint : Color.primary.opacity(0.045),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PanelButtonStyle())
                            .foregroundStyle(active ? .white : .primary)
                            .hoverHighlight(active: active)
                            .help("Noise cancelling strength \(level) of 5")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .panelSurface(tint: tint, radius: 16)
    }

    private func ancModeButton(_ title: String, _ mode: ANCMode, icon: String) -> some View {
        let active = dev.state?.ancMode == mode.rawValue
        return Button {
            dev.setANC(mode, level: dev.state?.ancLevel ?? 5)
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Color.white.opacity(0.16) : tint.opacity(0.08))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(width: 31, height: 31)
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: active
                        ? [tint, tint.opacity(0.72)]
                        : [Color.primary.opacity(0.055), Color.primary.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.16) : Color.primary.opacity(0.045), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(PanelButtonStyle())
        .hoverHighlight(active: active)
        .help(title)
    }

    // MARK: - Equaliser Card

    private var equaliserCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equaliser")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(activePresetTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(tint)
                }

                Spacer()

                Button {
                    showAllPresets.toggle()
                    if showAllPresets { showCustomEQ = false }
                } label: {
                    HStack(spacing: 3) {
                        Text(showAllPresets ? "Show less" : "Browse presets")
                        Image(systemName: showAllPresets ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(PanelButtonStyle())
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
                                .background(active ? tint : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                                .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(PanelButtonStyle())
                            .hoverHighlight(active: active)
                        }
                    }
                    .padding(.vertical, 2)
                }

            } else {
                HStack(spacing: 6) {
                    ForEach(quickPresetKeys, id: \.self) { key in
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
                                    .padding(.vertical, 7)
                                    .background(active ? tint : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                    .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(PanelButtonStyle())
                            .hoverHighlight(active: active)
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
                    .padding(.vertical, 6)
                    .background(showCustomEQ ? tint : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .foregroundStyle(showCustomEQ ? .white : .primary)
                }
                .buttonStyle(PanelButtonStyle())
                .hoverHighlight(active: showCustomEQ)

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
        .padding(14)
        .panelSurface(tint: tint, radius: 16)
    }

    // MARK: - Custom EQ Sliders

    private var customEditorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("8-band tuning", systemImage: "waveform.path.ecg")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text("−6 dB  ·  +6 dB")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

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
                        .tint(tint)

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
                .font(.caption2.weight(.medium))
                .buttonStyle(PanelButtonStyle())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Spacer()

                Label("Live on device", systemImage: "bolt.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.075), Color.primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(tint.opacity(0.12), lineWidth: 1))
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
            if dev.availableDevices.count > 1 {
                Menu {
                    ForEach(dev.availableDevices) { device in
                        Button {
                            dev.selectDevice(device.address)
                        } label: {
                            if dev.selectedDeviceAddress == device.address {
                                Label("\(device.name) · \(device.address.suffix(5))", systemImage: "checkmark")
                            } else {
                                Text("\(device.name) · \(device.address.suffix(5))")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "headphones")
                        Text("Devices")
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                dev.refresh()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PanelButtonStyle())
            .foregroundStyle(.secondary)
            .help("Refresh device state")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PanelButtonStyle())
            .foregroundStyle(.secondary)
            .help("Quit SoundcoreBridge")
        }
        .padding(.horizontal, 2)
    }
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

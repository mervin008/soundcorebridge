import Foundation
import IOBluetooth

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

struct PairedSoundcoreDevice: Identifiable, Equatable {
    let address: String
    let name: String
    var id: String { address }
}

/// Firmware-flashing services. These are matched by the *service* advertised on
/// a channel, not by channel number: channel 12 is firmware OTA on a Space 2 but
/// OBEX Object Push on an Android phone, so a number-based blocklist is both
/// wrong elsewhere and useless on any device it was not written for.
let blockedServiceNames = ["tota", "besota", "ota"]

/// Apple's iAP2/MFi service. Not dangerous, but it does not speak this protocol.
let iap2UUID = "00000000-deca-fade-deca-deafdecacaff"

/// BES chipset OTA service.
let besOTAUUID = "66666666-6666-6666-6666-666666666666"

/// Returns a reason if the channel must not be opened on this device.
///
/// Resolves the channel against the device's own SDP records, so the guard
/// travels to every model rather than only the one it was written on.
func blockedChannel(_ ch: UInt8, device: IOBluetoothDevice) -> String? {
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    for record in records {
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess, id == ch else { continue }

        let name = (record.getServiceName() ?? "").lowercased()
        if blockedServiceNames.contains(where: { name == $0 || name.hasSuffix($0) }) {
            return "\(record.getServiceName() ?? "OTA") — firmware update service (bricking risk)"
        }
        let attributes = (record.attributes as? [NSNumber: IOBluetoothSDPDataElement]) ?? [:]
        let described = attributes[NSNumber(value: 1)]?.description.lowercased() ?? ""
        let compact = described.replacingOccurrences(of: " ", with: "")
        if compact.contains(besOTAUUID.replacingOccurrences(of: "-", with: "")) {
            return "BES chipset OTA (bricking risk)"
        }
        if compact.contains(iap2UUID.replacingOccurrences(of: "-", with: "")) {
            return "Apple iAP2 / MFi — not this protocol"
        }
    }
    return nil
}

/// Vendor control channels seen on Soundcore hardware. Order matters when SDP
/// records are unavailable: try the currently verified Space 2 channel first.
let defaultControlChannels: [UInt8] = [30, 17]
let allowedChannels = Set(defaultControlChannels)

/// Combine model knowledge and cached SDP evidence without ever broadening the
/// safety allowlist. Kept pure so ordering behavior can be tested offline.
func orderedControlChannels(preferred: [UInt8], advertised: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    let safeDiscovery = advertised.filter { allowedChannels.contains($0) }
    for channel in preferred + safeDiscovery + defaultControlChannels
    where !result.contains(channel) {
        result.append(channel)
    }
    return result
}

/// IOBluetooth delivers delegate callbacks through the *run loop* of the thread
/// that opened the channel — not through a dispatch queue. Awaiting a Swift
/// continuation therefore never sees them: the loop has to be pumped explicitly.
/// This class is deliberately plain (no actor isolation) for that reason.
final class RFCOMMLink: NSObject {
    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private let parser = FrameParser()
    private var liveWrites = Set<UnsafeMutableRawPointer>()
    private var allChannels: [IOBluetoothRFCOMMChannel] = []

    private(set) var isOpen = false
    private var openFailure: IOReturn?
    private(set) var wasClosed = false

    var onPacket: ((Packet) -> Void)?
    var onRaw: (([UInt8]) -> Void)?

    var anyChannel = false
    var profileChannels: Set<UInt8> = []
    var maxOpenAttempts = 20
    var verbose = false

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    static func pairedSoundcoreDevices() -> [PairedSoundcoreDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard let address = device.addressString,
                  DeviceRegistry.isLikelySoundcore(device.name ?? "") else { return nil }
            return PairedSoundcoreDevice(address: address,
                                         name: device.name ?? "Soundcore device")
        }
        .sorted {
            let names = $0.name.localizedCaseInsensitiveCompare($1.name)
            return names == .orderedSame ? $0.address < $1.address : names == .orderedAscending
        }
    }

    static func advertisedChannels(device: IOBluetoothDevice) -> [UInt8] {
        ((device.services as? [IOBluetoothSDPServiceRecord]) ?? []).compactMap { record in
            var channel: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channel) == kIOReturnSuccess,
                  allowedChannels.contains(channel),
                  blockedChannel(channel, device: device) == nil else { return nil }
            return channel
        }
    }

    static func controlChannelCandidates(device: IOBluetoothDevice,
                                         preferred: [UInt8]) -> [UInt8] {
        orderedControlChannels(preferred: preferred,
                               advertised: advertisedChannels(device: device))
    }

    /// Open the first safe candidate. The primary candidate retains the longer
    /// retry budget needed by macOS RFCOMM; fallbacks fail faster.
    static func openControl(device: IOBluetoothDevice,
                            preferred: [UInt8],
                            verbose: Bool = false) throws -> (link: RFCOMMLink, channel: UInt8) {
        let candidates = controlChannelCandidates(device: device, preferred: preferred)
        var failures: [String] = []
        for (index, channel) in candidates.enumerated() {
            let link = RFCOMMLink(device: device)
            link.verbose = verbose
            link.profileChannels = Set(preferred)
            link.maxOpenAttempts = index == 0 ? 20 : 4
            do {
                try link.open(channelID: channel)
                return (link, channel)
            } catch {
                failures.append("\(channel): \(error)")
                link.close()
            }
        }
        throw ProbeError("no safe control channel opened (\(failures.joined(separator: "; ")))")
    }

    static func find(address: String?) throws -> IOBluetoothDevice {
        if let address {
            guard let d = IOBluetoothDevice(addressString: address) else {
                throw ProbeError("not a valid Bluetooth address: \(address)")
            }
            return d
        }
        guard let candidate = pairedSoundcoreDevices().first,
              let d = IOBluetoothDevice(addressString: candidate.address) else {
            throw ProbeError("no paired Soundcore device found — pass --device <addr>")
        }
        return d
    }

    /// One open attempt. Returns the channel if the stack reported it open.
    private func openOnce(channelID: UInt8, timeout: TimeInterval) -> IOBluetoothRFCOMMChannel? {
        isOpen = false
        openFailure = nil
        wasClosed = false

        _ = device.openConnection()

        var ch: IOBluetoothRFCOMMChannel?
        let r = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
        guard r == kIOReturnSuccess, let ch else { return nil }
        channel = ch
        allChannels.append(ch)   // every one of these must be closed on exit

        // Never break on wasClosed here — a close deferred from a previous
        // attempt lands in this window and would cut the wait short.
        pump(timeout) { self.isOpen || self.openFailure != nil }
        return (isOpen || ch.isOpen()) ? ch : nil
    }

    /// Open the channel and prove it is usable by writing to it. The macOS
    /// RFCOMM stack reports success on channels that are already dead, and
    /// `isOpen()` is unreliable in both directions, so a real write is the only
    /// trustworthy liveness test. Failed attempts are never closed: the close
    /// lands asynchronously and tears down whichever attempt succeeds next.
    func open(channelID: UInt8, timeout: TimeInterval = 1.5) throws {
        if let why = blockedChannel(channelID, device: device) {
            throw ProbeError("refusing channel \(channelID): \(why)")
        }
        guard allowedChannels.contains(channelID) || profileChannels.contains(channelID) || anyChannel else {
            throw ProbeError("channel \(channelID) is not approved by discovery or a verified profile — pass --any-channel to override")
        }

        let liveness = Frame.encode(Command(0x01, 0x01))
        for attempt in 1...maxOpenAttempts {
            if let ch = openOnce(channelID: channelID, timeout: timeout) {
                do {
                    try write(ch, liveness)
                    isOpen = true
                    // Deferred closes from earlier attempts have landed by now;
                    // clear the flag so callers can use it to detect a real
                    // disconnect rather than an echo of our own retries.
                    wasClosed = false
                    if attempt > 1 || verbose { log("channel live on attempt \(attempt)") }
                    return
                } catch {
                    if verbose { log("  attempt \(attempt): opened but write failed") }
                }
            } else if verbose {
                log("  attempt \(attempt): no open")
            }
            channel = nil
            pump(0.4)
        }
        throw ProbeError("channel \(channelID) never became usable after \(maxOpenAttempts) attempts")
    }

    func send(_ bytes: [UInt8]) throws {
        guard let ch = channel else { throw ProbeError("no channel") }
        try write(ch, bytes)
    }

    private func write(_ ch: IOBluetoothRFCOMMChannel, _ bytes: [UInt8]) throws {
        // writeAsync does not copy, so the buffer has to outlive the call.
        let p = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        liveWrites.insert(p)

        let r = ch.writeAsync(p, length: UInt16(bytes.count), refcon: p)
        if r != kIOReturnSuccess {
            liveWrites.remove(p)
            p.deallocate()
            throw ProbeError("write failed (\(ioReturnName(r)))")
        }
    }

    func send(_ cmd: Command, payload: [UInt8] = []) throws {
        try send(Frame.encode(cmd, payload: payload))
    }

    var mtu: UInt16 { channel?.getMTU() ?? 0 }

    /// Close every channel this process opened. Leaking half-open RFCOMM
    /// sessions exhausts the headset's SPP slots, after which it accepts
    /// connections and drops them instantly until power-cycled.
    func close() {
        for c in allChannels { c.close() }
        allChannels.removeAll()
        channel = nil
        isOpen = false
        pump(0.2)   // let the closes reach the device
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate (informal — matched by selector)

    @objc func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess { isOpen = true } else { openFailure = error }
    }

    @objc func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!,
                                 data dataPointer: UnsafeMutableRawPointer!,
                                 length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        onRaw?(bytes)
        for p in parser.feed(bytes) { onPacket?(p) }
    }

    @objc func rfcommChannelWriteComplete(_ ch: IOBluetoothRFCOMMChannel!,
                                          refcon: UnsafeMutableRawPointer!,
                                          status error: IOReturn) {
        guard let refcon, liveWrites.remove(refcon) != nil else { return }
        refcon.deallocate()
    }

    @objc func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        wasClosed = true
        isOpen = false
    }
}

func ioReturnName(_ r: IOReturn) -> String {
    switch r {
    case kIOReturnSuccess:         return "success"
    case kIOReturnNoDevice:        return "kIOReturnNoDevice"
    case kIOReturnNotOpen:         return "kIOReturnNotOpen"
    case kIOReturnBusy:            return "kIOReturnBusy"
    case kIOReturnTimeout:         return "kIOReturnTimeout"
    case kIOReturnNotPermitted:    return "kIOReturnNotPermitted"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
    default: return String(format: "0x%08X", UInt32(bitPattern: r))
    }
}

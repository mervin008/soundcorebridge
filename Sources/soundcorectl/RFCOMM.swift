import Foundation
import IOBluetooth

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

/// Channels we will never open — scoped to the Space 2, since channel numbers
/// mean entirely different things on other devices (ch 12 is OBEX Object Push
/// on an Android phone, not firmware OTA).
let space2Address = "84-9d-4b-b0-79-8f"

func blockedChannel(_ ch: UInt8, address: String?) -> String? {
    guard address?.lowercased() == space2Address else { return nil }
    return space2BlockedChannels[ch]
}

let space2BlockedChannels: [UInt8: String] = [
    12: "TOTA — firmware OTA (bricking risk)",
    13: "BESOTA — BES chipset OTA (bricking risk)",
    16: "IOSSPP — Apple iAP2 / MFi, not our protocol",
]

/// Vendor control channels found in the Space 2 SDP record.
let allowedChannels: Set<UInt8> = [30, 17]

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
    var maxOpenAttempts = 20
    var verbose = false

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    static func find(address: String?) throws -> IOBluetoothDevice {
        if let address {
            guard let d = IOBluetoothDevice(addressString: address) else {
                throw ProbeError("not a valid Bluetooth address: \(address)")
            }
            return d
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let d = paired.first(where: {
            DeviceRegistry.isLikelySoundcore($0.name ?? "")
        }) else {
            throw ProbeError("no paired Soundcore device found — pass --device <addr>")
        }
        // Rebuild from the address: objects vended by pairedDevices() do not
        // reliably route an RFCOMM open, while a freshly constructed one does.
        if let addr = d.addressString, let fresh = IOBluetoothDevice(addressString: addr) {
            return fresh
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
        if let why = blockedChannel(channelID, address: device.addressString) {
            throw ProbeError("refusing channel \(channelID): \(why)")
        }
        guard allowedChannels.contains(channelID) || anyChannel else {
            throw ProbeError("channel \(channelID) is not in the allowlist \(allowedChannels.sorted()) — pass --any-channel to override")
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

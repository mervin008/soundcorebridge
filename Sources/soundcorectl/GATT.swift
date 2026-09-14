import Foundation
import CoreBluetooth

/// BLE reconnaissance. IOBluetooth's classic RFCOMM path is refused by macOS for
/// this process on every channel, so the remaining in-band control surface is
/// GATT — which CoreBluetooth supports without the legacy restrictions.
@MainActor
final class GATTScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var pending = 0
    private let nameHint: String
    private let scanSeconds: Int

    private let connectTo: String?

    init(nameHint: String, scanSeconds: Int, connectTo: String? = nil) {
        self.connectTo = connectTo
        self.nameHint = nameHint.lowercased()
        self.scanSeconds = scanSeconds
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            guard c.state == .poweredOn else {
                log("bluetooth state: \(c.state.rawValue) (need 5 = poweredOn)")
                return
            }
            // Devices already connected over LE never re-advertise; check both.
            let connected = c.retrieveConnectedPeripherals(withServices: [
                CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180F"),
            ])
            for p in connected {
                log("already-connected LE peripheral: \(p.name ?? "(unnamed)")  \(p.identifier)")
                if matches(p) { connect(p); return }
            }
            log("scanning \(scanSeconds)s — showing every LE advertisement:\n")
            c.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(scanSeconds) * 1_000_000_000)
                if target == nil {
                    c.stopScan()
                    log("\n\(seen.count) peripheral(s) seen, none named like a Soundcore device.")
                    log("Look above for a strong signal (-30..-55 dBm = on your desk) with no name")
                    log("or an unfamiliar one — then: space2ctl gatt --connect <identifier>")
                    exit(0)
                }
            }
        }
    }

    private func matches(_ p: CBPeripheral) -> Bool {
        guard let n = p.name?.lowercased() else { return false }
        return n.contains(nameHint) || n.contains("soundcore") || n.contains("space")
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            // Log EVERY advertisement. peripheral.name is often nil during a scan
            // even when the device advertises a local name, so filtering on it
            // first throws away the device we are looking for.
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = p.name ?? localName
            let key = p.identifier.uuidString
            guard !seen.contains(key) else { return }
            seen.insert(key)

            var bits: [String] = []
            if let svc = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !svc.isEmpty {
                bits.append("services=[\(svc.map(\.uuidString).joined(separator: ","))]")
            }
            if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfr.count >= 2 {
                let b = [UInt8](mfr)
                let company = UInt16(b[0]) | (UInt16(b[1]) << 8)   // company ID is LE
                bits.append(String(format: "company=0x%04X data=%@", company, hex(Array(b.dropFirst(2)))))
            }
            if advertisementData[CBAdvertisementDataIsConnectable] as? Bool == true {
                bits.append("connectable")
            }

            let flag = (name.map { $0.lowercased().contains("space") || $0.lowercased().contains("soundcore") } ?? false)
                ? "  <<<< MATCH" : ""
            log(String(format: "  %4d dBm  %@  %-24@ %@%@",
                       RSSI.intValue,
                       key as NSString,
                       (name ?? "(no name)") as NSString,
                       bits.joined(separator: "  ") as NSString,
                       flag as NSString))

            if let connectTo, key.lowercased() == connectTo.lowercased(), target == nil {
                c.stopScan(); log(""); connect(p); return
            }
            if connectTo == nil, let name, matchesName(name), target == nil {
                c.stopScan()
                log("")
                connect(p)
            }
        }
    }

    private var seen = Set<String>()

    private func matchesName(_ n: String) -> Bool {
        let l = n.lowercased()
        return l.contains("space") || l.contains("soundcore")
    }

    private func connect(_ p: CBPeripheral) {
        target = p
        p.delegate = self
        central.connect(p, options: nil)
        log("connecting …")
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            log("connected — discovering services")
            p.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            warn("connect failed: \(error?.localizedDescription ?? "unknown")")
            exit(1)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { warn("service discovery: \(error)"); exit(1) }
            let services = p.services ?? []
            log("\n\(services.count) service(s):")
            pending = services.count
            for s in services {
                log("  \(s.uuid.uuidString)\(isStandard(s.uuid) ? "" : "   << custom")")
                p.discoverCharacteristics(nil, for: s)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) { props.append("write") }
                if c.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
                if c.properties.contains(.notify) { props.append("notify") }
                if c.properties.contains(.indicate) { props.append("indicate") }
                log("      \(c.uuid.uuidString)  [\(props.joined(separator: ","))]")
            }
            pending -= 1
            if pending <= 0 {
                log("\nA custom service carrying a write+notify pair is the control channel.")
                log("Write 08EE-framed packets to the write characteristic, read replies from notify.")
                exit(0)
            }
        }
    }

    private func isStandard(_ u: CBUUID) -> Bool { u.uuidString.count <= 6 }
}

@MainActor var scanner: GATTScanner?

@MainActor
func modeGATT() async {
    scanner = GATTScanner(nameHint: "space",
                          scanSeconds: args.int("duration", 20),
                          connectTo: args.str("connect"))
    // Delegate callbacks drive the run loop and call exit() when done.
    while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
}

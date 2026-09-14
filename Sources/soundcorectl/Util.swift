import Foundation

let stderrHandle = FileHandle.standardError

func log(_ s: String) { print(s) }
func warn(_ s: String) { stderrHandle.write(("! " + s + "\n").data(using: .utf8)!) }

func hex(_ bytes: [UInt8], separator: String = " ") -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
}

func parseHex(_ s: String) -> [UInt8]? {
    let t = s.replacingOccurrences(of: ":", with: "")
             .replacingOccurrences(of: " ", with: "")
    guard t.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = t.startIndex
    while i < t.endIndex {
        let j = t.index(i, offsetBy: 2)
        guard let b = UInt8(t[i..<j], radix: 16) else { return nil }
        out.append(b)
        i = j
    }
    return out
}

func hexdump(_ bytes: [UInt8], indent: String = "    ") -> String {
    var lines: [String] = []
    for off in stride(from: 0, to: bytes.count, by: 16) {
        let row = Array(bytes[off..<min(off + 16, bytes.count)])
        let ascii = row.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : "." }.joined()
        let h = hex(row).padding(toLength: 47, withPad: " ", startingAt: 0)
        lines.append(String(format: "%@%04X  %@ |%@|", indent, off, h, ascii))
    }
    return lines.joined(separator: "\n")
}

func describe(_ p: Packet) -> String {
    let dir = p.isResponse ? "RX" : "TX-echo"
    let ck = p.checksumOK ? "" : "  [BAD CHECKSUM]"
    var s = "\(dir) \(p.cmd)  len=\(p.raw.count)  payload=\(p.payload.count)B\(ck)"
    if !p.payload.isEmpty { s += "\n" + hexdump(p.payload) }
    return s
}

/// Byte-level diff between two payloads of the same command.
func diff(_ old: [UInt8], _ new: [UInt8]) -> [String] {
    guard old.count == new.count else {
        return ["length \(old.count) → \(new.count)", "  was: \(hex(old))", "  now: \(hex(new))"]
    }
    var out: [String] = []
    for i in 0..<old.count where old[i] != new[i] {
        out.append(String(format: "  byte[%d] (0x%02X): %02X → %02X", i, i, old[i], new[i]))
    }
    return out
}

struct Args {
    let mode: String
    private var flags: [String: String] = [:]
    private var positional: [String] = []

    init(_ argv: [String]) {
        var a = Array(argv.dropFirst())
        mode = a.first.map { $0.hasPrefix("--") ? "probe" : $0 } ?? "probe"
        if !a.isEmpty && !a[0].hasPrefix("--") { a.removeFirst() }
        var i = 0
        while i < a.count {
            if a[i].hasPrefix("--") {
                let key = String(a[i].dropFirst(2))
                if i + 1 < a.count && !a[i + 1].hasPrefix("--") {
                    flags[key] = a[i + 1]; i += 2
                } else {
                    flags[key] = "true"; i += 1
                }
            } else {
                positional.append(a[i]); i += 1
            }
        }
    }

    func str(_ k: String) -> String? { flags[k] }
    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap { Int($0) } ?? d }
    func bool(_ k: String) -> Bool { flags[k] == "true" }
    func pos(_ i: Int) -> String? { i < positional.count ? positional[i] : nil }
}

/// Run the current thread's run loop for `seconds`, stopping early if `until`
/// becomes true. IOBluetooth callbacks are delivered here and nowhere else.
func pump(_ seconds: TimeInterval, until: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.05, remaining)))
        if until() { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

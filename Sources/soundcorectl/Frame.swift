import Foundation

/// A 2-byte Soundcore command word: `group` then `code`.
///
/// Observed convention (hypothesis, not confirmed for D1402): a `code` with the
/// high bit set is a write, with it clear is a read. e.g. LDAC query is 01:7F,
/// LDAC set is 01:FF.
struct Command: Equatable, Hashable, CustomStringConvertible {
    let group: UInt8
    let code: UInt8

    var isWrite: Bool { code & 0x80 != 0 }
    var description: String { String(format: "%02X:%02X", group, code) }

    /// Parses "01:01" or "0101".
    init?(_ s: String) {
        let t = s.replacingOccurrences(of: ":", with: "")
                 .replacingOccurrences(of: " ", with: "")
        guard t.count == 4, let v = UInt16(t, radix: 16) else { return nil }
        group = UInt8(v >> 8)
        code = UInt8(v & 0xFF)
    }

    init(_ group: UInt8, _ code: UInt8) {
        self.group = group
        self.code = code
    }
}

struct Packet {
    let isResponse: Bool
    let direction: UInt8
    let cmd: Command
    let payload: [UInt8]
    let checksumOK: Bool
    let raw: [UInt8]
}

enum Frame {
    static let cmdMagic: [UInt8] = [0x08, 0xEE, 0x00, 0x00]   // host -> device
    static let rspMagic: [UInt8] = [0x09, 0xFF, 0x00, 0x00]   // device -> host
    static let headerLen = 9    // magic(4) + direction(1) + cmd(2) + length(2)
    static let minLen = 10      // header + checksum
    static let maxLen = 4096

    /// Sum of every preceding byte, truncated to 8 bits.
    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF)
    }

    static func encode(_ cmd: Command, payload: [UInt8] = []) -> [UInt8] {
        let total = minLen + payload.count
        var b = cmdMagic
        b.append(0x00)                              // direction / sequence
        b.append(cmd.group)
        b.append(cmd.code)
        b.append(UInt8(total & 0xFF))               // total length, u16 LE
        b.append(UInt8((total >> 8) & 0xFF))
        b.append(contentsOf: payload)
        b.append(checksum(b))
        return b
    }
}

/// Reassembles packets from an RFCOMM byte stream, resyncing on garbage.
final class FrameParser {
    private var buf: [UInt8] = []

    func feed(_ incoming: [UInt8]) -> [Packet] {
        buf.append(contentsOf: incoming)
        var out: [Packet] = []

        while true {
            guard let start = seekMagic() else { break }
            if start > 0 { buf.removeFirst(start) }
            guard buf.count >= Frame.minLen else { break }

            let total = Int(buf[7]) | (Int(buf[8]) << 8)
            guard total >= Frame.minLen, total <= Frame.maxLen else {
                buf.removeFirst(1)      // bad length, not a real frame
                continue
            }
            guard buf.count >= total else { break }   // wait for the rest

            let raw = Array(buf[0..<total])
            buf.removeFirst(total)
            out.append(Packet(
                isResponse: Array(raw[0..<4]) == Frame.rspMagic,
                direction: raw[4],
                cmd: Command(raw[5], raw[6]),
                payload: total > Frame.minLen ? Array(raw[9..<(total - 1)]) : [],
                checksumOK: Frame.checksum(raw.dropLast()) == raw[total - 1],
                raw: raw
            ))
        }
        return out
    }

    /// Index of the next frame magic, dropping unparseable leading bytes.
    private func seekMagic() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) {
            let window = Array(buf[i..<(i + 4)])
            if window == Frame.cmdMagic || window == Frame.rspMagic { return i }
        }
        // Nothing found: keep only a possible partial magic.
        if buf.count > 3 { buf.removeFirst(buf.count - 3) }
        return nil
    }

    func reset() { buf.removeAll() }
}

import Foundation

/// One H.264 access unit (Annex-B) rebuilt from `video` chunks.
struct AccessUnit: Equatable {
    var data: Data
    var idr: Bool
    var config: Bool
    var snap: Bool
    var boardMs: UInt32  // board timestamp from the START chunk
    var generation = 0  // local receive generation; not part of the wire protocol
}

/// Rebuilds access units from `video` notifies: `[seq u16 LE][flags u8][payload]` (docs/ble-protocol.md).
///
/// A seq gap counts as a drop; everything is then discarded until the next START chunk that is an IDR or
/// CONFIG, because P-frames after a lost chunk cannot be decoded.
struct VideoAssembler {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let start = Flags(rawValue: 1 << 0)
        static let end = Flags(rawValue: 1 << 1)
        static let idr = Flags(rawValue: 1 << 2)
        static let config = Flags(rawValue: 1 << 3)
        static let bench = Flags(rawValue: 1 << 4)
        static let snap = Flags(rawValue: 1 << 5)
    }

    private(set) var drops = 0         // chunks lost (seq gaps)
    private(set) var bytes = 0         // all chunk bytes received, bench included
    private(set) var benchBytes = 0
    private(set) var waitingForKey = true  // until the first IDR/CONFIG
    private var lastSeq: UInt16?
    private var current: AccessUnit?

    mutating func reset() {
        lastSeq = nil
        current = nil
        waitingForKey = true
    }

    /// Feed one notify; returns a completed access unit, if this chunk finished one.
    mutating func add(_ chunk: Data) -> AccessUnit? {
        let c = [UInt8](chunk)
        guard c.count >= 3 else { return nil }
        bytes += c.count
        let seq = UInt16(c[0]) | UInt16(c[1]) << 8
        let flags = Flags(rawValue: c[2])
        if let last = lastSeq, seq != last &+ 1 {
            drops += Int(seq &- last &- 1)
            current = nil
            waitingForKey = true
        }
        lastSeq = seq
        var payload = Data(c[3...])
        if flags.contains(.bench) {
            benchBytes += c.count
            return nil
        }
        if flags.contains(.start) {
            let key = flags.contains(.idr) || flags.contains(.config)
            if waitingForKey && !key { current = nil; return nil }
            waitingForKey = false
            guard payload.count >= 4 else { current = nil; return nil }
            let p = [UInt8](payload.prefix(4))
            let ms = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            payload = payload.dropFirst(4)
            current = AccessUnit(data: Data(payload), idr: flags.contains(.idr), config: flags.contains(.config),
                                 snap: flags.contains(.snap), boardMs: ms)
        } else if current != nil {
            current!.data.append(payload)
        } else {
            return nil  // a middle chunk without its start: skip
        }
        guard flags.contains(.end) else { return nil }
        defer { current = nil }
        return current
    }
}

/// NAL units of an Annex-B buffer (start codes 00 00 01 or 00 00 00 01), without the start codes.
func annexBUnits(_ data: Data) -> [Data] {
    let b = [UInt8](data)
    var starts: [(Int, Int)] = []  // (start code index, payload index)
    var i = 0
    while i + 2 < b.count {
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            let code = i > 0 && b[i - 1] == 0 ? i - 1 : i
            starts.append((code, i + 3))
            i += 3
        } else {
            i += 1
        }
    }
    return starts.enumerated().compactMap { n, s in
        let end = n + 1 < starts.count ? starts[n + 1].0 : b.count
        return end > s.1 ? Data(b[s.1..<end]) : nil
    }
}

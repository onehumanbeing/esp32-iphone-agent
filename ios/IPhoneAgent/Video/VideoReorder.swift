import Foundation

/// Puts Wi-Fi video datagrams back in seq order before the VideoAssembler (docs/ble-protocol.md, "Wi-Fi video").
///
/// UDP can lose or reorder datagrams. A gap is asked for again at once (`nack from to`) and once more after
/// `renack`; if it is still missing after `giveUp`, the chunks after it are delivered anyway (the assembler then
/// waits for a key frame) and the board is asked to start over from the GOP's IDR (`resync`).
struct VideoReorder {
    enum Request: Equatable {
        case nack(UInt16, UInt16)
        case resync
    }
    typealias Output = (chunks: [Data], requests: [Request])

    /// A hole is asked for again every `renack` until `giveUp`; then the board resends the GOP from its IDR,
    /// at most once per `resyncGap`. A congested link loses resends too: giving up after one renack (0.25 s)
    /// restarted a multi-MB GOP four times a second and the screen never came (2026-10-19 14:51 log).
    var renack = 0.08
    var giveUp = 1.0
    var resyncGap = 2.0
    private(set) var nacks = 0, recovered = 0, lost = 0
    private var expect: UInt16?
    private var pending: [UInt16: Data] = [:]
    private var gapSince: Double?
    private var lastNack = 0.0
    private var lastResync = -Double.infinity

    mutating func reset() {
        expect = nil
        pending = [:]
        gapSince = nil
    }

    /// One datagram; returns the chunks now in order, and what to ask the board for.
    mutating func add(_ chunk: Data, at t: Double) -> Output {
        guard chunk.count >= 3 else { return ([], []) }
        let seq = UInt16(chunk[chunk.startIndex]) | UInt16(chunk[chunk.startIndex + 1]) << 8
        let next = expect ?? seq
        let ahead = seq &- next
        guard ahead < 0x8000 else { return ([], []) }  // already delivered (a duplicate or a late resend)
        if ahead > 0x4000 { reset(); return add(chunk, at: t) }  // far ahead: the board restarted its numbering
        expect = next
        pending[seq] = chunk
        return drain(at: t)
    }

    /// Call every ~20 ms: repeats a nack, or gives up on a gap.
    mutating func tick(at t: Double) -> Output {
        guard let since = gapSince, let next = expect, let first = firstPending else { return ([], []) }
        if t - since >= giveUp && t - lastResync >= resyncGap {
            lost += 1
            lastResync = t
            gapSince = nil
            expect = first
            let out = drain(at: t)
            return (out.chunks, [.resync] + out.requests)
        }
        if t - lastNack >= renack {
            lastNack = t
            nacks += 1
            return ([], [.nack(next, first &- 1)])
        }
        return ([], [])
    }

    /// The nearest buffered chunk after the gap.
    private var firstPending: UInt16? {
        guard let next = expect else { return nil }
        return pending.keys.min { ($0 &- next) < ($1 &- next) }
    }

    private mutating func drain(at t: Double) -> Output {
        var out: [Data] = []
        while let next = expect, let c = pending.removeValue(forKey: next) {
            out.append(c)
            expect = next &+ 1
            if gapSince != nil { recovered += 1; gapSince = nil }
        }
        guard gapSince == nil, let next = expect, let first = firstPending else { return (out, []) }
        gapSince = t  // a new gap: ask for it right away
        lastNack = t
        nacks += 1
        return (out, [.nack(next, first &- 1)])
    }
}

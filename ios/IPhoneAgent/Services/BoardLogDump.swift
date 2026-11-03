import Foundation

/// The board's recent log, kept in its RAM (firmware `logs <offset> <max>`), read a page at a time so a problem
/// on a board plugged into the phone can be looked into without a serial cable.
enum BoardLogDump {
    /// The whole log, or nil with no board or with firmware that has no `logs` (0.2.2 and older).
    @MainActor static func read(_ device: HIDDevice, page: Int = 120, maxPages: Int = 100) async -> String? {
        guard device.connected else { return nil }
        var from = 0, text = ""
        for _ in 0..<maxPages {
            guard let reply = try? await device.send("logs \(from) \(page)"), let p = parse(reply) else {
                return text.isEmpty ? nil : text
            }
            text += p.text
            if p.next >= p.end || p.next == from { break }
            from = p.next
        }
        return text
    }

    /// The board's last reset reason and crash ("rst usb, last dump: none"), or nil.
    @MainActor static func crash(_ device: HIDDevice) async -> String? {
        guard device.connected else { return nil }
        return try? await device.send("crash")
    }

    /// "<next> <end> <text>" (after "ok"), with '\n' and '\\' escaped by the board.
    static func parse(_ reply: String) -> (next: Int, end: Int, text: String)? {
        let parts = reply.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let next = Int(parts[0]), let end = Int(parts[1]) else { return nil }
        return (next, end, unescape(parts.count > 2 ? String(parts[2]) : ""))
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaped = false
        for c in s {
            if escaped { out.append(c == "n" ? "\n" : c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }
}

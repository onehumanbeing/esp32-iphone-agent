import Foundation

/// A rolling text log in Documents/debug.log (pull it with `devicectl device copy from … appDataContainer`
/// or share it from About › Logs). One timestamped line per event; at 2 MB it rolls to debug.1.log.
/// Secrets are redacted before writing.
enum DebugLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")
    private static let old = url.deletingLastPathComponent().appendingPathComponent("debug.1.log")
    private static let limit = 2_000_000
    private static let queue = DispatchQueue(label: "debug-log")
    nonisolated(unsafe) private static var secrets: [String] = []
    private static let lock = NSLock()
    /// Each (redacted) line also goes here, on the caller's thread (the app relays it to the Mac harness).
    nonisolated(unsafe) static var relay: ((String) -> Void)?
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Strings never to write (e.g. the API key); replaced by "‹redacted›".
    static func redact(_ values: [String]) {
        let keep = values.filter { $0.count >= 6 }
        lock.lock(); secrets = keep; lock.unlock()
    }

    /// The last n lines of debug.log (after pending writes).
    static func tail(_ n: Int) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return Array(text.split(separator: "\n").suffix(max(0, n)).map(String.init))
        }
    }

    static func write(_ text: String) {
        let time = Date()
        lock.lock(); let hidden = secrets; lock.unlock()
        var line = text
        for s in hidden { line = line.replacingOccurrences(of: s, with: "‹redacted›") }
        relay?(line)
        queue.async {
            let data = Data("\(stamp.string(from: time)) \(line)\n".utf8)
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > limit {
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                // The throwing calls: the old seekToEndOfFile()/write(_:) raise an ObjC exception on an I/O
                // error, which aborted the app (TestFlight 1.0.1 (9), C3). A lost log line is fine.
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

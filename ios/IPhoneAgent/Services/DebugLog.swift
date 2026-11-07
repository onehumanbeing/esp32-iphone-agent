import Foundation

/// A rolling text log in Documents/debug.log (pull it with `devicectl device copy from … appDataContainer`
/// or share it from About › Logs). One timestamped line per event; at 2 MB it rolls to debug.1.log.
/// Secrets are redacted before writing.
enum DebugLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")
    private static let old = url.deletingLastPathComponent().appendingPathComponent("debug.1.log")
    private static let limit = 2_000_000
    /// The last lines only, for the harness: copying the whole 2 MB log every 20 s over Wi-Fi, beside mirroring and a
    /// run, timed out for 11 minutes and the run went unwatched (2026-11-06).
    static let recent = url.deletingLastPathComponent().appendingPathComponent("debug.recent.log")
    private static let recentLimit = 256_000, recentKeep = 64_000
    private static let queue = DispatchQueue(label: "debug-log")
    nonisolated(unsafe) private static var secrets: [String] = []
    private static let lock = NSLock()
    /// Each (redacted) line also goes here, on the caller's thread (the app relays it to the Mac harness).
    nonisolated(unsafe) static var relay: ((String) -> Void)?
    /// Each stamped line, on the log queue (Debug builds: the harness link to the Mac, HarnessLink).
    nonisolated(unsafe) static var live: ((String) -> Void)?
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

    private static func append(_ data: Data, to file: URL) {
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    static func write(_ text: String) {
        let time = Date()
        lock.lock(); let hidden = secrets; lock.unlock()
        var line = text
        for s in hidden { line = line.replacingOccurrences(of: s, with: "‹redacted›") }
        relay?(line)
        queue.async {
            let stamped = "\(stamp.string(from: time)) \(line)"
            live?(stamped)
            let data = Data((stamped + "\n").utf8)
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > limit {
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            append(data, to: url)
            if let size = (try? fm.attributesOfItem(atPath: recent.path)[.size]) as? Int, size > recentLimit,
               let all = try? Data(contentsOf: recent), let cut = all.dropFirst(all.count - recentKeep).firstIndex(of: 10) {
                try? all[(cut + 1)...].write(to: recent)
            }
            append(data, to: recent)
        }
    }
}

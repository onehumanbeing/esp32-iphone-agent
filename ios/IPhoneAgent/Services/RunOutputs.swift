import Foundation

/// What a run saved in the agent's files (Documents/memory), read from its own `file` and `snap` steps: their
/// results say "ok: created results/x/README.md (812 bytes)", "ok: saved …", "ok: renamed A to B", "ok: deleted …".
/// Nothing extra is stored; files deleted since are left out.
enum RunOutputs {
    /// Files the run wrote that are still there, in the order first written; paths relative to Documents/memory.
    static func files(_ run: Run, root: URL = MemoryFiles.root) -> [String] {
        var order: [String] = []
        for step in run.steps where ["file", "snap"].contains(step.name) {
            guard let reason = step.action["reason"]?.str, reason.hasPrefix("ok: ") else { continue }
            let said = String(reason.dropFirst(4))
            if let path = written(said).map(Self.current) {
                if !order.contains(path) { order.append(path) }
            } else if said.hasPrefix("deleted ") {
                let gone = Self.current(String(said.dropFirst(8)))
                order.removeAll { $0 == gone || $0.hasPrefix(gone + "/") }
            } else if said.hasPrefix("renamed "), let range = said.range(of: " to ") {
                let from = Self.current(String(said[said.index(said.startIndex, offsetBy: 8)..<range.lowerBound]))
                let to = Self.current(String(said[range.upperBound...]))
                order = order.map { $0 == from ? to : $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 }
            }
        }
        return order.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    /// What to show for a run: its result folders (results/<name>), and any file it wrote outside one.
    static func items(_ run: Run, root: URL = MemoryFiles.root) -> [String] {
        var out: [String] = []
        for path in files(run, root: root) {
            let item = folder(of: path) ?? path
            if !out.contains(item) { out.append(item) }
        }
        return out
    }

    /// The folder a saved file is shown by: "results/orders/page-01.jpg" -> "results/orders", "orders/page-01.jpg"
    /// (a result kept outside results/) -> "orders"; a file at the top or right in results/ -> nil, itself.
    static func folder(of path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? String(parts[0]) : nil
    }

    /// Where a path a run wrote is now: runs before 2026-11-17 wrote "results/NAME/…" inside memory/, and those
    /// folders moved to the top level (FilesLayout.moveResultsUp).
    static func current(_ path: String) -> String {
        path.hasPrefix("results/") ? String(path.dropFirst("results/".count)) : path
    }

    /// The newest run (of those loaded) that wrote into `item` (a path relative to Documents/memory).
    static func source(of item: String, in runs: [Run], root: URL = MemoryFiles.root) -> Run? {
        runs.first { items($0, root: root).contains(item) }
    }

    /// "created results/x/README.md (812 bytes)" -> "results/x/README.md"
    static func written(_ said: String) -> String? {
        for verb in ["created ", "edited ", "saved "] where said.hasPrefix(verb) {
            var path = String(said.dropFirst(verb.count))
            while path.hasPrefix("./") { path.removeFirst(2) }
            if let size = path.range(of: " (", options: .backwards) { path = String(path[..<size.lowerBound]) }
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

import Foundation

/// The one folder a run's results go to, fixed when it starts. Henry 2026-11-18: a run put its screenshots in
/// "orders/", then in an earlier run's folder of the same name, and its notes followed, so two runs' notes mixed
/// in one notes.md. Now every snap and file write of the run lands in its own folder, unless the goal names
/// another folder that was already there when the run started. The write's result says where it went.
enum RunFolder {
    /// Where `path` goes: inside `folder`, kept as it is only when it is already there, or its top folder was there
    /// before the run (`earlier`) and the goal names it.
    static func place(_ path: String, in folder: String, goal: String, earlier: Set<String> = []) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") || p.hasPrefix("/") { p.removeFirst(p.hasPrefix("/") ? 1 : 2) }
        if p.hasPrefix("results/") { p.removeFirst("results/".count) }
        let parts = p.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return p.isEmpty ? p : folder + "/" + p }
        if parts[0] == folder || earlier.contains(parts[0]) && goal.contains(parts[0]) { return p }
        return folder + "/" + parts[1]
    }

    /// A `snap PATH [box]` line with its path placed.
    static func snap(_ line: String, in folder: String, goal: String, earlier: Set<String> = []) -> String {
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return line }
        words[0] = place(first, in: folder, goal: goal, earlier: earlier)
        return words.joined(separator: " ")
    }

    /// A `file {JSON}` line with the paths it writes placed (a view reads anywhere).
    static func file(_ line: String, in folder: String, goal: String, earlier: Set<String> = []) -> String {
        guard let data = line.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["command"] as? String) != "view" else { return line }
        for key in ["path", "old_path", "new_path"] {
            if let p = json[key] as? String { json[key] = place(p, in: folder, goal: goal, earlier: earlier) }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return line }
        return text
    }

    /// The top-level folders in the agent's files now.
    static func folders(root: URL = MemoryFiles.root) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }

    /// The run's folder from its own steps (a resumed run): the first one it wrote into.
    static func from(_ steps: [JObject]) -> String? {
        for step in steps where ["file", "snap"].contains(step["action"]?.str ?? "") {
            guard let reason = step["reason"]?.str, reason.hasPrefix("ok: "),
                  let path = RunOutputs.written(String(reason.dropFirst(4))).map(RunOutputs.current),
                  let top = RunOutputs.folder(of: path) else { continue }
            return top
        }
        return nil
    }
}

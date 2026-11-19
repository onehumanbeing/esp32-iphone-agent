import Foundation

/// The agent's files: the Files tab's top level (`Documents`), where each result is a folder the user sees at once
/// (Henry 2026-11-17: under memory/results nobody found them). The app's own folders there (memory, logs, traces …,
/// FilesLayout) are not the agent's: it cannot see, write or delete them.
///
/// The `file` action uses the command set of Anthropic's memory tool (view, create, str_replace, insert, delete,
/// rename), so models already know it. `snap` saves the screen, or a box of it, as a .jpg. A result is a folder with a
/// Markdown README that shows its images by relative path, so it opens anywhere (the app, Files, Obsidian, GitHub).
/// Paths cannot leave the folder (FileSandbox). MEMORY.md stays the user's: the agent changes it only by `remember`.
struct MemoryFiles {
    let box: FileSandbox
    /// When this run started: a file last written before it is an earlier run's, and create/snap do not overwrite it.
    var since: Date? = nil

    static var root: URL { AgentFiles.root }
    /// Top-level names that are the app's, not the agent's: hidden from its listings, refused for every command.
    static let reserved: Set<String> = FilesLayout.internalNames.union(["memory", "logs", "developer", "memory.md", PlanCache.folderName.lowercased()])

    static func isReserved(_ path: String) -> Bool {
        guard let first = path.split(separator: "/").first.map({ String($0).lowercased() }) else { return false }
        return reserved.contains { $0.lowercased() == first } || FilesLayout.internalPrefixes.contains { first.hasPrefix($0) }
    }
    static let reservedRefusal = "refused: that is the app's own folder; keep results in a folder of their own"

    static func open(since: Date? = nil) -> MemoryFiles {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MemoryFiles(box: FileSandbox(root: root), since: since)
    }

    static let commands = "view, create, str_replace, insert, delete, rename"
    static let viewLimit = 12_000

    /// One `file` action: a line of JSON such as {"command":"view","path":"results"}. The text the model sees next.
    func run(_ json: String) -> String {
        // the object only, if a model wrapped it in quotes or backticks
        var object = Substring()
        if let from = json.firstIndex(of: "{"), let to = json.lastIndex(of: "}"), from < to { object = json[from...to] }
        guard let data = String(object).data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = args["command"] as? String else {
            return #"refused: file needs one line of JSON with a command, e.g. {"command":"view","path":""}"#
        }
        let text = { (key: String) in args[key] as? String }
        for key in ["path", "old_path", "new_path"] {
            guard let raw = text(key), Self.isReserved(Self.relative(raw)) else { continue }
            if isMemoryFile(Self.relative(raw)) { if command == "view" { continue }; return Self.memoryRefusal }  // reading it is fine
            return Self.reservedRefusal
        }
        switch command {
        case "view":
            return view(text("path") ?? "", range: args["view_range"] as? [Int])
        case "create":
            guard let path = text("path"), let body = text("file_text") else { return "refused: create needs path and file_text" }
            return create(path, body)
        case "str_replace":
            guard let path = text("path"), let old = text("old_str") else { return "refused: str_replace needs path and old_str" }
            return replace(path, old, text("new_str") ?? "")
        case "insert":
            guard let path = text("path"), let line = args["insert_line"] as? Int, let body = text("insert_text") else {
                return "refused: insert needs path, insert_line and insert_text"
            }
            return insert(path, line, body)
        case "delete":
            guard let path = text("path") else { return "refused: delete needs path" }
            return delete(path)
        case "rename":
            guard let from = text("old_path"), let to = text("new_path") else { return "refused: rename needs old_path and new_path" }
            return rename(from, to)
        default:
            return "refused: unknown command \(command) (\(Self.commands))"
        }
    }

    /// `snap PATH [X1 Y1 X2 Y2]`: the screen, or the box in 0-1000 screen units, saved as a .jpg.
    func snap(_ frame: Data?, _ line: String) -> String {
        let (first, rest) = FileTool.tokens(line)
        guard !first.isEmpty else { return "refused: snap needs a file name, e.g. snap orders-20261117/page-01.jpg" }
        var path = Self.relative(first)
        guard !Self.isReserved(path) else { return Self.reservedRefusal }
        if (path as NSString).pathExtension.isEmpty { path += ".jpg" }
        guard FileSandbox.isImageName(path) else { return "refused: snap saves a .jpg" }
        guard let frame else { return "refused: no screen to save" }
        if let refusal = earlierRun(path) { return refusal }
        let n = rest.compactMap { Int($0) }
        guard n.count >= 4 else { return write(frame, to: path, verb: "saved") }  // the whole screen, as it came
        let cut = (n[0], n[1], n[2] - n[0], n[3] - n[1])
        guard cut.2 > 0, cut.3 > 0 else { return "refused: the box needs X1 < X2 and Y1 < Y2" }
        guard let jpeg = FileSandbox.cropJPEG(frame, x: cut.0, y: cut.1, w: cut.2, h: cut.3) else {
            return "refused: could not save the screen"
        }
        return write(jpeg, to: path, verb: "saved")
    }

    // MARK: - commands

    private func view(_ raw: String, range: [Int]?) -> String {
        let path = Self.relative(raw)
        guard let url = box.resolve(path) else { return "refused: \(raw) is outside your files" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "refused: no such file: \(path)" }
        if isDir.boolValue { return "ok: \(path.isEmpty ? "." : path)/\n" + listing(url, depth: 2, indent: "") }
        if FileSandbox.isImageName(path) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "ok: \(path) is an image (\(size) bytes); show it in Markdown with ![](\(url.lastPathComponent))"
        }
        guard let body = box.textFile(path) else { return "refused: \(path) is not a text file" }
        let lines = body.components(separatedBy: "\n")
        let from = max(1, range?.first ?? 1)
        let end = range.flatMap { $0.count > 1 ? $0[1] : nil } ?? -1  // -1: to the end, as the memory tool has it
        let to = end > 0 ? min(end, lines.count) : lines.count
        guard from <= to else { return "refused: view_range is outside the file (\(lines.count) lines)" }
        let numbered = (from...to).map { String(format: "%6d\t", $0) + lines[$0 - 1] }.joined(separator: "\n")
        return "ok: \(path)\n" + Self.capped(numbered)
    }

    private func create(_ raw: String, _ body: String) -> String {
        let path = Self.relative(raw)
        if let refusal = refuseText(path) { return refusal }
        guard body.utf8.count <= 200_000 else { return "refused: file_text is too large" }
        if let refusal = earlierRun(path) { return refusal }
        return write(Data(body.utf8), to: path, verb: "created") + missingImages(body, in: path)
    }

    private func replace(_ raw: String, _ old: String, _ new: String) -> String {
        let path = Self.relative(raw)
        if let refusal = refuseText(path) { return refusal }
        guard let body = box.textFile(path) else { return "refused: no such text file: \(path)" }
        let count = body.components(separatedBy: old).count - 1
        guard !old.isEmpty, count == 1 else {
            return count == 0 ? "refused: old_str is not in \(path)" : "refused: old_str is in \(path) \(count) times; make it unique"
        }
        return write(Data(body.replacingOccurrences(of: old, with: new).utf8), to: path, verb: "edited")
    }

    private func insert(_ raw: String, _ line: Int, _ text: String) -> String {
        let path = Self.relative(raw)
        if let refusal = refuseText(path) { return refusal }
        guard let body = box.textFile(path) else { return "refused: no such text file: \(path)" }
        var lines = body.components(separatedBy: "\n")
        guard (0...lines.count).contains(line) else { return "refused: insert_line must be 0-\(lines.count)" }
        lines.insert(contentsOf: text.components(separatedBy: "\n"), at: line)
        return write(Data(lines.joined(separator: "\n").utf8), to: path, verb: "edited")
    }

    private func delete(_ raw: String) -> String {
        let path = Self.relative(raw)
        guard !path.isEmpty else { return "refused: won't delete the whole folder" }
        guard !isMemoryFile(path) else { return Self.memoryRefusal }
        guard let url = box.resolve(path), FileManager.default.fileExists(atPath: url.path) else { return "refused: no such file: \(path)" }
        do { try FileManager.default.removeItem(at: url) } catch { return "refused: \(error.localizedDescription)" }
        return "ok: deleted \(path)"
    }

    private func rename(_ rawFrom: String, _ rawTo: String) -> String {
        let from = Self.relative(rawFrom), to = Self.relative(rawTo)
        guard !isMemoryFile(from), !isMemoryFile(to) else { return Self.memoryRefusal }
        guard !from.isEmpty, let src = box.resolve(from), FileManager.default.fileExists(atPath: src.path) else {
            return "refused: no such file: \(from)"
        }
        guard !to.isEmpty, let dest = box.resolve(to) else { return "refused: \(rawTo) is outside your files" }
        guard !FileManager.default.fileExists(atPath: dest.path) else { return "refused: \(to) already exists" }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            return "refused: \(error.localizedDescription)"
        }
        return "ok: renamed \(from) to \(to)"
    }

    // MARK: - helpers

    /// A file an earlier run wrote is not overwritten by create or snap: the model decides whether this run adds to
    /// that result (another file name, or str_replace) or is a separate one (a new folder).
    func earlierRun(_ path: String) -> String? {
        guard let since, let url = box.resolve(path),
              let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              written < since else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return "refused: \(path) is from an earlier run (\(Self.stamp(written))). If this run adds to that result, save "
            + "under another name (e.g. page-02.jpg) or edit its README with str_replace; if it is a separate result, "
            + "use a new folder (e.g. \(folder.isEmpty ? "name" : folder)-\(Self.day(Date())))"
    }

    /// A README's images that are not next to it: where they are, so the model can move them in.
    func missingImages(_ markdown: String, in path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let linked = Self.imageLinks(markdown).filter { !$0.contains("://") }
        let missing = linked.filter { link in
            box.resolve(folder.isEmpty ? link : folder + "/" + link).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        }
        guard !missing.isEmpty else { return "" }
        return "; missing next to it: " + missing.prefix(5).map { name in
            let found = find((name as NSString).lastPathComponent)
            return name + (found.map { " (it is at \($0): rename it into \(folder.isEmpty ? "this folder" : folder))" } ?? " (not saved)")
        }.joined(separator: ", ")
    }

    static func imageLinks(_ markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { Range($0.range(at: 1), in: markdown).map { String(markdown[$0]) } }
    }

    /// The first file with this name anywhere in the folder (relative path), newest first.
    private func find(_ name: String) -> String? {
        guard let items = FileManager.default.enumerator(at: box.root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let rootPath = box.root.standardizedFileURL.path
        let hits = items.compactMap { $0 as? URL }.filter { $0.lastPathComponent == name }
        let newest = hits.max { a, b in
            let d = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
            return d(a) < d(b)
        }
        return newest.map { String($0.standardizedFileURL.path.dropFirst(rootPath.count + 1)) }
    }

    /// The result folders there are (newest first, at most `limit`): name, last change, README title. For the run's
    /// prompt, so the model can tell a result to add to from one to start anew.
    func results(limit: Int = 8) -> String {
        guard let items = try? FileManager.default.contentsOfDirectory(at: box.root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles]) else { return "" }
        let folders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !Self.isReserved($0.lastPathComponent) }
            .map { url -> (URL, Date) in (url, Self.lastChange(url)) }
            .sorted { $0.1 > $1.1 }
        return folders.prefix(limit).map { url, changed in
            let title = (try? String(contentsOf: url.appendingPathComponent("README.md"), encoding: .utf8))?
                .split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { " — " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(60) } ?? ""
            return "- \(url.lastPathComponent)/ (\(Self.stamp(changed)))\(title)"
        }.joined(separator: "\n")
    }

    private static func lastChange(_ folder: URL) -> Date {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        let dates = (items?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } }) ?? []
        return dates.max() ?? .distantPast
    }

    static func stamp(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm") }
    static func day(_ date: Date) -> String { format(date, "yyyyMMdd") }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private func refuseText(_ path: String) -> String? {
        if isMemoryFile(path) { return Self.memoryRefusal }
        let ext = (path as NSString).pathExtension.lowercased()
        guard FileSandbox.textExtensions.contains(ext) else { return "refused: text files only (.md, .txt, .csv, .json); images come from snap" }
        return nil
    }

    private func write(_ data: Data, to path: String, verb: String) -> String {
        guard let url = box.resolve(path), url != box.root else { return "refused: \(path) is outside your files" }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return "refused: \(error.localizedDescription)"
        }
        return "ok: \(verb) \(path) (\(data.count) bytes)"
    }

    private func listing(_ url: URL, depth: Int, indent: String) -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.standardizedFileURL != box.root.appendingPathComponent($0.lastPathComponent).standardizedFileURL
                || !Self.isReserved($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !items.isEmpty else { return indent + "(empty)" }
        let rows = items.prefix(100).map { item -> String in
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { return "\(indent)\(item.lastPathComponent)\t\(values?.fileSize ?? 0)" }
            let inner = depth > 1 ? "\n" + listing(item, depth: depth - 1, indent: indent + "  ") : ""
            return "\(indent)\(item.lastPathComponent)/" + inner
        }
        return Self.capped(rows.joined(separator: "\n"))
    }

    /// Models trained on the memory tool write `/memories/...`: the same folder here.
    static func relative(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") { path.removeFirst() }
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if ["memories", "memory"].contains(first[0].lowercased()) {  // a whole name only: not memory.md
            path = first.count > 1 ? String(first[1]) : ""
        }
        // results used to be a folder of their own (memory/results/NAME): a model that still writes it lands at the top
        while path.lowercased().hasPrefix("results/") { path.removeFirst("results/".count) }
        if path.lowercased() == "results" { path = "" }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path == "." ? "" : path
    }

    /// MEMORY.md however it is written (`./MEMORY.md`, `results/../memory.md`): by where the path lands.
    func isMemoryFile(_ path: String) -> Bool {
        guard let url = box.resolve(path) else { return false }
        let p = url.standardizedFileURL.path.lowercased()
        return [box.root.appendingPathComponent("MEMORY.md"), box.root.appendingPathComponent("memory/MEMORY.md")]
            .contains { $0.standardizedFileURL.path.lowercased() == p }
    }
    static let memoryRefusal = "refused: MEMORY.md is the user's; keep facts with remember, results in their own folder"

    static func capped(_ text: String) -> String {
        text.count <= viewLimit ? text : text.prefix(viewLimit) + "\n…(cut: view a smaller view_range)"
    }
}

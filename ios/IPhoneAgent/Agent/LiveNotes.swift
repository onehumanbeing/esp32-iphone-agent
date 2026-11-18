import Foundation

/// The run's notes, on disk as they are made: notes.md in the run's result folder, so the user can check them in
/// Files while the run goes on, and nothing is lost when it stops. 2026-11-17: four orders noted over 19 minutes
/// lived only in the notebook; the run was stopped before its README and the result was empty.
///
/// The folder: the one this run already wrote into (file / snap), else a new one named after the task and the day.
/// When the run later writes its result somewhere else, notes.md moves there (if its own folder holds nothing else).
struct LiveNotes {
    private(set) var folder: String?
    private var created = false  // this run made `folder` for the notes alone
    private(set) var count = 0
    private var lastShot: (data: Data, name: String)?  // several notes off one screen share its image
    private var entries: [(text: String, image: String?)] = []
    private var head = ""
    static let file = "notes.md"

    /// One note: added (or put in place of the earlier note it completes), the file and folder made on the first. `shot`: the screen it was read off, saved next to
    /// notes.md and shown under the note (2026-11-17: a paused run left notes.md alone, no screenshots).
    /// The run's folder, fixed at its start (RunFolder): the notes go there and never move.
    /// A resumed run picks up the notes.md already there instead of writing over it (2026-11-18: a Continue after a
    /// reinstall rewrote the file and the run's earlier orders were gone from it).
    mutating func use(_ runFolder: String, files: MemoryFiles? = nil) {
        (folder, created) = (runFolder, false)
        guard entries.isEmpty, let files, let url = files.box.resolve(runFolder + "/" + Self.file),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        (head, entries) = Self.parse(text)
        count = max(count, Self.lastImageNumber(in: url.deletingLastPathComponent()))
    }

    /// notes.md back into its top and its notes; the closing line of a stopped run is dropped.
    static func parse(_ text: String) -> (head: String, entries: [(text: String, image: String?)]) {
        var head = "", entries: [(text: String, image: String?)] = [], inBody = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- ") {
                inBody = true
                entries.append((String(line.dropFirst(2)), nil))
            } else if inBody, let last = entries.indices.last,
                      let m = line.range(of: #"^\s+!\[\]\((.+)\)$"#, options: .regularExpression) {
                entries[last].image = String(line[m]).trimmingCharacters(in: .whitespaces).dropFirst(4).dropLast().description
            } else if !inBody {
                head += line + "\n"
            }
        }
        if !head.hasSuffix("\n\n") { head += "\n" }
        return (entries.isEmpty ? "" : head, entries)
    }

    private static func lastImageNumber(in dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { n -> Int? in
            guard n.hasPrefix("note-"), n.hasSuffix(".jpg") else { return nil }
            return Int(n.dropFirst(5).dropLast(4))
        }.max() ?? 0
    }

    mutating func add(_ text: String, task: String, name: String?, since: Date, files: MemoryFiles, shot: Data? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // one that says less about an item already kept is left out
        let place = Notebook.place(text, in: entries.map(\.text))
        guard !text.isEmpty, place != .known else { return }
        if folder == nil {
            folder = Self.newFolder(name ?? task, since: since, files: files)
            created = true
        }
        guard let folder, let url = files.box.resolve(folder + "/" + Self.file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if head.isEmpty { head = Self.head(name ?? task, since: since, chinese: HanTyper.isHan(task)) }
        count += 1
        var image: String?
        if let shot {
            if let last = lastShot, last.data == shot {
                image = last.name
            } else {
                let name = String(format: "note-%02d.jpg", count)
                if (try? shot.write(to: url.deletingLastPathComponent().appendingPathComponent(name))) != nil {
                    lastShot = (shot, name)
                    image = name
                }
            }
        }
        // a note that completes an earlier one replaces it in place (Notebook.place)
        if case .replaces(let i) = place {
            let dropped = entries[i].image
            entries[i] = (text, image ?? dropped)
            if let dropped, dropped != entries[i].image, !entries.contains(where: { $0.image == dropped }) {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(dropped))
            }
        } else {
            entries.append((text, image))
        }
        write(to: url)
    }

    /// The whole file from the notes kept: rewritten on every note, so a completed note can take an earlier one's place.
    private func write(to url: URL, closing: String = "") {
        let body = entries.map { "- \($0.text)\n" + ($0.image.map { "  ![](\($0))\n" } ?? "") }.joined()
        try? Data((head + body + closing).utf8).write(to: url)
    }

    /// The run wrote `path` (a file or snap that worked): its folder is the result's. Notes so far move there.
    mutating func wrote(_ path: String, files: MemoryFiles) {
        guard let target = RunOutputs.folder(of: path), target != folder else { return }
        defer { (folder, created) = (target, false) }
        guard let from = folder, created, let old = files.box.resolve(from), let new = files.box.resolve(target) else { return }
        let fm = FileManager.default
        let notes = old.appendingPathComponent(Self.file)
        let own = { (f: String) in f == Self.file || f.hasPrefix("note-") && f.hasSuffix(".jpg") }
        let listed = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        let others = listed.filter { !own($0) && !$0.hasPrefix(".") }
        guard fm.fileExists(atPath: notes.path), others.isEmpty else { return }
        var dest = new.appendingPathComponent(Self.file)
        if fm.fileExists(atPath: dest.path) { dest = new.appendingPathComponent("notes-\(MemoryFiles.day(Date())).md") }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: notes, to: dest)) != nil else { return }
        for image in listed where own(image) && image != Self.file && !fm.fileExists(atPath: new.appendingPathComponent(image).path) {
            try? fm.moveItem(at: old.appendingPathComponent(image), to: new.appendingPathComponent(image))
        }
        try? fm.removeItem(at: old)
    }

    /// The run ended: one closing line, so a stopped run's notes say they are not the whole result. In the task's
    /// language and for the person reading the result: no step numbers (Henry 2026-11-17: the file is for users).
    /// `asResult`: the write-up after the hand back did not write a result, so the notes become README.md.
    func finish(done: Bool, task: String, files: MemoryFiles, asResult: Bool = false) {
        guard count > 0, let folder, let url = files.box.resolve(folder + "/" + Self.file),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent()
        if done, !asResult, Self.dropWhenResultWritten(in: dir) { return }
        var notes = self
        notes.shareSnaps(in: dir)
        let readme = dir.appendingPathComponent("README.md")
        let promote = asResult && !FileManager.default.fileExists(atPath: readme.path)
        notes.write(to: promote ? readme : url, closing: "\n" + Self.closing(done: done, at: Date(), chinese: HanTyper.isHan(task)) + "\n")
        if promote { try? FileManager.default.removeItem(at: url) }
    }

    /// A finished run that wrote its own result (README.md, a table) beside notes.md: the notes were the safety net
    /// while it ran, now they only repeat it (Henry 2026-11-18: "notes.md 有点多余"). notes.md goes, and so do note
    /// images the result does not show. A stopped run keeps them: they may be all there is.
    static func dropWhenResultWritten(in dir: URL) -> Bool {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let results = names.filter { $0 != file && !$0.hasPrefix("notes-") && ["md", "markdown", "csv", "txt"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard !results.isEmpty else { return false }
        let shown = results.compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
        try? fm.removeItem(at: dir.appendingPathComponent(file))
        for name in names where name.hasPrefix("note-") && FileSandbox.isImageName(name) && !shown.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        return true
    }

    /// A note's screenshot that the run also saved itself (snap, the same screen): the note points at that file and
    /// its own copy goes (Henry 2026-11-18: note-02.jpg and order1.jpg were the same picture).
    private mutating func shareSnaps(in dir: URL) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { FileSandbox.isImageName($0) && !$0.hasPrefix("note-") }.sorted()
        guard !names.isEmpty else { return }
        var snaps: [Data: String] = [:]
        for name in names { if let d = try? Data(contentsOf: dir.appendingPathComponent(name)), snaps[d] == nil { snaps[d] = name } }
        for e in entries {
            guard let own = e.image, own.hasPrefix("note-"), let d = try? Data(contentsOf: dir.appendingPathComponent(own)),
                  let snap = snaps[d] else { continue }
            for j in entries.indices where entries[j].image == own { entries[j].image = snap }
            try? fm.removeItem(at: dir.appendingPathComponent(own))
        }
    }

    /// The file's top: the result's name and when the run began, in the task's language.
    static func head(_ title: String, since: Date, chinese: Bool) -> String {
        let time = MemoryFiles.stamp(since)
        return chinese ? "# \(title)\n\n\(time) 开始记录，边做边写。\n\n" : "# \(title)\n\nNoted as the run went, from \(time).\n\n"
    }

    static func closing(done: Bool, at: Date, chinese: Bool) -> String {
        let time = String(MemoryFiles.stamp(at).suffix(5))
        if done { return chinese ? "—— \(time) 完成。" : "— Finished at \(time)." }
        return chinese ? "> 这次运行在 \(time) 停止，上面的记录可能不完整。" : "> The run stopped at \(time); the notes above may be incomplete."
    }

    /// A new top-level folder for `title`: its first words (no path characters), then the day; never an earlier one.
    static func newFolder(_ title: String, since: Date, files: MemoryFiles) -> String {
        let cut = title.split(whereSeparator: { "，。,.;；:：\n".contains($0) }).first.map(String.init) ?? title
        let allowed = cut.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        var base = String(allowed).split(separator: "-").joined(separator: "-")
        base = String(base.prefix(24))
        if base.isEmpty || MemoryFiles.isReserved(base) { base = "notes" }
        var name = base + "-" + MemoryFiles.day(since)
        var n = 2
        while let url = files.box.resolve(name), FileManager.default.fileExists(atPath: url.path) {
            name = base + "-" + MemoryFiles.day(since) + "-\(n)"
            n += 1
        }
        return name
    }
}

import Foundation

/// How Documents is laid out for the user (the Files tab): what they see, what each known folder is called, what
/// they may not delete, and the developer folders hidden until Settings › Developer › Show developer files.
///
///     memory/        Memory   MEMORY.md (the Memory page) and results/ (the agent's saved results)
///     Plans/         Plans    one saved plan per intent (PlanCache), editable
///     logs/          Logs     debug logs, crash traces, iOS diagnostics
///     developer/     hidden   harness inbox, screenshots and test firmware
///     traces/ …      hidden   the app's own data behind Runs, Intents and chats
///
/// Names on disk stay English (the agent and the harness use them); only what the list shows is translated.
enum FilesLayout {
    static let developerKey = "developerFiles"
    static var showsDeveloper: Bool { UserDefaults.standard.bool(forKey: developerKey) }

    static var logs: URL { AgentFiles.root.appendingPathComponent("logs", isDirectory: true) }
    static var developer: URL { AgentFiles.root.appendingPathComponent("developer", isDirectory: true) }

    /// Top-level names that are the app's own data or developer tools.
    static let internalNames: Set<String> = [
        "traces", "threads", "recordings", "intent-frames", "developer", "firmware", "demo-recordings",
        "remote-debug-log.json", "Inbox",
    ]
    static let internalPrefixes = ["harness-", "treebench"]

    /// Shown in the list? `relative` is from Documents ("memory/results").
    static func isVisible(_ relative: String, developer: Bool = showsDeveloper) -> Bool {
        if developer { return true }
        let parts = relative.split(separator: "/")
        guard parts.count == 1, let name = parts.first.map(String.init) else { return true }
        return !internalNames.contains(name) && !internalPrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// The folders and file the app relies on: no delete, no rename.
    static func isSystem(_ relative: String) -> Bool {
        ["memory", "memory/memory.md", "logs", "plans"].contains(relative.lowercased())
    }

    static func isMemoryFile(_ relative: String) -> Bool { relative.lowercased() == "memory/memory.md" }

    /// The name the list shows for a known folder; anything else keeps its own name.
    static func displayName(_ relative: String) -> String {
        switch relative {
        case "memory": String(localized: "Memory")
        case "logs": String(localized: "Logs")
        case "developer": String(localized: "Developer")
        case PlanCache.folderName: String(localized: "Plans")
        default: (relative as NSString).lastPathComponent
        }
    }

    /// Where a known item sorts in its folder, before everything else.
    static func rank(_ relative: String) -> Int? {
        ["memory", "memory/MEMORY.md", PlanCache.folderName, "logs", "developer"].firstIndex(of: relative)
    }

    static func symbol(_ relative: String) -> String? {
        switch relative {
        case "memory": "brain.head.profile"
        case "logs": "doc.text.magnifyingglass"
        case PlanCache.folderName: "list.bullet.clipboard"
        case "developer": "hammer"
        default: nil
        }
    }

    // MARK: - one-time move from the old flat layout

    static let logNames = ["debug.log", "debug.1.log", "debug.recent.log", "crash-trace.txt", "board.log", "diagnostics"]
    static let developerNames = ["harness-inbox", "harness-shots"]

    /// Moves logs into logs/ and harness folders into developer/. Run before anything opens a log (app start).
    static func migrate(root: URL = AgentFiles.root) {
        let fm = FileManager.default
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let developer = root.appendingPathComponent("developer", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        // Memory is always there to open, even before the first `remember`
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try? fm.createDirectory(at: memory, withIntermediateDirectories: true)
        moveResultsUp(from: memory.appendingPathComponent("results", isDirectory: true), to: root)
        let memoryFile = memory.appendingPathComponent("MEMORY.md")
        if !fm.fileExists(atPath: memoryFile.path) { fm.createFile(atPath: memoryFile.path, contents: Data()) }
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let target: URL
            if logNames.contains(name) { target = logs }
            else if developerNames.contains(name) || name.hasPrefix("harness-fw-") { target = developer }
            else { continue }
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            move(root.appendingPathComponent(name), into: target)
        }
    }

    /// `item` into `folder`; a folder already there gets the contents, a file already there wins (it is newer).
    /// Results used to live in memory/results (until 2026-11-17): each folder moves to the top level, where the
    /// agent now writes them; a name already taken there gets "-1", "-2" …
    static func moveResultsUp(from old: URL, to root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for item in items {
            var dest = root.appendingPathComponent(item.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) || MemoryFiles.isReserved(dest.lastPathComponent) {
                dest = root.appendingPathComponent("\(item.lastPathComponent)-\(n)")
                n += 1
            }
            try? fm.moveItem(at: item, to: dest)
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty { try? fm.removeItem(at: old) }
    }

    private static func move(_ item: URL, into folder: URL) {
        let fm = FileManager.default
        let dest = folder.appendingPathComponent(item.lastPathComponent)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir) {
            if isDir.boolValue {
                for child in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    move(child, into: dest)
                }
            }
            try? fm.removeItem(at: item)
        } else {
            try? fm.moveItem(at: item, to: dest)
        }
    }
}

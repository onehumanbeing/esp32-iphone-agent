import CryptoKit
import Foundation

/// An intent's first plan, kept so its next runs start without waiting for the planner (Henry 2026-11-18). One
/// Markdown file per intent in the Files tab's Plans folder (PlanFile), so the user sees it and can edit it.
/// - The app's own plan goes stale after 7 days, when a run with it fails, or when the intent's words change.
/// - A plan the user edited is theirs: never overwritten, expired or dropped on a failure; only other words for the
///   intent, or deleting the file, ends it.
/// The agent's file tool cannot touch the folder (MemoryFiles.reserved).
@MainActor
final class PlanCache: ObservableObject {
    struct Entry: Equatable {
        var file: PlanFile
        var url: URL
        var plan: String { file.plan }
        var run: String { file.run }
        var saved: Date { file.saved }
        var edited: Bool { file.edited }
    }

    nonisolated static let folderName = "Plans"
    static var defaultFolder: URL { AgentFiles.root.appendingPathComponent(folderName, isDirectory: true) }
    /// A file in the Plans folder (`relative` from Documents)?
    nonisolated static func holds(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        return parts.count == 2 && parts[0].lowercased() == folderName.lowercased()
    }
    static let maxAge: TimeInterval = 7 * 24 * 3600

    @Published private(set) var entries: [UUID: Entry] = [:]
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        reload()
    }

    nonisolated static func key(_ intent: SavedTask) -> String {
        let words = intent.prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + (intent.kind ?? "")
        return SHA256.hash(data: Data(words.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Read the folder again (the user may have edited, deleted or added a file in Files).
    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        var found: [UUID: Entry] = [:]
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let file = PlanFile.parse(text) else { continue }
            if let other = found[file.intent], other.saved > file.saved { continue }  // a copy: the newer wins
            found[file.intent] = Entry(file: file, url: url)
        }
        if found != entries { entries = found }
    }

    /// The plan a run of `intent` starts from, if it still fits.
    func entry(for intent: SavedTask, now: Date = Date()) -> Entry? {
        guard let e = entries[intent.id], e.file.key == Self.key(intent), !e.plan.isEmpty,
              e.edited || now.timeIntervalSince(e.saved) < Self.maxAge else { return nil }
        return e
    }

    /// A file is there but no longer used: the intent's words changed, or the app's plan is too old.
    func stale(for intent: SavedTask, now: Date = Date()) -> Entry? {
        guard let e = entries[intent.id], entry(for: intent, now: now) == nil else { return nil }
        return e
    }

    func save(_ plan: String, for intent: SavedTask, run: String, now: Date = Date()) {
        let plan = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else { return }
        let old = entries[intent.id]
        if let old, old.file.newer || (old.edited && old.file.key == Self.key(intent)) { return }  // not ours to replace
        var file = PlanFile(intent: intent, plan: plan, run: run, saved: now)
        file.extra = old?.file.extra ?? []
        let url = old?.url ?? freeURL(intent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? Data(file.text.utf8).write(to: url, options: .atomic)) != nil else { return }
        entries[intent.id] = Entry(file: file, url: url)
    }

    /// The user's edit of a plan file's body (PlanFilePage): the header stays, so the plan now counts as theirs.
    @discardableResult func update(_ url: URL, plan: String) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8), var file = PlanFile.parse(text), !file.newer
        else { return false }
        file.plan = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Data(file.text.utf8).write(to: url, options: .atomic)) != nil else { return false }
        reload()
        return true
    }

    /// The user's "Forget": the file goes, edited or not.
    func forget(_ id: UUID) {
        guard let e = entries.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: e.url)
    }

    /// The app's own drop (a run with the plan failed): a plan the user edited stays.
    func drop(_ id: UUID) {
        guard let e = entries[id], !e.edited, !e.file.newer else { return }
        forget(id)
    }

    /// A run marked bad: drop the app's plans that came from it.
    func forget(run: String) {
        entries.values.filter { $0.run == run }.forEach { drop($0.file.intent) }
    }

    private func freeURL(_ intent: SavedTask) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines).union(.controlCharacters)
        var name = intent.name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        name = String(name.prefix(60))
        if name.isEmpty || name.hasPrefix(".") { name = "Plan" }
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name + ".md")
        if fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(intent.id.uuidString.prefix(4)).md")
        }
        return url
    }
}

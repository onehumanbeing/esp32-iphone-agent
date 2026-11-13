import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let esp32Intent = UTType(exportedAs: "com.onehumanbeing.esp32agent.intent", conformingTo: .json)
}

/// Saved intents as a shareable .esp32intent file (JSON): name, prompt, icon, checklist and recorded steps.
/// Reference screens only when the user asks for them; never run history or run ids.
enum IntentArchive {
    static let format = 1
    static let fileExtension = "esp32intent"
    static let maxBytes = 25_000_000

    struct File: Codable, Equatable {
        var format: Int
        var note: String?  // for whoever opens the file, e.g. how to treat the screenshots
        var intents: [Item]
    }

    struct Item: Codable, Equatable {
        var name: String
        var prompt: String
        var icon: String?
        var hints: [String]?
        var steps: [Step]?
        var until: String?  // a script's "repeat until" condition (ScriptRunner)
        var maxLoops: Int?
        var color: String?  // IntentTint name (2026-11-12); older files have none
    }

    struct Step: Codable, Equatable {
        var action: String  // JSON object, like RecordedStep
        var sure: Bool
        var frame: String?  // base64 JPEG
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func item(_ intent: SavedTask, screenshots: Bool, frame: (UUID, String?) -> Data? = IntentFrames.data) -> Item {
        Item(name: intent.name, prompt: intent.prompt, icon: intent.icon, hints: intent.hints,
             steps: intent.steps.map { steps in steps.map {
                 Step(action: $0.action, sure: $0.sure,
                      frame: screenshots ? frame(intent.id, $0.frame)?.base64EncodedString() : nil)
             } }, until: intent.until, maxLoops: intent.maxLoops, color: intent.color)
    }

    static func encode(_ items: [Item], note: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(format: format, note: note, intents: items))
    }

    /// Checks the format; drops steps whose action isn't a JSON object and screens that aren't images.
    static func decode(_ data: Data) throws -> [Item] {
        guard data.count <= maxBytes else { throw Failure(String(localized: "This file is too large.")) }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw Failure(String(localized: "This isn't an \(AppName.current) intent file."))
        }
        guard file.format == format else { throw Failure(String(localized: "This intent file needs a newer version of the app.")) }
        return file.intents.compactMap { item in
            var item = item
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.prompt.isEmpty else { return nil }
            item.steps = item.steps?.compactMap { step in
                guard RecordedStep(json: step.action) != nil else { return nil }
                var step = step
                if let f = step.frame, Data(base64Encoded: f).flatMap(Vision.image) == nil { step.frame = nil }
                return step
            }
            return item
        }
    }

    /// A temporary file to share, named after the intent (or "Intents" for several).
    static func write(_ items: [Item], note: String? = nil) throws -> URL {
        let base = items.count == 1 ? items[0].name : String(localized: "Intents")
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("intent-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Intent" : safe) + "." + fileExtension)
        try encode(items, note: note).write(to: url, options: .atomic)
        return url
    }

    /// New intents (new ids) for the items not already saved under the same name and prompt.
    static func newIntents(_ items: [Item], existing: [SavedTask]) throws -> (added: [SavedTask], skipped: Int) {
        var seen = Set(existing.map { key($0.name, $0.prompt) })
        var added: [SavedTask] = []
        for item in items {
            let name = item.name.isEmpty ? String(item.prompt.prefix(30)) : item.name
            guard seen.insert(key(name, item.prompt)).inserted else { continue }
            var intent = SavedTask(name: name, prompt: item.prompt, icon: item.icon, hints: item.hints)
            intent.until = item.until
            intent.color = item.color
            intent.maxLoops = item.maxLoops
            intent.steps = try item.steps.map { try save($0, for: intent.id) }
            added.append(intent)
        }
        return (added, items.count - added.count)
    }

    private static func key(_ name: String, _ prompt: String) -> String {
        name.lowercased() + "\u{1F}" + prompt.lowercased()
    }

    private static func save(_ steps: [Step], for id: UUID) throws -> [RecordedStep] {
        let folder = IntentFrames.folder(id)
        return try steps.enumerated().map { i, step in
            var name: String?
            if let frame = step.frame.flatMap({ Data(base64Encoded: $0) }) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                name = String(format: "s%02d.jpg", i + 1)
                try frame.write(to: folder.appendingPathComponent(name!), options: .atomic)
            }
            var recorded = RecordedStep(json: step.action)!
            recorded.sure = step.sure
            recorded.frame = name
            return recorded
        }
    }
}

extension RecordedStep {
    /// From an action's JSON text; nil when it isn't a JSON object.
    init?(json: String) {
        guard let any = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              case .obj(let o) = PyJSON.from(any) else { return nil }
        self.init(action: o, sure: false, frame: nil)
    }
}

extension IntentStore {
    /// A .esp32intent file from Files, the share sheet or Import. Returns how many were added and skipped.
    func importFile(_ url: URL) throws -> (added: Int, skipped: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let items = try IntentArchive.decode(try Data(contentsOf: url))
        let (added, skipped) = try IntentArchive.newIntents(items, existing: self.items)
        added.reversed().forEach(upsert)  // upsert puts each at the top: keep the file's order
        return (added.count, skipped)
    }
}

extension AppModel {
    /// A .esp32intent file opened from Files, the share sheet or the intent list's Import.
    func importIntents(_ url: URL) {
        do {
            let (added, skipped) = try intents.importFile(url)
            tab = .agent
            notice = added == 0 ? String(localized: "No new intents. \(skipped) already saved.")
                : skipped == 0 ? String(localized: "Imported \(added) intents.")
                : String(localized: "Imported \(added) intents. Skipped \(skipped) already saved.")
            say("imported intents: \(added) added, \(skipped) skipped")
        } catch {
            notice = error.localizedDescription
        }
    }
}

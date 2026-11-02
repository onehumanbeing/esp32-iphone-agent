import Foundation

/// One run in a chat: what the user asked and how it ended.
struct ChatTurn: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var ask: String
    var run: String  // trace folder name (Runs tab)
    var outcome: String  // done / failed / stopped / error
    var answer: String
    var items: [String] = []  // the notebook's items
    var summary = ""  // what was done and what is left (ChatContext.stopSummary)
}

struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var turns: [ChatTurn] = []
}

/// The current chat on the Agent tab: each run is one turn, and the next task sees the earlier turns
/// (ChatContext), so "now do the second one too" works. Chats are saved in Documents/threads/<id>.json.
@MainActor final class ThreadStore: ObservableObject {
    @Published private(set) var current = ChatThread()
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("threads")
        if let latest = try? FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "json" })
            .max(by: { Self.modified($0) < Self.modified($1) }),
           let data = try? Data(contentsOf: latest), let thread = try? JSONDecoder().decode(ChatThread.self, from: data) {
            current = thread
        }
    }

    func append(_ turn: ChatTurn) {
        current.turns.append(turn)
        save()
    }

    func newChat() { current = ChatThread() }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: folder.appendingPathComponent(current.id.uuidString + ".json"), options: .atomic)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

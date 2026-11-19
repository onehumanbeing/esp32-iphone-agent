import Foundation

/// Notes on how one app's screens work (which part of an order card opens the order …), kept on the Manina AI server
/// (GET /trial/guides). A run lists which apps have one; the model loads a guide with `guide APP` only when its goal
/// is done in that app, and the notes stay in its prompt for the rest of the run.
struct AppGuide: Decodable, Equatable {
    let id: String
    let names: [String]
    var text: String? = nil
}

@MainActor final class AppGuides {
    static let shared = AppGuides()
    static let perRun = 2

    private var listed: [AppGuide] = []
    private var listedAt = Date.distantPast

    private var pending: Task<[AppGuide], Never>?

    /// Asked for as the run starts, while the app opens (2026-11-17: the 2 s ask after it timed out on the board's
    /// hotspot, and that run had no guides). `list()` then takes this answer.
    func prefetch() {
        guard pending == nil else { return }
        pending = Task { await self.fetch() }
    }

    /// The apps with a guide; asked again after 10 min. Empty when the server is not reachable or this install may
    /// not read it: the run goes on without guides.
    func list() async -> [AppGuide] {
        if let pending {
            self.pending = nil
            return await pending.value
        }
        return await fetch()
    }

    private func fetch() async -> [AppGuide] {
        guard Date().timeIntervalSince(listedAt) > 600 || listed.isEmpty else { return listed }
        struct Index: Decodable { let guides: [AppGuide] }
        guard let data = await get("/trial/guides", timeout: 5), let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return listed }
        (listed, listedAt) = (index.guides, Date())
        DebugLog.write("guides: " + index.guides.map(\.id).joined(separator: ", "))
        return listed
    }

    /// The guide the model asked for by any of its names ("美团外卖", "Meituan Waimai"), with its notes.
    func load(_ name: String, from guides: [AppGuide]) async -> AppGuide? {
        guard let guide = Self.match(name, in: guides),
              let data = await get("/trial/guides/" + guide.id, timeout: 5) else { return nil }
        return try? JSONDecoder().decode(AppGuide.self, from: data)
    }

    nonisolated static func match(_ name: String, in guides: [AppGuide]) -> AppGuide? {
        let want = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        return guides.first { $0.id == want || $0.names.contains { $0.lowercased() == want } }
    }

    /// The system prompt's part: which guides there are and when to load one. Empty without any.
    nonisolated static func prompt(_ guides: [AppGuide]) -> String {
        guard !guides.isEmpty else { return "" }
        return "\n\nApp guides: `guide APP` loads notes on how that app's screens work (e.g. which part of a card "
            + "opens what); they appear under \"Guide\" from the next round on. Load one, as the only DO line, when the "
            + "goal is done in an app listed here, before acting in it or as soon as you are in it. Never load one for "
            + "an app the goal does not use. At most \(perRun) per task. Guides for: "
            + guides.map { $0.names.joined(separator: " / ") }.joined(separator: "; ")
    }

    private func get(_ path: String, timeout: TimeInterval) async -> Data? {
        guard Trial.available, let url = URL(string: Trial.origin + path),
              let headers = try? Trial.shared.recordingHeaders() else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { DebugLog.write("guides: HTTP \(code) for \(path)"); return nil }
            return data
        } catch {
            DebugLog.write("guides: \(error.localizedDescription)")
            return nil
        }
    }
}

import Foundation

/// Tools the agent may call before or while it acts (Henry 2026-11-12): `tool <name> "query"`, answered as text the
/// next round reads ("Looked up"). A search before acting catches a misspelt brand or a product that doesn't exist.
/// Three kinds: Handsy search (with a Handsy key, run by the gateway as part of the key's plan), a built-in
/// web search on one's own Exa key, and tools imported from a JSON file (an HTTPS endpoint that takes a query). Keys stay in the
/// Keychain. No tool on: the prompt says nothing about tools.
struct ToolSpec: Codable, Identifiable, Equatable, Hashable {
    var id: String              // also the name the model uses: lowercase letters, digits, "_"
    var title: String
    var about: String           // one line for the model and the list
    var url: String
    var method = "POST"         // POST: JSON body {query_field: query, …body}; GET: ?query_field=query
    var key_header: String? = "Authorization"
    var key_prefix: String? = "Bearer "
    var query_field = "query"
    var body: [String: String]? = nil
    var builtin: String? = nil  // "handsy", "exa"

    var needsKey: Bool { builtin != "handsy" && key_header != nil }
    static func validID(_ id: String) -> Bool {
        (2...24).contains(id.count) && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }
    }
}

extension ToolSpec {
    enum CodingKeys: String, CodingKey { case id, title, about, url, method, key_header, key_prefix, query_field, body, builtin }

    /// A tool file may leave out everything but id, title, about and url.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        about = try c.decode(String.self, forKey: .about)
        url = try c.decode(String.self, forKey: .url)
        method = try c.decodeIfPresent(String.self, forKey: .method)?.uppercased() ?? "POST"
        key_header = c.contains(.key_header) ? try c.decodeIfPresent(String.self, forKey: .key_header) : "Authorization"
        key_prefix = c.contains(.key_prefix) ? try c.decodeIfPresent(String.self, forKey: .key_prefix) : "Bearer "
        query_field = try c.decodeIfPresent(String.self, forKey: .query_field) ?? "query"
        body = try c.decodeIfPresent([String: String].self, forKey: .body)
        builtin = try c.decodeIfPresent(String.self, forKey: .builtin)
    }

    /// Writes a missing key header as null (not left out), so an exported keyless tool reads back keyless.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(about, forKey: .about)
        try c.encode(url, forKey: .url)
        try c.encode(method, forKey: .method)
        if let key_header { try c.encode(key_header, forKey: .key_header) } else { try c.encodeNil(forKey: .key_header) }
        if let key_prefix { try c.encode(key_prefix, forKey: .key_prefix) } else { try c.encodeNil(forKey: .key_prefix) }
        try c.encode(query_field, forKey: .query_field)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(builtin, forKey: .builtin)
    }
}

@MainActor final class ToolStore: ObservableObject {
    static let shared = ToolStore()
    static let handsy = ToolSpec(id: "search", title: "Handsy Search", about: "Search the web: titles, links and snippets.",
                                 url: Trial.origin + "/tools/v1/search", builtin: "handsy")
    static let exa = ToolSpec(id: "web", title: "Web Search (Exa)", about: "Search the web: titles, links and snippets.",
                              url: "https://api.exa.ai/search", key_header: "x-api-key", key_prefix: "",
                              body: ["numResults": "5", "type": "auto"], builtin: "exa")

    @Published private(set) var imported: [ToolSpec]
    @Published private(set) var enabled: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        imported = (defaults.data(forKey: "tools").flatMap { try? JSONDecoder().decode([ToolSpec].self, from: $0) }) ?? []
        enabled = Set(defaults.stringArray(forKey: "toolsOn") ?? ["search"])  // Handsy Search: on whenever there is a key
    }

    /// Every tool this build can show, built-in first.
    var all: [ToolSpec] { (Trial.available ? [Self.handsy] : []) + [Self.exa] + imported }

    /// Usable now: switched on, and its key (Handsy's or its own) is there.
    func ready(_ tool: ToolSpec) -> Bool {
        guard enabled.contains(tool.id) else { return false }
        if tool.builtin == "handsy" { return Trial.shared.keyed }
        return !tool.needsKey || !key(tool.id).isEmpty
    }
    var active: [ToolSpec] { all.filter(ready) }

    func set(_ id: String, on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
        defaults.set(Array(enabled).sorted(), forKey: "toolsOn")
    }

    func key(_ id: String) -> String { Keychain.get("tool-key-" + id) ?? "" }
    func setKey(_ id: String, _ value: String) {
        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: "tool-key-" + id)
        objectWillChange.send()
    }

    /// Tools from a JSON file: one tool (ToolSpec's fields) or a list of them, as Export writes. All or none;
    /// a tool with the same id is replaced. Returns the error to show, nil when added.
    func add(json data: Data) -> String? {
        let decoder = JSONDecoder()
        guard let tools = (try? decoder.decode([ToolSpec].self, from: data)) ?? (try? decoder.decode(ToolSpec.self, from: data)).map({ [$0] }),
              !tools.isEmpty else { return String(localized: "Not a tool file.") }
        for tool in tools {
            guard ToolSpec.validID(tool.id), tool.id != Self.handsy.id, tool.id != Self.exa.id else {
                return String(localized: "The tool's id must be 2–24 lowercase letters, digits or _, and not a built-in one.")
            }
            guard let url = URL(string: tool.url), url.scheme == "https" else { return String(localized: "A tool's address must be https.") }
        }
        for var tool in tools {
            tool.builtin = nil
            imported.removeAll { $0.id == tool.id }
            imported.append(tool)
            enabled.insert(tool.id)
        }
        save()
        return nil
    }

    /// The imported tools as one JSON file (a list), to share or import on another iPhone. Keys are not in it.
    func export() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(imported)) ?? Data("[]".utf8)
    }

    func remove(_ id: String) {
        imported.removeAll { $0.id == id }
        set(id, on: false)
        Keychain.set("", for: "tool-key-" + id)
        save()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(imported), forKey: "tools") }

    /// Calls a run may make, whatever the model asks (Henry 2026-11-12: only when it needs one, never as a habit).
    static let perRun = 3

    /// The actor's prompt section for the tools that are ready; empty when none is (fixed for a run).
    static func prompt(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        return "\n\nTools: `tool <name> \"query\"` looks something up off the screen; the answer is under \"Looked up\" "
            + "next round. Most tasks need none: use one only when you cannot go on well without it, such as a product, "
            + "brand or place in the goal you do not recognise or that may be misspelt, or something the goal asks for "
            + "that is still not on screen after a few tries. Never to check what the screen already shows. At most "
            + "\(perRun) per task.\n" + tools.map { "- \($0.id): \($0.about)" }.joined(separator: "\n")
    }
}

/// One tool call: the request, and its answer cut down to text the model can read.
enum ToolRunner {
    static let limit = 1_500

    static func request(_ tool: ToolSpec, query: String, key: String, run: String?) -> URLRequest? {
        guard var components = URLComponents(string: tool.url) else { return nil }
        if tool.method == "GET" {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: tool.query_field, value: query)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = tool.method == "GET" ? "GET" : "POST"
        if let header = tool.key_header, !key.isEmpty { request.setValue((tool.key_prefix ?? "") + key, forHTTPHeaderField: header) }
        if let run { request.setValue(run, forHTTPHeaderField: "X-Run-ID") }
        if tool.builtin == "handsy" { request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Device-Model") }
        if request.httpMethod == "POST" {
            var body: [String: Any] = [tool.query_field: query]
            for (k, v) in tool.body ?? [:] { body[k] = Int(v).map { $0 as Any } ?? v }
            if tool.builtin == "exa" { body["contents"] = ["text": ["maxCharacters": 600]] }  // snippets, not just links
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Search-shaped JSON (`results` with title/url/content or snippet, an `answer`) as lines; anything else as text.
    static func text(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var lines: [String] = []
            if let answer = json["answer"] as? String, !answer.isEmpty { lines.append(answer) }
            for item in (json["results"] as? [[String: Any]] ?? []).prefix(6) {
                let title = item["title"] as? String ?? ""
                let snippet = (item["content"] ?? item["text"] ?? item["snippet"] ?? item["description"]) as? String ?? ""
                let url = item["url"] as? String ?? ""
                lines.append("- \(title): \(snippet.prefix(220)) (\(url))")
            }
            if lines.isEmpty, let result = (json["result"] ?? json["text"]) as? String { lines.append(result) }
            if !lines.isEmpty { return String(lines.joined(separator: "\n").prefix(limit)) }
        }
        return String((String(data: data, encoding: .utf8) ?? "").prefix(limit))
    }

    /// Runs `tool <name> "query"`; the answer, or why there is none.
    @MainActor static func run(_ line: String, run: String?) async -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let query = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let store = ToolStore.shared
        guard let tool = store.active.first(where: { $0.id == name }) else {
            return "no tool \"\(name)\" here; tools: " + (store.active.map(\.id).joined(separator: ", ").nilIfEmpty ?? "none")
        }
        guard !query.isEmpty else { return "tool \(name): nothing to look up" }
        let key = tool.builtin == "handsy" ? Trial.shared.key : store.key(tool.id)
        guard let request = request(tool, query: query, key: key, run: run) else { return "tool \(name): bad address" }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.write("tool \(name): HTTP \(code), \(data.count) bytes")
            guard (200..<300).contains(code) else { return "tool \(name) failed (HTTP \(code)); go on without it" }
            let text = Self.text(data)
            return text.isEmpty ? "tool \(name): nothing found" : text
        } catch {
            DebugLog.write("tool \(name): \(error.localizedDescription)")
            return "tool \(name) failed (\(error.localizedDescription)); go on without it"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

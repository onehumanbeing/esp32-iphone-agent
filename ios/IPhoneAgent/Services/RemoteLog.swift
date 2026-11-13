import Foundation

/// Remote debug log: a developer's own pull channel for the text debug log (debug.log) of a phone that can't be
/// reached, e.g. on cellular with the board plugged in. Off unless an endpoint URL and token are set (Settings ›
/// Developer, or a `remote-debug-log.json` dropped into Documents). When set, the app polls `<url>/poll` about
/// every 30 s while it is active or a run is going; when the server asks, it uploads the requested tail of
/// debug.log to `<url>/upload` as text/plain, secrets redacted. Never screenshots or other files.
/// Server API: docs/remote-debug-log.md.
struct RemoteLogConfig: Equatable {
    var url = ""
    var token = ""

    static let urlKey = "remoteLogURL"
    static let tokenAccount = "remote-log-token"
    static let dropName = "remote-debug-log.json"

    /// Where to poll, or nil = off: both set, https, a host, no credentials in the URL.
    var endpoint: URL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, let u = parts.url else { return nil }
        return u
    }

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(url: defaults.string(forKey: urlKey) ?? "", token: Keychain.get(tokenAccount) ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey)
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenAccount)
    }

    /// `{"url": "...", "token": "..."}`; nil if malformed or not https.
    static func parse(drop data: Data) -> Self? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = d["url"] as? String, let token = d["token"] as? String else { return nil }
        let config = Self(url: url, token: token)
        return config.endpoint == nil ? nil : config
    }

    /// Import `Documents/remote-debug-log.json` (e.g. `devicectl device copy to` or Finder file sharing) and delete
    /// it, so no one has to type a token on the phone. Returns whether a config was imported.
    @discardableResult
    static func importDrop(from dir: URL, defaults: UserDefaults = .standard) -> Bool {
        let file = dir.appendingPathComponent(dropName)
        guard let data = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        guard let config = parse(drop: data) else {
            DebugLog.write("remote log: ignored a malformed \(dropName)")
            return false
        }
        config.save(defaults)
        DebugLog.write("remote log: configured from \(dropName)")
        return true
    }
}

/// What may go out: strips secrets and anything key-, token- or image-shaped from log text.
enum RemoteLogRedaction {
    private static let mask = Redactor.mask
    private static let rules: [(String, String)] = [
        (#"data:image/[^\s"']*"#, "[image removed]"),
        (#"(?i)\b(authorization|bearer)\b(["']?\s*[:=]?\s*["']?)(bearer\s+)?[A-Za-z0-9._~+/=-]{6,}"#, "$1$2\(mask)"),
        (#"(?i)\b(api[_-]?key|x-api-key|token|secret|password|passwd|pass|pwd|key)\b(["']?\s*[:=]\s*["']?)[^\s"',&;]{4,}"#,
         "$1$2\(mask)"),
        (#"\b(sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{10,}"#, mask),
        (#"\bv1\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, mask),     // signed tickets
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+)?"#, mask),  // JWTs
        (#"\b[A-Za-z0-9_-]{40,}\b"#, mask),                             // long opaque strings (keys, tokens)
    ]

    static func clean(_ text: String, secrets: [String]) -> String {
        var out = Redactor(secrets: secrets).text(text)  // exact secrets, IPs, typed text
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// The values this app knows are secret: model, Jev and free-line keys and the channel's own token.
    @MainActor static func knownSecrets(_ config: RemoteLogConfig) -> [String] {
        var keys = ["llm-api-key", JevConfig.keychainAccount, "trial-device-token", "trial-pending-token"]
            .compactMap { Keychain.get($0) }
        if let base = UserDefaults.standard.string(forKey: "baseURL") { keys += Keychain.get("llm-endpoint-" + base).map { [$0] } ?? [] }
        return (keys + [config.token]).filter { $0.count >= 4 }
    }
}

/// The server's answer to a poll: `{"want": {"id", "minutes" | "lines"}}` or `{}`.
struct RemoteLogWant: Decodable, Equatable {
    var id: String
    var minutes: Int?
    var lines: Int?
}

protocol RemoteLogTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionRemoteLogTransport: RemoteLogTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

@MainActor final class RemoteLog {
    static let shared = RemoteLog()
    static let interval: UInt64 = 30_000_000_000
    static let maxBytes = 1_900_000  // the server takes ≤ 2 MB

    var transport: RemoteLogTransport = URLSessionRemoteLogTransport()
    var config: () -> RemoteLogConfig = { RemoteLogConfig.load() }
    var logText: () -> String = { DebugLog.allText() }
    var secrets: (RemoteLogConfig) -> [String] = { RemoteLogRedaction.knownSecrets($0) }
    var now: () -> Date = { Date() }
    private(set) var lastUpload: Date?
    private var lastError = ""

    /// One poll, and the upload it asks for. No network at all when not configured. Returns the upload's id.
    @discardableResult
    func tick() async -> String? {
        let config = config()
        guard let base = config.endpoint else { return nil }
        do {
            let (data, status) = try await transport.send(request(base, "poll", config.token, body: Data("{}".utf8),
                                                                  type: "application/json"))
            guard status == 200 else { throw Failure.status("poll", status) }
            struct Reply: Decodable { var want: RemoteLogWant? }
            guard let want = try JSONDecoder().decode(Reply.self, from: data).want else { return nil }
            let text = Self.tail(logText(), want: want, now: now())
            let clean = RemoteLogRedaction.clean(text, secrets: secrets(config))
            var up = request(base, "upload", config.token, body: Data(Self.capped(clean).utf8), type: "text/plain; charset=utf-8")
            up.setValue(want.id, forHTTPHeaderField: "X-Request-Id")
            let (_, upStatus) = try await transport.send(up)
            guard upStatus == 200 else { throw Failure.status("upload", upStatus) }
            lastUpload = now()
            lastError = ""
            DebugLog.write("remote log: uploaded \(clean.split(separator: "\n").count) lines for request \(want.id)")
            return want.id
        } catch {
            let line = "\(error)"
            if line != lastError { DebugLog.write("remote log: \(line.prefix(120))") }  // once per kind of failure
            lastError = line
            return nil
        }
    }

    private enum Failure: Error, CustomStringConvertible {
        case status(String, Int)
        var description: String {
            switch self { case let .status(what, code): return "\(what) failed: HTTP \(code)" }
        }
    }

    private func request(_ base: URL, _ path: String, _ token: String, body: Data, type: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return r
    }

    /// The asked-for part of the log: the last `lines` lines, or the lines stamped within the last `minutes`
    /// (an unstamped line follows the one before it).
    static func tail(_ text: String, want: RemoteLogWant, now: Date) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        if let n = want.lines { return all.suffix(max(0, min(n, 50_000))).joined(separator: "\n") + "\n" }
        let cutoff = now.addingTimeInterval(-Double(max(1, min(want.minutes ?? 10, 1440))) * 60)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var keep = false
        let picked = all.filter { line in
            if let first = line.split(separator: " ", maxSplits: 1).first, let t = stamp.date(from: String(first)) {
                keep = t >= cutoff
            }
            return keep
        }
        return picked.isEmpty ? "" : picked.joined(separator: "\n") + "\n"
    }

    /// At most maxBytes, keeping the end (whole lines).
    static func capped(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        let tail = data.suffix(maxBytes)
        let start = tail.firstIndex(of: 10).map { $0 + 1 } ?? tail.startIndex
        return String(decoding: tail[start...], as: UTF8.self)
    }
}

extension AppModel {
    /// Polls while the app is active or a run is going (the BLE background mode keeps a run's process alive);
    /// a suspended app just skips. Not configured: only the local check for a dropped config file.
    func startRemoteLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Task { [weak self] in
            while !Task.isCancelled {
                RemoteLogConfig.importDrop(from: docs)
                guard let self else { return }
                if !self.isBackground() || self.agent.running { await RemoteLog.shared.tick() }
                try? await Task.sleep(nanoseconds: RemoteLog.interval)
            }
        }
    }
}

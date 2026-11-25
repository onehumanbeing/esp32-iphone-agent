import Foundation

/// Sign in with ChatGPT: runs use the user's own Plus or Pro plan through the Codex endpoint, with no API key.
/// The sign-in is Codex's device-code flow (codex-rs/login/src/device_code_auth.rs): the user enters a short code
/// on OpenAI's page, the app polls, then trades the result for tokens. The tokens stay in the Keychain.
@MainActor final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth(store: SystemKeychain(), session: .shared)

    static let issuer = "https://auth.openai.com"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"  // Codex's public OAuth client
    static let codexVersion = "0.171.0"  // the models list hides models newer than the client asking
    private static let keychainAccount = "chatgpt-auth"

    struct Account: Equatable {
        let email: String?
        let plan: String?
        let accountID: String
    }

    /// One usage window from the reply headers (x-codex-primary-*: the 5-hour one, secondary: the weekly one).
    struct Window: Equatable {
        let usedPercent: Double
        let minutes: Int?
        let resetsAt: Date?
    }

    struct DeviceCode {
        let userCode: String
        let verificationURL: URL
        fileprivate let deviceAuthID: String
        fileprivate let interval: Double
    }

    private struct Tokens: Codable {
        var idToken: String
        var accessToken: String
        var refreshToken: String
    }

    @Published private(set) var account: Account?
    @Published private(set) var limits: (primary: Window?, secondary: Window?) = (nil, nil) {
        didSet { DebugLog.write("chatgpt: usage \(limits.primary?.usedPercent ?? -1)% / \(limits.secondary?.usedPercent ?? -1)%") }
    }
    private var tokens: Tokens? {
        didSet {
            account = tokens.flatMap { Self.account(fromIDToken: $0.idToken) }
            if let tokens { DebugLog.redact([tokens.accessToken, tokens.refreshToken, tokens.idToken]) }
        }
    }

    private let store: KeychainStoring
    private let session: URLSession
    private let defaults: UserDefaults
    private static let effortsKey = "chatgpt-reasoning-levels"
    /// Each listed model's reasoning efforts, as the models list names them (kept across launches, so the chosen
    /// effort applies before the list is fetched again).
    @Published private(set) var efforts: [String: [String]] = [:]

    /// The app uses `shared` (the Keychain, the real network). Tests make their own: an in-memory store and a
    /// stubbed session, never the app's sign-in.
    init(store: KeychainStoring, session: URLSession, defaults: UserDefaults = .standard) {
        self.store = store
        self.session = session
        self.defaults = defaults
        efforts = defaults.dictionary(forKey: Self.effortsKey) as? [String: [String]] ?? [:]
        if let raw = store.get(Self.keychainAccount), let saved = try? JSONDecoder().decode(Tokens.self, from: Data(raw.utf8)) {
            tokens = saved
            account = Self.account(fromIDToken: saved.idToken)
            DebugLog.redact([saved.accessToken, saved.refreshToken, saved.idToken])
        }
    }

    var signedIn: Bool { account != nil }

    // MARK: - sign-in

    func requestDeviceCode() async throws -> DeviceCode {
        let json = try await postJSON("\(Self.issuer)/api/accounts/deviceauth/usercode", ["client_id": Self.clientID])
        guard let id = json["device_auth_id"] as? String,
              let code = (json["user_code"] ?? json["usercode"]) as? String else {
            throw LLMError(message: String(localized: "OpenAI's sign-in did not return a code. Try again."))
        }
        let interval = Double("\(json["interval"] ?? 5)") ?? 5
        return DeviceCode(userCode: code, verificationURL: URL(string: "\(Self.issuer)/codex/device")!,
                          deviceAuthID: id, interval: max(interval, 1))
    }

    /// Polls until the user has entered the code (15 minutes at most), then stores the tokens. Cancel the task to stop.
    func complete(_ code: DeviceCode) async throws {
        let started = Date()
        var granted: [String: Any]?
        while granted == nil {
            try Task.checkCancellation()
            let (status, json) = try await post("\(Self.issuer)/api/accounts/deviceauth/token",
                                                     ["device_auth_id": code.deviceAuthID, "user_code": code.userCode])
            if (200..<300).contains(status) { granted = json; break }
            guard status == 403 || status == 404 else {
                throw LLMError(message: String(localized: "ChatGPT sign-in failed (HTTP \(status)). Try again."), status: status)
            }
            guard Date().timeIntervalSince(started) < 15 * 60 else {
                throw LLMError(message: String(localized: "The sign-in code expired. Start again."))
            }
            try await Task.sleep(for: .seconds(code.interval))
        }
        guard let granted, let authCode = granted["authorization_code"] as? String,
              let verifier = granted["code_verifier"] as? String else {
            throw LLMError(message: String(localized: "OpenAI's sign-in returned no authorization. Try again."))
        }
        let form = ["grant_type": "authorization_code", "client_id": Self.clientID, "code": authCode,
                    "redirect_uri": "\(Self.issuer)/deviceauth/callback", "code_verifier": verifier]
        let json = try await postForm("\(Self.issuer)/oauth/token", form)
        guard let id = json["id_token"] as? String, let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String, Self.account(fromIDToken: id) != nil else {
            throw LLMError(message: String(localized: "This ChatGPT account has no plan the app can use."))
        }
        save(Tokens(idToken: id, accessToken: access, refreshToken: refresh))
        DebugLog.write("chatgpt: signed in, plan \(account?.plan ?? "-")")
    }

    func signOut() {
        tokens = nil
        limits = (nil, nil)
        store.set("", for: Self.keychainAccount)
        DebugLog.write("chatgpt: signed out")
    }

    // MARK: - requests

    /// The renewal in flight, if any: while it runs, every caller waits for its result instead of sending another
    /// (a second renewal would spend the rotated refresh token twice, and its refusal signs out).
    private var renewal: Task<String, Error>?

    /// The access token, refreshed first when it expires within 10 minutes (or `force`, after a 401).
    func accessToken(force: Bool = false) async throws -> String {
        if let renewal { return try await renewal.value }
        guard let current = tokens else { throw Self.signInAgain }
        let expires = Self.claims(current.accessToken)?["exp"] as? Double ?? 0
        guard force || Date(timeIntervalSince1970: expires).timeIntervalSinceNow < 600 else { return current.accessToken }
        let task = Task { [self] in try await renew(current) }
        renewal = task
        defer { renewal = nil }  // done or failed: the next caller decides afresh
        return try await task.value
    }

    private func renew(_ old: Tokens) async throws -> String {
        var current = old
        let (status, json) = try await post("\(Self.issuer)/oauth/token",
                                                 ["grant_type": "refresh_token", "client_id": Self.clientID,
                                                  "refresh_token": current.refreshToken])
        guard (200..<300).contains(status), let access = json["access_token"] as? String else {
            DebugLog.write("chatgpt: refresh failed, HTTP \(status)")
            if status == 400 || status == 401 { signOut() }  // refresh token expired, reused or revoked
            throw Self.signInAgain
        }
        current.accessToken = access
        if let id = json["id_token"] as? String { current.idToken = id }
        if let refresh = json["refresh_token"] as? String { current.refreshToken = refresh }
        save(current)
        DebugLog.write("chatgpt: token refreshed")
        return access
    }

    /// Sent with every Codex request besides the bearer token.
    func headers() throws -> [String: String] {
        guard let account else { throw Self.signInAgain }
        return ["chatgpt-account-id": account.accountID, "originator": "manina_ios"]
    }

    /// The usage windows the Codex endpoint reports on each reply.
    func noteLimits(_ response: HTTPURLResponse) {
        func window(_ which: String) -> Window? {
            func value(_ name: String) -> String? { response.value(forHTTPHeaderField: "x-codex-\(which)-\(name)") }
            guard let used = value("used-percent").flatMap(Double.init) else { return nil }
            return Window(usedPercent: used, minutes: value("window-minutes").flatMap(Int.init),
                          resetsAt: value("reset-at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        }
        let next = (window("primary"), window("secondary"))
        if next.0 != nil || next.1 != nil, next.0 != limits.primary || next.1 != limits.secondary { limits = next }
    }

    /// The models the Codex endpoint offers this account, in its own order.
    func models() async throws -> [String] {
        var request = URLRequest(url: URL(string: "\(ModelProvider.chatGPT.baseURL)/models?client_version=\(Self.codexVersion)")!,
                                 timeoutInterval: 20)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        for (name, value) in try headers() { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(message: "GET /models: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))", status: status)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = body["models"] as? [[String: Any]] else {  // not the expected shape: say so, not "no models"
            throw LLMError(message: "GET /models: unexpected body (HTTP \(status), \(data.count) bytes)", status: status)
        }
        let listed = list.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
        var levels: [String: [String]] = [:]
        for model in listed {
            guard let slug = model["slug"] as? String else { continue }
            levels[slug] = Self.reasoningLevels(model["supported_reasoning_levels"])
        }
        efforts = levels
        defaults.set(levels, forKey: Self.effortsKey)
        return listed.compactMap { $0["slug"] as? String }
    }

    /// A model's reasoning efforts: a list of names, or of objects with an "effort" (and a description).
    static func reasoningLevels(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? [String: Any])?["effort"] as? String }
    }

    static var signInAgain: LLMError {
        LLMError(message: String(localized: "Sign in to ChatGPT again in Settings › Model."), status: 401, kind: "chatgpt_signed_out")
    }

    // MARK: - helpers

    private func save(_ new: Tokens) {
        tokens = new
        if let data = try? JSONEncoder().encode(new) { store.set(String(decoding: data, as: UTF8.self), for: Self.keychainAccount) }
    }

    static func account(fromIDToken token: String) -> Account? {
        guard let claims = claims(token) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let id = auth?["chatgpt_account_id"] as? String, !id.isEmpty else { return nil }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return Account(email: (claims["email"] ?? profile?["email"]) as? String, plan: auth?["chatgpt_plan_type"] as? String,
                       accountID: id)
    }

    /// A JWT's payload (no signature check: the token came straight from OpenAI over TLS).
    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func post(_ url: String, _ body: [String: String]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    private func postJSON(_ url: String, _ body: [String: String]) async throws -> [String: Any] {
        let (status, json) = try await post(url, body)
        guard (200..<300).contains(status) else {
            throw LLMError(message: status == 404
                ? String(localized: "Device-code sign-in is off for this ChatGPT account. Turn it on in ChatGPT › Settings › Security, then try again.")
                : String(localized: "ChatGPT sign-in failed (HTTP \(status)). Try again."), status: status)
        }
        return json
    }

    private func postForm(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(message: String(localized: "ChatGPT sign-in failed (HTTP \(status)). Try again."), status: status)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}


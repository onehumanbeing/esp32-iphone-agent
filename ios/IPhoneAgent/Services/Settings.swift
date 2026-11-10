import Foundation
import Network
import NetworkExtension
import Security
import UIKit

/// LLM settings. The API key lives in the Keychain, everything else in UserDefaults (mirrored into the
/// Keychain by SettingsBackup, so a reinstall keeps it).
@MainActor final class Settings: ObservableObject {
    static let defaultBaseURL = ""  // user enters their own OpenAI-compatible endpoint
    static let defaultModel = ""

    @Published private(set) var provider: ModelProvider = .others
    @Published private(set) var configurationRevision = 0
    /// Saved custom endpoints (provider Others) and the one in use.
    @Published private(set) var customEndpoints: [CustomEndpoint] = []
    @Published private(set) var activeCustomID: String? { didSet { defaults.set(activeCustomID, forKey: "customEndpointID") } }
    private let defaults: UserDefaults
    private var backupObserver: NSObjectProtocol?
    @Published var baseURL: String { didSet {
        defaults.set(baseURL, forKey: "baseURL")
        if baseURL != oldValue {
            // Never carry an old provider's credential to a newly typed endpoint.
            if URL(string: oldValue)?.host != URL(string: baseURL)?.host { apiKey = "" }
            modelsChanged()
        }
    } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model"); configurationRevision += 1 } }  // empty preserves a legacy saved selection
    /// The model picked from the endpoint's list when `model` is empty (forgotten when the endpoint or key changes).
    @Published private(set) var autoModel: String { didSet { defaults.set(autoModel, forKey: "autoModel") } }
    @Published var plannerModel: String { didSet { defaults.set(plannerModel, forKey: "plannerModel"); configurationRevision += 1 } }  // "" = model
    @Published var actorModel: String { didSet { defaults.set(actorModel, forKey: "actorModel"); configurationRevision += 1 } }        // "" = model
    @Published var tokenParam: String { didSet { defaults.set(tokenParam, forKey: "tokenParam"); configurationRevision += 1 } }        // auto | ...
    @Published var extraBody: String { didSet { defaults.set(extraBody, forKey: "extraBody"); configurationRevision += 1 } }          // JSON object
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: "llm-api-key"); DebugLog.redact([apiKey])
        if apiKey != oldValue { modelsChanged() } } }
    /// What the agent is called (Agent tab title, greeting, Live Activity); empty = the default.
    /// The endpoint's model list (GET /models), for the pickers; empty until loaded or when it can't be fetched.
    @Published private(set) var models: [String] = []
    /// OpenRouter only: the listed models that cost nothing (the list itself is vision models only).
    @Published private(set) var freeModels: Set<String> = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelsError: String?
    private var modelsRequest = 0
    @Published var agentName: String {
        didSet {
            let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.agentNameKey)
            let shown = trimmed.isEmpty ? Self.defaultAgentName : trimmed
            if shown != agentName { agentName = shown }  // no observer re-entry inside didSet
        }
    }
    static let agentNameKey = "agentName"
    static var defaultAgentName: String { String(localized: "ESP32 Agent") }
    /// The name, for code without a Settings instance (Live Activity).
    static var storedAgentName: String { UserDefaults.standard.string(forKey: agentNameKey) ?? defaultAgentName }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var restoreKeyboardAfterRun: Bool { didSet { defaults.set(restoreKeyboardAfterRun, forKey: "restoreKeyboardAfterRun") } }
    @Published var acceptedDisclaimer: Bool { didSet { defaults.set(acceptedDisclaimer, forKey: "acceptedDisclaimer") } }

    /// info: where build-time presets are read from (the app's Info.plist; tests pass none).
    init(defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary) {
        self.defaults = defaults
        if defaults === UserDefaults.standard { SettingsBackup.restoreIfFresh(defaults) }  // tests use their own suite
        let preset = { (key: String) in Self.stored((info?[key] as? String)?.trimmingCharacters(in: .whitespaces)) }
        baseURL = Self.stored(defaults.string(forKey: "baseURL")) ?? preset("IAPresetBaseURL") ?? Self.defaultBaseURL
        model = Self.stored(defaults.string(forKey: "model")) ?? preset("IAPresetModel") ?? Self.defaultModel
        autoModel = defaults.string(forKey: "autoModel") ?? ""
        plannerModel = defaults.string(forKey: "plannerModel") ?? ""
        actorModel = defaults.string(forKey: "actorModel") ?? ""
        tokenParam = defaults.string(forKey: "tokenParam") ?? "auto"
        extraBody = defaults.string(forKey: "extraBody") ?? "{}"
        apiKey = Self.stored(Keychain.get("llm-api-key")) ?? preset("IAPresetKey") ?? ""
        agentName = defaults.string(forKey: Self.agentNameKey) ?? Self.defaultAgentName
        onboarded = defaults.bool(forKey: "onboarded")
        restoreKeyboardAfterRun = defaults.object(forKey: "restoreKeyboardAfterRun") as? Bool ?? true
        acceptedDisclaimer = defaults.bool(forKey: "acceptedDisclaimer")
        provider = defaults.string(forKey: "modelProvider").flatMap(ModelProvider.init(rawValue:))
            ?? ModelProvider.infer(baseURL: baseURL, model: model)
        customEndpoints = Self.loadCustom(defaults)
        activeCustomID = defaults.string(forKey: "customEndpointID")
        DebugLog.redact([apiKey])  // never in debug.log
        if defaults === UserDefaults.standard {
            SettingsBackup.save(defaults)
            backupObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                                    queue: .main) { _ in
                MainActor.assumeIsolated { SettingsBackup.schedule(.standard) }
            }
        }
    }

    private static func stored(_ v: String?) -> String? { v?.isEmpty == false ? v : nil }

    /// The endpoint is valid (local endpoints may not require a key).
    var isConfigured: Bool {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The manual override, else the model already picked from the endpoint, else nil.
    var currentModel: String? {
        let manual = model.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { return manual }
        return autoModel.isEmpty ? nil : autoModel
    }

    /// For usage stats: the provider, and the model ID only for a known provider (a custom server's model
    /// name could identify it). Never the address or key.
    var analyticsModel: [String: Any] {
        var p: [String: Any] = ["provider": provider.rawValue]
        if provider != .others, let m = currentModel { p["model"] = m }
        return p
    }

    /// A model request's stats with the provider; the model names are dropped for a custom server, as above.
    func analyticsModel(_ call: ModelCall) -> [String: Any] {
        var p = analyticsModel.merging(call.props) { $1 }
        if provider == .others { p["model"] = nil; p["served_model"] = nil }
        return p
    }

    /// Use an explicit model or a previously saved selection; never guess from API list order.
    func resolvedModel() async throws -> String {
        if let m = currentModel { return m }
        throw LLMError(message: "Choose a vision model or enter its model ID before testing.")
    }

    private func modelsChanged() {
        configurationRevision += 1
        modelsRequest += 1
        loadingModels = false
        autoModel = ""
        models = []
        freeModels = []
        modelsError = nil
    }

    var selectedProvider: ModelProvider {
        get { provider }
        set { selectProvider(newValue) }
    }

    func selectProvider(_ choice: ModelProvider) {
        guard choice != provider else { return }
        if choice == .others { return selectCustom(activeCustomID ?? customEndpoints.first?.id) }
        saveCurrent()
        provider = choice
        defaults.set(choice.rawValue, forKey: "modelProvider")
        if let saved = defaults.dictionary(forKey: Self.profileKey(choice)) as? [String: String] {
            restore(saved)
            return
        }
        let changedEndpoint = baseURL != choice.baseURL
        baseURL = choice.baseURL
        if changedEndpoint { apiKey = Keychain.get("llm-endpoint-" + baseURL) ?? "" }
        model = choice == .openRouter ? "openrouter/free" : ""  // works with any key, no model to pick first
        if choice == .handsyTrial { model = Trial.model }  // free line: its one model
        plannerModel = ""
        actorModel = ""
        tokenParam = "auto"
        extraBody = "{}"
        if let pick = TestedModels.list(for: choice).first(where: \.recommended) { choose(pick) }
        modelsChanged()
    }

    /// Switch to a saved custom endpoint, or start a new blank one (nil).
    func selectCustom(_ id: String?) {
        if provider == .others, id != nil, id == activeCustomID { return }
        saveCurrent()
        provider = .others
        defaults.set(ModelProvider.others.rawValue, forKey: "modelProvider")
        activeCustomID = id
        restore(customEndpoints.first { $0.id == id }?.fields ?? ["baseURL": "", "model": ""])
    }

    func deleteCustom(_ id: String) {
        guard !(provider == .others && id == activeCustomID) else { return }  // not the one in use
        customEndpoints.removeAll { $0.id == id }
        storeCustom()
    }

    // Each provider keeps its own settings, so switching back finds them unchanged; custom endpoints are
    // kept as a list. Keys stay per endpoint in the Keychain.
    private static func profileKey(_ p: ModelProvider) -> String { "modelProfile." + p.rawValue }

    private var currentProfile: [String: String] {
        ["baseURL": baseURL, "model": model, "plannerModel": plannerModel, "actorModel": actorModel,
         "tokenParam": tokenParam, "extraBody": extraBody]
    }

    /// Remember the live configuration under its provider (or custom endpoint) and its key under its endpoint.
    func saveCurrent() {
        Keychain.set(apiKey, for: "llm-endpoint-" + baseURL)  // an empty key removes this endpoint's saved key
        guard provider == .others else { return defaults.set(currentProfile, forKey: Self.profileKey(provider)) }
        guard isConfigured else { return }  // a blank new endpoint isn't kept
        let id = activeCustomID
            ?? customEndpoints.first { $0.baseURL == baseURL && $0.model == model }?.id ?? UUID().uuidString
        let entry = CustomEndpoint(id: id, fields: currentProfile)
        if let i = customEndpoints.firstIndex(where: { $0.id == id }) { customEndpoints[i] = entry } else { customEndpoints.append(entry) }
        activeCustomID = id
        storeCustom()
    }

    private func storeCustom() {
        defaults.set(customEndpoints.map { $0.fields.merging(["id": $0.id]) { $1 } }, forKey: "customEndpoints")
    }

    private static func loadCustom(_ defaults: UserDefaults) -> [CustomEndpoint] {
        var list = (defaults.array(forKey: "customEndpoints") as? [[String: String]] ?? []).compactMap { d in
            d["id"].map { CustomEndpoint(id: $0, fields: d.filter { $0.key != "id" }) }
        }
        // Builds before the list kept a single custom profile.
        if list.isEmpty, let legacy = defaults.dictionary(forKey: profileKey(.others)) as? [String: String] {
            list = [CustomEndpoint(id: UUID().uuidString, fields: legacy)]
        }
        return list
    }

    private func restore(_ p: [String: String]) {
        let url = p["baseURL"] ?? baseURL
        let changedEndpoint = url != baseURL
        baseURL = url
        if changedEndpoint { apiKey = url.isEmpty ? "" : Keychain.get("llm-endpoint-" + url) ?? "" }
        model = p["model"] ?? ""
        plannerModel = p["plannerModel"] ?? ""
        actorModel = p["actorModel"] ?? ""
        tokenParam = p["tokenParam"] ?? "auto"
        extraBody = p["extraBody"] ?? "{}"
        modelsChanged()
    }

    /// The provider has a usable setup: an endpoint and a key (a custom server may not need one).
    func isConfigured(_ p: ModelProvider) -> Bool {
        if p == .handsyTrial { return Trial.available }  // free line: no key
        if p == .others { return !customEndpoints.isEmpty || (provider == .others && isConfigured) }
        if p == provider { return isConfigured && !apiKey.isEmpty }
        let url = (defaults.dictionary(forKey: Self.profileKey(p)) as? [String: String])?["baseURL"] ?? p.baseURL
        guard let host = URL(string: url)?.host, !host.isEmpty else { return false }
        return Keychain.get("llm-endpoint-" + url)?.isEmpty == false
    }

    /// The shared model; a tested one also brings the request parameters it was measured with.
    func chooseModel(_ id: String) {
        if let tested = TestedModels.find(id, for: provider) { choose(tested) } else { model = id }
    }

    private func choose(_ tested: TestedModel) {
        model = tested.id
        extraBody = tested.extraBody
    }

    #if DEBUG
    /// Apply validated developer input atomically before startup commands or UI requests.
    /// Omitted credentials always clear the previous key, including on the same host.
    @discardableResult
    func importLaunchConfiguration(arguments: [String], environment: [String: String] = [:]) throws -> Bool {
        guard let config = try ModelLaunchConfiguration.parse(arguments, environment: environment) else { return false }
        selectProvider(.others)
        activeCustomID = nil  // a new custom endpoint, never written over a saved one
        defaults.set(ModelProvider.others.rawValue, forKey: "modelProvider")
        apiKey = ""
        baseURL = config.baseURL
        model = config.model
        plannerModel = ""
        actorModel = ""
        tokenParam = "auto"
        extraBody = config.extraBody
        apiKey = config.apiKey
        modelsChanged()  // invalidate lists and connection results even if endpoint/model did not change
        return true
    }
    #endif

    /// Fetch the model list; only a result for the current configuration is accepted.
    func loadModels() async {
        guard isConfigured, AIConsent.granted(baseURL), provider != .handsyTrial else { return }  // asks first in store builds
        modelsRequest += 1
        let request = modelsRequest
        loadingModels = true
        defer { if request == modelsRequest { loadingModels = false } }
        do {
            var list: [String], free = Set<String>()
            if provider == .openRouter {
                (list, free) = try await LLMClient.openRouterModels(apiKey: apiKey)
            } else {
                list = try await LLMClient.models(baseURL: baseURL, apiKey: apiKey)
            }
            guard request == modelsRequest else { return }
            models = list
            freeModels = free
            modelsError = list.isEmpty ? String(localized: "The endpoint lists no models.") : nil
            // Model order does not indicate image support; never silently select the first entry.
            DebugLog.write("models: \(list.count) listed, first \(list.first ?? "-")")
        } catch {
            guard request == modelsRequest else { return }
            models = []
            freeModels = []
            modelsError = error.localizedDescription
            DebugLog.write("models: \(error.localizedDescription)")
        }
    }

    /// The AI-service agreement changed (store builds): refresh what depends on it.
    func consentChanged() {
        configurationRevision += 1
        Task { await loadModels() }
    }

    var extra: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(extraBody.utf8))) as? [String: Any] ?? [:]
    }

    /// The free line builds the screen tree on Spark, unless Jev runs in the app (own TypeSafe key) and needs it here.
    static func serverTree(_ provider: ModelProvider) -> Bool { provider == .handsyTrial && !JevConfig.ownActive }

    /// role "planner" or "actor": its own model if set, else the shared one.
    func client(_ role: String) async throws -> LLMClient {
        // free line: its one model with the gateway's own parameters. Advanced overrides (models, token
        // parameter, Extra body) are for one's own endpoint; the gateway refuses them.
        let freeLine = provider == .handsyTrial
        let own = freeLine ? Trial.model : role == "planner" ? plannerModel : actorModel
        let model = own.isEmpty ? try await resolvedModel() : own
        var extra = freeLine ? [:] : extra
        if provider == .openRouter, model.hasSuffix(":free"), extra["models"] == nil {
            // When that free model's providers are rate-limited or down, OpenRouter tries two other free vision models.
            let others = freeModels.filter { $0 != model && $0.hasSuffix(":free") }.sorted().prefix(2)
            if !others.isEmpty { extra["models"] = [model] + others }
        }
        // free line: the actor's steps go to Jev first when the deciders say so (race: Jev and the model at
        // once, the first sure answer wins). Read per request: JevGate.hold changes during the run.
        let defaults = defaults
        let jev = { role == "actor" && !JevConfig.ownActive ? Deciders.load(freeLine: true, defaults: defaults)
            .freeLineHeader(race: Deciders.race(defaults)) : [:] }
        // free line: Spark builds the actor's tree (~70 ms, the phone ~1 s) and lists it in the app's format
        let tree = role == "actor" && Self.serverTree(provider) ? ["X-Handsy-Tree": "slim"] : [:]
        // free line: the previous step's timing (seconds only), so slow steps on the phone show on the server
        let step = { role == "actor" ? StepReport.shared.take() : [:] }
        let headers: (() throws -> [String: String])? = freeLine
            ? { try Trial.shared.headers().merging(jev()) { a, _ in a }.merging(tree) { a, _ in a }
                .merging(step()) { a, _ in a } } : nil
        return LLMClient(baseURL: freeLine ? Trial.baseURL : baseURL, model: model, apiKey: apiKey, extra: extra,
                         tokenParam: freeLine ? "auto" : tokenParam, headers: headers)
    }

    /// Own model with Jev on (and agreed to): the run's actor, Jev and the model in the deciders' order.
    /// Nil means the plain model. The free line does this on its server instead (see `client`).
    /// What a run still needs a yes for: the model's host, Jev (when it is on).
    var pendingConsent: (model: Bool, jev: Bool) {
        (!AIConsent.granted(baseURL), jevOn && JevConsent.needed(freeLine: provider == .handsyTrial))
    }

    /// Jev decides steps on this line (on by default on the free line, off on one's own model).
    var jevOn: Bool { Trial.available && Deciders.load(freeLine: provider == .handsyTrial, defaults: defaults).isOn(.jev) }

    func jevActor(around actor: ChatModel) -> JevDeciderModel? {
        let freeLine = provider == .handsyTrial  // the free line asks Handsy's Jev itself, unless Jev has its own key
        guard Trial.available, !freeLine || JevConfig.ownActive, !JevConsent.needed(freeLine: freeLine) else { return nil }
        let deciders = Deciders.load(freeLine: freeLine, defaults: defaults)
        guard deciders.mode != .modelOnly else { return nil }
        return JevDeciderModel(inner: actor, jev: JevConfig.client(), mode: deciders.mode,
                               race: Deciders.race(defaults))
    }
}

enum Keychain {
    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Bundle.main.bundleIdentifier ?? "iphoneagent", kSecAttrAccount: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData] = Data(value.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock  // the agent may run while the phone is locked
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Joins the board's SoftAP with the credentials read over BLE (never shown or logged).
enum Hotspot {
    static func join(_ net: NetConfig) async throws {
        guard let ssid = net.ssid, let pass = net.pass else { throw DeviceError(message: "board sent no hotspot credentials") }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain
                    && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            return
        }
    }

    /// For the debug log: domain, code, the NEHotspotConfigurationError name and the message.
    static func describe(_ e: NSError) -> String {
        guard e.domain == NEHotspotConfigurationErrorDomain else { return "\(e.domain) \(e.code): \(e.localizedDescription)" }
        let names = ["invalid", "invalidSSID", "invalidWPAPassphrase", "invalidWEPPassphrase", "invalidEAPSettings",
                     "invalidHS20Settings", "invalidHS20DomainName", "userDenied", "internal", "pending",
                     "systemConfiguration", "unknown", "joinOnceNotSupported", "alreadyAssociated",
                     "applicationIsNotInForeground", "invalidSSIDPrefix", "userUnauthorized", "systemDenied"]
        let name = names.indices.contains(e.code) ? names[e.code] : "?"
        return "\(e.domain) \(e.code) \(name): \(e.localizedDescription)"
    }

    static func userDenied(_ e: NSError) -> Bool {
        e.domain == NEHotspotConfigurationErrorDomain && e.code == NEHotspotConfigurationError.userDenied.rawValue
    }

    /// This app's page in Settings: the only public link. iOS 18+ has no link to the Wi-Fi page at all.
    @MainActor static func openWiFiSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    /// False while the phone has no Wi-Fi link at all: Wi-Fi is off, or on but on no network. iOS tells apps
    /// nothing about the switch itself, and with Wi-Fi off apply() still "succeeds" without joining.
    nonisolated(unsafe) private(set) static var wifiLink = true
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in wifiLink = path.availableInterfaces.contains { $0.type == .wifi } }
        m.start(queue: DispatchQueue(label: "wifi-path"))
        return m
    }()

    /// Start watching the Wi-Fi link (call early: the first path arrives a moment later).
    static func watchWiFi() { _ = monitor }

    /// The SSID the phone is on, if it is one of ours (needs the hotspot entitlement).
    static func currentSSID() async -> String? {
        await NEHotspotNetwork.fetchCurrent()?.ssid
    }
}

/// A saved custom (Others) endpoint configuration.
struct CustomEndpoint: Identifiable, Equatable {
    let id: String
    let fields: [String: String]
    var baseURL: String { fields["baseURL"] ?? "" }
    var model: String { fields["model"] ?? "" }
    /// Host (and port) of the endpoint, e.g. "192.168.1.4:8080".
    var title: String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

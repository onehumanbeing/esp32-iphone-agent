import CryptoKit
import DeviceCheck
import Foundation
import UIKit

/// The free line: Manina AI's own model on private hardware, free to try while nobody else is using it.
///
/// Only builds that set IA_TRIAL_ORIGIN (the App Store build) show it. The server does the guarding: it only
/// enrolls the signed app (App Attest), limits concurrent runs, and limits each run's time, calls and how
/// many runs an install or network gets. So this client stays small: enroll once, hold one lease per run,
/// add its headers to model requests, and show free / busy.
///
/// To remove it: delete this folder and the lines marked "free line" in ModelProvider, TestedModels,
/// Settings, LLMClient, AppModel, RunSession, StatusChips, ProviderSelectionView, ProviderFields and
/// AIConsentView, plus IA_TRIAL_ORIGIN in project.yml / Shared.xcconfig / Fastfile.
@MainActor final class Trial: ObservableObject {
    static let shared = Trial()
    nonisolated static let origin = (Bundle.main.object(forInfoDictionaryKey: "IATrialOrigin") as? String ?? "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    nonisolated static var available: Bool { URL(string: origin)?.host != nil }
    nonisolated static var baseURL: String { origin + "/v1" }
    nonisolated static let model = "handsy-qwen"
    /// The gateway's planner model for the rounds that need judgement (AgentLoop+Checkpoint).
    nonisolated static let plannerModel = "handsy-planner"
    /// Recording analysis (the gateway's recording.py): owner phones and, later, paying users; never the free line.
    nonisolated static var recordingBaseURL: String { origin + "/recording/v1" }
    nonisolated static let recordingModel = "handsy-recording"
    nonisolated static let consentVersion = "2026-10-19"  // the server's recording-consent version
    nonisolated static var privacyURL: URL? { URL(string: origin + "/privacy") }
    nonisolated static func isTrial(_ baseURL: String) -> Bool {  // its old host too (AIConsent.sameService)
        guard available, let a = URL(string: baseURL)?.host, let b = URL(string: origin)?.host else { return false }
        return AIConsent.service(a) == AIConsent.service(b)
    }

    enum Status { case unknown, free, waiting, busy, usedUp, unavailable }
    @Published private(set) var status = Status.unknown
    /// The server lets this install analyse recordings (`"recording": true` in /trial/status: owner phones).
    @Published private(set) var recordingAllowed = false
    /// Recordings are read: on an owner phone, or with a Manina AI key that pays for it (Henry 2026-11-12).
    var canRecord: Bool { keyed || recordingAllowed }
    private var lease: (id: String, token: String, run: String)?
    /// A Manina AI key (from a Manina AI plan): runs go out under it, on the plan's balance. No lease, no waiting in
    /// line, and the free runs are not counted. Empty: the free line.
    @Published private(set) var key = Keychain.get(Trial.keyAccount) ?? ""
    nonisolated static let keyAccount = "handsy-key"
    /// Henry 2026-11-12: the key can be turned off for a while (Settings › Model, at the bottom) and kept.
    @Published private(set) var keyOn = UserDefaults.standard.object(forKey: Trial.keyOnKey) as? Bool ?? true
    nonisolated static let keyOnKey = "handsyKeyOn"
    /// A key saved on this iPhone, on or off. Text that isn't a key's shape is no key (2026-11-25: anything typed in
    /// the field was saved as one and turned the free line off; its runs were refused at the gateway).
    var hasKey: Bool { Self.keysOffered && Self.looksLikeKey(key) }
    /// Keys exist only in the App Store build (HANDSY_STORE): plans aren't sold anywhere else, so TestFlight and
    /// builds from this repository show no key field, plan card or key-only tool, and ignore a saved key
    /// (Henry 2026-11-25: the field in TestFlight read as "you have to pay").
    #if HANDSY_STORE
    nonisolated(unsafe) static var keysOffered = true
    #else
    nonisolated(unsafe) static var keysOffered = false  // tests of the key path turn it on
    #endif
    /// Runs go out under the key.
    var keyed: Bool { hasKey && keyOn }
    /// A key offered by a link (iphoneagent://key?k=…, from manina.ai): the app asks before it uses it.
    @Published var offeredKey: OfferedKey?
    private var keyRun: String?  // the run under way with the key
    /// The key run under way (X-Run-ID), for a tool its plan pays for.
    var runID: String? { keyRun }
    func setKey(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != key || (!value.isEmpty && !keyOn) else { return }
        end(nil)
        key = value
        Keychain.set(value, for: Self.keyAccount)
        if !value.isEmpty { keyOn = true; UserDefaults.standard.set(true, forKey: Self.keyOnKey) }
        status = .unknown
        Task { await refresh() }
    }
    func setKeyOn(_ on: Bool) {
        guard on != keyOn else { return }
        end(nil)
        keyOn = on
        UserDefaults.standard.set(on, forKey: Self.keyOnKey)
        status = .unknown
        Task { await refresh() }
    }
    /// What a Manina AI key looks like (hsk_live_…, hsk_test_…, then 43 characters; the gateway's own check):
    /// anything else is never saved, from a link or the field.
    nonisolated static func looksLikeKey(_ value: String) -> Bool {
        value.range(of: #"^hsk_(test|live)_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }
    private var keepAlive: Task<Void, Never>?
    private weak var app: AppModel?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// The random ID Manina AI Free keeps this install's records under (shown in Settings › Privacy).
    var installationID: String { deviceID }

    private var deviceID: String {
        if let id = Keychain.get("trial-device-id"), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        Keychain.set(id, for: "trial-device-id")
        return id
    }
    private var token: String? { Keychain.get("trial-device-token").flatMap { $0.isEmpty ? nil : $0 } }

    /// At launch: check the line, and pick it when free and nothing else is set up yet. Rechecks whenever
    /// the app comes to the front, so Home's Model chip says when the line is busy.
    func attach(_ app: AppModel) {
        guard Self.available, self.app == nil else { return }
        self.app = app
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in _ = await Trial.shared.refresh() }
        }
        Task {
            await releaseLeftover()  // before the status check: our own leftover lease would read as busy
            await refresh()
            let settings = app.settings
            if status == .free, settings.provider != .handsyTrial, !settings.isConfigured(settings.provider) {
                settings.selectedProvider = .handsyTrial
            }
        }
    }

    /// Free or busy. Never takes a run: an enrolled install also learns whether its own runs are used up.
    @discardableResult func refresh() async -> Status {
        guard Self.available else { return .unavailable }
        if keyed {  // the plan's own capacity: the free line's state says nothing about it
            status = .free
        } else if lease == nil {  // during our own run the line is ours, the server says busy
            do {
                guard DCAppAttestService.shared.isSupported else { throw TrialError.unsupported }
                let state: Hint
                do { state = try await call("GET", "/trial/status", token: token) } catch TrialError.unenrolled {
                    tokenRefused()  // asks once more as a new install; the next run enrolls again
                    state = try await call("GET", "/trial/status")
                }
                usedUpToday = state.reason == "rate_limit_day"
                recordingAllowed = state.recording == true
                switch (state.status, state.reason) {
                case ("free", _): status = .free
                case ("busy", "quota"), ("busy", "rate_limit_day"): status = .usedUp
                case ("busy", _): status = .busy
                default: status = .waiting  // "waiting" or a newer status: Start waits in line
                }
            } catch {
                status = error is TrialError ? .unavailable : .busy
            }
        }
        if let app, app.settings.provider == .handsyTrial, lease == nil {
            let usable = status == .free || status == .waiting
            app.modelOK = usable
            app.modelError = usable ? nil : (status == .usedUp ? usedUpError : TrialError.busy).localizedDescription
        }
        return status
    }

    /// Before leaving the app for a run: enroll if needed, then take the line (this uses one of the
    /// install's runs). Throws a friendly error when the line is busy.
    /// Before leaving the app: is the line open at all? Says busy/used up while the user can still read it; the
    /// lease itself is claimed only once the screen is ready (`begin`), so a start that fails on the way (board
    /// not on this iPhone, no mirroring) holds no lease and costs no free run.
    func precheck() async throws {
        if keyed { return }
        switch await refresh() {
        case .free, .waiting, .unknown: return
        case .usedUp: throw usedUpError
        case .unavailable: throw TrialError.unavailable
        case .busy: throw TrialError.busy
        }
    }

    /// Claim the run's lease, waiting in line up to `wait` seconds (onWait: the first time it has to wait).
    func begin(wait: TimeInterval = 600, onWait: (() -> Void)? = nil) async throws {
        end(nil)
        if keyed {
            let run = UUID().uuidString.lowercased()
            keyRun = run
            Self.leftover = Leftover(keyRun: run)
            return
        }
        var token = try await enrolledToken(), enrolledAgain = false, releasedLeftover = false
        struct Lease: Decodable { let lease_id: String; let lease_token: String; let generation: Int? }
        let run = UUID().uuidString.lowercased()
        // All places taken: wait in line (first come, first served) by asking again with the same run, as
        // often as the server says. Cancel ends the wait (the place lapses on the server by itself).
        let asked = Date(), waitUntil = asked.addingTimeInterval(wait)
        var taken: Lease, waited = false, dropped = 0
        // Henry 2026-11-19: a claim right after the app went to the background failed in 0.3 s without reaching
        // the server, and the run ended as "busy". A dropped connection is asked again, not taken as a refusal.
        let transportRetries = 5
        while true {
            do {
                taken = try await call("POST", "/trial/leases", token: token,
                                       body: ["run_id": run, "consent_version": Self.consentVersion])
                break
            } catch TrialError.waiting(let ms) where Date() < waitUntil {
                if !waited { onWait?() }
                waited = true
                app?.homeHint = TrialError.waiting(0).localizedDescription
                try await Task.sleep(nanoseconds: UInt64(min(max(ms, 500), 10_000)) * 1_000_000)
            } catch let error as URLError where dropped < transportRetries && !Task.isCancelled {
                dropped += 1
                DebugLog.write("trial: lease request did not reach the line (\(error.code.rawValue)); asking again (\(dropped))")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch TrialError.busy where !releasedLeftover && Self.leftover?.lease != nil {
                releasedLeftover = true  // the line may be busy with our own lease from before the app restarted
                await releaseLeftover()
            } catch TrialError.unenrolled where !enrolledAgain {
                enrolledAgain = true
                tokenRefused()
                token = try await enrolledToken()
            } catch {
                DebugLog.write(String(format: "trial: no lease after %.1f s: %@", Date().timeIntervalSince(asked),
                                      lastRefusal ?? String(describing: error)))
                if error is URLError { throw TrialError.offline }  // never reached the line: not "busy"
                if let e = error as? TrialError, !e.ownText { throw TrialError.busy }  // waited too long, refused
                throw error
            }
        }
        app?.homeHint = String(localized: "Preparing the run…")
        lease = (taken.lease_id, taken.lease_token, run)
        Self.leftover = Leftover(lease: taken.lease_id, leaseToken: taken.lease_token)
        claimedAt = Date()
        leaseLost = false
        lostReason = nil
        status = .busy
        DebugLog.write(String(format: "trial: lease %@ claimed (waited %.1f s)", String(taken.lease_id.prefix(8)),
                              claimedAt.timeIntervalSince(asked)))
        startKeepAlive(generation: taken.generation, token: token)
    }
    private var claimedAt = Date()
    private var holding = false, heldEnd: RunEnd?, holds = 0  // hold(): the ended run's line, kept for one more call
    private var leaseLost = false  // the server ended our lease (idle, time, admin): the run did not end itself
    private var lostReason: String?  // its reason, from the keep-alive
    private var lastRefusal: String?
    private var usedUpToday = false  // .usedUp only for today (rate_limit_day), not all the free runs
    private var usedUpError: TrialError { usedUpToday ? .usedUpToday : .usedUp }

    /// Every 10 s off the main actor: a main thread busy for 30 s (screen tree, a stuck UI) let the lease idle
    /// out while the run was still going.
    private func startKeepAlive(generation: Int?, token: String) {
        keepAlive?.cancel()
        guard let generation, let lease, let url = URL(string: Self.origin + "/trial/leases/\(lease.id)/action") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Device-Model")
        request.setValue(lease.token, forHTTPHeaderField: "X-Lease-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["generation": generation])
        let session = session, id = lease.id
        keepAlive = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                guard let failure = await Self.ping(request, session) else { continue }
                DebugLog.write("trial: keep-alive failed: \(failure)")
                // The server ended this lease (idle, paused, time): final. Stop asking every 10 s, and the run's
                // next model call fails at once (headers).
                if failure.hasPrefix("lease_") || failure == "admin_paused" {
                    await MainActor.run { if self?.lease?.id == id { self?.leaseLost = true; self?.lostReason = failure } }
                    return
                }
            }
        }
    }

    /// One keep-alive: nil when the server took it, else the refusal reason (or the error).
    private nonisolated static func ping(_ request: URLRequest, _ session: URLSession) async -> String? {
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return nil }
            return (try? JSONDecoder().decode(Hint.self, from: data))?.reason ?? "HTTP \(code)"
        } catch { return error.localizedDescription }
    }

    /// A model call was refused because the server ended this run's lease: the run has to stop.
    func runEnded() { if lease != nil, !holding { leaseLost = true } }  // held: the run already ended its own way

    /// The server no longer knows this install's token (401): forget it, so the next request enrolls again
    /// (App Attest) instead of being refused with it every time. A run under way ends: its lease came with that token.
    func tokenRefused() {
        guard token != nil else { return }
        DebugLog.write("trial: device token refused; enrolling again")
        Keychain.set("", for: "trial-device-token")
        jevTicketCache = nil
        runEnded()
    }

    /// Settings › Diagnostics: can the line be reached? Asks its status only, never takes a run.
    func reachable() async -> Bool {
        guard Self.available else { return false }
        let state: Hint? = try? await call("GET", "/trial/status", token: token)
        return state != nil
    }

    /// After a run (or a failed start): give the line back, saying why the run ended (old gateways ignore the
    /// body); the server also ends it on its own when idle. In its own background task: the run's ends right after,
    /// and a DELETE that never went out left the lease to idle out 30 s later.
    func end(_ runEnd: RunEnd?) {
        let ended = holding ? heldEnd ?? runEnd : runEnd  // a held run ends with its own reason
        holding = false
        heldEnd = nil
        keepAlive?.cancel()
        keepAlive = nil
        if let run = keyRun { endKeyRun(run, ended); Self.leftover = nil }
        keyRun = nil
        guard let lease else { return }
        self.lease = nil
        Self.leftover = nil
        guard let token else { return }  // refused (401): nothing to release it with, it idles out on the server
        var runEnd = ended ?? RunEnd(reason: .other, stage: .running)
        if leaseLost, runEnd.reason != .done { runEnd.reason = .leaseLost }
        let held = Date().timeIntervalSince(claimedAt), id = String(lease.id.prefix(8))
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "trial-release") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            var result = "ok"
            for attempt in 0..<2 {
                do {
                    let _: Empty = try await call("DELETE", "/trial/leases/\(lease.id)", token: token,
                                                  leaseToken: lease.token, body: ["run_end": runEnd.json])
                    result = "ok"
                    break
                } catch {
                    result = "failed: " + (lastRefusal ?? error.localizedDescription)
                    guard error is URLError, attempt == 0 else { break }  // a refusal is final; a dropped link, once more
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            DebugLog.write(String(format: "trial: lease %@ released after %.1f s: %@ → %@", id, held, runEnd.logLine, result))
        }
    }

    /// The run is over, but one short call (PlanJudge) still goes out on its line: given back on `release()`, within
    /// PlanJudge.timeout (under the server's 30 s idle end); a new run's `begin` releases it at once.
    /// Returns the hold's number for `release`: a later run's hold is not given back by this one's.
    @discardableResult func hold(_ runEnd: RunEnd?) -> Int {
        holds += 1
        guard lease != nil || keyRun != nil else { end(runEnd); return holds }
        keepAlive?.cancel()
        keepAlive = nil
        holding = true
        heldEnd = runEnd
        return holds
    }

    func release(_ hold: Int) { if holding, hold == holds { end(nil) } }

    /// The run's lease (or key run), on record while it is held: a process killed mid-run (2026-11-20: an app
    /// install) never gave it back, and the next start read "busy" until the gateway's idle timeout.
    struct Leftover: Codable, Equatable { var lease: String?; var leaseToken: String?; var keyRun: String? }
    nonisolated static let leftoverAccount = "trial-held-run"
    static var leftover: Leftover? {
        get { Keychain.get(leftoverAccount).flatMap { try? JSONDecoder().decode(Leftover.self, from: Data($0.utf8)) } ?? leftoverHere }
        set {
            leftoverHere = newValue  // this process's copy, where the keychain can't be written (an unsigned test host in CI)
            Keychain.set(newValue.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                         for: leftoverAccount)
        }
    }
    private static var leftoverHere: Leftover?

    /// At launch (and when a claim is refused as busy): give back what the previous process still held. `send`
    /// gives back a lease: nil when done, else the error (tests stub it). A dropped connection keeps the record
    /// for the next try; anything else is final (the gateway's idle timeout ends it all the same).
    func releaseLeftover(send: ((Leftover) async -> Error?)? = nil) async {
        guard lease == nil, keyRun == nil, let left = Self.leftover else { return }
        let runEnd = RunEnd(reason: .appRestart, stage: .running)
        if let run = left.keyRun {
            Self.leftover = nil
            DebugLog.write("trial: key run \(run.prefix(8)) left by the previous process; ending it")
            endKeyRun(run, runEnd)
        }
        guard let id = left.lease else { return }
        let error: Error?
        if let send { error = await send(left) } else if let token, let leaseToken = left.leaseToken {
            do {
                let _: Empty = try await call("DELETE", "/trial/leases/\(id)", token: token, leaseToken: leaseToken,
                                              body: ["run_end": runEnd.json])
                error = nil
            } catch let failure { error = failure }
        } else { error = TrialError.unenrolled }  // no token to release it with: it idles out on the server
        if !(error is URLError), Self.leftover == left { Self.leftover = nil }
        let result = error.map { "err (" + (lastRefusal ?? String(describing: $0)) + ")" } ?? "ok"
        DebugLog.write("trial: released lease \(id.prefix(8)) left by the previous process → \(result)")
    }

    func headers() throws -> [String: String] {
        if keyed {
            guard let keyRun else { throw TrialError.runsOnly }
            return ["Authorization": "Bearer \(key)", "X-Device-Model": DeviceInfo.model, "X-Run-ID": keyRun]
        }
        guard let lease, let token else { throw TrialError.runsOnly }
        guard !leaseLost else { throw lostReason.map(LLMError.timeUpReasons.contains) == true ? LLMError.trialTimeUp : LLMError.trialRunEnded }  // ended on the server
        return ["Authorization": "Bearer \(token)", "X-Device-ID": deviceID, "X-Device-Model": DeviceInfo.model,
                "X-Lease-ID": lease.id, "X-Lease-Token": lease.token, "X-Run-ID": lease.run]  // X-Request-ID: LLMClient
    }

    /// Recording analysis, no lease: the Manina AI key (it pays per call), else the enrolled install's own token.
    func recordingHeaders() throws -> [String: String] {
        if keyed { return ["Authorization": "Bearer \(key)", "X-Device-Model": DeviceInfo.model] }
        guard let token else { throw TrialError.unavailable }
        return ["Authorization": "Bearer \(token)", "X-Device-ID": deviceID, "X-Device-Model": DeviceInfo.model]
    }

    /// Send a diagnostics report (gzip). Same App Attest enrollment as the free line, so only this app can
    /// send one; it never uses a free run. Returns the report id to quote to the developer.
    func sendReport(_ gzip: Data) async throws -> String {
        guard Self.available else { throw TrialError.unavailable }
        struct Sent: Decodable { let report_id: String }
        let sent: Sent = try await enrolled { try await self.call("POST", "/trial/report", token: $0, gzip: gzip) }
        return sent.report_id
    }

    /// For own-model runs with Jev on: a ticket for Jev's server (no lease, never a free run). Cached until a
    /// minute before it expires; the server gives out a limited number per device and day.
    func jevTicket() async throws -> String {
        if let ticket = jevTicketCache, ticket.until > Date() { return ticket.value }
        guard Self.available else { throw TrialError.unavailable }
        struct Ticket: Decodable { let jev_ticket: String; let expires_in: Int }
        let got: Ticket = try await enrolled { try await self.call("POST", "/trial/jev-ticket", token: $0) }
        jevTicketCache = (got.jev_ticket, Date().addingTimeInterval(Double(got.expires_in) - 60))
        return got.jev_ticket
    }
    private var jevTicketCache: (value: String, until: Date)?

    // MARK: enrollment (once per install)

    /// A request with the install's token; refused with 401, the token is forgotten and enrolled once more.
    private func enrolled<T>(_ request: (String) async throws -> T) async throws -> T {
        do { return try await request(try await enrolledToken()) } catch TrialError.unenrolled {
            tokenRefused()
            return try await request(try await enrolledToken())
        }
    }

    /// The candidate token is saved before registering, so a lost reply is recovered by asking the status
    /// with it; App Attest never attests the same key twice (each attempt makes a new key).
    private func enrolledToken() async throws -> String {
        if let token { return token }
        guard DCAppAttestService.shared.isSupported else { throw TrialError.unsupported }
        var candidate = Keychain.get("trial-pending-token") ?? ""
        if candidate.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TrialError.unsupported }
            candidate = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            Keychain.set(candidate, for: "trial-pending-token")
        } else if await accepted(candidate) {
            return promote(candidate)
        }
        let key = try await DCAppAttestService.shared.generateKey()
        struct Challenge: Decodable { let challenge_id: String; let challenge: String }
        let challenge: Challenge = try await call("POST", "/trial/challenge", body: ["device_id": deviceID, "key_id": key])
        guard let raw = Data(base64Encoded: challenge.challenge), raw.count == 32 else { throw TrialError.unavailable }
        let proof = try await DCAppAttestService.shared.attestKey(key, clientDataHash: Data(SHA256.hash(data: raw)))
        do {
            struct Registered: Decodable { let device_token: String }
            let done: Registered = try await call("POST", "/trial/register", body: [
                "device_id": deviceID, "key_id": key, "challenge_id": challenge.challenge_id,
                "attestation": proof.base64EncodedString(), "device_token": candidate])
            guard done.device_token == candidate else { throw TrialError.unavailable }
        } catch {
            guard await accepted(candidate) else { throw error }  // enrolled, only the reply was lost
        }
        return promote(candidate)
    }

    private func accepted(_ candidate: String) async -> Bool {
        struct State: Decodable { let status: String }
        let state: State? = try? await call("GET", "/trial/status", token: candidate)
        return state != nil
    }

    private func promote(_ candidate: String) -> String {
        Keychain.set(candidate, for: "trial-device-token")
        Keychain.set("", for: "trial-pending-token")
        return candidate
    }

    // MARK: HTTP

    private struct Empty: Decodable {}
    fileprivate struct Hint: Decodable { let status: String?; let retry_after_ms: Int?; let reason: String?; let recording: Bool? }

    /// A key run's end: its hold on the plan is released now, not after the gateway's idle timeout (the plan card
    /// read high for two minutes). 404: the gateway never knew it, done all the same.
    private func endKeyRun(_ run: String, _ runEnd: RunEnd?) {
        guard !key.isEmpty, let url = URL(string: Self.origin + "/trial/key-runs/\(run)/end") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Device-Model")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let end = runEnd ?? RunEnd(reason: .other, stage: .running)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["run_end": end.json])
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "key-run-end") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        Task {
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            let code = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
            DebugLog.write("trial: key run \(run.prefix(8)) ended: \(end.logLine) → HTTP \(code)")
        }
    }

    private func call<T: Decodable>(_ method: String, _ path: String, token: String? = nil, leaseToken: String? = nil,
                                    body: [String: Any]? = nil, gzip: Data? = nil) async throws -> T {
        guard let url = URL(string: Self.origin + path) else { throw TrialError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
            request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Device-Model")  // e.g. iPhone18,2: adapting to screens
        }
        if let leaseToken { request.setValue(leaseToken, forHTTPHeaderField: "X-Lease-Token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let gzip {
            request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            request.httpBody = gzip
        }
        lastRefusal = nil  // a refusal of an earlier call (e.g. a 404 of an optional endpoint) is not this one's
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw token == nil ? TrialError.unavailable : TrialError.unenrolled }  // a token it doesn't know
            // Client contract: 503 "busy" is final; "waiting", an unknown status or none means ask again later.
            let hint = try? JSONDecoder().decode(Hint.self, from: data)
            if code == 503, hint?.status != "busy" { throw TrialError.waiting(hint?.retry_after_ms ?? 2000) }
            lastRefusal = "HTTP \(code) \(hint?.reason ?? "-")"  // the exact cause, for the log; users see TrialError
            throw TrialError.refused(status: code, reason: hint?.reason)
        }
        if T.self == Empty.self, let empty = Empty() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Optimize with AI without one's own model: a job on the server, which picks the model and the machine (Henry
/// 2026-11-19: "把口子给我留出来": off until the server turns it on; a long run may take minutes, so submit and poll).
///   GET  /trial/optimize       -> {"on": bool}
///   POST /trial/optimize       {"system", "input"} -> {"id"}
///   GET  /trial/optimize/<id>  -> {"status": "queued" | "running" | "done" | "failed", "text"?, "retry_after_ms"?}
/// The Manina AI key when one is on (it pays), else the install's own token.
extension Trial {
    private var optimizeToken: String? { keyed ? key : token }

    func optimizeOn() async -> Bool {
        guard Self.available, let auth = optimizeToken else { return false }
        struct On: Decodable { let on: Bool? }
        let reply: On? = try? await call("GET", "/trial/optimize", token: auth)
        return reply?.on == true
    }

    func optimize(system: String, input: String, timeout: Double = 600) async throws -> String {
        guard let auth = optimizeToken else { throw TrialError.unavailable }
        struct Job: Decodable { let id: String }
        struct Progress: Decodable { let status: String; let text: String?; let retry_after_ms: Int? }
        let job: Job = try await call("POST", "/trial/optimize", token: auth, body: ["system": system, "input": input])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let state: Progress = try await call("GET", "/trial/optimize/\(job.id)", token: auth)
            switch state.status {
            case "done": if let text = state.text, !text.isEmpty { return text }; throw TrialError.unavailable
            case "failed": throw TrialError.unavailable
            default: try await Task.sleep(nanoseconds: UInt64(max(state.retry_after_ms ?? 3000, 1000)) * 1_000_000)
            }
        }
        throw TrialError.unavailable
    }
}

/// Why a free-line run ended, sent when its lease is given back (DELETE /trial/leases): a small enum and counts,
/// never task text or screens. Without it the gateway could not tell a user's stop from the app failing.
struct RunEnd: Equatable {
    enum Reason: String {
        case done, userStop = "user_stop", helpStop = "help_stop", failErrors = "fail_errors", stall,
             stepLimit = "step_limit", modelFail = "model_fail", modelError = "model_error",
             blindMirroring = "blind_mirroring", boardLost = "board_lost", leaseLost = "lease_lost",
             startFailed = "start_failed", other
        case appRestart = "app_restart"  // the previous process ended mid-run: given back at the next launch
    }
    enum Stage: String { case startup, running }  // startup: the lease was held but the agent never started

    var outcome = "stopped"  // done | failed | stopped (Outcome)
    var reason: Reason
    var stage: Stage
    var steps = 0, calls = 0
    var firmware: String?
    var planCached: Bool?  // the run started from the intent's saved plan (PlanCache), sent as `plan_cached`
    /// A failed start: the startup step it stopped at (StartupFailure.Step), sent as `step`.
    var step: String?
    /// The link the mouse and keyboard went over (BoardStatus.hidTransport: usb | ble), sent as `transport`.
    var transport: String?
    /// The longest run of gestures in a row that changed nothing on the screen, sent as `unchanged_max`.
    var unchangedMax: Int?
    /// Who stopped a stopped run, sent as `by`: app (the Stop/Cancel button), live_activity, notification, review,
    /// departure (the overlay while leaving the app), debug, user (answered Stop to a question), policy (nobody
    /// answered in time), unknown (cancelled without a Stop).
    var by: String?

    init(reason: Reason, stage: Stage, outcome: String? = nil, steps: Int = 0, calls: Int = 0, firmware: String? = nil) {
        self.reason = reason
        self.stage = stage
        self.outcome = outcome ?? (reason == .done ? "done" : [.userStop, .helpStop].contains(reason) ? "stopped" : "failed")
        self.steps = steps
        self.calls = calls
        self.firmware = firmware
    }

    /// From the run's trace: its last record says how it ended (AgentLoop.run).
    init(steps trace: [JObject], moves: Int, calls: Int, firmware: String?) {
        let last = trace.last?["action"]?.str, why = trace.last?["reason"]?.str ?? ""
        let reason: Reason
        switch last {
        case "done": reason = .done
        case "stopped": reason = trace.dropLast().last?["action"]?.str == "help" ? .helpStop : .userStop
        case "fail":
            if why.hasSuffix(AgentLoop.errorsReason) { reason = .failErrors }
            // gestures that never reach the iPhone are a stall too: the gateway's list of reasons is closed
            // a guard gave up on moves that kept being held back (StuckGuard, PingPongGuard): stuck, not the model
            else if why.hasPrefix(AgentLoop.stallReason) || why == TouchCheck.reason || why.hasPrefix("stuck:") { reason = .stall }
            else if why == AgentLoop.stepLimitReason { reason = .stepLimit }
            else if [.board, .cable, .pointer].contains(where: { Recovery.matches(why, $0) }) { reason = .boardLost }
            else if why == BlindError().reason || why == LinkCheck.reason
                        || ([.locked, .hotspot, .mirroring, .frames] as [Recovery.Part]).contains(where: { Recovery.matches(why, $0) }) {
                reason = .blindMirroring
            } else { reason = .modelFail }  // the model itself said fail
        case "error": reason = .modelError
        default: reason = .other
        }
        self.init(reason: reason, stage: .running, outcome: "\(Outcome(last: last, running: false))", steps: moves,
                  calls: calls, firmware: firmware)
        unchangedMax = Self.longestUnchanged(trace)
    }

    /// Gestures in a row the screen showed no change after; other records (holds, notes) don't break the run.
    static func longestUnchanged(_ trace: [JObject]) -> Int {
        var run = 0, best = 0
        for s in trace where Actions.gestures.contains(s["action"]?.str ?? "") {
            run = s["changed"] == .bool(false) ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var json: [String: Any] {
        var body: [String: Any] = ["outcome": outcome, "reason": reason.rawValue, "stage": stage.rawValue,
                                   "steps": min(max(steps, 0), 10_000), "calls": min(max(calls, 0), 10_000),
                                   "app_version": Self.appVersion]
        if let firmware { body["fw"] = firmware }
        if let step { body["step"] = step }
        if let planCached { body["plan_cached"] = planCached }
        if let transport { body["transport"] = transport }
        if let unchangedMax { body["unchanged_max"] = min(unchangedMax, 10_000) }
        if let by { body["by"] = by }
        return body
    }

    var logLine: String { "\(reason.rawValue), outcome \(outcome), stage \(stage.rawValue), steps \(steps), calls \(calls)" }
}

enum TrialError: LocalizedError {
    case busy, usedUp, usedUpToday, cooldown, unavailable, unsupported, runsOnly
    case offline  // the request did not reach the line (no network, or the connection dropped on the way)
    case keyRefused, keyEmpty  // a Manina AI key the server doesn't accept / whose plan has nothing left
    case unenrolled  // 401: the server doesn't know this install's token; enroll again
    case waiting(Int)  // milliseconds until asking again

    /// A refusal: the free runs (all, or today's) used up and this install's few seconds between runs keep their
    /// own text; any other reason is on the line's side, so the user reads "busy" (the log keeps the reason).
    static func refused(status: Int, reason: String?) -> TrialError {
        switch reason {
        case "quota": return .usedUp
        case "rate_limit_day": return .usedUpToday
        case let r? where r.hasSuffix("cooldown") && r != "global_cooldown": return .cooldown
        default: return status == 429 ? .cooldown : .busy
        }
    }

    /// Not the line's side (used up, a few seconds between runs, this phone or build): shown as is, never as busy.
    var ownText: Bool {
        switch self {
        case .usedUp, .usedUpToday, .cooldown, .unsupported, .runsOnly, .keyRefused, .keyEmpty, .offline: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .waiting: return String(localized: "Manina AI Free is busy — waiting in line…")
        case .usedUp: return String(localized: "You've used the free runs on this iPhone. Add your own model to keep going.")
        case .usedUpToday: return String(localized: "You've used today's free runs on this iPhone. Try again tomorrow, or add your own model.")
        case .cooldown: return String(localized: "Manina AI Free needs a few seconds between runs. Try again in a moment.")
        case .busy: return String(localized: "Manina AI Free is busy right now — lots of people are using it. Please try again in a moment.")
        case .unavailable, .unenrolled: return String(localized: "Manina AI Free isn't available on this phone right now. Use your own model instead.")
        case .unsupported: return String(localized: "Manina AI Free needs the App Store version on a real iPhone.")
        case .keyRefused: return String(localized: "This Manina AI key isn't accepted. Check it in Settings › Model, or remove it to use the free runs.")
        case .keyEmpty: return String(localized: "This Manina AI key has no balance left. Remove it to use the free runs, or add your own model.")
        case .runsOnly: return String(localized: "Manina AI Free only runs tasks. Use your own model for tests and intent analysis.")
        case .offline: return String(localized: "Couldn't reach Manina AI Free. Check the internet connection and try again.")
        }
    }
}

/// A key from a link, waiting for the user's yes.
struct OfferedKey: Identifiable, Equatable {
    let key: String
    var id: String { key }
}

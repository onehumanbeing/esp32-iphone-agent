import CryptoKit
import DeviceCheck
import Foundation
import UIKit

/// The free line: Handsy's own model on private hardware, free to try while nobody else is using it.
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
    nonisolated static let consentVersion = "2026-10-19"  // the server's recording-consent version
    nonisolated static var privacyURL: URL? { URL(string: origin + "/privacy") }
    nonisolated static func isTrial(_ baseURL: String) -> Bool { available && URL(string: baseURL)?.host == URL(string: origin)?.host }

    enum Status { case unknown, free, waiting, busy, usedUp, unavailable }
    @Published private(set) var status = Status.unknown
    private var lease: (id: String, token: String, run: String)?
    private var keepAlive: Task<Void, Never>?
    private weak var app: AppModel?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

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
        if lease == nil {  // during our own run the line is ours, the server says busy
            do {
                guard DCAppAttestService.shared.isSupported else { throw TrialError.unsupported }
                let state: Hint = try await call("GET", "/trial/status", token: token)
                switch (state.status, state.reason) {
                case ("free", _): status = .free
                case ("busy", "quota"): status = .usedUp
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
            app.modelError = usable ? nil : (status == .usedUp ? TrialError.usedUp : TrialError.busy).localizedDescription
        }
        return status
    }

    /// Before leaving the app for a run: enroll if needed, then take the line (this uses one of the
    /// install's runs). Throws a friendly error when the line is busy.
    func begin() async throws {
        end()
        let token = try await enrolledToken()
        struct Lease: Decodable { let lease_id: String; let lease_token: String; let generation: Int? }
        let run = UUID().uuidString.lowercased()
        // All places taken: wait in line (first come, first served) by asking again with the same run, as
        // often as the server says. Cancel ends the wait (the place lapses on the server by itself).
        let waitUntil = Date().addingTimeInterval(600)
        var taken: Lease
        while true {
            do {
                taken = try await call("POST", "/trial/leases", token: token,
                                       body: ["run_id": run, "consent_version": Self.consentVersion])
                break
            } catch TrialError.waiting(let ms) where Date() < waitUntil {
                app?.homeHint = String(localized: "Waiting for the free line…")
                try await Task.sleep(nanoseconds: UInt64(min(max(ms, 500), 10_000)) * 1_000_000)
            }
        }
        app?.homeHint = String(localized: "Preparing the run…")
        lease = (taken.lease_id, taken.lease_token, run)
        status = .busy
        startKeepAlive(generation: taken.generation, token: token)
    }

    /// The server ends a lease after 30 s without model work or actions. A run can pause longer between model
    /// calls (2026-10-20: 38 s getting back out of this app after a stray tap, then every call got 503 busy), so
    /// report the run's activity every 10 s while it holds the line.
    private func startKeepAlive(generation: Int?, token: String) {
        keepAlive?.cancel()
        guard let generation, let lease else { return }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled, self.lease?.id == lease.id else { return }
                do {
                    let _: Empty = try await self.call("POST", "/trial/leases/\(lease.id)/action", token: token,
                                                       leaseToken: lease.token, body: ["generation": generation])
                } catch {
                    DebugLog.write("trial: keep-alive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// After a run (or a failed start): give the line back; the server also ends it on its own when idle.
    func end() {
        keepAlive?.cancel()
        keepAlive = nil
        guard let lease, let token else { return }
        self.lease = nil
        Task { let _: Empty? = try? await call("DELETE", "/trial/leases/\(lease.id)", token: token, leaseToken: lease.token) }
    }

    /// Headers for one model request. Only during a run: tests, intent analysis and the like need your own model.
    func headers() throws -> [String: String] {
        guard let lease, let token else { throw TrialError.runsOnly }
        return ["Authorization": "Bearer \(token)", "X-Device-ID": deviceID, "X-Lease-ID": lease.id,
                "X-Lease-Token": lease.token, "X-Run-ID": lease.run, "X-Request-ID": UUID().uuidString.lowercased()]
    }

    /// Send a diagnostics report (gzip). Same App Attest enrollment as the free line, so only this app can
    /// send one; it never uses a free run. Returns the report id to quote to the developer.
    func sendReport(_ gzip: Data) async throws -> String {
        guard Self.available else { throw TrialError.unavailable }
        let token = try await enrolledToken()
        struct Sent: Decodable { let report_id: String }
        let sent: Sent = try await call("POST", "/trial/report", token: token, gzip: gzip)
        return sent.report_id
    }

    // MARK: enrollment (once per install)

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
    private struct Hint: Decodable { let status: String?; let retry_after_ms: Int?; let reason: String? }

    private func call<T: Decodable>(_ method: String, _ path: String, token: String? = nil, leaseToken: String? = nil,
                                    body: [String: Any]? = nil, gzip: Data? = nil) async throws -> T {
        guard let url = URL(string: Self.origin + path) else { throw TrialError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
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
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw TrialError.unavailable }
            // Client contract: 503 "busy" is final; "waiting", an unknown status or none means ask again later.
            let hint = try? JSONDecoder().decode(Hint.self, from: data)
            if code == 503, hint?.status != "busy" { throw TrialError.waiting(hint?.retry_after_ms ?? 2000) }
            throw hint?.reason == "quota" ? TrialError.usedUp : TrialError.busy
        }
        if T.self == Empty.self, let empty = Empty() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum TrialError: LocalizedError {
    case busy, usedUp, unavailable, unsupported, runsOnly
    case waiting(Int)  // milliseconds until asking again
    var errorDescription: String? {
        switch self {
        case .waiting: return String(localized: "Waiting for the free line…")
        case .usedUp: return String(localized: "You've used the free runs on this iPhone. Add your own model to keep going.")
        case .busy: return String(localized: "The free line is busy or your free runs are used up. Try again in a few minutes, or use your own model.")
        case .unavailable: return String(localized: "The free line isn't available on this phone right now. Use your own model instead.")
        case .unsupported: return String(localized: "The free line needs the App Store version on a real iPhone.")
        case .runsOnly: return String(localized: "The free line only runs tasks. Use your own model for tests and intent analysis.")
        }
    }
}

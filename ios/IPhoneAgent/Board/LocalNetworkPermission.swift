import Foundation
import Network

/// The Local Network permission the Wi-Fi video needs (without it a socket to the board just reports "Network
/// is down" and video stays on BLE). iOS prompts the first time the app touches the local network and never
/// tells the app the answer, so: browse for our own Bonjour service. Browsing raises the prompt; finding our
/// listener means it was allowed.
///
/// Asked from the idle home screen, once per launch, at most `maxAttempts` times in all, then never again:
/// BLE carries the video without it, just slower.
@MainActor enum LocalNetworkPermission {
    static let service = "_esp32agent._tcp"  // also in Info.plist NSBonjourServices
    static let maxAttempts = 3
    private static let grantedKey = "localNetworkGranted", attemptsKey = "localNetworkAttempts"
    private static var askedThisLaunch = false

    static var granted: Bool {
        get { UserDefaults.standard.bool(forKey: grantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: grantedKey) }
    }

    static func askIfNeeded() {
        let attempts = UserDefaults.standard.integer(forKey: attemptsKey)
        guard !granted, !askedThisLaunch, attempts < maxAttempts else { return }
        askedThisLaunch = true
        UserDefaults.standard.set(attempts + 1, forKey: attemptsKey)
        Probe().run(timeout: 20) { allowed in
            DispatchQueue.main.async {
                if allowed == true { granted = true }
                DebugLog.write("local network: \(allowed.map { $0 ? "allowed" : "denied" } ?? "no answer")"
                               + " (ask \(attempts + 1)/\(maxAttempts))")
            }
        }
    }

    /// A Bonjour listener and a browser for it; everything runs on `queue`.
    private final class Probe: @unchecked Sendable {
        private let queue = DispatchQueue(label: "local-network-probe")
        private var listener: NWListener?
        private var browser: NWBrowser?
        private var done: ((Bool?) -> Void)?
        private var denied = false

        func run(timeout: Double, done: @escaping (Bool?) -> Void) {
            queue.async { [self] in
                self.done = done
                do {
                    let l = try NWListener(using: .tcp)
                    l.service = NWListener.Service(name: UUID().uuidString, type: LocalNetworkPermission.service)
                    l.newConnectionHandler = { $0.cancel() }
                    l.stateUpdateHandler = { [self] in if case .failed = $0 { finish(nil) } }
                    l.start(queue: queue)
                    listener = l
                } catch { return finish(nil) }
                let b = NWBrowser(for: .bonjour(type: LocalNetworkPermission.service, domain: nil), using: NWParameters())
                // PolicyDenied also shows while the prompt is still up: only a verdict once the time is over.
                b.stateUpdateHandler = { [self] state in
                    if case .waiting(let e) = state, case .dns(let code) = e,
                       code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { denied = true }
                }
                b.browseResultsChangedHandler = { [self] results, _ in if !results.isEmpty { finish(true) } }
                b.start(queue: queue)
                browser = b
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(denied ? false : nil) }
            }
        }

        private func finish(_ allowed: Bool?) {
            guard let done else { return }
            self.done = nil
            listener?.cancel()
            browser?.cancel()
            done(allowed)
        }
    }
}

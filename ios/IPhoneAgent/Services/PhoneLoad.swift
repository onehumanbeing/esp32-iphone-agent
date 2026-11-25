import Foundation
import UIKit

/// The iPhone itself is slow: the app's main thread keeps waiting seconds for its turn (MainLag). Shown as a tip on
/// Home, so a slow run is not taken for the app's fault. Henry 2026-11-25: right after an update to iOS 27 the
/// main thread stalled 3-11 s every few seconds for minutes (mostly "system only": the app got no CPU), the first
/// frame took 10 s and the phone felt slow everywhere.
@MainActor final class PhoneLoad: ObservableObject {
    static let shared = PhoneLoad()
    @Published private(set) var slow = false

    /// Share of a stall's samples outside the app's code for it to count (the phone was busy, not the app).
    nonisolated static let systemShare = 0.75
    /// A stall this long counts; `count` of them within `window` seconds make the phone slow; it is fine again
    /// after `calm` seconds without one.
    nonisolated static let stallSeconds = 2.0, count = 3, window = 120.0, calm = 300.0
    private var stalls: [Double] = []
    private var clear: Task<Void, Never>?

    func stall(_ seconds: Double, at t: Double = now()) {
        guard seconds >= Self.stallSeconds else { return }
        stalls = (stalls + [t]).filter { t - $0 <= Self.window }
        guard Self.isSlow(stalls, at: t) else { return }
        if !slow { DebugLog.write("phone load: \(stalls.count) main-thread stalls over \(Int(Self.stallSeconds)) s in \(Int(Self.window)) s; showing the slow-phone tip") }
        slow = true
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.calm * 1e9))
            guard !Task.isCancelled else { return }
            self?.slow = false
        }
    }

    nonisolated static func isSlow(_ stalls: [Double], at t: Double) -> Bool {
        stalls.filter { t - $0 <= window }.count >= count
    }

    /// The tip: names the update when iOS changed in the last two days.
    var tip: String {
        if let version = OSUpdate.recent() {
            return String(localized: "This iPhone is running slowly. It was updated to iOS \(version) recently: for a few hours after an update iOS works in the background and every app is slower. Leave it charging on Wi-Fi for a while, then try again.")
        }
        return String(localized: "This iPhone is running slowly right now, so runs are slower too. If you updated iOS recently, it is still working in the background: leave it charging on Wi-Fi for a while. Closing other apps can help.")
    }
}

/// When this iPhone's iOS version last changed, as seen by the app at launch.
enum OSUpdate {
    static let versionKey = "osUpdate.version", changedKey = "osUpdate.changed"
    nonisolated static let recentFor = 48 * 3600.0

    /// At launch: a new version since the last launch is an update now (the first launch ever records none).
    static func note(_ version: String = UIDevice.current.systemVersion, at t: Double = now(),
                     defaults: UserDefaults = .standard) {
        let seen = defaults.string(forKey: versionKey)
        guard seen != version else { return }
        defaults.set(version, forKey: versionKey)
        if seen != nil { defaults.set(t, forKey: changedKey) }
    }

    /// The version when it changed within `recentFor`, else nil.
    static func recent(at t: Double = now(), defaults: UserDefaults = .standard) -> String? {
        let changed = defaults.double(forKey: changedKey)
        guard changed > 0, t - changed < recentFor else { return nil }
        return defaults.string(forKey: versionKey)
    }
}

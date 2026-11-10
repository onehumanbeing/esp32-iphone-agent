import Foundation

/// App Store builds (IA_STORE_BUILD, set only by fastlane): nothing goes to a model endpoint until the user
/// agrees to send screenshots and task text to that host, per host; withdrawn in Settings › Privacy.
/// Builds from source have no gate (the developer chose the endpoint). Every request passes `check`.
enum AIConsent {
    static let key = "aiConsentHost"
    nonisolated(unsafe) static var store = (Bundle.main.object(forInfoDictionaryKey: "IAStoreBuild") as? String) == "YES"  // var: tests

    static func host(_ baseURL: String) -> String { URL(string: baseURL)?.host ?? baseURL }

    static func granted(_ baseURL: String) -> Bool {
        !store || UserDefaults.standard.string(forKey: key) == host(baseURL)
    }

    static func grant(_ baseURL: String) { UserDefaults.standard.set(host(baseURL), forKey: key) }
    static func revoke() { UserDefaults.standard.removeObject(forKey: key) }
    static var grantedHost: String? { UserDefaults.standard.string(forKey: key) }

    /// Thrown before any request the user has not agreed to.
    static func check(_ baseURL: String) throws {
        guard granted(baseURL) else {
            throw LLMError(message: String(localized: "Allow sending screenshots and your task to \(host(baseURL)) first (Settings › Model)."))
        }
    }
}

extension Settings {
    /// The yes the consent sheets record: the model's current host and/or Jev's current target. Another host or
    /// Jev target later is not covered and is asked again (pendingConsent).
    func grantConsent(model: Bool, jev: Bool) {
        if model {
            AIConsent.grant(baseURL)
            Analytics.capture("ai_consent", ["granted": true])
        }
        if jev {
            JevConsent.grant()
            Analytics.capture("jev_consent", ["granted": true])
        }
        consentChanged()
    }
}

/// First launch: one sheet says what a run sends (the model once one is set up, Jev when it is on) and what is
/// kept here. Agree records the same yes as SendConsentSheet; Not Now records none, so the first run still asks.
@MainActor enum FirstConsent {
    static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: RunShare.askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: RunShare.askedKey) }
    }

    static func parts(_ settings: Settings) -> (model: Bool, jev: Bool) { (settings.isConfigured, settings.jevOn) }

    static func agree(_ settings: Settings) {
        let parts = parts(settings)
        settings.grantConsent(model: parts.model, jev: parts.jev)
        asked = true
    }

    static func notNow() { asked = true }
}

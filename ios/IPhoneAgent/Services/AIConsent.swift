import Foundation

/// App Store builds (IA_STORE_BUILD, set only by fastlane): nothing goes to a model endpoint until the user
/// agrees to send screenshots and task text to that host, per host; withdrawn in Settings › Privacy.
/// Builds from source have no gate (the developer chose the endpoint). Every request passes `check`.
enum AIConsent {
    static let key = "aiConsentHost"
    static let store = (Bundle.main.object(forInfoDictionaryKey: "IAStoreBuild") as? String) == "YES"

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

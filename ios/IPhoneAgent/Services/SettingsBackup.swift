import Foundation

/// The model setup (provider, endpoints, models, the "Others" list) mirrored into the Keychain, so a
/// reinstall finds it again: UserDefaults goes with the app, the Keychain stays. The keys themselves are already
/// Keychain items per endpoint. Device-only (not synced) and readable only by this app.
@MainActor enum SettingsBackup {
    static let account = "llm-config"
    static var keys: [String] {
        ["baseURL", "model", "autoModel", "plannerModel", "actorModel", "tokenParam", "extraBody", "modelProvider",
         "customEndpoints", "customEndpointID", Settings.agentNameKey]
            + ModelProvider.allCases.map { "modelProfile." + $0.rawValue }
    }
    private static var pending: Task<Void, Never>?

    /// A fresh install (none of the keys set): put the saved setup back before Settings reads it.
    static func restoreIfFresh(_ defaults: UserDefaults) {
        guard !keys.contains(where: { defaults.object(forKey: $0) != nil }),
              let text = Keychain.get(account), let data = Data(base64Encoded: text),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for (k, v) in saved where keys.contains(k) { defaults.set(v, forKey: k) }
        DebugLog.write("settings: model setup restored from the Keychain (\(saved.count) values)")
    }

    /// Save the current setup a moment after it changes (one write for a burst of changes).
    static func schedule(_ defaults: UserDefaults) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save(defaults)
        }
    }

    static func save(_ defaults: UserDefaults) {
        var snapshot: [String: Any] = [:]
        for k in keys { if let v = defaults.object(forKey: k) { snapshot[k] = v } }
        guard !snapshot.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return }
        let text = data.base64EncodedString()
        if Keychain.get(account) != text { Keychain.set(text, for: account) }
    }
}

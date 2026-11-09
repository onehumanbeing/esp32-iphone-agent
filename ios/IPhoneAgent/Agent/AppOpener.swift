import Foundation

/// What `open APP` found, for the model's next round (AgentLoop.effect).
enum OpenResult: String {
    case opened, notFound = "not_found", notOpened = "not_opened"
    case unchecked  // no live screen: the keys went out, nothing was read back
}

/// `open APP` done by code, read back on the screen: the Home key, Spotlight (cmd+space), the name typed, Return
/// only once the results list the name, then a check that the screen left Spotlight and the Home Screen.
/// The model used to tap the app in the results itself: a tap that missed closed Spotlight back to the Home
/// Screen, and a Chinese name could stay uncommitted pinyin that never found the app.
/// A name Spotlight does not know ("闹钟") is tried once more under its system names (AppNames: 时钟, Clock; the
/// device language's name first).
/// Bounded: `tries` rounds of a few keys per name, at most three names, every look has a ceiling; the result goes
/// to the model, which decides.
@MainActor struct AppOpener {
    var home: () async throws -> Void
    var key: (String) async throws -> Void
    var type: (String) async throws -> Void
    /// The screen once it settled; nil = no live screen.
    var look: () async -> Data?
    /// The text lines on a frame (OCR).
    var read: (Data) async -> [String]
    /// The agent app itself came to the front (a tap on its notification, its own shortcut as the top hit).
    var ownAppInFront: () -> Bool = { false }
    var same: (Data?, Data?) -> Bool = { Vision.similar($0, $1) }
    var pause: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    /// Picks the other names to try (AppNames.language).
    var language = AppNames.deviceLanguage
    static let tries = 2

    func open(_ name: String) async throws -> OpenResult {
        let result = try await open(named: name)
        guard result == .notFound else { return result }
        for other in AppNames.alternatives(name, language: language) {
            let found = try await open(named: other)
            if found == .opened || found == .notOpened { return found }  // listed under that name
        }
        return .notFound
    }

    private func open(named name: String) async throws -> OpenResult {
        for _ in 0..<Self.tries {
            try await home()
            try await pause(0.4)
            let homeFrame = await look()
            try await key("cmd+space")
            try await pause(0.7)
            try await type(name)  // a Chinese name goes in through the pinyin keyboard, committed (HanTyper)
            guard let results = await look() else { return .unchecked }
            if same(results, homeFrame) { continue }  // Spotlight did not come up
            guard Self.listed(name, in: await read(results)) else { return .notFound }  // Spotlight stays for the model
            try await key("enter")  // opens the top hit
            let after = await look()
            if !ownAppInFront(), !same(after, results), !same(after, homeFrame) { return .opened }
        }
        return .notOpened
    }

    /// The name shows in the search field and again in the results (a label cut short with "…" counts):
    /// only the field = no such app; Return would open whatever matched instead (a message, 2026-11-03).
    static func listed(_ name: String, in lines: [String]) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let want = norm(name)
        guard !want.isEmpty else { return false }
        let hits = lines.map(norm).filter { line in
            if line.contains(want) { return true }
            let cut = line.hasSuffix("…") ? String(line.dropLast()) : line.hasSuffix("...") ? String(line.dropLast(3)) : nil
            return cut.map { $0.count >= 3 && want.hasPrefix($0) } ?? false
        }
        return hits.count >= 2
    }
}

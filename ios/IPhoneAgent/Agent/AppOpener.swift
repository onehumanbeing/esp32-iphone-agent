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
/// Only the name asked for; a name Spotlight does not list goes back to the model, which picks another.
/// A name the board cannot type (kana, Hangul; Han off a Chinese iPhone, where no pinyin keyboard may be set up) is
/// put on the clipboard once and pasted into Spotlight (cmd+v); without the clipboard it is not typed at all.
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
    /// Puts text on the clipboard (the agent app hops to the front and back home); nil = no clipboard here.
    var paste: ((String) async throws -> Bool)?
    /// Taps the Home Screen's Search button; false = none on screen. Used only after cmd+space brought nothing up.
    var searchButton: (() async throws -> Bool)?
    static let tries = 2
    static let relooks = 2

    func open(_ name: String) async throws -> OpenResult {
        // Only the name asked for: the model sees the iPhone's language on screen and picks another name itself.
        // Code trying other names (电话 after Phone) switched an English iPhone to pinyin and opened a note (2026-11-13).
        try await open(named: name)
    }

    /// Whether `name` goes in by the clipboard: the board types ASCII and accented Latin, and Chinese only on a
    /// Chinese iPhone (its pinyin keyboard).
    func pastes(_ name: String) -> Bool {
        Scripts.needsPaste(name) || HanTyper.isHan(name) && !language.hasPrefix("zh") && paste != nil
    }

    private func open(named name: String) async throws -> OpenResult {
        let pasting = pastes(name)
        if pasting { guard let paste, try await paste(name) else { return .notFound } }  // never typed as garbage
        let labels = AppNames.labels(name, language: language)
        var button = false  // cmd+space did not bring Spotlight up last try (2026-11-13, twice in one run)
        for _ in 0..<Self.tries {
            try await home()
            try await pause(0.4)
            let homeFrame = await look()
            if button, let searchButton, try await searchButton() {} else { try await key("cmd+space") }
            try await pause(0.7)
            // Spotlight brings back the last query and typing appends to it (2026-11-11: "GoogleMaps" + "Google Maps")
            try await key("cmd+a")
            try await key("backspace")
            // a Chinese name goes in through the pinyin keyboard, committed (HanTyper)
            if pasting { try await key("cmd+v") } else { try await type(name) }
            guard var results = await look() else { return .unchecked }
            // Read first: with the board's keyboard iOS shows no on-screen one, so on a plain wallpaper Spotlight
            // looks much like the Home Screen (2026-11-11: WeChat listed, judged "did not come up" twice).
            var lines = await read(results)
            // The field and the results lag the typing by up to ~1.5 s: the first look still had an empty field over
            // Siri Suggestions, so "WeChat" read as not found and it went on to type 微信 (2026-11-12). Look again
            // (not "while the screen changes": the typed name in the field alone is too small a change for `same`).
            for _ in 0..<Self.relooks where !Self.listed(name, in: lines, as: labels) && !same(results, homeFrame) {
                try await pause(0.6)
                guard let again = await look() else { break }
                results = again
                lines = await read(again)
            }
            if !Self.listed(name, in: lines, as: labels) {
                if same(results, homeFrame) { button = true; continue }  // Spotlight did not come up
                // The typed name is nowhere new on screen: cmd+space did nothing and the frames differ only where
                // something moves (the Live Activity). 2026-11-13: read as "no such app", so it went on to 电话 on an
                // English iPhone and Return opened a note; the Search button next time instead.
                let before = await homeFrame.asyncMap(read) ?? []
                if Self.count(name, in: lines) <= Self.count(name, in: before) { button = true; continue }
                return .notFound  // Spotlight stays for the model
            }
            try await key("enter")  // opens the top hit
            guard let after = await look() else { return .unchecked }
            if ownAppInFront() { continue }
            if !same(after, results), !same(after, homeFrame) { return .opened }
            if !Self.listed(name, in: await read(after), as: labels) { return .opened }  // a plain screen: Spotlight is gone
        }
        return .notOpened
    }

    /// Lines that show `name` (folded).
    static func count(_ name: String, in lines: [String]) -> Int {
        let want = Scripts.fold(name)
        return want.isEmpty ? 0 : lines.filter { Scripts.fold($0).contains(want) }.count
    }

    /// The name shows in the search field and again in the results (a label cut short with "…" counts):
    /// only the field = no such app; Return would open whatever matched instead (a message, 2026-11-03).
    /// The results may list the app under another of its `labels` (the iPhone's language: "Notes" typed, メモ
    /// listed); widths and kana are folded (Scripts.fold).
    static func listed(_ name: String, in lines: [String], as labels: [String] = []) -> Bool {
        func shows(_ want: String, _ line: String) -> Bool {
            if line.contains(want) { return true }
            let cut = line.hasSuffix("…") ? String(line.dropLast()) : line.hasSuffix("...") ? String(line.dropLast(3)) : nil
            return cut.map { $0.count >= 3 && want.hasPrefix($0) } ?? false
        }
        let want = Scripts.fold(name), others = labels.map(Scripts.fold).filter { !$0.isEmpty && $0 != want }
        guard !want.isEmpty else { return false }
        let folded = lines.map(Scripts.fold)
        let typed = folded.filter { shows(want, $0) }.count
        return typed >= 2 || typed >= 1 && folded.contains { line in !shows(want, line) && others.contains { shows($0, line) } }
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await f(self)
    }
}

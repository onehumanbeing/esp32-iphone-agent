import CoreGraphics
import Foundation

/// What `open APP` found, for the model's next round (AgentLoop.effect).
enum OpenResult: String {
    case opened, notFound = "not_found", notOpened = "not_opened"
    case already = "already_open"  // this run opened it and has not left it since: nothing was sent (AlreadyOpen)
    case unchecked  // no live screen: the keys went out, nothing was read back
}

/// `open APP` done by code, read back on the screen: the Home key, Spotlight (cmd+space), the name typed, its listed
/// row tapped (Return only when no row is read), then a check that the screen left Spotlight and the Home Screen.
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
    /// A new screen rather than the same one redrawn (Spotlight after its letters were committed).
    var big: (Data?, Data?) -> Bool = { Vision.bigChange($0, $1) }
    var pause: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    /// Picks the other names to try (AppNames.language).
    var language = AppNames.deviceLanguage
    /// Puts text on the clipboard (the agent app hops to the front and back home); nil = no clipboard here.
    var paste: ((String) async throws -> Bool)?
    /// Taps the Home Screen's Search button; false = none on screen. Used only after cmd+space brought nothing up in this open.
    var searchButton: (() async throws -> Bool)?
    /// The text lines on a frame with their boxes (pixels, top-left origin) and the frame's size, for tapping a
    /// listed result; nil = no tapping (tests, no screen).
    var readBoxes: ((Data) async -> (lines: [(text: String, box: [Int])], size: CGSize))?
    /// Taps a point (screen fractions), aimed.
    var tapAt: ((CGPoint) async throws -> Void)?
    /// The clock for `budget` (seconds).
    var clock: () -> Double = { CFAbsoluteTimeGetCurrent() }
    var log: (String) -> Void = { DebugLog.write($0) }
    static let tries = 2
    static let relooks = 2
    /// The whole open: no new try and no tap on a listed result after this many seconds; the model decides then
    /// (2026-11-17: opens took 20-92 s, one 57 s and not opened; most of it pointer searches for the Search button
    /// and the result row).
    static let budget = 15.0

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

    /// What goes into Spotlight for `name`, in order. A Chinese name goes in as its pinyin letters first, typed on
    /// the English keyboard (Spotlight matches app names by pinyin): no input method, no candidate to pick, nothing
    /// left uncommitted in the field. The name itself, through the pinyin keyboard, only when the letters list nothing. The same name either way, never another one.
    static func queries(_ name: String, pasting: Bool) -> [String] {
        guard !pasting, HanTyper.isHan(name), name.allSatisfy({ HanTyper.isHan(String($0)) || $0 == " " }) else { return [name] }
        let letters = Pointer.typeable(name).lowercased().filter { $0.isLetter }
        return letters.count >= 2 ? [letters, name] : [name]
    }

    private func open(named name: String) async throws -> OpenResult {
        let pasting = pastes(name)
        if pasting { guard let paste, try await paste(name) else { return .notFound } }  // never typed as garbage
        let queries = Self.queries(name, pasting: pasting)
        for (i, query) in queries.enumerated() {
            let result = try await open(name, typing: query, pasting: pasting)
            if result == .notFound, i < queries.count - 1 { continue }  // Home first again: nothing left in the field
            return result
        }
        return .notFound
    }

    private func open(_ name: String, typing query: String, pasting: Bool) async throws -> OpenResult {
        let labels = AppNames.labels(name, language: language)
        // typed as itself, the field shows the name too, so a result row makes two; typed as letters, one row more
        // than the Home Screen showed (its icon label) is enough
        var onHome = 0
        func shows(_ lines: [String]) -> Bool {
            Self.listed(name, in: lines, as: labels) || query != name && Self.count(name, in: lines) > onHome
        }
        // cmd+space first on every open (0.2 s); the Search button (a pointer search, 10-24 s) only after it brought
        // nothing up in this open. 2026-11-17: a "Search button first" kept across runs since one miss on 11-13 meant
        // cmd+space was never sent again, and the log said it had failed each time.
        var button = false
        let started = clock()
        func overBudget() -> Bool { clock() - started > Self.budget }
        for attempt in 0..<Self.tries {
            if attempt > 0, overBudget() { return .notOpened }
            try await home()
            try await pause(0.4)
            let homeFrame = await look()
            // the Home Screen's words are read while Spotlight opens and the name is typed, not before it (an OCR
            // read is 1-3 s, 13 s on an iPhone X; 2026-11-25: an open took 21 s at the median)
            let reading = homeFrame.map { frame in Task { await read(frame) } }
            defer { reading?.cancel() }
            func homeLines() async -> [String] { await reading?.value ?? [] }
            if button, let searchButton, try await searchButton() {} else { try await key("cmd+space") }
            try await pause(0.7)
            // Spotlight brings back the last query and typing appends to it (2026-11-11: "GoogleMaps" + "Google Maps")
            try await key("cmd+a")
            try await key("backspace")
            // letters on the English keyboard; a Chinese name itself through the pinyin keyboard, committed (HanTyper)
            if pasting { try await key("cmd+v") } else { try await type(query) }
            guard var results = await look() else { return .unchecked }
            // Read first: with the board's keyboard iOS shows no on-screen one, so on a plain wallpaper Spotlight
            // looks much like the Home Screen (2026-11-11: WeChat listed, judged "did not come up" twice).
            var lines = await read(results)
            if query != name { onHome = Self.count(name, in: await homeLines()) }
            // The field and the results lag the typing by up to ~1.5 s: the first look still had an empty field over
            // Siri Suggestions, so "WeChat" read as not found and it went on to type 微信 (2026-11-12). Look again
            // (not "while the screen changes": the typed name in the field alone is too small a change for `same`).
            for _ in 0..<Self.relooks where !shows(lines) && !same(results, homeFrame) {
                try await pause(0.6)
                guard let again = await look() else { break }
                results = again
                lines = await read(again)
            }
            if !shows(lines) {
                if same(results, homeFrame) { button = true; continue }  // Spotlight did not come up
                // The typed name is nowhere new on screen: cmd+space did nothing and the frames differ only where
                // something moves (the Live Activity). 2026-11-13: read as "no such app", so it went on to 电话 on an
                // English iPhone and Return opened a note; the Search button next time instead.
                let before = await homeLines()
                if Self.count(query, in: lines) <= Self.count(query, in: before) { button = true; continue }
                return .notFound  // Spotlight stays for the model
            }
            // The results list the app: tap its row. Return only when no row is read, or a tap left Spotlight up:
            // with the pinyin keyboard on, the typed letters are still composing and Return commits them instead
            // of opening the top hit (2026-11-20: `open Pocket Chess` reported opened twice, Spotlight still up and
            // listing it). Then the rows are read again and tapped. Opened only once Spotlight's words are gone:
            // a commit changes the frame as much as a new app does.
            // Only a line that is the app's name (not one that contains it: a message, a web hit), at most two per
            // look, top first; the search field holding the same text may be one of them, a tap there changes nothing.
            var shown = results, closed = false
            for round in 0..<2 {
                let (spots, web) = await spots(shown, name, labels)
                if web {  // not installed: tapping it or Return opens a web search
                    log("open \(name) via Spotlight: listed only as a web suggestion; not installed")
                    return .notFound
                }
                for spot in spots.prefix(2) {
                    log("open \(name) via Spotlight: typed, result row read at (\(fmt(spot.x)),\(fmt(spot.y))) → tapped")
                    try await tapAt?(spot)
                    guard let now = await look() else { return .unchecked }
                    let after = await state(now, spotlight: shown, home: homeFrame, name, shows)
                    if after == .left { return .opened }
                    let moved = !same(now, shown)
                    shown = now
                    closed = after == .closed
                    if closed || moved { break }  // the old spots are stale on a changed screen
                }
                if closed || round == 1 || overBudget() { break }
                log("open \(name) via Spotlight: \(spots.isEmpty ? "not listed" : "still on Spotlight") → enter")
                try await key("enter")  // opens the top hit, or commits letters still composing
                guard let now = await look() else { return .unchecked }
                let after = await state(now, spotlight: shown, home: homeFrame, name, shows)
                if after == .left { return .opened }
                shown = now
                closed = after == .closed
                if closed { break }
            }
            log("open \(name) via Spotlight: \(closed ? "closed without opening it" : "still on Spotlight")")
        }
        return .notOpened
    }

    private enum After { case left, closed, still }

    /// What a tap or Return did: the app came up (Spotlight's words are gone), Spotlight closed to the Home Screen
    /// or this app came to the front, or Spotlight is still up.
    /// An app that shows its own name twice ("Notes" over a "Notes" folder) is not Spotlight: still up only when
    /// the frame barely changed or a line other than the name is still there (a section heading, another result).
    private func state(_ now: Data, spotlight: Data, home: Data?, _ name: String, _ shows: ([String]) -> Bool) async -> After {
        if ownAppInFront() { return .closed }
        let lines = await read(now)
        // words first: on a plain wallpaper Spotlight, the Home Screen and the app can all look alike (2026-11-11)
        guard shows(lines) else { return same(now, home) && !same(spotlight, home) ? .closed : .left }
        if same(now, spotlight) { return .still }
        if same(now, home) { return .closed }
        if !big(spotlight, now) { return .still }
        let before = Set(await read(spotlight).map(Scripts.fold))
        let kept = lines.contains { line in
            let l = Scripts.fold(line)
            return !l.isEmpty && before.contains(l) && Self.count(name, in: [line]) == 0
        }
        return kept ? .still : .left
    }

    /// The listed rows of the app on `frame`, top first; none without boxes or a way to tap.
    private func spots(_ frame: Data, _ name: String, _ labels: [String]) async -> (spots: [CGPoint], web: Bool) {
        guard let readBoxes, tapAt != nil else { return ([], false) }
        let (found, size) = await readBoxes(frame)
        return (Self.resultSpots(found, labels: [name] + labels, size: size),
                Self.onlyOnTheWeb(found, labels: [name] + labels, size: size))
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Spotlight's header over web search suggestions, per language (folded).
    static let webHeaders: Set<String> = Set(["Suggestions", "建议", "建議", "候補", "제안", "Vorschläge", "Suggestioni",
                                              "Sugerencias", "Suggestões"].map(Scripts.fold))

    /// Where to tap a listed result: the centers (screen fractions) of the lines that are one of `labels` (folded,
    /// a label cut short with "…" counts), below the status bar and above the home bar, top first.
    static func resultSpots(_ lines: [(text: String, box: [Int])], labels: [String], size: CGSize) -> [CGPoint] {
        resultRows(lines, labels: labels, size: size).filter { !$0.web }.map(\.at)
    }

    /// The top row of the name is a web suggestion: the app is not installed (Return would open the browser too).
    static func onlyOnTheWeb(_ lines: [(text: String, box: [Int])], labels: [String], size: CGSize) -> Bool {
        resultRows(lines, labels: labels, size: size).first?.web == true
    }

    /// The rows that are one of `labels`, top first, each marked when it is a web suggestion. Spotlight's
    /// "Suggestions" are web searches (they open the browser), and an app that is not installed is listed only there
    /// (2026-11-25, 汽水音乐 on an iPhone without it opened Chrome). Section headers start at the left margin, a row's
    /// text after its icon: a row whose nearest header above is a web one is a web suggestion.
    static func resultRows(_ lines: [(text: String, box: [Int])], labels: [String], size: CGSize) -> [(at: CGPoint, web: Bool)] {
        guard size.width > 0, size.height > 0 else { return [] }
        let wants = Set(labels.map(Scripts.fold).filter { !$0.isEmpty })
        func isLabel(_ text: String) -> Bool {
            let line = Scripts.fold(text)
            if wants.contains(line) { return true }
            let cut = line.hasSuffix("…") ? String(line.dropLast()) : line.hasSuffix("...") ? String(line.dropLast(3)) : nil
            return cut.map { c in c.count >= 3 && wants.contains { $0.hasPrefix(c) } } ?? false
        }
        let boxed = lines.filter { $0.box.count == 4 }
        let margin = (boxed.map { $0.box[0] }.min() ?? 0) + Int(size.width * 0.03)
        func web(_ line: (text: String, box: [Int])) -> Bool {
            let header = boxed.filter { $0.box[0] <= margin && $0.box[3] <= line.box[1] }.max { $0.box[3] < $1.box[3] }
            return header.map { webHeaders.contains(Scripts.fold($0.text)) } ?? false
        }
        return boxed.compactMap { line -> (at: CGPoint, web: Bool)? in
            guard isLabel(line.text) else { return nil }
            let p = CGPoint(x: Double(line.box[0] + line.box[2]) / 2 / size.width, y: Double(line.box[1] + line.box[3]) / 2 / size.height)
            return (0.06...0.95).contains(p.y) && (0...1).contains(p.x) ? (p, web(line)) : nil
        }.sorted { $0.at.y < $1.at.y }
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

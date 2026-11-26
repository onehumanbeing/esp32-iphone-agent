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
    /// The frame now, without waiting for it to settle: whether cmd+space brought anything up before keys are typed.
    /// nil = not checked (tests feed their own frames to `look`).
    var glance: (() async -> Data?)?
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
    /// Below this (screen fraction) a row with the name is the keyboard's candidate bar, not a result.
    static let candidateBarBelow = 0.5

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
    /// On an iPhone in another language, a known app goes in by its name there first: Spotlight lists 地图 as Maps
    /// and 小红书 as rednote, and their pinyin found nothing (2026-11-26: 4 opens failed, 2 minutes of one run). The
    /// same app either way: its own row in AppNames, never another app.
    static func queries(_ name: String, pasting: Bool, language: String = AppNames.deviceLanguage) -> [String] {
        guard !pasting, HanTyper.isHan(name), name.allSatisfy({ HanTyper.isHan(String($0)) || $0 == " " }) else { return [name] }
        let letters = Pointer.typeable(name).lowercased().filter { $0.isLetter }
        let pinyin = letters.count >= 2 ? [letters] : []
        if !language.hasPrefix("zh"), let local = AppNames.alternatives(name, language: language).first,
           Accents.typeable(local) {
            return [local] + pinyin
        }
        return pinyin + [name]
    }

    /// This open saw the name only as a web suggestion: the app is not installed (a box: the opener is a struct).
    private final class Seen { var webOnly = false }
    private let seen = Seen()

    private func open(named name: String) async throws -> OpenResult {
        let pasting = pastes(name)
        if pasting { guard let paste, try await paste(name) else { return .notFound } }  // never typed as garbage
        let queries = Self.queries(name, pasting: pasting, language: language)
        seen.webOnly = false
        for (i, query) in queries.enumerated() {
            let result = try await open(name, typing: query, pasting: pasting)
            // a web suggestion with the name: the pinyin already found it, typed as Han it is the same (10 s, 2026-11-25)
            if result == .notFound, !seen.webOnly, i < queries.count - 1 { continue }  // Home first again: nothing left in the field
            return result
        }
        return .notFound
    }

    private func open(_ name: String, typing query: String, pasting: Bool) async throws -> OpenResult {
        let labels = AppNames.labels(name, language: language)
        // typed as itself, the field shows the name too, so a result row makes two; typed as letters, one row more
        // than the Home Screen showed (its icon label) is enough
        var onHome = 0
        // typed as its name in the iPhone's language (Calculator for 计算器), the field and the row show that name:
        // judged by 计算器 alone it was never found, 8 s lost before the pinyin on every such open (2026-11-27)
        let asLabel = query != name && labels.contains(query)
        func shows(_ lines: [String]) -> Bool {
            Self.listed(name, in: lines, as: labels) || asLabel && Self.listed(query, in: lines, as: labels)
                || query != name && Self.count(name, in: lines) > onHome
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
            var viaKey = false
            if button, let searchButton, try await searchButton() {} else { try await key("cmd+space"); viaKey = true }
            try await pause(0.7)
            // Nothing came up: the keys below would go to the app in front, cmd+a and backspace clearing its field
            // and the name typed into it (2026-11-27 open review: a name typed into a chat's input box 4 times on
            // build 24). Look first; the same screen as before = no Spotlight, the Search button next time.
            // (twice, 0.6 s apart: the picture can run up to a second behind the phone)
            // three looks over ~1.4 s, all the same as before = nothing came up. Not a second cmd+space: it is a
            // toggle, and with the picture behind it closed a Spotlight that had come up (2026-11-27)
            func nothingUp() async -> Bool {
                guard let glance, homeFrame != nil else { return false }
                for wait in [0.0, 0.6, 0.8] {
                    if wait > 0, (try? await pause(wait)) == nil { return false }
                    guard let now = await glance(), same(now, homeFrame) else { return false }
                }
                return true
            }
            if viaKey, await nothingUp() {
                log("open \(name): nothing came up after cmd+space; not typing into the app in front")
                button = true
                continue
            }
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
            // Siri Suggestions still on the picture = it is from before the results came in (the picture ran ~2 s
            // behind). Their icon grid lists the app too: a tap there landed on whatever result had come in at that
            // spot, an App Store page, and the open said opened (2026-11-27, case 37). Looked at until they go; still
            // there after ~3 s, the picture has caught up and they are the screen.
            for _ in 0..<Self.suggestionLooks where Self.suggesting(lines) {
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
            var shown = results, closed = false, changed = false, entered = 0
            for round in 0..<2 {
                changed = false
                var (spots, web, topHit) = await spots(shown, name, labels)
                // one look is no proof: Spotlight fills its sections in one by one, and the web suggestions can be read
                // before the app's Top Hit above them (2026-11-27: Safari, installed, "not installed", Chrome opened)
                if web {
                    try await pause(1.0)
                    if let again = await look() {
                        shown = again
                        (spots, web, topHit) = await self.spots(again, name, labels)
                    }
                }
                if web {  // not installed: tapping it or Return opens a web search
                    seen.webOnly = true
                    let note = await rowsNote(shown, name, labels)
                    log("open \(name) via Spotlight: listed only as a web suggestion; not installed (rows: \(note))")
                    return .notFound
                }
                // The pinyin letters stayed composing (the pinyin keyboard was on) and the name is read only low on
                // the screen, in the candidate bar over the keyboard: space puts the first candidate in, and the rows
                // are read again. Tapping it first found the pointer, 13 s (2026-11-26, 汽水音乐).
                if round == 0, query != name, query.allSatisfy(\.isASCII), let low = spots.first, low.y > Self.candidateBarBelow {
                    log("open \(name) via Spotlight: the name is in the candidate bar → space")
                    try await key("space")
                    guard let now = await look() else { return .unchecked }
                    if !same(now, shown) { shown = now; continue }
                }
                // The app's row is Spotlight's Top Hit and the name went in as plain letters: Return opens it at once,
                // the tap first finds the pointer (5 s of an 18.6 s open, 2026-11-26). Still on Spotlight after it:
                // the letters were composing on the pinyin keyboard and that Return put them in (2026-11-20); the
                // rows are read again and one more Return opens the Top Hit (the tap after it took 7.5 s, 2026-11-26).
                if entered < 2, topHit, !pasting, query.allSatisfy(\.isASCII) {
                    if entered > 0, try await cameUp(shown, spotlight: results, home: homeFrame, name, shows) { return .opened }
                    entered += 1
                    log("open \(name) via Spotlight: typed, its row is the top hit → enter")
                    try await key("enter")
                    guard let now = await look() else { return .unchecked }
                    let after = await state(now, spotlight: shown, home: homeFrame, name, shows)
                    if after == .left { return .opened }
                    if after == .closed { closed = true; break }
                    // the letters going in barely changes the frame (2026-11-26: "Settings" looked the same): the
                    // second Return is sent either way
                    let moved = !same(now, shown)
                    shown = now
                    if moved || entered < 2 { continue }
                }
                for spot in spots.prefix(2) {
                    if entered > 0 || round > 0, try await cameUp(shown, spotlight: results, home: homeFrame, name, shows) { return .opened }
                    log("open \(name) via Spotlight: typed, result row read at (\(fmt(spot.x)),\(fmt(spot.y))) → tapped")
                    try await tapAt?(spot)
                    guard let now = await look() else { return .unchecked }
                    let after = await state(now, spotlight: shown, home: homeFrame, name, shows)
                    if after == .left { return .opened }
                    let moved = !same(now, shown)
                    shown = now
                    closed = after == .closed
                    changed = moved
                    // the tap committed the pinyin and Spotlight now lists the name only as a web suggestion: not
                    // installed. Checked here, not in the next round, which the time budget may skip (2026-11-25:
                    // "still on Spotlight", then the model tapped the suggestion and Chrome opened)
                    if moved, !closed, await self.spots(now, name, labels).web {
                        seen.webOnly = true
                    log("open \(name) via Spotlight: listed only as a web suggestion; not installed")
                        return .notFound
                    }
                    if closed || moved { break }  // the old spots are stale on a changed screen
                }
                if closed || round == 1 || overBudget() { break }
                // the tap changed Spotlight (a keyboard candidate committed the pinyin, 2026-11-25): read its new
                // results first; Return there opened whatever came first, a web suggestion for an app not installed
                if changed { continue }
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

    /// One more look before another Return or a tap on a result: the look after a Return can be cut short on a
    /// moving screen (0.8 s) and still show Spotlight while the app comes up; the second Return and the tap meant
    /// for the result row then went into Settings and opened Apple Account (2026-11-26).
    private func cameUp(_ last: Data, spotlight: Data, home: Data?, _ name: String, _ shows: ([String]) -> Bool) async throws -> Bool {
        try await pause(0.5)
        guard let now = await look(), !same(now, last) else { return false }
        if await state(now, spotlight: spotlight, home: home, name, shows) == .left {
            log("open \(name) via Spotlight: it came up after all")
            return true
        }
        return false
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
        let shown = await read(spotlight)
        // Spotlight's Top Hit header gone: Spotlight is. The words test below took Settings for it, whose rows
        // "Apps" and "Watch" were Spotlight's suggestions too, and a tap meant for the result opened Apple Account
        // (2026-11-26)
        func headed(_ lines: [String]) -> Bool { lines.contains { Self.topHitHeaders.contains(Scripts.fold($0)) } }
        if headed(shown), !headed(lines) { return .left }
        let before = Set(shown.map(Scripts.fold))
        let kept = lines.contains { line in
            let l = Scripts.fold(line)
            return !l.isEmpty && before.contains(l) && Self.count(name, in: [line]) == 0
        }
        return kept ? .still : .left
    }

    /// The listed rows of the app on `frame`, top first; none without boxes or a way to tap.
    private func spots(_ frame: Data, _ name: String, _ labels: [String]) async -> (spots: [CGPoint], web: Bool, topHit: Bool) {
        guard let readBoxes, tapAt != nil else { return ([], false, false) }
        let (found, size) = await readBoxes(frame)
        let rows = Self.resultRows(found, labels: [name] + labels, size: size)
        return (rows.filter { !$0.web }.map(\.at), rows.first?.web == true, Self.isTopHit(rows))
    }

    /// What a "not installed" rests on, for the log: each row of the name, top first, at its height with the header
    /// over it (2026-11-27: Safari, installed, was called not installed; the log had no way to tell why).
    private func rowsNote(_ frame: Data, _ name: String, _ labels: [String]) async -> String {
        guard let readBoxes else { return "?" }
        let (found, size) = await readBoxes(frame)
        let rows = Self.resultRows(found, labels: [name] + labels, size: size)
        return rows.map { "y \(fmt($0.at.y)) under \($0.header.map { "\"\($0)\"" } ?? "none")" }.joined(separator: "; ")
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Spotlight's header over web search suggestions, per language (folded).
    static let webHeaders: Set<String> = Set(["Suggestions", "建议", "建議", "候補", "제안", "Vorschläge", "Suggestioni",
                                              "Sugerencias", "Suggestões"].map(Scripts.fold))
    /// Spotlight's header over its Top Hit (the row Return opens), per language (folded).
    static let topHitHeaders: Set<String> = Set(["Top Hit", "最佳匹配", "最佳搜尋結果", "トップヒット", "상위 히트",
                                                 "Toptreffer", "Meilleur résultat"].map(Scripts.fold))

    /// Spotlight's header over its suggestions before any results, per language (folded).
    static let suggestionHeaders: Set<String> = Set(["Siri Suggestions", "Siri 建议", "Siri建议", "Siri 建議", "Siri建議",
                                                     "Siriからの提案", "Siri 제안", "Siri-Vorschläge",
                                                     "Suggestions de Siri"].map(Scripts.fold))
    /// Looks (0.6 s apart) while Siri Suggestions are still on the picture after the name was typed.
    static let suggestionLooks = 5

    /// The lines are Spotlight before its results: the Siri Suggestions header (over the icon grid) and no Top Hit.
    /// Not the field: Spotlight brings back the last query, so the field already read "Reminders" over the grid
    /// (2026-11-27, phone-side capture), and the grid's Reminders spot was a web suggestion once the results came.
    static func suggesting(_ lines: [String]) -> Bool {
        let folded = lines.map(Scripts.fold)
        return folded.contains { suggestionHeaders.contains($0) } && !folded.contains { topHitHeaders.contains($0) }
    }

    /// The app's first row is under the Top Hit header: Return opens the app (never a field, a web suggestion,
    /// or another result that came first).
    static func isTopHit(_ rows: [(at: CGPoint, web: Bool, header: String?)]) -> Bool {
        guard let first = rows.first, !first.web, let header = first.header else { return false }
        return topHitHeaders.contains(Scripts.fold(header))
    }

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
    static func resultRows(_ lines: [(text: String, box: [Int])], labels: [String], size: CGSize)
        -> [(at: CGPoint, web: Bool, header: String?)] {
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
        func header(_ line: (text: String, box: [Int])) -> String? {
            boxed.filter { $0.box[0] <= margin && $0.box[3] <= line.box[1] }.max { $0.box[3] < $1.box[3] }?.text
        }
        return boxed.compactMap { line -> (at: CGPoint, web: Bool, header: String?)? in
            guard isLabel(line.text) else { return nil }
            let p = CGPoint(x: Double(line.box[0] + line.box[2]) / 2 / size.width, y: Double(line.box[1] + line.box[3]) / 2 / size.height)
            let over = header(line)
            return (0.06...0.95).contains(p.y) && (0...1).contains(p.x)
                ? (p, over.map { webHeaders.contains(Scripts.fold($0)) } ?? false, over) : nil
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

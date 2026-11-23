import Foundation
import NaturalLanguage

/// Plain text the board types in one `type` command. Initial estimate: short enough that each command
/// stays inside the firmware's 4 s type budget (and the 8 s task watchdog on older firmware, which types
/// the whole command before it can feed the watchdog). Splits on extended grapheme clusters, so a
/// combining accent is never cut in half.
enum TypeChunks {
    static let maxChars = 48

    static func split(_ text: String, maxChars: Int = maxChars) -> [String] {
        guard maxChars > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var current = ""
        var count = 0
        for ch in text {
            if count >= maxChars {
                out.append(current)
                current = ""
                count = 0
            }
            current.append(ch)
            count += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Sends `text` in chunks. A firmware `err typed N of M: budget|asleep` becomes `TypeHalted`
    /// (N is bytes; chunks are ASCII, so it matches characters). Any other error is rethrown.
    static func send(_ text: String, _ send: (String) async throws -> Void) async throws {
        let pieces = split(text)
        for (i, piece) in pieces.enumerated() {
            do {
                try await send(piece)
            } catch let error as DeviceError {
                guard let stop = TypeStop.parse(error.message) else { throw error }
                let kept = min(stop.typed, piece.count)
                let left = String(piece.dropFirst(kept)) + pieces.dropFirst(i + 1).joined()
                throw TypeHalted(why: stop.why, left: left)
            }
        }
    }
}

/// The board stopped halfway through a `type` command. `left` is the part of this send that did not go in.
struct TypeHalted: Error {
    var why: String
    var left: String
}

enum TypeStop {
    static func parse(_ message: String) -> (typed: Int, total: Int, why: String)? {
        guard let range = message.range(of: "typed ") else { return nil }
        let parts = message[range.upperBound...].split(separator: " ").map(String.init)
        guard parts.count >= 4, parts[1] == "of", let typed = Int(parts[0]) else { return nil }
        let totalWord = parts[2].hasSuffix(":") ? String(parts[2].dropLast()) : parts[2]
        guard let total = Int(totalWord) else { return nil }
        let why = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard why == "budget" || why == "asleep" else { return nil }
        return (typed, total, why)
    }
}

/// Chinese text through the pinyin keyboard, read back: the board types ASCII only, so Chinese goes in as
/// toneless pinyin and the keyboard's candidates turn it into characters. A whole sentence's first candidate is
/// often not the sentence, so the text goes in short words (≤ 4 characters), each its pinyin and space (the first
/// candidate, almost always the word). Reading the screen costs 1–2 s, so it is read once per run of up to four
/// words (`settle`): the field is checked for them, not the candidate bar (OCR misses its cells often: 2026-11-20,
/// 中 and 西 "not among the candidates" stopped runs whose first candidates were right). A word the field shows as
/// another one is deleted with the words after it (backspace × their length: one character per syllable) and those
/// go in again, the wrong one by halves (pairs of characters for 3 or 4, else characters), each half read from the
/// candidate bar first: space when it is the first candidate, its digit for a single character further on, the
/// first candidate unread (checked in the field) when the bar is not read. A word not read back but whose pinyin is
/// gone is taken as committed (OCR misses characters in the field too). The first word, and the first after
/// English letters, goes in with space and is read back at once: Chinese in the field = pinyin keyboard, its letters
/// = English (deleted, ctrl+space once, typed again once). The bar is not read for it (hidden with a hardware
/// keyboard, and search suggestions read as candidates). Bounded: words are split at most twice (characters are never
/// split again), a word is retyped once after ctrl+space; anything that does not check out is cleared (only what
/// this typing put in) and the typing stops with a note for the model (`not typed: "…"`). When the field then holds
/// exactly what was typed, the stop says what is left (`Stop.rest`).
@MainActor struct HanTyper {
    struct Seen {
        var words: [(text: String, box: [Int])]
        var height: Int
    }
    enum Piece: Equatable { case han(String), plain(String) }

    /// ASCII the board types as is (accented letters go through `key`: Accents).
    var send: (String) async throws -> Void
    var key: (String) async throws -> Void
    /// ctrl+space, waited for: pinyin <-> English.
    var toggle: () async throws -> Void
    /// The screen's words once it settled; nil = no live screen (then the pinyin is committed unchecked).
    var look: () async -> Seen?
    /// The fast way first (`fast`); off in the tests of the careful way.
    var fastFirst = true
    static let segment = 4
    /// Words committed unread before the field is read back. Each costs about 0.3 s of typing, a read 1–2 s; a
    /// wrong word costs retyping the words after it, so four keeps a repair short.
    static let unreadRun = 4
    /// Labels on the keyboard itself, not candidates (the return key turns to 选定 while composing).
    static let keyLabels: Set<String> = ["空格", "选定", "确认", "拼音", "拼", "换行", "发送", "搜索", "前往", "完成"]

    /// A typing that stopped: the note for the model, and `rest` when the field holds what was typed (the letters of
    /// the word that failed cleared: not offered, not shown after its commit, the keyboard stuck in English), so the
    /// rest can go in another way. nil when it cannot (symbols that came out wrong, the board stopping).
    struct Stop: Equatable {
        var note: String
        var rest: String? = nil
    }

    /// Types `text`; nil = typed and checked (or no screen to check), else what went wrong and what is left.
    /// `checkLetters`: the keyboard may be pinyin (unknown), so letters are checked not to stay uncommitted.
    func type(_ text: String, checkLetters: Bool = true) async throws -> String? {
        try await attempt(text, checkLetters: checkLetters)?.note
    }

    /// `type`, with what is left when the rest may be pasted.
    func attempt(_ text: String, checkLetters: Bool = true) async throws -> Stop? {
        let start = Date(), looks = Tally()
        var counted = self
        counted.look = { looks.n += 1; return await look() }
        defer {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DebugLog.write("type: \(text.count) chars in \(ms) ms, \(looks.n) screen reads")
        }
        do {
            switch fastFirst ? try await counted.fast(text) : nil {
            case .done?: return nil
            case .unread?:  // typed, the field not read: never typed again on top of itself
                return Stop(note: "typed \"\(text)\" in one go, but the field could not be read back; look at it, not typed: \"\"")
            case .redo?, nil: return try await counted.typeBody(text, checkLetters: checkLetters)
            }
        }
        catch let halt as TypeHalted {
            return Stop(note: "typing stopped (\(halt.why)); not typed: \"\(halt.left)\"")
        }
    }

    private final class Tally { var n = 0 }

    /// A piece on the queue. `careful`: read from the candidate bar before it is committed; `firstWrong`: its first
    /// candidate showed up as another word, so it is only picked when the bar shows it; `toggled`: retyped after
    /// ctrl+space.
    private struct Item {
        var piece: Piece
        var careful = false, firstWrong = false, toggled = false
    }

    private func typeBody(_ text: String, checkLetters: Bool) async throws -> Stop? {
        var queue = Self.pieces(text).map { Item(piece: $0) }[...]
        var typed = ""
        let checked = checkLetters || queue.contains {
            if case .plain(let s) = $0.piece { !Self.layoutSymbols(in: s).isEmpty } else { true }
        }
        var last = checked ? await look() : nil  // the screen before the next piece
        var lastRow: Set<Int> = []
        var pinyinSeen = false  // the keyboard showed it is pinyin: words may go in without reading the bar
        // words committed with space and not read back yet (`settle`), the field before them, and what this typing
        // had put in before them
        var unread: [String] = [], unreadBase = "", unreadPrior = ""
        func rest(_ piece: Piece?) -> String { ((piece.map { [$0] } ?? []) + queue.map(\.piece)).map(\.text).joined() }
        /// The failed word's letters are cleared and the field holds `typed`, so the rest may be pasted.
        func stop(_ why: String, _ piece: Piece) -> Stop {
            Stop(note: "\(why); typed \"\(typed)\", not typed: \"\(rest(piece))\"", rest: rest(piece))
        }
        func halted(_ halt: TypeHalted, _ piece: Piece) -> Stop {
            Stop(note: "typing stopped (\(halt.why)); typed \"\(typed)\", not typed: \"\(halt.left)\(queue.map(\.piece.text).joined())\"")
        }
        /// The next look, with its candidate row (relative to `last`).
        func next() async -> (seen: Seen, row: [Int])? {
            guard let now = await look() else { return nil }
            return (now, last.map { Self.candidateRow(now, before: $0, ignoring: lastRow) } ?? [])
        }
        func moved(_ s: (seen: Seen, row: [Int])) { last = s.seen; lastRow = Set(s.row) }
        func field(_ s: (seen: Seen, row: [Int])) -> String { Self.fieldText(s.seen, minus: s.row) }
        func startUnread() {
            guard unread.isEmpty else { return }
            unreadBase = last.map { Self.fieldText($0, minus: Array(lastRow)) } ?? ""
            unreadPrior = typed
        }
        /// Reads the unread words back in `now`: a word shown as another one is deleted with the words after it,
        /// and they go back on the queue (the wrong one by halves). nil = typing goes on.
        func settle(_ given: (seen: Seen, row: [Int])?) async throws -> Stop? {
            let words = unread
            unread = []
            guard !words.isEmpty, var now = given else { return nil }
            let pinyin = words.map { Pointer.typeable($0) }.joined().filter { $0.isASCII && $0.isLetter }.lowercased()
            if let left = Self.pinyinLeft(field(now), base: unreadBase, pinyin: pinyin) {
                // the first candidate took only part of the pinyin: space commits the rest (one character a syllable)
                DebugLog.write("type: pinyin \"\(left)\" left after \"\(words.joined())\"; space once more")
                try await key("space")
                guard let again = await next() else { return nil }
                now = again
                if let still = Self.pinyinLeft(field(now), base: unreadBase, pinyin: pinyin) {
                    try await erase(still.count)
                    moved(now)
                    return Stop(note: "the pinyin \"\(still)\" stayed in the field after \"\(words.joined())\" (those letters cleared, the words before"
                        + " them unchecked); typed \"\(typed)\", not typed: \"\(rest(nil))\"")
                }
            }
            moved(now)
            let lines = now.seen.words.indices.filter { !now.row.contains($0) }.map { now.seen.words[$0].text.filter { !$0.isWhitespace } }
            let verdicts = Self.readBack(words, prior: unreadPrior, field: field(now), base: unreadBase, lines: lines)
            for (word, verdict) in zip(words, verdicts) {
                switch verdict {
                case .seen: DebugLog.write("type: \"\(word)\" verified in the field")
                case .unseen: DebugLog.write("type: \"\(word)\" not read back, but its pinyin is gone; taken as committed")
                case .wrong(let shown): DebugLog.write("type: \"\(word)\" shows as \"\(shown)\" in the field; repairing")
                }
            }
            // none of the words read back and the screen's text is as it was before them: the keys went nowhere
            // (2026-11-20: the field had lost focus, every word "taken as committed", the model searched the placeholder)
            if verdicts.allSatisfy({ $0 == .unseen }), field(now) == unreadBase {
                DebugLog.write("type: nothing of \"\(words.joined())\" reached the screen; the field may not have focus")
                typed.removeLast(words.joined().count)
                return Stop(note: "nothing appeared in the field (it may not have focus): tap the text field, then type again;"
                    + " typed \"\(typed)\", not typed: \"\(words.joined())\(rest(nil))\"")
            }
            guard let j = verdicts.firstIndex(where: { if case .wrong = $0 { true } else { false } }) else { return nil }
            let gone = words[j...].joined()
            try await erase(gone.count)
            typed.removeLast(gone.count)
            let wrong = words[j]
            var back = wrong.count > 1 ? Self.halves(wrong).map { Item(piece: .han($0), careful: true) }
                : [Item(piece: .han(wrong), careful: true, firstWrong: true)]
            back += words[(j + 1)...].map { Item(piece: .han($0)) }
            DebugLog.write("type: deleted \"\(gone)\"; \"\(wrong)\" goes in again \(wrong.count > 1 ? "by halves" : "from the bar")")
            queue.insert(contentsOf: back, at: queue.startIndex)
            return nil
        }
        while true {
            // the unread words are read back before a piece that reads the screen itself, every few words, and at the end
            if !unread.isEmpty {
                let first = queue.first
                let readsScreen = first.map { item -> Bool in
                    guard case .han = item.piece else { return true }
                    return item.careful || !pinyinSeen
                } ?? true
                if readsScreen || unread.count >= Self.unreadRun {
                    if let stop = try await settle(await next()) { return stop }
                    continue
                }
            }
            guard let item = queue.popFirst() else { break }
            let piece = item.piece
            switch piece {
            case .plain(let s):
                let (strokes, plain) = Accents.plan(s)  // accented letters through Option keys
                guard !strokes.isEmpty else { continue }
                do { try await enter(strokes) }
                catch let halt as TypeHalted { return halted(halt, piece) }
                if plain.contains(where: \.isLetter) { pinyinSeen = false }  // may switch to English
                let letters = checkLetters && plain.contains(where: \.isLetter), symbols = Self.layoutSymbols(in: plain)
                guard letters || !symbols.isEmpty, let before = last else { typed += s; continue }
                guard var seen = await next() else { typed += s; continue }
                if letters, seen.row.count >= 2 {  // the letters are pinyin being composed: English keyboard, again
                    try await erase(plain.count)
                    try await toggle()
                    do { try await enter(strokes) }
                    catch let halt as TypeHalted { return halted(halt, piece) }
                    guard let again = await next() else { typed += s; continue }
                    if again.row.count >= 2 {
                        try await erase(plain.count)
                        return stop("the letters stayed uncommitted pinyin even after ctrl+space (cleared)", piece)
                    }
                    seen = again
                }
                typed += s
                if Self.symbolsWrong(plain, symbols, now: seen.seen, row: seen.row, before: before, beforeRow: lastRow) {
                    return Stop(note: "the symbols \(String(symbols)) came out as other characters: the \(DeviceKind.name)'s hardware keyboard layout"
                        + " is not U.S. (Settings > General > Keyboard > Hardware Keyboard); typed \"\(typed)\" with them"
                        + " wrong, not typed: \"\(queue.map(\.piece.text).joined())\"")
                }
                moved(seen)
            case .han(let word):
                let pinyin = Pointer.typeable(word)
                do { try await emit(pinyin) }
                catch let halt as TypeHalted {
                    return Stop(note: "typing stopped (\(halt.why)); typed \"\(typed)\", not typed: \"\(rest(piece))\"")
                }
                guard last != nil else {  // no screen: commit the first candidate blind
                    try await key("space")
                    typed += word
                    continue
                }
                guard item.careful || !pinyinSeen else {  // the first candidate, read back with the next few words
                    startUnread()
                    try await key("space")
                    unread.append(word)
                    typed += word
                    DebugLog.write("type: \"\(word)\" (\(pinyin)): first candidate, read back later")
                    continue
                }
                // the keyboard is told from the field, never the bar: with the board as a hardware keyboard iOS hides
                // the on-screen keyboard, and Amap's suggestions read as candidates (2026-11-20: "上" not among the
                // candidates, a 3 typed to pick 西). Until a commit showed pinyin, the first candidate goes in with
                // space, the bar not read.
                let read: (seen: Seen, row: [Int])? = pinyinSeen ? await next() : (last!, Array(lastRow))
                guard let seen = read else { try await key("space"); typed += word; continue }
                let base = Self.fieldText(last!, minus: Array(lastRow))
                let words = pinyinSeen ? seen.row.map { seen.seen.words[$0].text } : []
                if let at = Self.choice(word, in: words), at == 0 || word.count == 1 {
                    pinyinSeen = true
                    if at == 0, item.firstWrong {  // read first in the bar, but it showed up as another word
                        try await erase(pinyin.count)
                        moved(seen)
                        return stop("\"\(word)\" came out as another word from the first candidate for \(pinyin) (cleared)", piece)
                    }
                    if at == 0 {
                        startUnread()
                        try await key("space")
                        unread.append(word)
                        typed += word
                        moved(seen)
                        DebugLog.write("type: \"\(word)\" (\(pinyin)): first candidate in the bar")
                        continue
                    }
                    do {  // one character further on: its digit
                        try await send(String(at + 1))
                        moved(seen)
                        // a number key can go into the pinyin instead of picking, and leave the letters in the field
                        guard let after = await next() else { typed += word; continue }
                        let now = field(after)
                        if Self.count(word, in: now) <= Self.count(word, in: base), now.lowercased().contains(pinyin) {
                            try await erase(pinyin.count + 1)
                            return stop("\"\(word)\" did not show up in the field after committing it (cleared)", piece)
                        }
                        typed += word
                        moved(after)
                        DebugLog.write("type: \"\(word)\" (\(pinyin)): candidate \(at + 1) in the bar, verified")
                        continue
                    }
                }
                if let at = Self.choice(word, in: words), at > 0 {
                    // not first: halves, each more likely first, before a number key
                    pinyinSeen = true
                    try await erase(pinyin.count)
                    moved(seen)
                    DebugLog.write("type: \"\(word)\" is candidate \(at + 1) for \(pinyin); by halves")
                    queue.insert(contentsOf: Self.halves(word).map { Item(piece: .han($0), careful: true) }, at: queue.startIndex)
                    continue
                }
                // not read among the candidates (or no bar read): the first one is almost always the word, so it is
                // committed and checked in the field; unless it already showed up as another word
                if item.firstWrong {
                    try await erase(pinyin.count)
                    moved(seen)
                    return stop("\"\(word)\" is not among the candidates for \(pinyin) (cleared)", piece)
                }
                try await key("space")
                guard let after = await next() else { typed += word; continue }
                if Self.count(pinyin, in: field(after).lowercased()) > Self.count(pinyin, in: base.lowercased())
                    || Self.wentEnglish(from: base, to: field(after)) {
                    // the letters stayed in the field after space: English keyboard (ctrl+space only for this)
                    try await erase(pinyin.count + 1)
                    if item.toggled { return stop("the Chinese (pinyin) keyboard did not come up with ctrl+space (cleared)", piece) }
                    try await toggle()
                    DebugLog.write("type: \"\(word)\" went in as letters; ctrl+space and again")
                    queue.insert(Item(piece: piece, careful: true, firstWrong: item.firstWrong, toggled: true), at: queue.startIndex)
                    continue
                }
                pinyinSeen = true
                DebugLog.write("type: \"\(word)\" not read among the candidates for \(pinyin); first candidate committed, checking the field")
                unreadBase = base
                unreadPrior = typed
                unread = [word]
                typed += word
                if let stop = try await settle(after) { return stop }
            }
        }
        return nil
    }

    /// The fast way first (Henry 2026-11-23: Chinese typed in one go is as fast as English; reading the screen every
    /// few words made 7 characters take 22 s with 5 reads): each Han run as its pinyin and one space (runs over
    /// `fastRun` characters in word groups), punctuation by its key, then one read of the field. true: the field
    /// shows the text. false: it does not, and what this typing put there is deleted for the careful way. nil: not
    /// tried (no Chinese, or no screen to check it on).
    enum Fast { case done, redo, unread }

    /// `from`: the field before (after an English go is deleted it is as it was: not read again).
    func fast(_ text: String, from: Seen? = nil) async throws -> Fast? {
        let toggled = from != nil
        guard Self.isHan(text) else { return nil }
        var read = from
        if read == nil { read = await look() }
        guard let before = read else { return nil }
        var keys = 0, letters = 0, spaces = 0
        for piece in Self.fastPieces(text) {
            switch piece {
            case .han(let run):
                let pinyin = Pointer.typeable(run)
                try await emit(pinyin)
                try await key("space")
                keys += pinyin.count + 1  // the space: a character itself when the keyboard is English
                spaces += 1
                letters += pinyin.filter(\.isLetter).count
            case .plain(let plain):
                let (strokes, typed) = Accents.plan(plain)
                if !strokes.isEmpty { try await enter(strokes) }
                keys += typed.count
            }
        }
        guard let after = await look() else { return .unread }
        let was = Self.core(Self.fieldText(before, minus: [])), now = Self.core(Self.fieldText(after, minus: []))
        let want = Self.core(text)
        if !want.isEmpty, Self.occurrences(want, in: now) > Self.occurrences(want, in: was) {
            DebugLog.write("type: fast, \(text.count) chars in one go, read back once: ok")
            return .done
        }
        // what this typing left: pinyin letters (the English keyboard, or a run not committed) and the characters
        let newLetters = max(0, now.filter(\.isASCII).count - was.filter(\.isASCII).count)
        // never more than the field grew by: deleting past what this typing put there would eat the field's own text
        let grew = max(0, Self.fieldText(after, minus: []).count - Self.fieldText(before, minus: []).count)
        guard grew > 0 else {  // nothing new read in the field: OCR missed it, or it has no focus; unknown, so kept
            DebugLog.write("type: fast, nothing new read in the field; not typed again")
            return .unread
        }
        // letters and no Chinese: the English keyboard (2026-11-23, iPhone X: OCR read 4 of 17 letters, the ratio
        // missed it, a few letters were deleted and the rest stayed). Everything typed is deleted, ctrl+space, again.
        if !toggled, Self.wentEnglish(from: Self.fieldText(before, minus: []), to: Self.fieldText(after, minus: [])) {
            DebugLog.write("type: fast, letters and no Chinese (\(newLetters) new letters): English keyboard; deleting \(keys), ctrl+space")
            try await erase(keys)
            try await toggle()
            return try await fast(text, from: before)
        }
        let english = newLetters * 10 >= letters * 8
        let drop = min(grew + (english ? spaces : 0), english ? keys : text.count + newLetters)
        DebugLog.write("type: fast, read back wrong (\(newLetters) new letters); deleting \(drop), typing it the careful way")
        try await erase(drop)
        return .redo
    }

    static let fastRun = segment  // a group commits with one space; longer ones came out as other words more often

    /// The text for the fast way: Han runs (a long one in groups of words up to `fastRun` characters) and the rest.
    static func fastPieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        for piece in pieces(text) {
            guard case .han(let word) = piece else { out.append(piece); continue }
            if case .han(let last)? = out.last, last.count + word.count <= fastRun {
                out[out.count - 1] = .han(last + word)
            } else {
                out.append(.han(word))
            }
        }
        return out
    }

    /// Letters, digits and Han, folded: what OCR reads reliably (punctuation and spaces left out).
    static func core(_ text: String) -> String {
        Scripts.fold(text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).filter { $0.isLetter || $0.isNumber }
    }

    /// New letters in the field and no new Chinese: the keys went in as English.
    static func wentEnglish(from was: String, to now: String) -> Bool {
        func tally(_ t: String) -> (latin: Int, han: Int) {
            (t.filter { $0.isASCII && $0.isLetter }.count, t.filter { isHan(String($0)) }.count)
        }
        let (a, b) = (tally(was), tally(now))
        return b.latin - a.latin >= 2 && b.han <= a.han
    }

    static func occurrences(_ want: String, in text: String) -> Int {
        guard !want.isEmpty else { return 0 }
        return text.components(separatedBy: want).count - 1
    }

    /// One `type` command, split so a long run cannot sit inside the board's watchdog.
    private func emit(_ text: String) async throws {
        try await TypeChunks.send(text, send)
    }

    private func enter(_ strokes: [Accents.Stroke]) async throws {
        for stroke in strokes {
            switch stroke {
            case .text(let t): try await emit(t)
            case .key(let k): try await key(k)
            }
        }
    }

    private func erase(_ count: Int) async throws {
        for _ in 0..<count { try await key("backspace") }
    }

    /// The candidate to pick for `word` (0 = the first): an exact one among the first nine, or a first candidate
    /// that starts with the word (OCR ran a few candidates together; not for one character, which would then
    /// commit a longer word).
    static func choice(_ word: String, in candidates: [String]) -> Int? {
        if let at = candidates.prefix(9).firstIndex(of: word) { return at }
        return word.count > 1 && candidates.first?.hasPrefix(word) == true ? 0 : nil
    }

    /// A word not among the candidates in smaller ones: pairs of characters for 3 or 4, else characters.
    static func halves(_ word: String) -> [String] {
        let size = word.count > 2 ? 2 : 1
        return stride(from: 0, to: word.count, by: size).map { String(word.dropFirst($0).prefix(size)) }
    }

    struct Glyph { var char: Character; var x0, x1, height: Int }
    /// What OCR makes of the chevron at the candidate bar's end that opens the full list (2026-11-11 trace: "<", "：v").
    static let barTail = Set("<>vV∨^：:﹀…·.")

    /// The candidates in one OCR word of the candidate bar; nil when the word is not a run of Han characters (bar
    /// the chevron at its end). Vision reads the bar's tight cells as one word ("北方北方人北房被杯背倍北" for
    /// beifang, 2026-11-11 trace), its box for each character spanning that character's share of the bar: a cell's
    /// last character takes the gap to the next cell and comes out about 1.6 to 2 times as wide as high, the other
    /// characters about square. Plain text cut here does no harm: the candidate row is told apart by its new words.
    static func cells(_ glyphs: [Glyph]) -> [(text: String, x0: Int, x1: Int)]? {
        var run = glyphs[...]
        while let last = run.last, run.count > glyphs.count - 2, !isHan(String(last.char)), barTail.contains(last.char) {
            run.removeLast()
        }
        guard run.count >= 2, run.allSatisfy({ isHan(String($0.char)) && $0.height > 0 && $0.x1 > $0.x0 }) else { return nil }
        var out: [(text: String, x0: Int, x1: Int)] = [], text = "", x0 = run.first!.x0
        for (i, g) in zip(run.indices, run) {
            text.append(g.char)
            if (g.x1 - g.x0) * 10 > g.height * 13 || i == run.indices.last {
                out.append((text, x0, g.x1))
                (text, x0) = ("", g.x1)
            }
        }
        return out
    }

    /// "今天天气不错, ok" → han 今天, han 天气, han 不错, plain ", ok": Han runs cut into words of ≤ 4.
    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = [], run = "", runHan = false
        func flush() {
            guard !run.isEmpty else { return }
            out += runHan ? words(run).map(Piece.han) : [.plain(run)]
            run = ""
        }
        for ch in text {
            let han = isHan(String(ch))
            if han != runHan { flush() }
            run.append(ch)
            runHan = han
        }
        flush()
        return out
    }

    /// A Han run in words (the system's Chinese word breaker), longer ones cut into pieces of ≤ 4.
    static func words(_ run: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = run
        var words: [String] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            words.append(String(run[range]))
            return true
        }
        if words.joined() != run { words = [run] }  // the breaker skipped something: cut the run as is
        return words.flatMap { w -> [String] in
            stride(from: 0, to: w.count, by: segment).map { String(w.dropFirst($0).prefix(segment)) }
        }
    }

    nonisolated static func isHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
    }

    /// Indexes (left to right) of the candidate row: the row in the lower part of the screen with the most Han
    /// words that were not on the screen before, plus the other Han words on that row. Only words all of Han
    /// characters count, and the bar counts by its cells (`cells`): read as one word, the bar lost to a search
    /// suggestion row ("…美容S P A会所": two new Han words) or a stray 个 read off a key (2026-11-11 trace).
    static func candidateRow(_ now: Seen, before: Seen, ignoring: Set<Int> = []) -> [Int] {
        var old: [String: Int] = [:]
        // the previous candidate row is gone once new pinyin is typed: its words do not count as old
        for (i, w) in before.words.enumerated() where !ignoring.contains(i) { old[w.text, default: 0] += 1 }
        func center(_ i: Int) -> Int { (now.words[i].box[1] + now.words[i].box[3]) / 2 }
        func size(_ i: Int) -> Int { max(1, now.words[i].box[3] - now.words[i].box[1]) }
        let han = now.words.indices.filter { i in
            let t = now.words[i].text
            return now.words[i].box.count == 4 && !t.isEmpty && t.allSatisfy({ isHan(String($0)) }) && !keyLabels.contains(t)
                && center(i) > now.height * 35 / 100
        }
        var fresh: [Int] = []
        for i in han {
            if old[now.words[i].text, default: 0] > 0 { old[now.words[i].text]! -= 1 } else { fresh.append(i) }
        }
        func sameRow(_ a: Int, _ b: Int) -> Bool { abs(center(a) - center(b)) * 2 < max(size(a), size(b)) }
        func tally(_ i: Int) -> (words: Int, chars: Int) {
            let row = fresh.filter { sameRow($0, i) }
            return (row.count, row.reduce(0) { $0 + now.words[$1].text.count })
        }
        guard let anchor = fresh.max(by: { a, b in
            let (ta, tb) = (tally(a), tally(b))
            return ta != tb ? ta < tb : center(a) < center(b)  // most new words, then characters, then the lowest
        }) else { return [] }
        return han.filter { sameRow($0, anchor) }.sorted { now.words[$0].box[0] < now.words[$1].box[0] }
    }

    /// The screen's text without the candidate row, run together (a field's text wraps over lines).
    static func fieldText(_ seen: Seen, minus row: [Int]) -> String {
        let skip = Set(row)
        return seen.words.indices.filter { !skip.contains($0) }.map { seen.words[$0].text }.joined()
            .filter { !$0.isWhitespace }
    }

    /// Symbols that sit on other keys in other hardware layouts (shift+2 is " on a U.K. one) and that OCR reads
    /// reliably; the board sends U.S. key codes.
    static let layoutSensitive = Set("@#$%&*+=[]{}\\<>/?~^")

    static func layoutSymbols(in text: String) -> [Character] {
        var out: [Character] = []
        for ch in text where layoutSensitive.contains(ch) && !out.contains(ch) { out.append(ch) }
        return out
    }

    /// The typed words show up in the field but a symbol among them does not: the keys made other characters.
    /// No verdict when the words do not show up either (a password field, or a field OCR cannot read).
    static func symbolsWrong(_ text: String, _ symbols: [Character], now: Seen, row: [Int], before: Seen,
                             beforeRow: Set<Int>) -> Bool {
        guard !symbols.isEmpty else { return false }
        // OCR reads a typed "?" as "？" in a field next to Chinese: fold full-width forms first, or a sentence typed
        // right was called wrong and not said (2026-11-13, a call's "Can you confirm that?")
        func half(_ t: String) -> String { t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t }
        let after = half(fieldText(now, minus: row)), base = half(fieldText(before, minus: Array(beforeRow)))
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        guard words.contains(where: { count($0, in: after) > count($0, in: base) }) else { return false }
        return symbols.contains { count(String($0), in: after) <= count(String($0), in: base) }
    }

    /// How a word committed unread reads in the field.
    enum ReadBack: Equatable { case seen, unseen, wrong(String) }

    /// The words committed one after another, read back: all of them newly in the field, or word by word; a word
    /// not read back is `wrong` only when the field shows other Han characters of its length at its place (after
    /// the text before it, before the text after it or the field's end); else OCR missed it (`unseen`). Stops at
    /// the first wrong one.
    static func readBack(_ words: [String], prior: String, field: String, base: String, lines: [String]) -> [ReadBack] {
        func new(_ s: String) -> Bool { count(s, in: field) > count(s, in: base) }
        if new(words.joined()) { return words.map { _ in .seen } }
        var out: [ReadBack] = []
        for (i, w) in words.enumerated() {
            if new(w) { out.append(.seen); continue }
            let before = String((prior + words[..<i].joined()).suffix(2))
            let after = String(words[(i + 1)...].joined().prefix(2))
            if let shown = shownInstead(w, before: before, after: after, lines: lines, new: new) {
                out.append(.wrong(shown))
                return out
            }
            out.append(.unseen)
        }
        return out
    }

    /// Other Han characters of `word`'s length in a line right after `before` (the line's start when empty), followed
    /// by `after`, the line's end or pinyin being composed; and new there (a suggestion list holds other words).
    static func shownInstead(_ word: String, before: String, after: String, lines: [String], new: (String) -> Bool) -> String? {
        let b = Array(before), n = word.count
        for line in lines {
            let chars = Array(line)
            for start in 0...max(0, chars.count - b.count) where before.isEmpty ? start == 0 : Array(chars[start..<min(chars.count, start + b.count)]) == b {
                let s = start + b.count
                guard s + n <= chars.count else { continue }
                let shown = String(chars[s..<s + n]), tail = String(chars[(s + n)...])
                let ends = tail.isEmpty || (!after.isEmpty && tail.hasPrefix(after)) || tail.first.map { $0.isASCII && $0.isLetter } == true
                if shown != word, shown.allSatisfy({ isHan(String($0)) }), ends, new(before + shown) { return shown }
            }
        }
        return nil
    }

    /// Letters of the words' pinyin still in the field after their commits: a newly read run of letters (≥ 2) that
    /// ends their pinyin (the first candidate took only part of it).
    static func pinyinLeft(_ field: String, base: String, pinyin: String) -> String? {
        let low = field.lowercased(), lowBase = base.lowercased()
        let runs = low.split { !($0.isASCII && $0.isLetter) && $0 != "'" }.map { String($0.filter { $0.isASCII && $0.isLetter }) }
        return runs.first { $0.count >= 2 && pinyin.hasSuffix($0) && count($0, in: low.filter { $0 != "'" }) > count($0, in: lowBase.filter { $0 != "'" }) }
    }

    static func count(_ needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }
}

extension HanTyper.Piece {
    var text: String {
        switch self { case .han(let s), .plain(let s): return s }
    }
}

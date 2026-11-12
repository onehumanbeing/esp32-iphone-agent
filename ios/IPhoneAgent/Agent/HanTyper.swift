import Foundation
import NaturalLanguage

/// Chinese text through the pinyin keyboard, read back: the board types ASCII only, so Chinese goes in as
/// toneless pinyin and the keyboard's candidates turn it into characters. A whole sentence's first candidate is
/// often not the sentence (wrong words, or pinyin left uncommitted in the field), so the text goes in short words
/// (≤ 4 characters): the word's pinyin, then the candidate that reads as the word (space for the first, its digit
/// otherwise), checked on the next look. A word not among the candidates is retried in pairs of characters (3 or
/// 4 of them), then character by character. Bounded: a piece is typed once more after one ctrl+space, and split
/// at most twice (characters are never split again); anything that does not check out is cleared (only the uncommitted pinyin, never text
/// already in the field) and the typing stops with a note for the model.
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
    static let segment = 4
    /// Labels on the keyboard itself, not candidates (the return key turns to 选定 while composing).
    static let keyLabels: Set<String> = ["空格", "选定", "确认", "拼音", "拼", "换行", "发送", "搜索", "前往", "完成"]

    /// Types `text`; nil = typed and checked (or no screen to check), else what went wrong and what is left.
    /// `checkLetters`: the keyboard may be pinyin (unknown), so letters are checked not to stay uncommitted.
    func type(_ text: String, checkLetters: Bool = true) async throws -> String? {
        var queue = Self.pieces(text)[...]
        var typed = ""
        let checked = checkLetters || queue.contains {
            if case .plain(let s) = $0 { !Self.layoutSymbols(in: s).isEmpty } else { true }
        }
        var last = checked ? await look() : nil  // the screen before the next piece
        var lastRow: Set<Int> = []
        var pending: (word: String, base: String)?  // a committed word, checked on the next look
        func remaining(_ piece: Piece) -> String { ([piece] + queue).map(\.text).joined() }
        func stop(_ why: String, _ piece: Piece) -> String {
            "\(why); typed \"\(typed)\", not typed: \"\(remaining(piece))\""
        }
        /// The next look: checks the pending word against it and finds the candidate row (relative to `last`).
        func next() async -> (seen: Seen, row: [Int], ok: Bool)? {
            guard let now = await look() else { return nil }
            let row = last.map { Self.candidateRow(now, before: $0, ignoring: lastRow) } ?? []
            var ok = true
            if let pending {
                let field = Self.fieldText(now, minus: row)
                ok = Self.count(pending.word, in: field) > Self.count(pending.word, in: pending.base)
                // OCR often misses one or two characters in a message box: 我 was there and the typing stopped
                // anyway, four times in one message (2026-11-13). Its pinyin gone from the box = committed.
                if !ok, !field.lowercased().contains(Pointer.typeable(pending.word)) {
                    ok = true
                    DebugLog.write("type: \"\(pending.word)\" not read back, but its pinyin is gone; taken as committed")
                }
            }
            return (now, row, ok)
        }
        while let piece = queue.popFirst() {
            switch piece {
            case .plain(let s):
                let (strokes, plain) = Accents.plan(s)  // accented letters through Option keys
                guard !strokes.isEmpty else { continue }
                try await enter(strokes)
                let letters = checkLetters && plain.contains(where: \.isLetter), symbols = Self.layoutSymbols(in: plain)
                guard letters || !symbols.isEmpty, let before = last else { typed += s; continue }
                guard var seen = await next() else { typed += s; continue }
                if !seen.ok { return stop("\"\(pending!.word)\" did not show up in the field after committing it", piece) }
                pending = nil
                if letters, seen.row.count >= 2 {  // the letters are pinyin being composed: English keyboard, again
                    try await erase(plain.count)
                    try await toggle()
                    try await enter(strokes)
                    guard let again = await next() else { typed += s; continue }
                    if again.row.count >= 2 {
                        try await erase(plain.count)
                        return stop("the letters stayed uncommitted pinyin even after ctrl+space (cleared)", piece)
                    }
                    seen = again
                }
                typed += s
                if Self.symbolsWrong(plain, symbols, now: seen.seen, row: seen.row, before: before, beforeRow: lastRow) {
                    return "the symbols \(String(symbols)) came out as other characters: the iPhone's hardware keyboard layout"
                        + " is not U.S. (Settings > General > Keyboard > Hardware Keyboard); typed \"\(typed)\" with them"
                        + " wrong, not typed: \"\(queue.map(\.text).joined())\""
                }
                last = seen.seen; lastRow = Set(seen.row)
            case .han(let word):
                let pinyin = Pointer.typeable(word)
                try await send(pinyin)
                guard last != nil, var seen = await next() else {  // no screen: commit the first candidate blind
                    try await key("space")
                    typed += word
                    continue
                }
                if !seen.ok {
                    try await erase(pinyin.count)
                    return stop("\"\(pending!.word)\" did not show up in the field after committing it", piece)
                }
                pending = nil
                let base = Self.fieldText(last!, minus: Array(lastRow))
                if seen.row.isEmpty, Self.count(pinyin, in: Self.fieldText(seen.seen, minus: []).lowercased())
                    > Self.count(pinyin, in: base.lowercased()) {  // the letters went in as text: English keyboard
                    try await erase(pinyin.count)
                    try await toggle()
                    try await send(pinyin)
                    guard let again = await next() else { try await key("space"); typed += word; continue }
                    guard !again.row.isEmpty else {
                        try await erase(pinyin.count)
                        return stop("the Chinese (pinyin) keyboard did not come up with ctrl+space (cleared)", piece)
                    }
                    seen = again
                }
                let words = seen.row.map { seen.seen.words[$0].text }
                if seen.row.isEmpty {
                    try await key("space")  // no candidates read: commit the first, checked on the next look
                } else if let at = Self.choice(word, in: words) {
                    if at == 0 { try await key("space") } else { try await send(String(at + 1)) }
                } else {
                    try await erase(pinyin.count)
                    guard word.count > 1 else {
                        return stop("\"\(word)\" is not among the candidates for \(pinyin) (cleared)", piece)
                    }
                    queue.insert(contentsOf: Self.halves(word).map(Piece.han), at: queue.startIndex)
                    last = seen.seen; lastRow = Set(seen.row)
                    continue
                }
                typed += word
                pending = (word, base)
                last = seen.seen; lastRow = Set(seen.row)
            }
        }
        if pending != nil, let seen = await next(), !seen.ok {
            return "\"\(pending!.word)\" did not show up in the field after committing it; typed \"\(typed)\""
        }
        return nil
    }

    private func enter(_ strokes: [Accents.Stroke]) async throws {
        for stroke in strokes {
            switch stroke {
            case .text(let t): try await send(t)
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

import Foundation
import NaturalLanguage

/// Chinese text through the pinyin keyboard, read back: the board types ASCII only, so Chinese goes in as
/// toneless pinyin and the keyboard's candidates turn it into characters. A whole sentence's first candidate is
/// often not the sentence (wrong words, or pinyin left uncommitted in the field), so the text goes in short words
/// (≤ 4 characters): the word's pinyin, then the candidate that reads as the word (space for the first, its digit
/// otherwise), checked on the next look. A word not among the candidates is retried once character by character.
/// Bounded: each piece is typed at most twice (once more after one ctrl+space, or split into characters, which
/// are never split again); anything that does not check out is cleared (only the uncommitted pinyin, never text
/// already in the field) and the typing stops with a note for the model.
@MainActor struct HanTyper {
    struct Seen {
        var words: [(text: String, box: [Int])]
        var height: Int
    }
    enum Piece: Equatable { case han(String), plain(String) }

    /// ASCII the board types as is.
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
        let checked = checkLetters || queue.contains { if case .han = $0 { true } else { false } }
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
                ok = Self.count(pending.word, in: Self.fieldText(now, minus: row)) > Self.count(pending.word, in: pending.base)
            }
            return (now, row, ok)
        }
        while let piece = queue.popFirst() {
            switch piece {
            case .plain(let s):
                let ascii = Pointer.typeable(s, trim: false)
                guard !ascii.isEmpty else { continue }
                try await send(ascii)
                guard checkLetters, ascii.contains(where: \.isLetter), last != nil else { typed += s; continue }
                guard var seen = await next() else { typed += s; continue }
                if !seen.ok { return stop("\"\(pending!.word)\" did not show up in the field after committing it", piece) }
                pending = nil
                if seen.row.count >= 2 {  // the letters are pinyin being composed: English keyboard, again
                    try await erase(ascii.count)
                    try await toggle()
                    try await send(ascii)
                    guard let again = await next() else { typed += s; continue }
                    if again.row.count >= 2 {
                        try await erase(ascii.count)
                        return stop("the letters stayed uncommitted pinyin even after ctrl+space (cleared)", piece)
                    }
                    seen = again
                }
                typed += s
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
                    queue.insert(contentsOf: word.map { Piece.han(String($0)) }, at: queue.startIndex)
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

    static func isHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
    }

    /// Indexes (left to right) of the candidate row: the row in the lower part of the screen with the most Han
    /// words that were not on the screen before, plus the other Han words on that row.
    static func candidateRow(_ now: Seen, before: Seen, ignoring: Set<Int> = []) -> [Int] {
        var old: [String: Int] = [:]
        // the previous candidate row is gone once new pinyin is typed: its words do not count as old
        for (i, w) in before.words.enumerated() where !ignoring.contains(i) { old[w.text, default: 0] += 1 }
        func center(_ i: Int) -> Int { (now.words[i].box[1] + now.words[i].box[3]) / 2 }
        func size(_ i: Int) -> Int { max(1, now.words[i].box[3] - now.words[i].box[1]) }
        let han = now.words.indices.filter { i in
            let t = now.words[i].text
            return now.words[i].box.count == 4 && isHan(t) && !keyLabels.contains(t) && center(i) > now.height * 35 / 100
        }
        var fresh: [Int] = []
        for i in han {
            if old[now.words[i].text, default: 0] > 0 { old[now.words[i].text]! -= 1 } else { fresh.append(i) }
        }
        func sameRow(_ a: Int, _ b: Int) -> Bool { abs(center(a) - center(b)) * 2 < max(size(a), size(b)) }
        guard let anchor = fresh.max(by: { a, b in
            let (na, nb) = (fresh.filter { sameRow($0, a) }.count, fresh.filter { sameRow($0, b) }.count)
            return na != nb ? na < nb : center(a) < center(b)  // most new words, then the lowest
        }) else { return [] }
        return han.filter { sameRow($0, anchor) }.sorted { now.words[$0].box[0] < now.words[$1].box[0] }
    }

    /// The screen's text without the candidate row, run together (a field's text wraps over lines).
    static func fieldText(_ seen: Seen, minus row: [Int]) -> String {
        let skip = Set(row)
        return seen.words.indices.filter { !skip.contains($0) }.map { seen.words[$0].text }.joined()
            .filter { !$0.isWhitespace }
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

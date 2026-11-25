import Foundation

/// Pinyin of Han characters read by word, not one by one: per character, 乐 is always le, so 音乐 came out as
/// "yinle" and Spotlight never found 汽水音乐 (2026-11-25, every open of it failed). The system tokenizer reads
/// words in context (音乐 yinyue, 银行 yinhang, 长大 zhangda); its transcription has no breaks inside a word, so it
/// is split back into one syllable per character, guided by each character's own reading.
enum HanReading {
    /// Character offset in `text` → its syllable (ASCII, no tones), for Han characters inside words the tokenizer
    /// read. Characters missing here fall back to their own reading.
    nonisolated static func readings(_ text: String) -> [Int: String] {
        let ns = text as NSString
        let cf = text as CFString
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWord,
                                                Locale(identifier: "zh_CN") as CFLocale) else { return [:] }
        // UTF-16 offset → Character offset
        var charAt: [Int: Int] = [:]
        var u = 0
        for (i, ch) in text.enumerated() { charAt[u] = i; u += ch.utf16.count }
        var out: [Int: String] = [:]
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            guard let start = charAt[r.location],
                  let raw = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription)
                    as? String else { continue }
            let word = Array(ns.substring(with: NSRange(location: r.location, length: r.length)))
            guard word.count > 1, word.allSatisfy(isHan) else { continue }  // one character: its own reading is the same
            let joined = plain(raw)
            guard let parts = split(joined, guides: word.map { plain(String($0).applyingTransform(.toLatin, reverse: false) ?? "") })
            else { continue }
            for (k, p) in parts.enumerated() { out[start + k] = p }
        }
        return out
    }

    /// Every pinyin syllable (initial + final; a few impossible pairs too, which never match a real word).
    nonisolated static let syllables: Set<String> = {
        let initials = ["", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "zh", "ch", "sh", "r",
                        "z", "c", "s", "y", "w"]
        let finals = ["a", "o", "e", "i", "u", "v", "ai", "ei", "ui", "ao", "ou", "iu", "ie", "ue", "ve", "er", "an", "en",
                      "in", "un", "vn", "ang", "eng", "ing", "ong", "ia", "iao", "ian", "iang", "iong", "ua", "uo", "uai",
                      "uan", "uang", "n", "ng"]
        return Set(initials.flatMap { i in finals.map { i + $0 } })
    }()

    nonisolated static func isHan(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
    }

    /// Lowercase ASCII letters only (tones and spaces dropped).
    nonisolated static func plain(_ s: String) -> String {
        let bare = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return String(bare.lowercased().unicodeScalars.filter { (0x61...0x7a).contains($0.value) }.map(Character.init))
    }

    /// `joined` cut into exactly `guides.count` syllables. A piece equal to its character's own reading is taken
    /// first; a character whose reading differs here (乐 → yue) takes whatever length lets the rest fit.
    nonisolated static func split(_ joined: String, guides: [String]) -> [String]? {
        let s = Array(joined)
        func go(_ at: Int, _ k: Int) -> [String]? {
            if k == guides.count { return at == s.count ? [] : nil }
            let left = s.count - at, need = guides.count - k
            guard left >= need else { return nil }
            let guide = guides[k]
            var lengths = Array(1...min(6, left - (need - 1)))
            if !guide.isEmpty, let g = lengths.firstIndex(of: guide.count),
               String(s[at..<at + guide.count]) == guide {
                lengths.remove(at: g); lengths.insert(guide.count, at: 0)
            }
            // the guide first, then other real syllables, longest first (重新: chong|xin, not ch|ongxin)
            let others = lengths.filter { n in String(s[at..<at + n]) != guide }.sorted(by: >)
            let tries = (lengths.first.map { String(s[at..<at + $0]) == guide ? [$0] : [] } ?? []) + others
            for n in tries {
                let piece = String(s[at..<at + n])
                if piece != guide, !syllables.contains(piece) { continue }
                if let rest = go(at + n, k + 1) { return [piece] + rest }
            }
            return nil
        }
        return go(0, 0)
    }
}

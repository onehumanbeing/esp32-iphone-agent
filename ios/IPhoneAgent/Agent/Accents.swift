import Foundation

/// Accented Latin letters through Option keys. The board is a hardware keyboard with the U.S. layout, whose
/// Option characters iOS shares with the Mac: dead keys (option+e, then e = é) and letters of their own
/// (option+c = ç, option+s = ß). Characters with no such key are folded or dropped (Pointer.typeable).
enum Accents {
    enum Stroke: Equatable { case text(String), key(String) }

    /// Dead key, the combining mark it puts on, and the letters it combines with.
    private static let deadKeys: [(key: String, mark: String, letters: String)] = [
        ("alt+e", "\u{301}", "aeiou"),   // acute
        ("alt+`", "\u{300}", "aeiou"),   // grave
        ("alt+i", "\u{302}", "aeiou"),   // circumflex
        ("alt+u", "\u{308}", "aeiouy"),  // diaeresis
        ("alt+n", "\u{303}", "ano"),     // tilde
    ]
    private static let ownKeys: [Character: String] = [
        "ç": "alt+c", "Ç": "alt+shift+c", "ß": "alt+s", "å": "alt+a", "Å": "alt+shift+a",
        "ø": "alt+o", "Ø": "alt+shift+o", "æ": "alt+'", "Æ": "alt+shift+'", "œ": "alt+q", "Œ": "alt+shift+q",
        "¡": "alt+1", "¿": "alt+shift+/",
    ]

    /// Character -> the combo, then the letter typed after it ("" for a letter of its own).
    static let table: [Character: (key: String, then: String)] = {
        var t: [Character: (key: String, then: String)] = [:]
        for (key, mark, letters) in deadKeys {
            for l in letters + letters.uppercased() { t[Character(String(l) + mark)] = (key, String(l)) }
        }
        for (c, key) in ownKeys { t[c] = (key, "") }
        return t
    }()

    /// "Café" → text "Caf", key alt+e, text "e": runs of other text folded as before; `typed` is what the field
    /// gets (one character per accented letter).
    static func plan(_ text: String) -> (strokes: [Stroke], typed: String) {
        var strokes: [Stroke] = [], typed = "", run = "", lead = ""
        func flush() {
            let ascii = Pointer.typeable(run, trim: false)
            if !(lead + ascii).isEmpty { strokes.append(.text(lead + ascii)) }
            typed += ascii
            (run, lead) = ("", "")
        }
        for ch in text {
            guard let hit = table[ch] else { run.append(ch); continue }
            flush()
            strokes.append(.key(hit.key))
            typed.append(ch)
            lead = hit.then  // the letter after a dead key starts the next text
        }
        flush()
        return (strokes, typed)
    }

    /// Whether the board can type `text` as is (printable ASCII and the letters above).
    static func typeable(_ text: String) -> Bool {
        text.allSatisfy { ch in table[ch] != nil || ch.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) } }
    }
}

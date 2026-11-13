import Foundation

/// Text by script, for the board and for names read off the screen. The board is a U.S. hardware keyboard: it types
/// ASCII, accented Latin letters (Accents) and Chinese through pinyin (HanTyper). Everything else (kana, Hangul,
/// Cyrillic, Greek, Arabic, Thai …) used to go in transliterated ("メモ" as "memo", "메모" as "memo"), which the
/// phone's own keyboard then turned into other text; such text goes on the clipboard and is pasted instead.
enum Scripts {
    /// Whether `text` has letters the board has no route for (see above); digits, symbols and emoji do not count.
    static func needsPaste(_ text: String) -> Bool {
        text.precomposedStringWithCompatibilityMapping.contains { ch in
            guard ch.isLetter, let v = ch.unicodeScalars.first?.value, v > 0x24f else { return false }
            return !(0x1e00...0x1eff).contains(v) && !HanTyper.isHan(String(ch))  // Vietnamese letters fold
        }
    }

    /// A name as compared on screen: case and spaces ignored, full- and half-width forms folded (ＡＢＣ = ABC,
    /// ﾒﾓ = メモ), hiragana as katakana (めも = メモ), decomposed Hangul and accents composed again.
    static func fold(_ s: String) -> String {
        let width = s.precomposedStringWithCompatibilityMapping
        let kana = width.applyingTransform(.hiraganaToKatakana, reverse: false) ?? width
        return kana.lowercased().filter { !$0.isWhitespace }
    }
}

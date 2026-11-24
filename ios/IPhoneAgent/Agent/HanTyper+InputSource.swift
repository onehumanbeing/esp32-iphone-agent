import Foundation

/// The phone's input method as Chinese typing found it, kept for the run (`shared`, reset when a run starts).
/// 2026-11-24, 122 runs: 27 failed Chinese typing (82 steps), nearly all on a phone whose active input method was
/// not the system Pinyin one (9-key, Zhuyin, Wubi or stroke, a third-party keyboard). The board is a hardware
/// keyboard: iOS gives its keys to the active system input source (a third-party keyboard never gets them, so they
/// stay plain letters; Zhuyin and Wubi read them as their own key codes), and ctrl+space steps through the
/// keyboards. Once no Pinyin source could be reached, every later Chinese `type` stops at once (no keys): the model
/// had cleared and typed the same text again and again, and one run sent a message with stray letters.
@MainActor final class InputSource {
    static let shared = InputSource()
    enum State: Equatable {
        case unknown
        case pinyin  // a typing read back right: the weak sign (other characters) is not taken as another method
        case unreachable(HanTyper.Foreign)  // ctrl+space went round without Pinyin
    }
    var state = State.unknown
    /// The user was told this run (one notice).
    var noticed = false

    func reset() { (state, noticed) = (.unknown, false) }
}

extension HanTyper {
    /// What a pinyin typing turned into when the active input method is not system Pinyin.
    enum Foreign: String, Equatable {
        case letters  // English, a third-party keyboard: the letters stay letters
        case zhuyin   // the Zhuyin layout: the keys are ㄅㄆㄇ… symbols
        case digits   // a layout that turns the keys into digits
        case shapes   // Wubi / stroke: other characters, none of them the text's or one with its pinyin
    }

    /// Zhuyin symbols and their tone marks.
    static func zhuyinCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0x3105...0x312f).contains($0.value) || (0x31a0...0x31bf).contains($0.value) || "ˊˇˋ˙".unicodeScalars.contains($0) }.count
    }

    /// The read after a typing of `text` (`before` → `after`, the whole screen) shows another input method, on hard
    /// evidence only: an OCR slip or a field read short is never one (Henry 2026-11-23: tolerate OCR). `pinyinKnown`:
    /// a typing this run read back right, so other characters are not taken as a shape method.
    static func foreign(_ text: String, before: Seen, after: Seen, pinyinKnown: Bool) -> Foreign? {
        let was = fieldText(before, minus: []), now = fieldText(after, minus: [])
        // the text's own English letters ("See you tomorrow!") are not a sign of the English keyboard (2026-11-23)
        if wentEnglish(from: was, to: now, expected: text.filter { $0.isASCII && $0.isLetter }.count) { return .letters }
        if zhuyinCount(now) - zhuyinCount(was) >= 2 { return .zhuyin }
        let wanted = Set(text.filter { isHan(String($0)) })
        guard !wanted.isEmpty else { return nil }
        func tally(_ s: String, _ keep: (Character) -> Bool) -> [Character: Int] { s.filter(keep).reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        // a wanted character newly on screen: the pinyin went in, whatever else the read shows
        let hanWas = tally(was) { isHan(String($0)) }
        let hanNowAll = tally(now) { isHan(String($0)) }
        if wanted.contains(where: { hanNowAll[$0, default: 0] > hanWas[$0, default: 0] }) { return nil }
        let digits = { (s: String) in s.filter { $0.isASCII && $0.isNumber }.count }
        if digits(now) - digits(was) >= digits(text) + 2 { return .digits }
        guard !pinyinKnown else { return nil }
        // new Han characters off the candidate bar (a row of several new words; the field is one) and off the keys
        // and buttons that show up while typing (发送): enough of them for the text, none with a wanted pinyin
        let row = candidateRow(after, before: before), bar = row.count >= 2 ? Set(row) : []
        let off = after.words.indices.filter { !bar.contains($0) && !keyLabels.contains(after.words[$0].text) && !SendGuard.isSend(after.words[$0].text) }
        let hanNow = tally(off.map { after.words[$0].text }.joined()) { isHan(String($0)) }
        let fresh = hanNow.flatMap { c, n in Array(repeating: c, count: max(0, n - hanWas[c, default: 0])) }
        let sounds = Set(wanted.map { Pointer.typeable(String($0)) })
        guard fresh.count >= 2, !fresh.contains(where: { sounds.contains(Pointer.typeable(String($0))) }) else { return nil }
        if fresh.filter(zhuyinLookalikes.contains).count * 2 >= fresh.count { return .zhuyin }
        return fresh.count >= (wanted.count + 1) / 2 ? .shapes : nil
    }

    /// What Vision makes of Zhuyin symbols: it has no Zhuyin and reads the radicals they look like (ㄋㄧˇㄏㄠˇ as
    /// 了一厂幺, ㄅ 勹, ㄕ 尸, ㄙ 厶, ㄔ 彳; rendered in the simulator 2026-11-24), or drops them.
    static let zhuyinLookalikes = Set("勹夂勿尸厶廿历又马冂厂彳幺尢了一匚巜儿丫")

    /// The note when no Pinyin input source could be reached: what to tell the user, and no typing again.
    static func noPinyinNote(_ kind: Foreign, text: String) -> String {
        let shown: String
        switch kind {
        case .letters: shown = "the letters stayed letters (an English or third-party keyboard)"
        case .zhuyin: shown = "the keys came out as Zhuyin symbols"
        case .digits: shown = "the keys came out as digits"
        case .shapes: shown = "the keys came out as other characters (a Wubi or stroke keyboard)"
        }
        return "the iPhone's keyboard is not the system Chinese Pinyin one: \(shown), and ctrl+space did not reach Pinyin"
            + " (what was typed is cleared). Chinese cannot be typed this run: do not type Chinese again or send;"
            + " fail and tell the user to add Settings > General > Keyboard > Keyboards > Chinese, Simplified > Pinyin – QWERTY"
            + " and switch to it. English still types; not typed: \"\(text)\""
    }
}

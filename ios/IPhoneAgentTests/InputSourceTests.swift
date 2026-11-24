import XCTest
import UIKit
@testable import IPhoneAgent

/// A phone whose keyboards ctrl+space steps through, each doing its own thing with the board's keys (2026-11-24:
/// 27 of 122 runs failed Chinese typing on a keyboard that is not system Pinyin).
@MainActor private final class FakeKeyboards {
    enum Method { case pinyin, letters, zhuyin, digits, wubi }
    var cycle: [Method]
    var at = 0
    var field = "", composing = ""
    var sent: [String] = []
    var looks = 0
    /// The pinyin keyboard's first candidate for each pinyin.
    var words: [String: String] = [:]
    /// Pinyin shows the association bar after a commit (several new Han words low on the screen).
    var association = false
    var fieldHidden = false
    var method: Method { cycle[at] }

    static let zhuyin: [Character: Character] = ["n": "ㄙ", "i": "ㄛ", "h": "ㄘ", "a": "ㄇ", "o": "ㄟ", "m": "ㄩ",
                                                  "g": "ㄕ", "t": "ㄔ", "j": "ㄨ", "e": "ㄍ", "s": "ㄋ", "d": "ㄎ"]
    static let pad: [Character: Character] = ["a": "2", "d": "3", "e": "3", "g": "4", "h": "4", "i": "4", "j": "5",
                                              "m": "6", "n": "6", "o": "6", "s": "7", "t": "8"]
    static let shapes = Array("工了以在有地一上不")

    init(_ cycle: [Method], knowing text: String) {
        self.cycle = cycle
        let chars = Array(text)
        for i in chars.indices {
            for n in 1...8 where i + n <= chars.count { words[Pointer.typeable(String(chars[i..<i + n]))] = String(chars[i..<i + n]) }
        }
    }

    func send(_ s: String) {
        sent.append("type \(s)")
        for ch in s {
            switch method {
            case .pinyin: if ch.isLetter || ch == "'" { composing.append(ch) } else { field.append(ch) }
            case .letters: field.append(ch)
            case .zhuyin: field.append(Self.zhuyin[ch] ?? ch)
            case .digits: field.append(Self.pad[ch] ?? ch)
            case .wubi:  // four keys make a character
                composing.append(ch)
                if composing.count == 4 { field.append(Self.shapes[composing.count % 9]); composing = "" }
            }
        }
    }

    func key(_ k: String) {
        sent.append("key \(k)")
        switch (k, method) {
        case ("space", .pinyin): field += composing.isEmpty ? " " : words[composing] ?? "阿"; composing = ""
        case ("space", .wubi): if !composing.isEmpty { field.append("了"); composing = "" }
        case ("space", .letters), ("space", .digits): field += " "
        case ("backspace", _): if composing.isEmpty { _ = field.popLast() } else { _ = composing.popLast() }
        default: break
        }
    }

    var seen: HanTyper.Seen {
        var words: [(text: String, box: [Int])] = [("聊天", [300, 60, 420, 100])]
        if !fieldHidden { words.append((field + composing, [20, 1300, 700, 1340])) }
        if association, method == .pinyin, HanTyper.isHan(field) {
            for (i, w) in ["的", "了", "是", "吗"].enumerated() { words.append((w, [20 + 80 * i, 1420, 80 + 80 * i, 1460])) }
        }
        return HanTyper.Seen(words: words, height: 1554)
    }

    func typer(_ source: InputSource) -> HanTyper {
        var typer = HanTyper(send: { self.send($0) }, key: { self.key($0) },
                             toggle: { self.sent.append("toggle"); self.at = (self.at + 1) % self.cycle.count },
                             look: { self.looks += 1; return self.seen })
        typer.source = source
        return typer
    }
}

@MainActor final class InputSourceTests: XCTestCase {
    /// System Pinyin: the 1.0.10.1 fast way as it was, no extra keys and no extra reads; Pinyin kept for the run.
    func testSystemPinyinTypesInOneGoWithNothingExtra() async throws {
        let ime = FakeKeyboards([.pinyin, .letters], knowing: "好的明天见")
        let source = InputSource()
        let stop = try await ime.typer(source).attempt("好的，明天见")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "好的,明天见")
        XCTAssertEqual(ime.sent, ["type haode", "key space", "type ,", "type mingtianjian", "key space"])
        XCTAssertEqual(ime.looks, 2)
        XCTAssertEqual(source.state, .pinyin)
    }

    /// Pinyin whose field OCR missed while the association bar came up: not taken for a shape method.
    func testTheAssociationBarIsNotAnotherInputMethod() async throws {
        let ime = FakeKeyboards([.pinyin, .letters], knowing: "你好")
        (ime.association, ime.fieldHidden) = (true, true)
        let stop = try await ime.typer(InputSource()).attempt("你好")
        XCTAssertEqual(stop?.noPinyin ?? false, false)
        XCTAssertFalse(ime.sent.contains("toggle"), "\(ime.sent)")
        XCTAssertEqual(ime.field, "你好")
    }

    func testZhuyinIsSwitchedAndTheTextTypedAgain() async throws {
        let ime = FakeKeyboards([.zhuyin, .pinyin], knowing: "你好")
        let source = InputSource()
        let stop = try await ime.typer(source).attempt("你好")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "你好", "\(ime.sent)")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1)
        XCTAssertEqual(source.state, .pinyin)
    }

    /// A third-party keyboard (iOS gives it no hardware keys): the letters stay letters.
    func testLettersLeftUncomposedAreSwitched() async throws {
        let ime = FakeKeyboards([.letters, .pinyin], knowing: "明天见")
        let stop = try await ime.typer(InputSource()).attempt("明天见")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "明天见")
    }

    func testNineKeyDigitsAndWubiCharactersAreSwitched() async throws {
        for method in [FakeKeyboards.Method.digits, .wubi] {
            let ime = FakeKeyboards([method, .pinyin], knowing: "你好明天")
            let stop = try await ime.typer(InputSource()).attempt("你好明天")
            XCTAssertNil(stop, "\(method)")
            XCTAssertEqual(ime.field, "你好明天", "\(method): \(ime.sent)")
            XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1, "\(method)")
        }
    }

    /// Two keyboards and neither is Pinyin: ctrl+space goes round once, everything typed is cleared, the stop says
    /// so, the send guard holds Enter, and the next Chinese type of the run sends no keys at all.
    func testNoPinyinReachedClearsStopsAndIsRemembered() async throws {
        let ime = FakeKeyboards([.zhuyin, .letters], knowing: "你好")
        let source = InputSource()
        let first = try await ime.typer(source).attempt("你好")
        let stop = try XCTUnwrap(first)
        XCTAssertTrue(stop.noPinyin)
        XCTAssertNil(stop.rest, "nothing to paste")
        XCTAssertEqual(ime.field, "", "\(ime.sent)")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 2)
        XCTAssertEqual(source.state, .unreachable(.zhuyin))
        var guardian = SendGuard()
        guardian.typed("你好", missing: SendGuard.missing(stop.note), at: 1)
        XCTAssertEqual(SendGuard.missing(stop.note), "你好")
        XCTAssertNotNil(guardian.enter(step: 2), "Enter held")
        XCTAssertNotEqual(guardian.send(step: 3, lines: [], again: "tap it again"), .go, "a send held or asked, never sent")

        ime.sent = []
        let second = try await ime.typer(source).attempt("明天")
        let again = try XCTUnwrap(second)
        XCTAssertTrue(again.noPinyin)
        XCTAssertEqual(ime.sent, [], "no keys, no retyping in a loop")
    }

    /// ctrl+space that does nothing: the same result after it, so one retype and the stop.
    func testASwitchThatDoesNothingStopsAfterOneRetype() async throws {
        let ime = FakeKeyboards([.wubi], knowing: "你好")
        let stop = try await ime.typer(InputSource()).attempt("你好")
        XCTAssertEqual(stop?.noPinyin, true)
        XCTAssertEqual(ime.sent.filter { $0 == "type nihao" }.count, 2)
        XCTAssertEqual(ime.field, "")
    }

    /// Zhuyin symbols rendered and read with the typer's OCR: Vision has no Zhuyin and reads them as look-alike
    /// radicals (ㄋㄧˇㄏㄠˇ as 了一厂幺, ㄅ as 勹, ㄕ as 尸; simulator, 2026-11-24) or drops them.
    func testZhuyinSymbolsReadAsLookAlikesAreAnotherInputMethod() async {
        func seen(_ rows: [[String]]) async -> HanTyper.Seen {
            let image = ChineseOCRTests.screen(rows, points: 28)
            return HanTyper.Seen(words: await UITreeOCR.lines(image, cells: true), height: image.height)
        }
        let before = await seen([["聊天"]]), zhuyin = await seen([["聊天"], ["ㄋㄧˇㄏㄠˇ"]]), typed = await seen([["聊天"], ["你好"]])
        XCTAssertEqual(HanTyper.foreign("你好", before: before, after: zhuyin, pinyinKnown: false), .zhuyin,
                       "read \(zhuyin.words.map(\.text))")
        XCTAssertNil(HanTyper.foreign("你好", before: before, after: typed, pinyinKnown: false), "read \(typed.words.map(\.text))")
    }
}

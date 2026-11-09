import XCTest
@testable import IPhoneAgent

/// A pinyin keyboard on a screen: letters compose, space or a digit commits a candidate, the field and the
/// candidate row are what OCR reads back.
@MainActor private final class FakeIME {
    var pinyin = true
    var toggles = true  // ctrl+space switches the layout
    var field = "", composing = ""
    var sent: [String] = []
    /// Every Chinese string the keyboard knows (its candidates for a pinyin: the known ones that spell it).
    var known: Set<String> = []
    /// Candidates put first, by pinyin; `only` replaces the known ones.
    var decoys: [String: [String]] = [:], only: [String: [String]] = [:]
    var association = ["的", "了", "是"]  // what the row shows after a commit
    var committed = false

    init(knowing text: String) {
        let chars = Array(text)
        for i in chars.indices { for n in 1...4 where i + n <= chars.count { known.insert(String(chars[i..<i + n])) } }
    }

    func candidates(_ p: String) -> [String] {
        if let only = only[p] { return only }
        let spelled = known.filter { HanTyper.isHan($0) && Pointer.typeable($0) == p }.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
        let found = (decoys[p] ?? []) + spelled
        return found.isEmpty ? ["阿", "啊"] : found
    }

    func commit(_ i: Int) {
        let c = candidates(composing)
        guard i < c.count else { return }
        field += c[i]
        composing = ""
        committed = true
    }

    func send(_ s: String) {
        sent.append("type \(s)")
        for ch in s {
            if !pinyin || (composing.isEmpty && !ch.isLetter) { field.append(ch); committed = false; continue }
            if let d = ch.wholeNumberValue, !composing.isEmpty, d >= 1 { commit(d - 1); continue }
            composing.append(ch)
            committed = false
        }
    }

    func key(_ k: String) {
        sent.append("key \(k)")
        switch k {
        case "space": if composing.isEmpty { field += " " } else { commit(0) }
        case "backspace": if composing.isEmpty { _ = field.popLast() } else { _ = composing.popLast() }
        default: break
        }
    }

    var seen: HanTyper.Seen {
        var words: [(text: String, box: [Int])] = [(field + composing, [20, 280, 700, 320])]
        let row = !composing.isEmpty ? candidates(composing) : committed ? association : []
        for (i, w) in row.enumerated() { words.append((w, [20 + 80 * i, 1400, 80 + 80 * i, 1440])) }
        return HanTyper.Seen(words: words, height: 1554)
    }

    func typer(screen: Bool = true) -> HanTyper {
        HanTyper(send: { self.send($0) }, key: { self.key($0) },
                 toggle: { self.sent.append("toggle"); self.committed = false; if self.toggles { self.pinyin.toggle() } },
                 look: { screen ? self.seen : nil })
    }
}

@MainActor final class HanTyperTests: XCTestCase {
    func testWordsGoInOneByOneAndCheckOut() async throws {
        let ime = FakeIME(knowing: "今天天气不错")
        let note = try await ime.typer().type("今天天气不错")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "今天天气不错")
        XCTAssertEqual(ime.composing, "")
    }

    func testTheRightCandidateIsPickedByItsNumber() async throws {
        let ime = FakeIME(knowing: "今天")
        ime.decoys["jintian"] = ["金天"]
        let note = try await ime.typer().type("今天")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "今天")
        XCTAssertTrue(ime.sent.contains("type 2"), "\(ime.sent)")
    }

    func testAWordMissingFromTheCandidatesGoesInCharacterByCharacter() async throws {
        let ime = FakeIME(knowing: "今天")
        ime.only["jintian"] = ["金天", "今田"]
        let note = try await ime.typer().type("今天")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "今天")
    }

    func testACharacterMissingFromTheCandidatesIsClearedAndReported() async throws {
        let ime = FakeIME(knowing: "好龘")
        ime.only["da"] = ["大", "打"]
        let note = try await ime.typer().type("好龘好")
        XCTAssertEqual(ime.field, "好", "the pinyin is cleared, what went in stays")
        XCTAssertEqual(ime.composing, "")
        let text = try XCTUnwrap(note)
        XCTAssertTrue(text.contains("龘") && text.contains("typed \"好\""), text)
    }

    func testAnEnglishKeyboardIsSwitchedOnceAndTheWordRetyped() async throws {
        let ime = FakeIME(knowing: "你好")
        ime.pinyin = false
        let note = try await ime.typer().type("你好")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "你好")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1)
    }

    func testAKeyboardThatNeverTurnsPinyinIsReportedWithNothingLeftBehind() async throws {
        let ime = FakeIME(knowing: "你好")
        (ime.pinyin, ime.toggles) = (false, false)
        let note = try await ime.typer().type("你好")
        XCTAssertEqual(ime.field, "")
        XCTAssertTrue(note?.contains("did not come up") == true, note ?? "nil")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1)
    }

    func testEnglishLettersLeftComposingOnAPinyinKeyboardAreRetypedInEnglish() async throws {
        let ime = FakeIME(knowing: "")
        let note = try await ime.typer().type("hello")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "hello")
        XCTAssertEqual(ime.composing, "")
    }

    func testMixedTextSwitchesForTheLettersAndBack() async throws {
        let ime = FakeIME(knowing: "我有个好")
        let note = try await ime.typer().type("我有3个apple好")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "我有3个apple好")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 2, "to English for apple, back to pinyin for 好")
    }

    func testACommitThatDoesNotLandIsReported() async throws {
        let ime = FakeIME(knowing: "今天")
        ime.decoys["jintian"] = ["金天"]
        let typer = ime.typer()
        let broken = HanTyper(send: { s in if s == "2" { ime.sent.append("type 2") } else { ime.send(s) } },  // no digit selection
                              key: typer.key, toggle: typer.toggle, look: typer.look)
        let note = try await broken.type("今天")
        XCTAssertTrue(note?.contains("\"今天\" did not show up") == true, note ?? "nil")
    }

    func testWithoutAScreenEachWordIsCommittedBlind() async throws {
        let ime = FakeIME(knowing: "今天天气")
        let note = try await ime.typer(screen: false).type("今天天气")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "今天天气")
        XCTAssertFalse(ime.sent.contains("key backspace"))
    }

    func testPiecesCutHanIntoShortWords() {
        let pieces = HanTyper.pieces("今天天气不错, ok")
        XCTAssertEqual(pieces.last, .plain(", ok"))
        let han = pieces.compactMap { if case .han(let w) = $0 { w } else { nil } }
        XCTAssertEqual(han.joined(), "今天天气不错")
        XCTAssertTrue(han.allSatisfy { $0.count <= HanTyper.segment })
        XCTAssertTrue(HanTyper.words("中华人民共和国万岁").allSatisfy { $0.count <= HanTyper.segment })
        XCTAssertEqual(HanTyper.words("中华人民共和国万岁").joined(), "中华人民共和国万岁")
    }

    func testTheCandidateRowIsTheNewRowLowOnTheScreen() {
        let before = HanTyper.Seen(words: [("聊天", [20, 100, 120, 140])], height: 1554)
        let now = HanTyper.Seen(words: [("聊天", [20, 100, 120, 140]), ("金天", [100, 1400, 160, 1440]),
                                        ("今天", [20, 1402, 80, 1442]), ("空格", [300, 1500, 400, 1540])], height: 1554)
        XCTAssertEqual(HanTyper.candidateRow(now, before: before).map { now.words[$0].text }, ["今天", "金天"])
        XCTAssertEqual(HanTyper.candidateRow(before, before: before), [])
    }
}

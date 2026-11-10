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
    /// The bar as Vision reads it on a device: one word run together, per-character boxes as wide as a cell's share
    /// (a cell's last character takes the gap), plus a search suggestion row and a stray 个 off a key.
    var barAsOneWord = false

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
        guard barAsOneWord else {
            for (i, w) in row.enumerated() { words.append((w, [20 + 80 * i, 1400, 80 + 80 * i, 1440])) }
            return HanTyper.Seen(words: words, height: 1554)
        }
        if !composing.isEmpty { words += [("銚丽人女子美容S", [90, 560, 300, 590]), ("P", [310, 560, 330, 590]), ("A会所", [340, 560, 440, 590])] }
        var glyphs: [HanTyper.Glyph] = [], x = 15
        for w in row {
            for (i, ch) in w.enumerated() {
                let width = i == w.count - 1 ? 64 : 34
                glyphs.append(HanTyper.Glyph(char: ch, x0: x, x1: x + width, height: 36))
                x += width
            }
        }
        if let cells = HanTyper.cells(glyphs) {
            words += cells.map { ($0.text, [$0.x0, 1022, $0.x1, 1058]) }
        } else if !row.isEmpty {
            words.append((row.joined(), [15, 1022, x, 1058]))
        }
        words += [("个", [29, 1290, 65, 1316]), ("选定", [332, 1380, 387, 1410])]
        return HanTyper.Seen(words: words, height: 1560)
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

    /// The device bar read as one word (2026-11-11 trace): 北方 and 锅贴 are found among its cells.
    func testTheBarReadAsOneWordStillGivesItsCandidates() async throws {
        let ime = FakeIME(knowing: "北方锅贴")
        ime.barAsOneWord = true
        ime.only["beifang"] = ["北方", "北方人", "北房", "被"]
        let note = try await ime.typer().type("北方锅贴")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "北方锅贴")
        XCTAssertEqual(ime.composing, "")
    }

    func testACharacterIsPickedByItsNumberFromTheBarReadAsOneWord() async throws {
        let ime = FakeIME(knowing: "北")
        ime.barAsOneWord = true
        ime.only["bei"] = ["被", "杯", "背", "倍", "北", "贝"]
        let note = try await ime.typer().type("北")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "北")
        XCTAssertTrue(ime.sent.contains("type 5"), "\(ime.sent)")
    }

    /// Per-character boxes Vision gave for the bar on the device frames (718 px wide), cut into cells.
    func testCellsCutTheBarAtItsWideCharacters() {
        func glyphs(_ text: String, _ widths: [Int], height: Int) -> [HanTyper.Glyph] {
            var x = 15
            return zip(text, widths).map { ch, w in defer { x += w }; return HanTyper.Glyph(char: ch, x0: x, x1: x + w, height: height) }
        }
        let beifang = HanTyper.cells(glyphs("北方北方人北房被杯背倍北", [36, 62, 31, 35, 58, 36, 63, 67, 67, 67, 63, 63], height: 36))
        XCTAssertEqual(beifang?.map(\.text), ["北方", "北方人", "北房", "被", "杯", "背", "倍", "北"])
        let bei = HanTyper.cells(glyphs("被杯背倍北贝呗备悲辈", [67, 68, 67, 63, 72, 63, 68, 63, 68, 46], height: 34))
        XCTAssertEqual(bei?.map(\.text), ["被", "杯", "背", "倍", "北", "贝", "呗", "备", "悲", "辈"])
        let idle = HanTyper.cells(glyphs("我你可以好这个嗯不对他<", [67, 68, 33, 59, 68, 38, 59, 68, 63, 68, 55, 29], height: 34))
        XCTAssertEqual(idle?.map(\.text), ["我", "你", "可以", "好", "这个", "嗯", "不", "对", "他"], "the chevron is dropped")
        XCTAssertNil(HanTyper.cells(glyphs("美容S", [36, 36, 20], height: 36)), "a Latin letter: not the bar")
        XCTAssertNil(HanTyper.cells(glyphs("北", [63], height: 36)))
    }

    func testTheCandidateRowSkipsMixedSuggestionsAndStrayCharacters() {
        let before = HanTyper.Seen(words: [], height: 1560)
        let now = HanTyper.Seen(words: [("銚丽人女子美容S", [90, 1000, 300, 1030]), ("A会所", [340, 1000, 440, 1030]),
                                        ("锅贴", [15, 1100, 115, 1136]), ("个", [29, 1290, 65, 1316])], height: 1560)
        XCTAssertEqual(HanTyper.candidateRow(now, before: before).map { now.words[$0].text }, ["锅贴"],
                       "a tie in new words goes to the row with more characters, not a stray one lower down")
    }

    /// A 3- or 4-character word missing from the candidates goes in as pairs before single characters.
    func testAMissingLongWordGoesInByPairsFirst() async throws {
        XCTAssertEqual(HanTyper.halves("北方锅贴"), ["北方", "锅贴"])
        XCTAssertEqual(HanTyper.halves("天安门"), ["天安", "门"])
        XCTAssertEqual(HanTyper.halves("北方"), ["北", "方"])
        let ime = FakeIME(knowing: "天安门")
        ime.only["tiananmen"] = ["天安们"]
        let note = try await ime.typer().type("天安门")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "天安门")
        XCTAssertFalse(ime.sent.contains("type tian"), "天安 goes in as a pair: \(ime.sent)")
    }
}

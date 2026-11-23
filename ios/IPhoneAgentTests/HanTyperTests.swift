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
    /// OCR reads nothing of the candidate bar (2026-11-20: 中 and 西 "not among the candidates").
    var barHidden = false
    /// OCR reads nothing of the field either.
    var fieldHidden = false
    /// What OCR reads of the field (2026-11-23, iPhone X: 4 of 17 English letters read).
    var fieldShown: (String) -> String = { $0 }
    var looks = 0

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
        var words: [(text: String, box: [Int])] = [(fieldHidden ? "" : fieldShown(field + composing), [20, 280, 700, 320])]
        let row = barHidden ? [] : !composing.isEmpty ? candidates(composing) : committed ? association : []
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

    /// `fast`: the one-go way first (HanTyper.fast); off for the tests of the careful way it falls back to.
    func typer(screen: Bool = true, fast: Bool = false) -> HanTyper {
        var typer = HanTyper(send: { self.send($0) }, key: { self.key($0) },
                 toggle: { self.sent.append("toggle"); self.committed = false; if self.toggles { self.pinyin.toggle() } },
                 look: { self.looks += 1; return screen ? self.seen : nil })
        typer.fastFirst = fast
        return typer
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

    /// A word that is not the first candidate goes in by halves, not by its number (a number key can go into the
    /// pinyin and leave the letters in the field).
    func testAWordNotFirstGoesInByHalvesNotByANumber() async throws {
        let ime = FakeIME(knowing: "今天")
        ime.decoys["jintian"] = ["金天"]
        let note = try await ime.typer().type("今天")
        XCTAssertNil(note)
        XCTAssertEqual(ime.field, "今天")
        XCTAssertFalse(ime.sent.contains("type 2"), "\(ime.sent)")
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

    /// 2026-11-20: 西岸 not offered (now typed as xi'an; here the keyboard still lacks it), then 西 not read among xi's candidates. What went in stays, the
    /// letters are cleared, and the stop says what is left to paste.
    /// 2026-11-23 (Henry: Chinese in one go is as fast as English): each group its pinyin and a space, punctuation by
    /// its key, one read before and one after; no backspace, no read in between.
    func testTheFastWayTypesASentenceInOneGoWithTwoReads() async throws {
        let ime = FakeIME(knowing: "好的明天见")
        let stop = try await ime.typer(fast: true).attempt("好的，明天见！")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "好的,明天见!")  // the fake keyboard keeps ASCII punctuation; iOS makes it ，！
        XCTAssertEqual(ime.looks, 2)
        XCTAssertEqual(ime.sent, ["type haode", "key space", "type ,", "type mingtianjian", "key space", "type !"])
    }

    func testTheFastWayOnAnEnglishKeyboardDeletesItsLettersAndTheCarefulWaySwitches() async throws {
        let ime = FakeIME(knowing: "你好")
        ime.pinyin = false
        let stop = try await ime.typer(fast: true).attempt("你好")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "你好", "the letters and the space deleted, then typed in pinyin")
    }

    /// 2026-11-23, iPhone X: the keyboard was English and OCR read only a few of the letters; a few were deleted,
    /// the rest stayed and the model saw English. Letters and no Chinese = English: all deleted, ctrl+space, again.
    func testTheFastWayOnAnEnglishKeyboardReadPoorlyDeletesAllAndToggles() async throws {
        let ime = FakeIME(knowing: "好的明天见")
        ime.pinyin = false
        ime.fieldShown = { $0.allSatisfy(\.isASCII) ? String($0.prefix(4)) : $0 }
        let stop = try await ime.typer(fast: true).attempt("好的，明天见！")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "好的,明天见!", "\(ime.sent)")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1)
        XCTAssertEqual(ime.looks, 3, "one read before, one after each go: no careful way")
    }

    /// 2026-11-23, iPhone X: a sentence over two lines read back short; 17 of 29 characters were deleted and the
    /// careful way typed it all after the rest, so it went out with its first half twice.
    func testAFastWayReadShortDeletesAllItTypedNotWhatGrew() async throws {
        let text = "今天下午三点在公司楼下的咖啡店开会"
        let ime = FakeIME(knowing: text)
        var reads = 0
        ime.fieldShown = { reads += 1; return reads <= 2 ? String($0.prefix(6)) : $0 }
        let stop = try await ime.typer(fast: true).attempt(text)
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, text, "\(ime.sent)")
    }

    /// 2026-11-23: 测试一下搜索 read back as 测试一下搜素; one OCR slip is not a wrong typing.
    func testOneCharacterReadOtherwiseStillCountsAsTyped() {
        XCTAssertEqual(HanTyper.near("测试一下搜索", in: "发送测试一下搜素4"), 1)
        XCTAssertEqual(HanTyper.near("测试一下搜索", in: "测试搜素一下"), 0)
    }

    func testTheFastWayNeverTypesTwiceWhenTheFieldIsNotRead() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        (ime.barHidden, ime.fieldHidden) = (true, true)
        let stop = try await ime.typer(fast: true).attempt("上海西岸艺术中心")
        XCTAssertEqual(ime.field, "上海西岸艺术中心", "typed once, not again on top")
        XCTAssertEqual(stop?.rest, nil)
        XCTAssertEqual(SendGuard.missing(stop?.note ?? "x"), "", "unsure: the send guard looks at the screen")
    }

    func testTheFastWayFallsBackToTheCarefulWayOnAWrongWord() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        ime.decoys["shanghaixi'an"] = ["上海西安"]
        let stop = try await ime.typer(fast: true).attempt("上海西岸艺术中心")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "上海西岸艺术中心", "\(ime.sent)")
    }

    func testAWordTheKeyboardDoesNotOfferLeavesTheRestToPaste() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        ime.only["xi'an"] = ["西安", "先"]
        ime.only["xi"] = ["系", "洗"]
        let stop = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertEqual(ime.field, "上海")
        XCTAssertEqual(ime.composing, "")
        XCTAssertEqual(stop?.rest, "西岸艺术中心")
        XCTAssertTrue(stop?.note.contains("not typed: \"西岸艺术中心\"") == true, stop?.note ?? "nil")
    }

    func testNothingIsLeftToPasteWhenPinyinWorksAndAWordNotShownIsOwed() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        let ok = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertNil(ok)
        XCTAssertEqual(ime.field, "上海西岸艺术中心")
        // a commit that did not land: its letters cleared, the word owed with the rest
        let bei = FakeIME(knowing: "北")
        bei.only["bei"] = ["被", "北"]
        let typer = bei.typer()
        let broken = HanTyper(send: { s in if s == "2" { bei.sent.append("type 2"); bei.composing.append("2") } else { bei.send(s) } },
                              key: typer.key, toggle: typer.toggle, look: typer.look)
        let unsure = try await broken.attempt("北")
        XCTAssertEqual(bei.field, "")
        XCTAssertEqual(unsure?.rest, "北")
        XCTAssertTrue(unsure?.note.contains("typed \"\", not typed: \"北\"") == true, unsure?.note ?? "nil")
    }

    /// 2026-11-20 device run: 上海西岸艺术中心 in four words; the field read after the first and once for the rest.
    func testTheWholeTextGoesInWithFewReads() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        let stop = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "上海西岸艺术中心")
        XCTAssertFalse(ime.sent.contains("key backspace"), "\(ime.sent)")
        XCTAssertLessThanOrEqual(ime.looks, 3, "the screen before, the field after the first word, the field once for the rest")
    }

    /// The bar is never read: each first candidate is right, checked in the field, and nothing stops.
    func testAnUnreadBarStillTypesTheFirstCandidates() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        ime.barHidden = true
        let stop = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "上海西岸艺术中心")
        XCTAssertEqual(ime.composing, "")
        XCTAssertFalse(ime.sent.contains("key backspace"), "\(ime.sent)")
        XCTAssertFalse(ime.sent.contains("toggle"), "an unread bar is no reason for ctrl+space: \(ime.sent)")
    }

    /// Nothing on screen changed (2026-11-20: the field had lost focus and the keys went nowhere): the typing says so
    /// instead of passing, and deletes nothing, no ctrl+space (the text may be in a field it cannot read).
    func testNothingSeenOnScreenStopsWithoutDeleting() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        (ime.barHidden, ime.fieldHidden) = (true, true)
        let stop = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertTrue(stop?.note.hasPrefix("nothing appeared in the field") == true, "\(String(describing: stop))")
        XCTAssertNil(stop?.rest, "nothing to paste: it may be in already")
        XCTAssertEqual(ime.field, "上海", "stops after the first word read back")
        XCTAssertFalse(ime.sent.contains("key backspace") || ime.sent.contains("toggle"), "\(ime.sent)")
    }

    /// English keyboard, bar hidden: the first word's letters show in the field after space; deleted, one
    /// ctrl+space, typed again, and the rest goes in.
    func testAnEnglishKeyboardIsToldFromTheField() async throws {
        let ime = FakeIME(knowing: "上海西岸艺术中心")
        (ime.pinyin, ime.barHidden) = (false, true)
        let stop = try await ime.typer().attempt("上海西岸艺术中心")
        XCTAssertNil(stop)
        XCTAssertEqual(ime.field, "上海西岸艺术中心")
        XCTAssertEqual(ime.sent.filter { $0 == "toggle" }.count, 1)
        XCTAssertFalse(ime.sent.contains { $0.hasPrefix("type ") && $0.dropFirst(5).allSatisfy(\.isNumber) }, "no digit picks: \(ime.sent)")
    }

    /// A first candidate that is another word (西安 for xi'an) is read in the field, deleted with the words after
    /// it, and typed again by halves.
    func testAWrongFirstCandidateIsRepaired() async throws {
        for hidden in [false, true] {
            let ime = FakeIME(knowing: "上海西岸艺术中心")
            ime.barHidden = hidden
            ime.decoys["xi'an"] = ["西安"]
            let stop = try await ime.typer().attempt("上海西岸艺术中心")
            XCTAssertNil(stop, "bar hidden \(hidden)")
            XCTAssertEqual(ime.field, "上海西岸艺术中心", "bar hidden \(hidden)")
            XCTAssertEqual(ime.sent.filter { $0 == "key backspace" }.count, 6, "西安艺术中心 deleted: \(ime.sent)")
        }
    }

    func testReadBackTellsAMissedWordFromAWrongOne() {
        let words = ["西岸", "艺术", "中心"]
        XCTAssertEqual(HanTyper.readBack(words, prior: "上海", field: "上海西岸艺术中心", base: "", lines: ["上海西岸艺术中心"]),
                       [.seen, .seen, .seen])
        XCTAssertEqual(HanTyper.readBack(words, prior: "上海", field: "上海艺术中心", base: "", lines: ["上海艺术中心"]),
                       [.unseen, .seen, .seen], "OCR dropped 西岸: taken as committed")
        XCTAssertEqual(HanTyper.readBack(words, prior: "上海", field: "上海西安艺术中心", base: "", lines: ["上海西安艺术中心"]),
                       [.wrong("西安")])
        XCTAssertEqual(HanTyper.readBack(words, prior: "上海", field: "上海西岸艺术中心上海博物馆", base: "上海博物馆",
                                         lines: ["上海西岸艺术中心", "上海博物馆"]), [.seen, .seen, .seen])
        XCTAssertEqual(HanTyper.readBack(["西岸"], prior: "上海", field: "上海上海博物", base: "上海博物", lines: ["上海", "上海博物"]),
                       [.unseen], "a suggestion that was there before is not the field")
        XCTAssertEqual(HanTyper.pinyinLeft("上海xin", base: "", pinyin: "zhongxin"), "xin")
        XCTAssertNil(HanTyper.pinyinLeft("上海中心", base: "", pinyin: "zhongxin"))
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
        (ime.pinyin, ime.field) = (false, "")
        let stuck = try await ime.typer().attempt("你好")
        XCTAssertEqual(stuck?.rest, "你好", "a keyboard stuck in English leaves the whole text to paste")
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

    /// The number key went into the pinyin instead of picking: reported, and the letters and the number cleared.
    func testACommitThatDoesNotLandIsReportedAndCleared() async throws {
        let ime = FakeIME(knowing: "北")
        ime.only["bei"] = ["被", "北"]
        let typer = ime.typer()
        let broken = HanTyper(send: { s in if s == "2" { ime.sent.append("type 2"); ime.composing.append("2") } else { ime.send(s) } },
                              key: typer.key, toggle: typer.toggle, look: typer.look)
        let note = try await broken.type("北")
        XCTAssertTrue(note?.contains("\"北\" did not show up") == true, note ?? "nil")
        XCTAssertEqual(ime.composing, "", "nothing left in the field")
        XCTAssertEqual(ime.field, "")
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

@MainActor final class TypeChunkTests: XCTestCase {
    func testLongTextSplitsOnCharacterBoundaries() {
        let text = String(repeating: "a", count: 500)
        let parts = TypeChunks.split(text)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertTrue(parts.allSatisfy { $0.count <= TypeChunks.maxChars })
        XCTAssertEqual(parts.count, Int((500 + TypeChunks.maxChars - 1) / TypeChunks.maxChars))
    }

    func testPinyinAndAccentsAreNotCutInsideACluster() {
        let mark = "e\u{301}"  // e + combining acute, one Character
        let text = String(repeating: mark, count: TypeChunks.maxChars + 3)
        let parts = TypeChunks.split(text)
        XCTAssertEqual(parts.map(\.count), [TypeChunks.maxChars, 3])
        XCTAssertEqual(parts.joined(), text)
        XCTAssertEqual(TypeChunks.split("你好world").joined(), "你好world")
        XCTAssertEqual(TypeChunks.split(""), [])
    }

    func testAPartialFirmwareReplyKeepsTheUntypedTail() async {
        let text = String(repeating: "b", count: 60)
        var sent: [String] = []
        do {
            try await TypeChunks.send(text) { piece in
                sent.append(piece)
                if sent.count == 1 {
                    throw DeviceError(message: "err typed 10 of \(piece.count): budget")
                }
            }
            XCTFail("expected the budget stop")
        } catch let halt as TypeHalted {
            XCTAssertEqual(halt.why, "budget")
            XCTAssertEqual(sent, [String(repeating: "b", count: TypeChunks.maxChars)])
            XCTAssertEqual(halt.left, String(repeating: "b", count: 60 - 10))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(TypeStop.parse("err typed 3 of 8: asleep")?.why, "asleep")
        XCTAssertNil(TypeStop.parse("err unknown command"))
    }

    func testTypingStopsAndReportsTheRestOfThePiece() async throws {
        let text = String(repeating: "c", count: 50) + "尾"
        var sent: [String] = []
        let typer = HanTyper(send: { piece in
            sent.append(piece)
            if piece.count > 10 { throw DeviceError(message: "err typed 4 of \(piece.count): asleep") }
        }, key: { _ in }, toggle: {}, look: { nil })
        let note = try await typer.type(text, checkLetters: false)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(note?.contains("typing stopped (asleep)") == true)
        XCTAssertTrue(note?.contains("not typed:") == true)
        XCTAssertTrue(note?.contains("尾") == true, note ?? "")
    }
}

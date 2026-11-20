import XCTest
import UIKit
@testable import IPhoneAgent

/// Japanese, Korean and other scripts the board cannot type: app names pasted and matched in any width or kana,
/// text put on the clipboard instead of typed as a transliteration.
@MainActor final class LocalScriptTests: XCTestCase {
    private let home = Data([1]), spotlight = Data([2]), app = Data([3])

    func testScriptsTheBoardCannotTypeArePasted() {
        for text in ["メモ", "こんにちは", "메모", "안녕하세요", "Привет", "Γειά", "ok メモ"] {
            XCTAssertTrue(Scripts.needsPaste(text), text)
        }
        for text in ["Notes", "café", "Straße", "微信", "Tiếng Việt", "ok 👍", "１２３", "ＡＢＣ", ""] {
            XCTAssertFalse(Scripts.needsPaste(text), text)
        }
    }

    func testNamesFoldWidthKanaAndComposition() {
        XCTAssertEqual(Scripts.fold("ﾒﾓ"), Scripts.fold("メモ"))
        XCTAssertEqual(Scripts.fold("めも"), Scripts.fold("メモ"))
        XCTAssertEqual(Scripts.fold("ＮＯＴＥＳ"), "notes")
        XCTAssertEqual(Scripts.fold("메모".decomposedStringWithCanonicalMapping), Scripts.fold("메모"))
        XCTAssertEqual(Scripts.fold("Voice Memos"), "voicememos")
        XCTAssertEqual(AppNames.alternatives("めも", language: "ja"), ["Notes", "备忘录"], "hiragana finds the katakana name")
    }

    func testThePastedLocalNameComesFirst() {
        XCTAssertEqual(AppNames.alternatives("Notes", language: "ja", paste: true), ["メモ"])
        XCTAssertEqual(AppNames.alternatives("Alarm", language: "ko", paste: true), ["시계", "Clock"])
        XCTAssertEqual(AppNames.alternatives("시계", language: "ko", paste: true), ["Clock"])
        XCTAssertEqual(AppNames.alternatives("KakaoTalk", language: "ko", paste: true), ["카카오톡"])
        XCTAssertEqual(AppNames.alternatives("メルカリ", language: "ja"), ["Mercari"])
        XCTAssertEqual(AppNames.alternatives("Notes", language: "ja"), ["备忘录"], "without the clipboard as before")
        XCTAssertEqual(AppNames.labels("Notes", language: "ja"), ["备忘录", "Notes", "メモ"])
        XCTAssertEqual(AppNames.labels("SkyTrip", language: "ja"), [], "an app the tables do not know")
    }

    func testResultsListingTheLocalNameCount() {
        let ja = AppNames.labels("Notes", language: "ja")
        XCTAssertTrue(AppOpener.listed("Notes", in: ["Notes", "メモ"], as: ja), "typed Notes, listed as メモ")
        XCTAssertFalse(AppOpener.listed("Notes", in: ["Notes", "メッセージ"], as: ja))
        XCTAssertFalse(AppOpener.listed("Notes", in: ["メモ"], as: ja), "the field must show what was typed")
        XCTAssertTrue(AppOpener.listed("めも", in: ["めも", "メモ"]), "hiragana field, katakana label")
        XCTAssertTrue(AppOpener.listed("ﾒﾓ", in: ["ﾒﾓ", "メモ"]))
        XCTAssertTrue(AppOpener.listed("설정", in: ["설정", "설정"]))
    }

    private func opener(language: String, paste: Bool, lines: @escaping (String) -> [String],
                        log: @escaping (String) -> Void) -> AppOpener {
        var queue = [home, spotlight, app, home, spotlight, app, home, spotlight, app]
        var shown = ""
        return AppOpener(home: { log("home") }, key: { k in log("key \(k)") }, type: { t in shown = t; log("type \(t)") },
                         look: { queue.isEmpty ? nil : queue.removeFirst() }, read: { _ in lines(shown) },
                         same: { $0 == $1 }, pause: { _ in }, language: language,
                         paste: paste ? { t in shown = t; log("paste \(t)"); return true } : nil)
    }

    func testAKanaNameIsPastedIntoSpotlightNeverTyped() async throws {
        var sent: [String] = []
        let result = try await opener(language: "ja", paste: true, lines: { [$0, $0] }) { sent.append($0) }.open("メモ")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent, ["paste メモ", "home", "key cmd+space", "key cmd+a", "key backspace", "key cmd+v", "key enter"])
    }

    func testWithoutTheClipboardAKanaNameGoesBackToTheModel() async throws {
        var sent: [String] = []
        let result = try await opener(language: "ja", paste: false, lines: { [$0] }) { sent.append($0) }.open("メモ")
        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, [], "メモ never went in as \"memo\"")
    }

    func testHanIsPastedOffAChineseIPhoneOnly() async throws {
        var ja: [String] = [], zh: [String] = []
        _ = try await opener(language: "ja", paste: true, lines: { [$0, $0] }) { ja.append($0) }.open("時計")
        _ = try await opener(language: "zh", paste: true, lines: { [$0, $0] }) { zh.append($0) }.open("时钟")
        XCTAssertEqual(ja.first, "paste 時計")
        XCTAssertFalse(zh.contains { $0.hasPrefix("paste") }, "never the clipboard on a Chinese iPhone")
        XCTAssertEqual(zh.first { $0.hasPrefix("type") }, "type shizhong", "its letters first, then the pinyin keyboard")
    }

    func testTypeWithJapaneseTextGoesOnTheClipboard() async throws {
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        var written: [String] = []
        agent.onWrite = { written.append($0); return true }
        let note = try await agent.perform(["action": .str("type"), "text": .str("こんにちは")])
        XCTAssertEqual(written, ["こんにちは"])
        XCTAssertFalse(phone.calls.contains("type"), "never typed as a transliteration")
        XCTAssertEqual(note?.field, "typed")
        XCTAssertTrue(note?.value.contains("key cmd+v") == true)
        agent.onWrite = nil
        let none = try await agent.perform(["action": .str("type"), "text": .str("안녕하세요")])
        XCTAssertTrue(none?.value.contains("clipboard is not available") == true)
        let plain = try await agent.perform(["action": .str("type"), "text": .str("hello")])
        XCTAssertNil(plain)
        XCTAssertEqual(phone.calls, ["type"])
    }

    /// The pinyin keyboard did not offer a word: the rest goes on the clipboard, the app opens again, cmd+v, and the
    /// field is read back; Enter then goes through (2026-11-20: the run stopped with 上海 typed, 西岸艺术中心 not).
    func testTheRestOfAStoppedChineseTypeIsPastedAndReadBack() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = UIImage(cgImage: ChineseOCRTests.screen([["上海西岸艺术中心"]], points: 28)).jpegData(compressionQuality: 1)
        let agent = AgentLoop(phone: phone, screen: screen, actor: nil, planner: nil, trace: nil)
        agent.openedAtStart = "Maps"
        var written: [String] = []
        agent.onWrite = { written.append($0); return true }
        phone.typeNote = "\"西\" is not among the candidates for xi (cleared); typed \"上海\", not typed: \"西岸艺术中心\""
        phone.typeRest = "西岸艺术中心"
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(written, ["西岸艺术中心"], "only the rest, not what pinyin already typed")
        XCTAssertEqual(phone.calls, ["type", "open Maps", "key"])
        XCTAssertEqual(result?.field, "result")
        XCTAssertTrue(result?.value.contains("pasted and read back") == true, result?.value ?? "nil")
        XCTAssertNil(agent.sendGuard.enter(step: 2), "the field is whole: Enter is not held")
    }

    func testARestNotSeenAfterPastingIsLeftToTheModelWithTheClipboardReady() async throws {
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.onWrite = { _ in true }
        phone.typeNote = "\"西\" is not among the candidates for xi (cleared); typed \"上海\", not typed: \"西岸艺术中心\""
        phone.typeRest = "西岸艺术中心"
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(result?.field, "typed")
        XCTAssertTrue(result?.value.contains("\"西岸艺术中心\" is on the clipboard") == true, result?.value ?? "nil")
        XCTAssertTrue(result?.value.contains("key cmd+v") == true)
        XCTAssertTrue(result?.value.hasPrefix("If the screen already lists what the goal needs") == true, "the listed target first")
        XCTAssertEqual(agent.sendGuard.missing, "西岸艺术中心")
    }

    func testAStopWithNothingToPasteNeverTouchesTheClipboard() async throws {
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        var written: [String] = []
        agent.onWrite = { written.append($0); return true }
        phone.typeNote = "typing stopped (budget); typed \"上海\", not typed: \"西岸\""
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸")])
        XCTAssertEqual(written, [])
        XCTAssertEqual(result?.value, SendGuard.listedHint + (phone.typeNote ?? ""))
        phone.typeNote = nil
        let typed = try await agent.perform(["action": .str("type"), "text": .str("上海西岸")])
        XCTAssertNil(typed, "pinyin worked: nothing changes")
        XCTAssertEqual(written, [])
        XCTAssertEqual(phone.calls, ["type", "type"])
    }

    /// The partial-type hold points to the app's own clear action, never a 清空 button (the pay guard stops at it).
    func testThePartialTypeHoldPointsToTheClearAction() {
        var guardian = SendGuard()
        guardian.typed("上海西岸艺术中心", missing: "西岸艺术中心")
        let held = guardian.enter(step: 5) ?? ""
        XCTAssertTrue(held.contains("If the screen already lists what the goal needs"), held)
        XCTAssertTrue(held.contains("type the rest first"), held)
        XCTAssertTrue(TypedGuard.reason("x").contains("tap it instead of typing more"))
        XCTAssertTrue(held.contains("the clear action"), held)
        XCTAssertTrue(held.contains("never a 清空"), held)
        XCTAssertTrue(Prompts.actor.contains("never a 清空 / Clear button"), "the action list says it too")
    }

    func testThePointerNeverSendsATransliteration() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        let note = try await pointer.type("メモ")
        XCTAssertNotNil(note)
        XCTAssertEqual(device.sent, [])
    }
}

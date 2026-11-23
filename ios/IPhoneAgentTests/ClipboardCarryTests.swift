import UIKit
import XCTest
@testable import IPhoneAgent

/// The Chinese text carried on the clipboard from the run's start, and the paste when pinyin stops part way: never a
/// hop back to this app (Henry 2026-11-20: the Spotlight hop failed on device and looked bizarre).
@MainActor final class ClipboardCarryTests: XCTestCase {
    func testThePromptsSearchTermIsCarriedWithoutTheAppName() {
        XCTAssertEqual(ClipboardCarry.fromPrompt("打开高德地图，搜索 上海西岸艺术中心，打开第一个结果的详情页"), "上海西岸艺术中心")
        XCTAssertEqual(ClipboardCarry.fromPrompt("在高德地图搜索上海西岸艺术中心"), "上海西岸艺术中心")
        XCTAssertEqual(ClipboardCarry.fromPrompt("打开微信，给文件传输助手发「明天见」"), "明天见", "no search verb: the one quoted text")
    }

    func testNothingIsCarriedWhenUnsureOrNotChinese() {
        XCTAssertNil(ClipboardCarry.fromPrompt("打开高德地图"))
        XCTAssertNil(ClipboardCarry.fromPrompt("open Maps and search coffee"))
        XCTAssertNil(ClipboardCarry.fromPrompt("搜索 咖啡，然后搜索 奶茶"), "two terms: unsure")
        XCTAssertNil(ClipboardCarry.fromPrompt("搜索 高德地图"), "only an app name")
        XCTAssertNil(ClipboardCarry.pick(task: "open Notes", plan: nil, typed: []))
    }

    func testThePlansTypeTextComesFirst() {
        let task = "打开高德地图，搜索 上海西岸艺术中心"
        XCTAssertEqual(ClipboardCarry.pick(task: task, plan: nil, typed: ["hello", "西岸美术馆"])?.text, "西岸美术馆")
        XCTAssertEqual(ClipboardCarry.pick(task: task, plan: nil, typed: [])?.source, "prompt")
        let plan = "1. open 高德地图\n2. tap the search bar, type \"西岸艺术中心\"\n3. tap the first result"
        let picked = ClipboardCarry.pick(task: task, plan: plan, typed: [])
        XCTAssertEqual(picked?.text, "西岸艺术中心")
        XCTAssertEqual(picked?.source, "plan")
    }

    private func stopped(_ phone: FakeGestures) {
        phone.typeNote = "\"西\" is not among the candidates for xi (cleared); typed \"上海\", not typed: \"西岸艺术中心\""
        phone.typeRest = "西岸艺术中心"
    }

    private func agent(_ phone: FakeGestures, screen: FakeScreen? = nil, count: Int = 7) -> AgentLoop {
        let agent = AgentLoop(phone: phone, screen: screen ?? FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.openedAtStart = "Maps"
        agent.carried = ClipboardCarry(text: "上海西岸艺术中心", changeCount: 7, source: "prompt")
        agent.clipboardCount = { count }
        agent.onWrite = { _ in XCTFail("no clipboard write (hop) mid-run"); return false }
        return agent
    }

    private func shows(_ text: String) -> Data? {
        UIImage(cgImage: ChineseOCRTests.screen([[text]], points: 28)).jpegData(compressionQuality: 1)
    }

    /// Equal to the carried text, clipboard unchanged: pasted first (clear, cmd+v, read back), no pinyin at all; no
    /// Home, Spotlight or app switch (Henry 2026-11-20 watched pinyin typed for the text the clipboard held).
    func testTheCarriedTextIsPastedFirstWithoutPinyin() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = shows("上海西岸艺术中心")
        let agent = agent(phone, screen: screen)
        let result = try await agent.perform(["action": .str("type"), "text": .str(" 上海西岸艺术中心 ")])
        XCTAssertEqual(result?.field, "result")
        XCTAssertTrue(result?.value.contains("read back") == true, result?.value ?? "nil")
        XCTAssertFalse(phone.calls.contains("type"), "no pinyin keys: \(phone.calls)")
        XCTAssertTrue(phone.calls.allSatisfy { $0 == "key" }, "clear's keys and cmd+v only: \(phone.calls)")
        XCTAssertEqual(phone.keys.last, "cmd+v")
        XCTAssertNil(agent.sendGuard.enter(step: 2), "the field is whole: Enter is not held")
        XCTAssertEqual(agent.typeStats, TypeStats(pinyinStops: 0, pasteOK: 1, pasteFailed: [:]))
    }

    /// Paste first not seen: the field is cleared again and the text typed in pinyin as before.
    func testAPasteFirstNotSeenFallsBackToPinyin() async throws {
        let phone = FakeGestures()
        let agent = agent(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertNil(result, "pinyin typed it all")
        XCTAssertEqual(phone.calls.last, "type")
        let paste = try XCTUnwrap(phone.keys.firstIndex(of: "cmd+v"))
        XCTAssertTrue(phone.keys[(paste + 1)...].contains("alt+backspace"), "cleared again before pinyin: \(phone.keys)")
        XCTAssertEqual(agent.typeStats, TypeStats(pinyinStops: 0, pasteOK: 0, pasteFailed: ["not_seen": 1]))
    }

    /// Paste first not seen, pinyin then stops part way, and the paste after the stop is read back.
    func testThePasteAfterAPinyinStopStillWorks() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let agent = agent(phone, screen: screen)
        stopped(phone)
        phone.onType = { screen.frame = self.shows("上海西岸艺术中心") }
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(result?.field, "result")
        XCTAssertTrue(result?.value.contains("stopped part way") == true, result?.value ?? "nil")
        XCTAssertEqual(phone.keys.filter { $0 == "cmd+v" }.count, 2)
        XCTAssertEqual(agent.typeStats, TypeStats(pinyinStops: 1, pasteOK: 1, pasteFailed: ["not_seen": 1]))
    }

    func testAPasteNotSeenTellsTheModelToCheckTheField() async throws {
        let phone = FakeGestures()
        let agent = agent(phone)
        stopped(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(result?.field, "typed")
        XCTAssertTrue(result?.value.contains("not seen") == true, result?.value ?? "nil")
        XCTAssertFalse(phone.calls.contains { $0.hasPrefix("open") || $0 == "home" || $0 == "swipe" }, "\(phone.calls)")
        XCTAssertEqual(agent.typeStats, TypeStats(pinyinStops: 1, pasteOK: 0, pasteFailed: ["not_seen": 2]))
    }

    /// Other text: nothing pasted. The clipboard's changeCount is not trusted (it moves in the background on a device).
    func testNoPasteWhenTheTextDiffers() async throws {
        for (count, text) in [(7, "上海西岸美术馆")] {
            let phone = FakeGestures()
            let agent = agent(phone, count: count)
            stopped(phone)
            let result = try await agent.perform(["action": .str("type"), "text": .str(text)])
            XCTAssertEqual(phone.calls, ["type"], "nothing pasted, no app switch")
            XCTAssertEqual(result?.field, "typed")
            XCTAssertTrue(result?.value.contains("type the rest yourself") == true, result?.value ?? "nil")
            XCTAssertEqual(agent.sendGuard.missing, "西岸艺术中心")
        }
    }

    func testNoPasteWithNothingCarried() async throws {
        let phone = FakeGestures()
        let agent = agent(phone)
        agent.carried = nil
        stopped(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(phone.calls, ["type"])
        XCTAssertTrue(result?.value.hasPrefix(SendGuard.listedHint) == true)
    }

    /// The agent's clipboard write expires (local only, ClipboardCarry.lifetime): an expired one is not pasted.
    func testNoPasteWhenTheCarriedTextExpired() async throws {
        let phone = FakeGestures()
        let agent = agent(phone)
        agent.carried?.expires = Date().addingTimeInterval(-1)
        stopped(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(phone.calls, ["type"], "nothing pasted")
        XCTAssertEqual(result?.field, "typed")
    }

    /// A vowel-initial syllable after another gets the pinyin separator: 西岸 is xi'an, not xian (先, 现).
    func testPinyinSeparatesVowelSyllables() {
        XCTAssertEqual(Pointer.typeable("上海西岸艺术中心"), "shanghaixi'anyishuzhongxin")
        XCTAssertEqual(Pointer.typeable("天安门"), "tian'anmen")
        XCTAssertEqual(Pointer.typeable("安全"), "anquan")
        XCTAssertEqual(Pointer.typeable("卫生纸 3卷"), "weishengzhi 3juan")
    }

    /// 2026-11-23, iPhone X: "好的，明天见！" went in as 好的明天见 (the punctuation dropped, no note) and the model
    /// cleared and retyped it for 10 minutes. Chinese punctuation goes in as the key that makes it on the pinyin keyboard.
    func testChinesePunctuationIsTyped() {
        XCTAssertEqual(Pointer.typeable("好的，明天见！"), "haode,mingtianjian!")
        XCTAssertEqual(Pointer.typeable("好。真的？是：对；（行）"), "hao.zhende?shi:dui;(xing)")
        XCTAssertEqual(Pointer.typeable("“你好”、《书》"), "\"nihao\"\\<shu>")
        XCTAssertEqual(Pointer.typeable("等等……走——"), "dengdeng^zou_")
        XCTAssertEqual(HanTyper.pieces("好的，明天见！").filter { if case .plain = $0 { true } else { false } },
                       [.plain("，"), .plain("！")])
        XCTAssertEqual(Accents.plan("，").typed, ",", "the plain piece is typed, not skipped")
    }
}

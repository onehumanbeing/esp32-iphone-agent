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

    /// Equal to the carried text, clipboard unchanged: clear, cmd+v, read back; no Home, Spotlight or app switch.
    func testTheCarriedTextIsPastedInPlaceAndReadBack() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = UIImage(cgImage: ChineseOCRTests.screen([["上海西岸艺术中心"]], points: 28)).jpegData(compressionQuality: 1)
        let agent = agent(phone, screen: screen)
        stopped(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str(" 上海西岸艺术中心 ")])
        XCTAssertEqual(result?.field, "result")
        XCTAssertTrue(result?.value.contains("read back") == true, result?.value ?? "nil")
        XCTAssertEqual(phone.calls.first, "type")
        XCTAssertTrue(phone.calls.dropFirst().allSatisfy { $0 == "key" }, "clear's keys and cmd+v only: \(phone.calls)")
        XCTAssertGreaterThan(phone.calls.count, 2)
        XCTAssertNil(agent.sendGuard.enter(step: 2), "the field is whole: Enter is not held")
    }

    func testAPasteNotSeenTellsTheModelToCheckTheField() async throws {
        let phone = FakeGestures()
        let agent = agent(phone)
        stopped(phone)
        let result = try await agent.perform(["action": .str("type"), "text": .str("上海西岸艺术中心")])
        XCTAssertEqual(result?.field, "typed")
        XCTAssertTrue(result?.value.contains("not seen") == true, result?.value ?? "nil")
        XCTAssertFalse(phone.calls.contains { $0.hasPrefix("open") || $0 == "home" || $0 == "swipe" }, "\(phone.calls)")
    }

    func testNoPasteWhenTheClipboardChangedOrTheTextDiffers() async throws {
        for (count, text) in [(8, "上海西岸艺术中心"), (7, "上海西岸美术馆")] {
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
}

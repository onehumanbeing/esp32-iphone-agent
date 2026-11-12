import XCTest
@testable import IPhoneAgent

/// `open APP` by code: Spotlight, Return only when the results list the name, read back that the app came up.
@MainActor final class AppOpenerTests: XCTestCase {
    private let home = Data([1]), spotlight = Data([2]), app = Data([3])

    /// A phone whose screens come in order (one per look) and whose OCR reads `lines` on Spotlight.
    private func opener(_ frames: [Data?], lines: [String] = ["Notes", "Notes"], own: Bool = false,
                        log: @escaping (String) -> Void) -> AppOpener {
        var queue = frames
        return AppOpener(home: { log("home") }, key: { log("key \($0)") }, type: { log("type \($0)") },
                         look: { queue.isEmpty ? nil : queue.removeFirst() }, read: { _ in lines },
                         ownAppInFront: { own }, same: { $0 == $1 }, pause: { _ in })
    }

    func testOpensWithReturnOnceTheResultsListTheApp() async throws {
        var sent: [String] = []
        let result = try await opener([home, spotlight, app]) { sent.append($0) }.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent, ["home", "key cmd+space", "key cmd+a", "key backspace", "type Notes", "key enter"])
    }

    /// A plain wallpaper and no on-screen keyboard: Spotlight looks like the Home Screen and the app like both,
    /// so what the screen says decides (2026-11-11: WeChat judged "Spotlight did not come up" twice).
    func testPlainWallpaperIsJudgedByWhatTheScreenSays() async throws {
        var sent: [String] = []
        var queue: [Data?] = [home, spotlight, app]
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [app] in $0 == app ? ["微信", "文件传输助手"] : ["WeChat", "WeChat"] },
                               same: { _, _ in true }, pause: { _ in })
        let result = try await opener.open("WeChat")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "key enter" }.count, 1)
    }

    func testChineseNameIsTypedAsIsTheTyperCommitsIt() async throws {
        var sent: [String] = []
        let result = try await opener([home, spotlight, app], lines: ["时钟", "时钟"]) { sent.append($0) }.open("时钟")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent, ["home", "key cmd+space", "key cmd+a", "key backspace", "type 时钟", "key enter"])
    }

    func testANameSpotlightDoesNotKnowIsTriedUnderItsSystemName() async throws {
        var sent: [String] = [], typed = ""
        var queue = [home, spotlight, spotlight, spotlight, home, spotlight, app]  // 闹钟: two more looks, still not listed
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") },
                               type: { typed = $0; sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { _ in typed == "时钟" ? ["时钟", "时钟"] : [typed] },
                               same: { $0 == $1 }, pause: { _ in }, language: "zh")
        let result = try await opener.open("闹钟")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, ["type 闹钟", "type 时钟"])
        XCTAssertEqual(sent.filter { $0 == "key enter" }.count, 1)
    }

    func testAliasesNameTheSystemAppsChineseFirst() {
        XCTAssertEqual(AppNames.alternatives("闹钟", language: "zh"), ["时钟", "Clock"])
        XCTAssertEqual(AppNames.alternatives("clock", language: "zh"), ["时钟"])
        XCTAssertEqual(AppNames.alternatives("时钟", language: "zh"), ["Clock"])
        XCTAssertEqual(AppNames.alternatives("Voice Memos", language: "zh"), ["语音备忘录"])
        XCTAssertEqual(AppNames.alternatives("App Store", language: "zh"), [])
        XCTAssertEqual(AppNames.alternatives("Duolingo", language: "zh"), [])
    }

    func testNoSuchAppLeavesSpotlightForTheModelWithoutReturn() async throws {
        var sent: [String] = []
        let result = try await opener([home, spotlight], lines: ["Notes", "Messages"]) { sent.append($0) }.open("Notes")
        XCTAssertEqual(result, .notFound)
        XCTAssertFalse(sent.contains("key enter"), "Return would open whatever matched instead")
    }

    func testStillOnSpotlightAfterReturnRetriesOnceThenGivesUp() async throws {
        var sent: [String] = []
        let frames = [home, spotlight, spotlight, home, spotlight, home]  // try 1: Return did nothing; try 2: back home
        let result = try await opener(frames) { sent.append($0) }.open("Notes")
        XCTAssertEqual(result, .notOpened)
        XCTAssertEqual(sent.filter { $0 == "key enter" }.count, AppOpener.tries)
    }

    func testSpotlightThatNeverCameUpIsTriedAgainWithoutReturn() async throws {
        var sent: [String] = []
        var queue: [Data?] = [home, home, home, spotlight, app]
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["Notes", "Notes"] },  // the Home Screen lists no results
                               same: { $0 == $1 }, pause: { _ in })
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "key cmd+space" }.count, 2)
        XCTAssertEqual(sent.filter { $0 == "key enter" }.count, 1)
    }

    func testThisAppInFrontIsNotTheOpenedApp() async throws {
        let result = try await opener([home, spotlight, app, home, spotlight, app], own: true) { _ in }.open("Notes")
        XCTAssertEqual(result, .notOpened)
    }

    func testWithoutAScreenTheKeysGoOutUnchecked() async throws {
        var sent: [String] = []
        let result = try await opener([]) { sent.append($0) }.open("Notes")
        XCTAssertEqual(result, .unchecked)
        XCTAssertEqual(sent, ["home", "key cmd+space", "key cmd+a", "key backspace", "type Notes"])
    }

    func testListedNeedsTheNameBeyondTheSearchField() {
        XCTAssertFalse(AppOpener.listed("Notes", in: ["notes"]))
        XCTAssertTrue(AppOpener.listed("Notes", in: ["notes", "Notes"]))
        XCTAssertTrue(AppOpener.listed("App Store", in: ["App Store", "AppStore"]))
        XCTAssertTrue(AppOpener.listed("Microsoft Outlook", in: ["Microsoft Outlook", "Microsoft Ou…"]))
        XCTAssertFalse(AppOpener.listed("Microsoft Outlook", in: ["Microsoft Outlook", "Mi…"]))
        XCTAssertFalse(AppOpener.listed("", in: ["", ""]))
    }

    func testTheModelSeesWhatOpenFound() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        phone.openResult = .notFound
        let actor = FakeModel { _ in "THINK: open it\nDO: open Notes" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(phone.calls, ["open Notes"])
        let line = AgentLoop.effect(try XCTUnwrap(agent.steps.last))
        XCTAssertTrue(line.contains("Spotlight lists no app named Notes nor 备忘录"), line)
    }

    func testTheModelSeesWhatTypingCouldNotType() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        phone.typeNote = "\"龘\" is not among the candidates for da (cleared)"
        let actor = FakeModel { _ in "THINK: type it\nDO: type 龘" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.step()
        let line = AgentLoop.effect(try XCTUnwrap(agent.steps.last))
        XCTAssertTrue(line.contains("typing stopped: \"龘\" is not among"), line)
    }

    /// The results come up after the first look: an empty field over Siri Suggestions, then "WeChat" in the field
    /// (2026-11-12). It looks again instead of typing 微信 next.
    func testResultsThatLagTheTypingAreLookedAtAgain() async throws {
        var sent: [String] = []
        let early = Data([4])
        var queue: [Data?] = [home, early, spotlight, app]
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [early] in $0 == early ? ["Siri Suggestions", "WeChat"] : ["WeChat", "WeChat"] },
                               same: { $0 == $1 }, pause: { _ in })
        let result = try await opener.open("WeChat")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, ["type WeChat"])
        XCTAssertEqual(sent.filter { $0 == "key enter" }.count, 1)
    }
}

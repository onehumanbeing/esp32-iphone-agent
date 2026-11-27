import XCTest
@testable import IPhoneAgent

/// `open APP` by code: Spotlight, Return only when the results list the name, read back that the app came up.
@MainActor final class AppOpenerTests: XCTestCase {
    private let home = Data([1]), spotlight = Data([2]), app = Data([3])

    /// A phone whose screens come in order (one per look) and whose OCR reads `lines` on Spotlight.
    private func opener(_ frames: [Data?], lines: [String] = ["Notes", "Notes"], homeLines: [String]? = nil, appLines: [String]? = nil,
                        own: Bool = false, log: @escaping (String) -> Void) -> AppOpener {
        var queue = frames
        return AppOpener(home: { log("home") }, key: { log("key \($0)") }, type: { log("type \($0)") },
                         look: { queue.isEmpty ? nil : queue.removeFirst() }, read: { [home, app] in $0 == home ? homeLines ?? lines : $0 == app ? appLines ?? lines : lines },
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

    /// A Chinese name goes in as its pinyin letters first: no input method.
    func testChineseNameIsTypedAsPinyinLettersFirst() async throws {
        var sent: [String] = []
        var zh = opener([home, spotlight, app], lines: ["shizhong", "时钟"], homeLines: [], appLines: ["时钟"]) { sent.append($0) }
        zh.language = "zh"  // a Chinese iPhone (an English one types the app's English name first)
        let result = try await zh.open("时钟")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent, ["home", "key cmd+space", "key cmd+a", "key backspace", "type shizhong", "key enter"])
    }

    /// An English iPhone: 计算器 goes in as Calculator, and the results listing Calculator are the app (2026-11-27:
    /// judged by 计算器 alone, never found, and the pinyin after it failed too).
    func testAChineseNameTypedInTheIPhonesLanguageIsFoundByThatName() async throws {
        var sent: [String] = []
        var en = opener([home, spotlight, app], lines: ["Calculator", "Calculator"], homeLines: [], appLines: ["AC", "%"]) { sent.append($0) }
        en.language = "en"
        let result = try await en.open("计算器")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, ["type Calculator"], "\(sent)")
    }

    /// The letters list nothing: the name itself, through the pinyin keyboard, after Home.
    func testChineseNameItselfWhenThePinyinListsNothing() async throws {
        var sent: [String] = [], typed = ""
        var queue = [home, spotlight, spotlight, spotlight, home, spotlight, app]
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") },
                               type: { typed = $0; sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : typed == "时钟" ? ["时钟", "时钟"] : [typed] },
                               same: { $0 == $1 }, pause: { _ in }, language: "zh")
        let result = try await opener.open("时钟")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, ["type shizhong", "type 时钟"])
    }

    func testOnlyAChineseNameGetsItsLettersFirst() {
        XCTAssertEqual(AppOpener.queries("微信", pasting: false, language: "zh"), ["weixin", "微信"])
        XCTAssertEqual(AppOpener.queries("WeChat", pasting: false, language: "zh"), ["WeChat"])
        XCTAssertEqual(AppOpener.queries("微信", pasting: true, language: "zh"), ["微信"])
        // an English iPhone lists them by their English names: pinyin found nothing there
        XCTAssertEqual(AppOpener.queries("地图", pasting: false, language: "en"), ["Maps", "ditu"])
        XCTAssertEqual(AppOpener.queries("小红书", pasting: false, language: "en"), ["rednote", "xiaohongshu"])
    }

    /// A name Spotlight does not list goes back to the model; code never types other names (2026-11-13).
    func testANameSpotlightDoesNotKnowGoesBackToTheModel() async throws {
        var sent: [String] = [], typed = ""
        var queue = [home, spotlight, spotlight, spotlight, home, spotlight, spotlight, spotlight]  // 闹钟, letters then itself: never listed
        let opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") },
                               type: { typed = $0; sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : [typed] },
                               same: { $0 == $1 }, pause: { _ in }, language: "zh")
        let result = try await opener.open("闹钟")
        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(sent.filter { $0.hasPrefix("type") }, ["type naozhong", "type 闹钟"], "the same name, never another")
        XCTAssertFalse(sent.contains("key enter"))
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
        let result = try await opener([home, spotlight], lines: ["Notes", "Messages"], homeLines: []) { sent.append($0) }.open("Notes")
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

    /// The picture ran behind: the look after typing still shows Siri Suggestions, whose icon grid lists the app.
    /// No tap there (it landed on another result, 2026-11-27 case 37); looked at again until the results are in.
    func testNoTapOnSiriSuggestionsFromBeforeTheResults() async throws {
        let suggestions = Data([7])
        var queue: [Data?] = [home, suggestions, spotlight, app]
        var tapped: [CGPoint] = []
        var opener = AppOpener(home: {}, key: { _ in }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, app, suggestions] in
                                   $0 == home ? [] : $0 == app ? ["Shopping list"]
                                       : $0 == suggestions ? ["Siri Suggestions", "Notes", "Notes", "Settings", "Q Search"] : ["Notes", "Notes", "Apps"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.readBoxes = { [suggestions] frame in
            (frame == suggestions ? [("Siri Suggestions", [40, 180, 400, 220]), ("Notes", [760, 620, 900, 660])]
                                  : [("Notes", [100, 600, 300, 640])], CGSize(width: 1000, height: 2000))
        }
        opener.tapAt = { tapped.append($0) }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(Double(tapped[0].x), 0.2, accuracy: 0.001, "the results row, not the suggestions grid")
    }

    func testSuggestingIsTheHeaderWithoutATopHit() {
        XCTAssertTrue(AppOpener.suggesting(["Siri Suggestions", "Reminders", "Q Search"]))
        XCTAssertTrue(AppOpener.suggesting(["Siri Suggestions", "Show Less", "Reminders", "Q Reminders"]),
                      "the last query brought back over the grid, 2026-11-27")
        XCTAssertFalse(AppOpener.suggesting(["Top Hit", "Reminders", "Suggestions", "Reminders"]))
        XCTAssertFalse(AppOpener.suggesting(["Q Search", "Reminders"]))
    }

    /// The results list the app: its row is tapped, never Return (Wiki #1007 N1; 2026-11-20 Pocket Chess). The
    /// search field (the same text) is tapped first when it is on top and changes nothing; opened once Spotlight is gone.
    func testAListedResultIsTappedNotReturn() async throws {
        for (field, taps) in [(false, 1), (true, 2)] {
            var queue: [Data?] = field ? [home, spotlight, spotlight, app] : [home, spotlight, app]
            var tapped: [CGPoint] = [], sent: [String] = []
            var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                                   read: { [home, app] in $0 == home ? [] : $0 == app ? ["Shopping list"] : ["Notes", "Notes"] },
                                   same: { $0 == $1 }, pause: { _ in })
            let rows: [(text: String, box: [Int])] = field
                ? [("Notes", [100, 200, 300, 240]), ("Notes", [100, 600, 300, 640]), ("Notes from Mike", [100, 900, 500, 940])]
                : [("Notes", [100, 600, 300, 640]), ("Notes from Mike", [100, 900, 500, 940])]
            opener.readBoxes = { _ in (rows, CGSize(width: 1000, height: 2000)) }
            opener.tapAt = { tapped.append($0) }
            var logs: [String] = []
            opener.log = { logs.append($0) }
            let result = try await opener.open("Notes")
            XCTAssertEqual(result, .opened)
            XCTAssertFalse(sent.contains("enter"), "Return commits pinyin letters instead of opening the top hit")
            XCTAssertEqual(tapped.count, taps)
            XCTAssertEqual(Double(tapped.last!.y), 0.31, accuracy: 0.001, "the result row, never the line that only contains the name")
            XCTAssertEqual(logs.last, "open Notes via Spotlight: typed, result row read at (0.20,0.31) → tapped")
        }
    }

    /// The pinyin letters stayed composing and the name is only in the candidate bar: space, never a tap there
    /// (2026-11-26: the tap's pointer search and settle took 13 s). Then the web-only result says not installed.
    func testTheNameInTheCandidateBarIsPutInWithSpace() async throws {
        let committed = Data([5])
        var queue: [Data?] = [home, spotlight, committed]
        var sent: [String] = [], tapped = 0
        var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["汽水音乐", "qi shui yin yue"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.language = "zh-Hans"
        opener.readBoxes = { [committed] frame in
            (frame == committed ? [("Suggestions", [40, 300, 300, 340]), ("汽水音乐", [140, 400, 400, 440])]
                                : [("汽水音乐", [20, 1270, 240, 1300])], CGSize(width: 1000, height: 2000))
        }
        opener.tapAt = { _ in tapped += 1 }
        let result = try await opener.open("汽水音乐")
        XCTAssertEqual(result, .notFound)
        XCTAssertEqual(tapped, 0)
        XCTAssertTrue(sent.contains("space"))
    }

    /// The app's row is the Top Hit and the name went in as letters: Return opens it, no pointer search for a tap
    /// (2026-11-26: the tap's pointer search was 5 s of an 18.6 s open). Letters still composing (Return only
    /// commits them, Spotlight stays): the row is tapped after all. A name under another header is tapped.
    func testTheTopHitIsOpenedWithReturn() async throws {
        let committed = Data([5])
        let topHit: [(text: String, box: [Int])] = [("Top Hit", [40, 150, 300, 190]), ("Settings", [140, 400, 400, 440]),
                                                    ("Settings", [140, 1100, 400, 1140])]
        // a look before another Return or a tap (`cameUp`) sees the same screen again: the repeated frames
        for (frames, keys, taps) in [([home, spotlight, app], ["enter"], 0),
                                     ([home, spotlight, committed, committed, app], ["enter", "enter"], 0),
                                     ([home, spotlight, spotlight, spotlight, app], ["enter", "enter"], 0),
                                     ([home, spotlight, committed, committed, committed, committed, app], ["enter", "enter"], 1)] {
            var queue: [Data?] = frames
            var sent: [String] = [], tapped = 0
            var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                                   read: { [home, app] in $0 == home ? [] : $0 == app ? ["General", "Privacy"] : ["Settings", "Settings", "Top Hit"] },
                                   same: { $0 == $1 }, pause: { _ in })
            opener.readBoxes = { _ in (topHit, CGSize(width: 1000, height: 2000)) }
            opener.tapAt = { _ in tapped += 1 }
            let result = try await opener.open("Settings")
            XCTAssertEqual(result, .opened)
            XCTAssertEqual(sent.filter { $0 == "enter" }, keys)
            XCTAssertEqual(tapped, taps)
        }
        let size = CGSize(width: 1000, height: 2000)
        let other: [(text: String, box: [Int])] = [("Top Hit", [40, 150, 300, 190]), ("BlockThreat", [140, 250, 400, 290]),
                                                   ("Applications", [40, 350, 300, 390]), ("Settings", [140, 450, 400, 490])]
        XCTAssertFalse(AppOpener.isTopHit(AppOpener.resultRows(other, labels: ["Settings"], size: size)))
        XCTAssertTrue(AppOpener.isTopHit(AppOpener.resultRows(topHit, labels: ["Settings"], size: size)))
        XCTAssertFalse(AppOpener.isTopHit(AppOpener.resultRows([("Settings", [140, 400, 400, 440])], labels: ["Settings"], size: size)))
    }

    /// The first Return only put composing letters in: a frame captured after it is Spotlight still, so the second
    /// Return goes at once, without a settled look and a read first (2026-11-27: ~9 s). One that changed: no quick one.
    func testAnUnchangedFrameAfterTheFirstReturnGetsTheSecondAtOnce() async throws {
        let topHit: [(text: String, box: [Int])] = [("Top Hit", [40, 150, 300, 190]), ("Calendar", [140, 400, 400, 440])]
        for (quick, keys, looks) in [(spotlight, ["enter", "enter"], 3), (app, ["enter"], 3)] {
            var queue: [Data?] = [home, spotlight, app]
            var sent: [String] = [], looked = 0
            var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in },
                                   look: { looked += 1; return queue.isEmpty ? nil : queue.removeFirst() },
                                   read: { [home, app] in $0 == home ? [] : $0 == app ? ["November", "Today"] : ["Calendar", "Calendar", "Top Hit"] },
                                   same: { $0 == $1 }, pause: { _ in })
            opener.readBoxes = { _ in (topHit, CGSize(width: 1000, height: 2000)) }
            opener.tapAt = { _ in XCTFail("no tap") }
            opener.freshAfter = { _ in quick }
            let result = try await opener.open("Calendar")
            XCTAssertEqual(result, .opened)
            XCTAssertEqual(sent.filter { $0 == "enter" }, keys)
            XCTAssertEqual(looked, looks)
        }
    }

    /// The device run of 2026-11-26: Settings came up on Return, and its title and its "Apps" and "Watch" rows were
    /// all words Spotlight had shown too. Spotlight's Top Hit header is gone: opened, no tap on the old row spot.
    func testAnAppSharingSpotlightsWordsIsOpenedOnceTheTopHitHeaderIsGone() async throws {
        let settingsApp = Data([6])
        var queue: [Data?] = [home, spotlight, settingsApp]
        var sent: [String] = [], tapped = 0
        var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, settingsApp] in
                                   $0 == home ? [] : $0 == settingsApp ? ["Settings", "Apple Account", "Apps", "Watch"]
                                       : ["Top Hit", "Settings", "Suggestions", "Settings", "Apps", "Watch"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.big = { _, _ in true }
        opener.readBoxes = { _ in ([("Top Hit", [40, 150, 300, 190]), ("Settings", [140, 400, 400, 440])], CGSize(width: 1000, height: 2000)) }
        opener.tapAt = { _ in tapped += 1 }
        let result = try await opener.open("Settings")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "enter" }, ["enter"])
        XCTAssertEqual(tapped, 0)
    }

    /// 2026-11-26 on the device: the look after Return was cut short and still showed Spotlight while Settings came
    /// up; a second Return and a tap on the old row spot went into Settings. One more look first: opened.
    func testAnAppComingUpLateGetsNoSecondReturnAndNoTap() async throws {
        let passing = Data([7])
        var queue: [Data?] = [home, spotlight, passing, app]
        var sent: [String] = [], tapped = 0, logs: [String] = []
        var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, app] in $0 == home ? [] : $0 == app ? ["General", "Privacy"] : ["Top Hit", "Settings", "Settings"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.readBoxes = { _ in ([("Top Hit", [40, 150, 300, 190]), ("Settings", [140, 400, 400, 440])], CGSize(width: 1000, height: 2000)) }
        opener.tapAt = { _ in tapped += 1 }
        opener.log = { logs.append($0) }
        let result = try await opener.open("Settings")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "enter" }, ["enter"])
        XCTAssertEqual(tapped, 0)
        XCTAssertTrue(logs.contains("open Settings via Spotlight: it came up after all"), "\(logs)")
    }

    /// Pinyin keyboard on (2026-11-20): the typed letters are still composing, only the field reads the name and a
    /// tap there does nothing. Return commits them, Spotlight stays (a new frame, its words still there), and the
    /// result row read then is tapped.
    func testComposingLettersAreCommittedThenTheResultTapped() async throws {
        let composing = Data([4]), committed = Data([5])
        var queue: [Data?] = [home, composing, composing, committed, committed, committed, committed, app]  // + the looks before each tap
        var sent: [String] = [], tapped: [CGPoint] = []
        var opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, composing, app] in
                                   $0 == home ? [] : $0 == app ? ["Level 1", "Play"]
                                       : $0 == composing ? ["Pocket Chess", "pocket chess", "Apps"]
                                       : ["Pocket Chess", "Pocket Chess", "Apps"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.readBoxes = { [composing] frame in
            let field: (text: String, box: [Int]) = ("Pocket Chess", [100, 200, 500, 240])
            return (frame == composing ? [field] : [field, ("Pocket Chess", [100, 600, 500, 640])], CGSize(width: 1000, height: 2000))
        }
        opener.tapAt = { sent.append("tap"); tapped.append($0) }
        var logs: [String] = []
        opener.log = { logs.append($0) }
        let result = try await opener.open("Pocket Chess")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent, ["home", "key cmd+space", "key cmd+a", "key backspace", "type Pocket Chess", "tap", "key enter", "tap", "tap"])
        XCTAssertEqual(Double(tapped.last!.y), 0.31, accuracy: 0.001)
        XCTAssertTrue(logs.contains("open Pocket Chess via Spotlight: still on Spotlight → enter"), "\(logs)")
    }

    /// The device run of 2026-11-20: Return changed the frame but Spotlight still listed the app. Not "opened".
    func testStillOnSpotlightAfterReturnIsNotReportedOpened() async throws {
        let committed = Data([5])
        var queue: [Data?] = [home, spotlight, committed, home, spotlight, committed]
        var opener = AppOpener(home: {}, key: { _ in }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["Pocket Chess", "Pocket Chess", "Apps"] },
                               same: { $0 == $1 }, pause: { _ in })
        var logs: [String] = []
        opener.log = { logs.append($0) }
        let result = try await opener.open("Pocket Chess")
        XCTAssertEqual(result, .notOpened)
        XCTAssertEqual(logs.filter { $0 == "open Pocket Chess via Spotlight: not listed → enter" }.count, AppOpener.tries)
        XCTAssertEqual(logs.last, "open Pocket Chess via Spotlight: still on Spotlight")
        XCTAssertTrue(AgentLoop.effect(["changed": .bool(true), "app": .str("Pocket Chess"), "opened": .str(result.rawValue)])
            .contains("tap its icon there"))
    }

    /// An app that shows its own name twice is the app, not Spotlight: nothing of Spotlight's is left on it.
    func testAnAppShowingItsNameTwiceIsOpened() async throws {
        var queue: [Data?] = [home, spotlight, app]
        let opener = AppOpener(home: {}, key: { _ in }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, app] in $0 == home ? [] : $0 == app ? ["Notes", "iCloud Notes", "Folders"] : ["Notes", "Notes", "Apps"] },
                               same: { $0 == $1 }, pause: { _ in })
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
    }

    func testResultSpotsAreTheAppsNameOnly() {
        let size = CGSize(width: 1000, height: 2000)
        let spots = AppOpener.resultSpots([("微信", [0, 20, 100, 60]),  // status bar height: no
                                           ("WeChat Pay", [0, 300, 200, 340]), ("Wec…", [0, 500, 100, 540]), ("微信", [0, 800, 100, 840])],
                                          labels: ["WeChat", "微信"], size: size)
        XCTAssertEqual(spots.map { Double($0.y) }, [0.26, 0.41])
        XCTAssertTrue(AppOpener.resultSpots([("WeChat", [0, 0, 1, 1])], labels: ["WeChat"], size: .zero).isEmpty)
    }

    func testAWebSuggestionIsNotTheApp() {
        // 2026-11-25: 汽水音乐 not installed; Spotlight listed it only under Suggestions (a Chrome search)
        let size = CGSize(width: 1000, height: 2000)
        let lines: [(text: String, box: [Int])] = [
            ("Suggestions", [40, 150, 300, 190]), ("汽水音乐", [140, 250, 400, 290]),
            ("Manina AI", [40, 400, 300, 440]), ("测1 汽水音乐", [140, 520, 500, 560]),
            ("Search in Apps", [40, 700, 400, 740]), ("Search App Store", [140, 800, 600, 840]),
        ]
        XCTAssertTrue(AppOpener.resultSpots(lines, labels: ["汽水音乐"], size: size).isEmpty)
        XCTAssertTrue(AppOpener.onlyOnTheWeb(lines, labels: ["汽水音乐"], size: size))
        let installed: [(text: String, box: [Int])] = [("Top Hit", [40, 150, 300, 190]), ("汽水音乐", [140, 250, 400, 290]),
                                                       ("Suggestions", [40, 350, 300, 390]), ("汽水音乐", [140, 450, 400, 490])]
        XCTAssertEqual(AppOpener.resultSpots(installed, labels: ["汽水音乐"], size: size).map { Double($0.y) }, [0.135])
        XCTAssertFalse(AppOpener.onlyOnTheWeb(installed, labels: ["汽水音乐"], size: size))
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
        XCTAssertTrue(line.contains("Spotlight lists no app named Notes"), line)
    }

    func testTheModelSeesWhatTypingCouldNotType() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        phone.typeNote = "\"龘\" is not among the candidates for da (cleared)"
        let actor = FakeModel { _ in "THINK: type it\nDO: type 龘" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.step()
        let line = AgentLoop.effect(try XCTUnwrap(agent.steps.last))
        XCTAssertTrue(line.contains("typing stopped: If the screen already lists"), line)  // a listed target first
        XCTAssertTrue(line.contains("tap it instead of typing more. \"龘\" is not among"), line)
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

    /// cmd+space brought nothing up (2026-11-13): the next try taps the Home Screen's Search button instead.
    func testSearchButtonWhenCmdSpaceBringsNothingUp() async throws {
        var sent: [String] = []
        var queue: [Data?] = [home, home, home, spotlight, app]
        var opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["Notes", "Notes"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.searchButton = { sent.append("search button"); return true }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "key cmd+space" }.count, 1)
        XCTAssertEqual(sent.filter { $0 == "search button" }.count, 1)
        sent = []
        queue = [home, spotlight, app]
        let again = try await opener.open("Notes")
        XCTAssertEqual(again, .opened)
        XCTAssertEqual(sent.filter { $0 == "key cmd+space" }.count, 1, "the next open tries cmd+space first again")
        XCTAssertEqual(sent.filter { $0 == "search button" }.count, 0)
    }

    /// cmd+space brought nothing up (the app in front still): no cmd+a, backspace or name goes into that app; the
    /// Search button next. A picture one frame behind is not taken for "nothing": only two looks that both match.
    func testNothingTypedIntoTheAppInFrontWhenSpotlightDidNotComeUp() async throws {
        var sent: [String] = []
        var queue: [Data?] = [home, home, spotlight, app]
        var glances: [Data?] = [home, home, home]  // three looks, all the Home Screen
        var opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["Notes", "Notes"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.glance = { glances.isEmpty ? self.spotlight : glances.removeFirst() }
        opener.searchButton = { sent.append("search button"); return true }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        let beforeButton = sent.prefix { $0 != "search button" }
        XCTAssertFalse(beforeButton.contains("key cmd+a"), "nothing cleared in the app in front")
        XCTAssertFalse(beforeButton.contains { $0.hasPrefix("type") }, "nothing typed into it")
        XCTAssertEqual(sent.filter { $0 == "search button" }.count, 1)

        sent = []
        queue = [home, spotlight, app]
        glances = [home, spotlight]  // one stale frame, then Spotlight: typed at once
        _ = try await opener.open("Notes")
        XCTAssertEqual(sent.filter { $0 == "search button" }.count, 0)
        XCTAssertTrue(sent.contains("type Notes"))
    }

    /// The picture runs behind: Spotlight shows on the third look. Typed then, with no second cmd+space (a toggle:
    /// it closed the Spotlight that had come up, 2026-11-27).
    func testALaggingPictureGetsNoSecondCmdSpace() async throws {
        var sent: [String] = []
        var queue: [Data?] = [home, spotlight, app]
        var glances: [Data?] = [home, home]
        var opener = AppOpener(home: { sent.append("home") }, key: { sent.append("key \($0)") }, type: { sent.append("type \($0)") },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home] in $0 == home ? [] : ["Notes", "Notes"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.glance = { glances.isEmpty ? self.spotlight : glances.removeFirst() }
        opener.searchButton = { sent.append("search button"); return true }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "key cmd+space" }.count, 1, "\(sent)")
        XCTAssertEqual(sent.filter { $0 == "search button" }.count, 0)
    }

    /// Past the budget no new try starts: the model gets not_opened and decides.
    func testAnOpenStopsTryingAfterItsBudget() async throws {
        var t = 0.0
        var queue: [Data?] = [home, home, home, home, home, home]
        var opener = AppOpener(home: { t += 16 }, key: { _ in }, type: { _ in },
                               look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { _ in [] }, same: { $0 == $1 }, pause: { _ in })
        opener.clock = { t }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .notOpened)
        XCTAssertEqual(t, 16, "one try only: the second would start past 15 s")
    }

    /// A row tap that changed nothing past the budget (it missed): one Return still goes before not_opened
    /// (2026-11-27 case 22: Safari listed, the tap at the screen's edge did nothing, the open gave up).
    func testAMissedRowTapPastTheBudgetStillGetsReturn() async throws {
        var t = 0.0
        var queue: [Data?] = [home, spotlight, spotlight, app]
        var sent: [String] = []
        var opener = AppOpener(home: {}, key: { sent.append($0) }, type: { _ in }, look: { queue.isEmpty ? nil : queue.removeFirst() },
                               read: { [home, app] in $0 == home ? [] : $0 == app ? ["Shopping list"] : ["Notes", "Notes"] },
                               same: { $0 == $1 }, pause: { _ in })
        opener.clock = { t }
        opener.readBoxes = { _ in ([("Notes", [100, 600, 300, 640])], CGSize(width: 1000, height: 2000)) }
        opener.tapAt = { _ in t += 20 }
        let result = try await opener.open("Notes")
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(sent.filter { $0 == "enter" }.count, 1, "\(sent)")
    }

    /// A tap on the AssistiveTouch button's spot opened its menu (2026-11-27: Calendar's 28th, a route panel's X):
    /// the button at the right edge's middle is in the way of a tap within its disc, and goes to the other half.
    func testATapUnderTheAssistiveTouchButtonMovesItAside() {
        let button = CGPoint(x: 0.92, y: 0.50), aspect = 390.0 / 844.0
        XCTAssertTrue(AssistiveButton.covers(button, tap: CGPoint(x: 0.90, y: 0.51), aspect: aspect))
        XCTAssertTrue(AssistiveButton.covers(button, tap: CGPoint(x: 0.95, y: 0.48), aspect: aspect))
        XCTAssertFalse(AssistiveButton.covers(button, tap: CGPoint(x: 0.70, y: 0.50), aspect: aspect), "left of it")
        XCTAssertFalse(AssistiveButton.covers(button, tap: CGPoint(x: 0.92, y: 0.58), aspect: aspect), "the row below")
        XCTAssertEqual(AssistiveButton.aside(button, from: CGPoint(x: 0.9, y: 0.51)), CGPoint(x: 0.92, y: 0.22))
        XCTAssertEqual(AssistiveButton.aside(button, from: CGPoint(x: 0.9, y: 0.49)), CGPoint(x: 0.92, y: 0.78))
        // the menu as read in a trace frame (20261127-163027/039): Notification / Center / Custom / Siri / Device / Home …
        XCTAssertTrue(AssistiveButton.menuShown(["November", "Notification", "Center", "Custom", "Siri", "Device", "Home",
                                                 "Control", "Center", "Today"]))
        XCTAssertFalse(AssistiveButton.menuShown(["Settings", "Home", "Device", "General"]), "a settings page")
    }

    func testTheHomeKeyFlicksWhenItMissedUnderAnAnimatedApp() {
        XCTAssertTrue(Pointer.needsFlick(changed: false, again: false, stayed: false), "nothing changed")
        XCTAssertTrue(Pointer.needsFlick(changed: true, again: true, stayed: false), "home again, little change")
        XCTAssertTrue(Pointer.needsFlick(changed: true, again: false, stayed: true), "a sheet that moves by itself, its words still there")
        XCTAssertFalse(Pointer.needsFlick(changed: true, again: false, stayed: false), "a small change that left the app's words")
    }

    func testTheSearchPillIsFoundLowOnTheScreenAndCoversItsIcon() {
        let size = CGSize(width: 1000, height: 2000)
        let pill = SearchPill.label([("Calendar", [100, 300, 260, 340]), ("Q Search", [440, 1640, 560, 1680])], size: size)
        XCTAssertEqual(pill?.minX ?? 0, 0.44, accuracy: 0.001)
        XCTAssertTrue(SearchPill.covers(pill!, CGPoint(x: 0.5, y: 0.83)))
        XCTAssertTrue(SearchPill.covers(pill!, CGPoint(x: 0.38, y: 0.83)), "the magnifier left of the label")
        XCTAssertFalse(SearchPill.covers(pill!, CGPoint(x: 0.5, y: 0.9)), "the dock")
        XCTAssertNotNil(SearchPill.label([("搜索", [460, 1640, 540, 1680])], size: size))
        XCTAssertNil(SearchPill.label([("Search", [440, 120, 560, 160])], size: size), "an app's own search field at the top")
        // Settings on iOS 27: left-aligned search fields low on the screen (measured at 73% and 93%, x 0.18)
        XCTAssertNil(SearchPill.label([("Search", [180, 1452, 320, 1492]), ("Search", [175, 1862, 313, 1902])], size: size))
    }
}

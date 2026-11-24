import XCTest
@testable import IPhoneAgent

/// First launch asks once whether the user has a board; the answer is kept and sent only with stats on.
@MainActor final class BoardQuestionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "BoardQuestionTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAskedOnceOnFirstLaunch() {
        XCTAssertTrue(BoardQuestion.shouldAsk(onboarded: false, defaults: defaults))
        BoardQuestion.record(.yes, defaults: defaults, statsOn: false)
        XCTAssertFalse(BoardQuestion.shouldAsk(onboarded: false, defaults: defaults), "answered: not again")
    }

    func testUsersWhoFinishedSetupAreNeverAsked() {
        XCTAssertFalse(BoardQuestion.shouldAsk(onboarded: true, defaults: defaults))
        BoardQuestion.skipIfOnboarded(false, defaults: defaults)
        XCTAssertTrue(BoardQuestion.shouldAsk(onboarded: false, defaults: defaults), "a new user is still asked")
        BoardQuestion.skipIfOnboarded(true, defaults: defaults)
        XCTAssertFalse(BoardQuestion.shouldAsk(onboarded: false, defaults: defaults), "Run setup again doesn't ask")
    }

    func testAnswerIsStored() {
        BoardQuestion.record(.yes, defaults: defaults, statsOn: false)
        XCTAssertEqual(defaults.string(forKey: BoardQuestion.key), "yes")
        BoardQuestion.record(.no, defaults: defaults, statsOn: false)
        XCTAssertEqual(defaults.string(forKey: BoardQuestion.key), "no")
        BoardQuestion.skipIfOnboarded(true, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: BoardQuestion.key), "no", "an answer is never overwritten")
    }

    func testEventOnlyWithStatsOn() {
        var sent: [(String, [String: Any])] = []
        BoardQuestion.record(.no, defaults: defaults, statsOn: false) { sent.append(($0, $1)) }
        XCTAssertTrue(sent.isEmpty, "stats off: nothing is sent")
        BoardQuestion.record(.no, defaults: defaults, statsOn: true) { sent.append(($0, $1)) }
        BoardQuestion.record(.yes, defaults: defaults, statsOn: true) { sent.append(($0, $1)) }
        XCTAssertEqual(sent.map(\.0), ["has_board_answer", "has_board_answer"])
        XCTAssertEqual(sent.map { $0.1 as? [String: String] }, [["answer": "no"], ["answer": "yes"]], "only the answer")
    }

    func testLinkFollowsTheAppLanguage() {
        XCTAssertEqual(BoardQuestion.url(language: "zh-Hans").absoluteString,
                       "https://manina.ai/zh/where-to-buy-esp32?from=app")
        XCTAssertEqual(BoardQuestion.url(language: "en").absoluteString, "https://manina.ai/where-to-buy-esp32?from=app")
        XCTAssertEqual(BoardQuestion.url(language: nil).absoluteString, "https://manina.ai/where-to-buy-esp32?from=app")
    }
}

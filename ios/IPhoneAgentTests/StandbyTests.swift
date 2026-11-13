import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: the island waits between runs with intents and New Task.
@MainActor final class StandbyTests: XCTestCase {
    func testTheStandbyStateCarriesThePicksAndNeverGoesStale() {
        let pick = StandbyPick(id: UUID(), name: "Daily alarm", symbol: "alarm")
        let state = LiveActivityController.standbyState([pick])
        XCTAssertEqual(state.phase, .standby)
        XCTAssertEqual(state.picks, [pick])
        XCTAssertFalse(state.finished)
        XCTAssertFalse(state.canGoStale)
        XCTAssertEqual(SavedIntentEntity(pick).id, pick.id)
    }

    func testAStateFromAnOlderBuildStillDecodes() throws {
        let old = LiveActivityController.State(mood: .thinking, step: 3, limit: 300, line: "x")
        var data = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "picks")
        data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(LiveActivityController.State.self, from: data)
        XCTAssertNil(back.picks)
        XCTAssertEqual(back.step, 3)
    }

    func testTheQuickSheetHasItsOwnLink() {
        XCTAssertEqual(AgentActivityAttributes.quickURL.host, "quick")
    }
}

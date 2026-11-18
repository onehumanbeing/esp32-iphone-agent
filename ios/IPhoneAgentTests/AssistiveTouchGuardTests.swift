import XCTest
@testable import IPhoneAgent

final class AssistiveTouchGuardTests: XCTestCase {
    let size = CGSize(width: 1000, height: 2000)

    func testTheMenuIsSeenByTwoOfItsItemsMidScreen() {
        let menu: [(text: String, box: [Int])] = [("通知中心", [300, 800, 450, 840]), ("主屏幕", [500, 1100, 620, 1140]),
                                                  ("设备", [700, 1100, 780, 1140])]
        XCTAssertTrue(AssistiveTouchGuard.menuShown(menu, size: size))
        XCTAssertTrue(AssistiveTouchGuard.menuShown([("Home", [500, 1000, 600, 1040]), ("Control Center", [200, 1000, 400, 1040])], size: size))
        // one word alone, or the words at the top or bottom edge (a tab bar's 首页 / a settings row), is not the menu
        XCTAssertFalse(AssistiveTouchGuard.menuShown([("设备", [500, 1000, 600, 1040])], size: size))
        XCTAssertFalse(AssistiveTouchGuard.menuShown([("Home", [100, 1900, 200, 1950]), ("Device", [400, 1900, 500, 1950])], size: size))
    }

    func testOnlyEdgeTapsAreChecked() {
        XCTAssertTrue(AssistiveTouchGuard.nearEdge(910, 487))
        XCTAssertTrue(AssistiveTouchGuard.nearEdge(60, 80))
        XCTAssertFalse(AssistiveTouchGuard.nearEdge(500, 500))
    }

    func testATapOnAHitSpotIsHeldWithAWayAround() {
        let hits = [CGPoint(x: 910, y: 487)]
        let held = AssistiveTouchGuard.held(890, 470, hits: hits)
        XCTAssertTrue(held?.hasPrefix("not tapped: 890, 470 is on the AssistiveTouch button") == true, held ?? "")
        XCTAssertTrue(held?.contains("swipe the content") == true)
        XCTAssertNil(AssistiveTouchGuard.held(700, 470, hits: hits))
        XCTAssertNil(AssistiveTouchGuard.held(910, 487, hits: []))  // spots of earlier runs are not guarded
    }
}

import XCTest
@testable import IPhoneAgent

final class RateLimitTests: XCTestCase {
    func testANewLimitLineIsFound() {
        XCTAssertEqual(RateLimit.shown(["全部订单", "操作频繁，请稍后再试"], before: ["全部订单"]), "操作频繁，请稍后再试")
        XCTAssertEqual(RateLimit.shown(["Too Many Requests"], before: []), "Too Many Requests")
    }

    func testWordsThatWereThereBeforeDoNotStop() {
        XCTAssertNil(RateLimit.shown(["每日删除次数上限 50 条"], before: ["每日删除次数上限 50 条"]))
        XCTAssertNil(RateLimit.shown(["网络不给力，请稍后再试"], before: []))
    }
}

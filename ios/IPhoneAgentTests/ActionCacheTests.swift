import XCTest
@testable import IPhoneAgent

/// Henry 2026-11-13: the taps that follow the same tap each time are done by code from the third time on.
final class ActionCacheTests: XCTestCase {
    private func feed(_ cache: inout ActionCache, _ labels: [String]) {
        for l in labels { l == "|" ? cache.gap() : cache.add(l, at: (500, 500)) }
    }

    func testTheThirdTimeTheTailIsKnown() {
        var cache = ActionCache()
        feed(&cache, ["文章 1", "…", "删除", "确定", "|", "文章 2", "…", "删除", "确定", "|", "文章 3", "…"])
        XCTAssertEqual(cache.tail(after: "…")?.map(\.label), ["删除", "确定"])
    }

    func testTwiceIsNotEnoughAndOnlyTheCommonPartRuns() {
        var cache = ActionCache()
        feed(&cache, ["…", "删除", "确定", "|", "…"])
        XCTAssertNil(cache.tail(after: "…"))
        var mixed = ActionCache()
        feed(&mixed, ["…", "删除", "确定", "|", "…", "删除", "取消", "|", "…"])
        XCTAssertEqual(mixed.tail(after: "…")?.map(\.label), ["删除"])
    }

    func testNoTailWhenTheAnchorIsNotTheLastMove() {
        var cache = ActionCache()
        feed(&cache, ["…", "删除", "|", "…", "删除", "|", "…", "删除"])
        XCTAssertNil(cache.tail(after: "…"))
    }

    func testPricesOnScreenStopTheCache() {
        XCTAssertTrue(ActionCache.paying([DemoAnalysis.Line(text: "¥ 12.00", x: 1, y: 1)]))
        XCTAssertTrue(ActionCache.paying([DemoAnalysis.Line(text: "立即支付", x: 1, y: 1)]))
        XCTAssertFalse(ActionCache.paying([DemoAnalysis.Line(text: "删除", x: 1, y: 1)]))
    }
}

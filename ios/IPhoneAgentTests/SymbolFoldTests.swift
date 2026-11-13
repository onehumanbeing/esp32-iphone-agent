import XCTest
@testable import IPhoneAgent

/// OCR reads a typed "?" as "？": that is not a wrong symbol (2026-11-13, a call's sentence not said).
@MainActor final class SymbolFoldTests: XCTestCase {
    func testFullWidthQuestionMarkCountsAsTyped() {
        let before = HanTyper.Seen(words: [("Type to Speak...", [0, 0, 10, 10])], height: 100)
        let now = HanTyper.Seen(words: [("Can you confirm that？", [0, 0, 10, 10])], height: 100)
        XCTAssertFalse(HanTyper.symbolsWrong("Can you confirm that?", ["?"], now: now, row: [], before: before, beforeRow: []))
        let wrong = HanTyper.Seen(words: [("Can you confirm that/", [0, 0, 10, 10])], height: 100)
        XCTAssertTrue(HanTyper.symbolsWrong("Can you confirm that?", ["?"], now: wrong, row: [], before: before, beforeRow: []))
    }
}

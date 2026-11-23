import XCTest
@testable import IPhoneAgent

/// OCR reads a typed "?" as "？": that is not a wrong symbol (2026-11-13, a call's sentence not said).
@MainActor final class SymbolFoldTests: XCTestCase {
    func testFullWidthQuestionMarkCountsAsTyped() {
        let before = HanTyper.Seen(words: [("Type to Speak...", [0, 0, 10, 10])], height: 100)
        let now = HanTyper.Seen(words: [("Can you confirm that？", [0, 0, 10, 10])], height: 100)
        XCTAssertFalse(HanTyper.symbolsWrong("Can you confirm that?", ["?"], now: now, row: [], before: before, beforeRow: []))
        let wrong = HanTyper.Seen(words: [("Can you confirm that/ Yes", [0, 0, 10, 10])], height: 100)
        XCTAssertTrue(HanTyper.symbolsWrong("Can you confirm that? Yes", ["?"], now: wrong, row: [], before: before, beforeRow: []))
    }

    /// 2026-11-23, iPhone X: "OK?" next to the cursor read as "OK"; the message was right and was held from sending.
    func testATrailingSymbolOCRDroppedIsNotWrong() {
        let before = HanTyper.Seen(words: [], height: 100)
        let now = HanTyper.Seen(words: [("See you at 3pm tomorrow,", [0, 0, 10, 10]), ("OK", [0, 12, 10, 20])], height: 100)
        XCTAssertFalse(HanTyper.symbolsWrong("See you at 3pm tomorrow, OK?", ["?"], now: now, row: [], before: before, beforeRow: []))
    }
}

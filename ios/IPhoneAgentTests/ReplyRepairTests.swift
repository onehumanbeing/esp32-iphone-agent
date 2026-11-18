import XCTest
@testable import IPhoneAgent

/// Replies in other shapes, as a model sent them on 2026-11-17 (screen text replaced).
final class ReplyRepairTests: XCTestCase {
    private func acts(_ reply: String) throws -> [JObject] { try Actions.parseActions(reply) }

    func testJSONAction() throws {
        let a = try acts(#"{"action": "tap", "x": 692, "y": 503}"#)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0]["action"], .str("tap"))
        XCTAssertEqual(a[0]["x"], .int(692))
        XCTAssertEqual(a[0]["y"], .int(503))
        XCTAssertEqual(a[0]["repaired"], .bool(true))
    }

    func testProseThenJSONKeepsTheProseAsTheThought() throws {
        let a = try acts("The screen shows a shop page, not the list. I go back.\n\n{\"action\": \"back\"}")
        XCTAssertEqual(a[0]["action"], .str("back"))
        XCTAssertEqual(a[0]["thought"], .str("The screen shows a shop page, not the list. I go back."))
    }

    func testMultilineJSONNote() throws {
        let a = try acts("{\n    \"action\": \"note\",\n    \"text\": \"Order: 11-17, ¥12.50, Shop A\"\n}")
        XCTAssertEqual(a[0]["action"], .str("note"))
        XCTAssertEqual(a[0]["text"], .str("Order: 11-17, ¥12.50, Shop A"))
    }

    func testSeveralJSONActionsInOrder() throws {
        let a = try acts("{\"action\": \"note\", \"text\": \"one\"}\n\n{\"action\": \"note\", \"text\": \"two\"}")
        XCTAssertEqual(a.map { $0["text"] }, [.str("one"), .str("two")])
    }

    func testJSONInACodeFence() throws {
        let a = try acts("swipe again\n\n```\n{\"action\": \"swipe\", \"x1\": 500, \"y1\": 700, \"x2\": 500, \"y2\": 400}\n```")
        XCTAssertEqual(a[0]["action"], .str("swipe"))
        XCTAssertEqual(a[0]["y2"], .int(400))
    }

    func testToolCallWithParameters() throws {
        let reply = "Tap the total price.\n\n<tool_call>\n<function=computer_use>\n<parameter=action>\ntap\n</parameter>\n"
            + "<parameter=x>\n500\n</parameter>\n<parameter=y>\n892\n</parameter>\n</function>\n</tool_call>"
        let a = try acts(reply)
        XCTAssertEqual(a[0]["action"], .str("tap"))
        XCTAssertEqual(a[0]["x"], .int(500))
        XCTAssertEqual(a[0]["y"], .int(892))
        XCTAssertEqual(a[0]["thought"], .str("Tap the total price."))
    }

    func testToolCallLeftClickWithCoordinate() throws {
        let reply = "<tool_call>\n<function=computer>\n<parameter=action>\nleft_click\n</parameter>\n"
            + "<parameter=coordinate>\n[854, 267]\n</parameter>\n</function>\n</tool_call>"
        let a = try acts(reply)
        XCTAssertEqual(a[0]["action"], .str("tap"))
        XCTAssertEqual(a[0]["x"], .int(854))
        XCTAssertEqual(a[0]["y"], .int(267))
    }

    func testUnclosedToolCallStillReads() throws {
        let reply = "<tool_call>\n<function=computer>\n<parameter=action>\nswipe\n</parameter>\n<parameter=x1>\n500\n</parameter>\n"
            + "<parameter=y1>\n700\n</parameter>\n<parameter=x2>\n500\n</parameter>\n<parameter=y2>\n400\n</parameter>\n</function>"
        XCTAssertEqual(try acts(reply)[0]["action"], .str("swipe"))
    }

    func testXMLTags() throws {
        let a = try acts("<action>swipe</action>\n<x1>500</x1>\n<y1>700</y1>\n<x2>500</x2>\n<y2>400</y2>")
        XCTAssertEqual(a[0]["action"], .str("swipe"))
        XCTAssertEqual(a[0]["x1"], .int(500))
        XCTAssertEqual(a[0]["y2"], .int(400))
    }

    func testSameActionAsJSONAndToolCallCountsOnce() throws {
        let reply = "{\"action\": \"note\", \"text\": \"Order A\"}\n\n<tool_call>\n<function=action>\n<parameter=action>\nnote\n"
            + "</parameter>\n<parameter=text>\nOrder A\n</parameter>\n</function>\n</tool_call>"
        XCTAssertEqual(try acts(reply).count, 1)
    }

    func testScrollDownIsAFingerUpSwipe() throws {
        let a = try acts(#"{"action": "scroll", "direction": "down"}"#)
        XCTAssertEqual(a[0]["action"], .str("swipe"))
        XCTAssertGreaterThan(a[0]["y1"]?.double ?? 0, a[0]["y2"]?.double ?? 0)
    }

    func testOpenWithEscapedName() throws {
        let a = try acts(#"{"action": "open", "app": "美团外卖"}"#)
        XCTAssertEqual(a[0]["app"], .str("美团外卖"))
    }

    func testADescriptionStaysUnparseable() {
        XCTAssertThrowsError(try acts("This is a screenshot of an order page.\n\n1. **Top**: a back arrow\n2. **Total**: ¥99.00"))
        XCTAssertThrowsError(try acts("I don't know what you mean."))
        XCTAssertThrowsError(try acts("1. Scroll down\n\n<tool_call>\n<function=computer>\n</function>\n</tool_call>"))
    }

    func testAProperReplyIsUntouched() throws {
        let a = try acts("THINK: open it\nDO: tap 10 20")
        XCTAssertNil(a[0]["repaired"])
    }
}

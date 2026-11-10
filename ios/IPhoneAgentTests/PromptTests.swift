import XCTest
@testable import IPhoneAgent

/// The prompts come from the bundled prompts/ folder.
final class PromptTests: XCTestCase {
    func testPromptsLoadFromTheBundle() {
        XCTAssertTrue(Prompts.actorServer.contains("DO: <action>"))
        XCTAssertFalse(Prompts.appRules.isEmpty)
        XCTAssertFalse(Prompts.actorServer.hasSuffix("\n"))  // the file's final newline is not part of the prompt
        XCTAssertEqual(Prompts.actor, Prompts.actorServer + "\n" + Prompts.appRules)
    }

    func testActionsTheParserKnowsAreDocumented() {
        for verb in ["tap X Y", "swipe X1", "path X1", "circle X Y R", "type TEXT", "key COMBO", "home | back | wait",
                     "PLAN:", "done ANSWER", "fail REASON"] {
            XCTAssertTrue(Prompts.actor.contains(verb), verb)
        }
    }
}

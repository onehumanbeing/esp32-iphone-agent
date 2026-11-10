import UIKit
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
                     "PLAN:", "done ANSWER", "fail REASON", "open APP", "confirm REASON", "read WHAT"] {
            XCTAssertTrue(Prompts.actor(for: .phone).contains(verb), verb)
        }
        for verb in ["tap X Y", "swipe X1", "path X1", "circle X Y R", "type TEXT", "key COMBO", "\n  home ", "\n  back ",
                     "\n  wait\n", "PLAN:", "done ANSWER", "fail REASON", "open APP", "confirm REASON", "read WHAT"] {
            XCTAssertTrue(Prompts.actor(for: .pad).contains(verb), "iPad: " + verb)
        }
    }

    /// An iPhone gets the files in prompts/ as they are; an iPad its own set in prompts/ipad/, which never calls it
    /// an iPhone except to say it isn't one, and keeps the same action syntax.
    func testIPadHasItsOwnPromptSet() {
        let phone = Prompts.actor(for: .phone), pad = Prompts.actor(for: .pad)
        XCTAssertEqual(phone, Prompts.load("actor") + "\n" + Prompts.load("app-rules") + Prompts.language)
        XCTAssertTrue(phone.hasPrefix("You operate an iPhone through a mouse pointer,"))
        XCTAssertTrue(pad.hasPrefix("You operate an iPad through a mouse pointer,"))
        XCTAssertFalse(phone.contains("iPad"))
        let mentions = pad.components(separatedBy: "iPhone").count - 1
        XCTAssertEqual(mentions, 2, "only \"not an iPhone\" and \"where it would be on an iPhone\"")
        XCTAssertTrue(pad.contains("Split View"))
        XCTAssertFalse(pad.contains("Dynamic Island"))
        XCTAssertTrue(Prompts.load("reader", for: .pad).hasPrefix("You copy text from an iPad screenshot."))
        XCTAssertEqual(Prompts.actor, Prompts.actor(for: DeviceKind.isPad ? .pad : .phone))
        // the lines both sets share word for word: the syntax the parser reads
        for line in Prompts.load("actor").split(separator: "\n") where line.hasPrefix("  tap ") || line.hasPrefix("  swipe ")
            || line.hasPrefix("  path ") || line.hasPrefix("  circle ") || line.hasPrefix("  type ") || line.hasPrefix("  key ")
            || line.hasPrefix("  open ") || line.hasPrefix("  done ") || line.hasPrefix("  fail ") {
            XCTAssertTrue(pad.contains(line), "iPad actor.md lost: " + line)
        }
    }

    /// iPhone wording stays as it is; an iPad shows its own variant of the same string (Localizable.xcstrings).
    func testIPhoneWordingHasAnIPadVariant() {
        let text = String(localized: "What should I do on this iPhone?")
        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        guard english else { return }
        XCTAssertEqual(text, UIDevice.current.userInterfaceIdiom == .pad ? "What should I do on this iPad?"
                                                                          : "What should I do on this iPhone?")
    }
}

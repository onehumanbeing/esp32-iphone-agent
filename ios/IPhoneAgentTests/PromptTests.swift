import UIKit
import XCTest
@testable import IPhoneAgent

/// The prompts come from the bundled prompts/ folder.
final class PromptTests: XCTestCase {
    func testPromptsLoadFromTheBundle() {
        XCTAssertTrue(Prompts.actorServer.contains("DO: <action>"))
        XCTAssertFalse(Prompts.appRules.isEmpty)
        XCTAssertFalse(Prompts.actorServer.hasSuffix("\n"))  // the file's final newline is not part of the prompt
        // made once, for the device the app runs on (tests may pin DeviceKind before it is first read)
        XCTAssertTrue([Prompts.actor(for: .phone), Prompts.actor(for: .pad)].contains(Prompts.actor))
    }

    func testActionsTheParserKnowsAreDocumented() {
        for device in [Prompts.Device.phone, .pad] {
            for verb in ["tap X Y", "swipe X1", "path X1", "circle X Y R", "type TEXT", "key COMBO", "home | back | wait",
                         "PLAN:", "done ANSWER", "fail REASON", "open APP", "confirm KIND REASON", "read WHAT"] {
                XCTAssertTrue(Prompts.actor(for: device).contains(verb), "\(device): \(verb)")
            }
        }
    }

    /// "Short reasons" swaps actor.md's THINK line: the copy in BriefThink must stay the same as the file's.
    func testBriefThinkReplacesTheActorThinkLine() {
        XCTAssertTrue(Prompts.actor.contains(BriefThink.full))
        let brief = BriefThink.apply(Prompts.actor, on: true)
        XCTAssertFalse(brief.contains(BriefThink.full))
        XCTAssertTrue(brief.contains(BriefThink.brief))
        XCTAssertEqual(BriefThink.apply(Prompts.actor, on: false), Prompts.actor)
    }

    /// An iPhone gets the files exactly as before the iPad came: only the marker lines around its own passages are
    /// taken out.
    func testIPhonePromptIsTheFilesAsTheyAre() {
        let phone = Prompts.actor(for: .phone)
        let files = (Prompts.load("actor") + "\n" + Prompts.load("app-rules")).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 != Prompts.phoneOnly && $0 != Prompts.phoneOnlyEnd }.joined(separator: "\n")
        XCTAssertEqual(phone, files + Prompts.language)
        XCTAssertTrue(phone.hasPrefix("You operate an iPhone through a mouse pointer,"))
        XCTAssertTrue(phone.contains("Never tap the Dynamic Island"))
        XCTAssertFalse(phone.contains("iPad"))
        XCTAssertFalse(phone.contains("<!--"))
        XCTAssertEqual(Prompts.reader(for: .phone), Prompts.load("reader"))
    }

    /// An iPad gets the same text with "iPhone" read as "iPad", without the iPhone-only passages, and its own rules
    /// after the shared ones: nothing to keep in step by hand, and the action syntax is the iPhone's word for word.
    func testIPadSharesTheTextAndAddsItsRulesLast() {
        let phone = Prompts.actor(for: .phone), pad = Prompts.actor(for: .pad)
        XCTAssertTrue(pad.hasPrefix("You operate an iPad through a mouse pointer,"))
        XCTAssertFalse(pad.contains("Dynamic Island\n") || pad.contains("Never tap the Dynamic Island"))
        XCTAssertFalse(pad.contains("<!--"))
        let ownRules = Prompts.load("devices/ipad")
        XCTAssertTrue(pad.hasSuffix(ownRules + Prompts.language), "the iPad's own rules come last")
        let shared = pad.dropLast(Prompts.language.count).dropLast(ownRules.count + 1)
        XCTAssertFalse(shared.contains("iPhone"), "the shared part names the iPad")
        XCTAssertEqual(pad.components(separatedBy: "iPhone").count - 1, 2, "only \"not an iPhone\" and \"would be on an iPhone\"")
        // the shared part is the iPhone's, line for line, but for the device's name and the iPhone-only passage
        let phoneLines = phone.dropLast(Prompts.language.count).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Dynamic Island (the top center") && !$0.hasPrefix("the app. For a field right under it") }
            .map { $0.replacingOccurrences(of: "iPhone", with: "iPad") }
        XCTAssertEqual(shared.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), phoneLines)
        for line in phone.split(separator: "\n") where line.hasPrefix("  tap ") || line.hasPrefix("  swipe ")
            || line.hasPrefix("  path ") || line.hasPrefix("  circle ") || line.hasPrefix("  type ") || line.hasPrefix("  key ")
            || line.hasPrefix("  done ") || line.hasPrefix("  fail ") || line.hasPrefix("  home ") {
            XCTAssertTrue(pad.contains(line), "iPad lost: " + line)
        }
        XCTAssertTrue(pad.contains("Split View"))
        XCTAssertTrue(Prompts.reader(for: .pad).hasPrefix("You copy text from an iPad screenshot."))
        XCTAssertTrue(Prompts.reader(for: .pad).hasSuffix(Prompts.load("devices/ipad-reader")))
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

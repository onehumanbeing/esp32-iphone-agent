import XCTest
@testable import IPhoneAgent

@MainActor final class AppGuidesTests: XCTestCase {
    let meituan = AppGuide(id: "meituan-waimai", names: ["美团外卖", "Meituan Waimai"])

    func testMatchByAnyNameOrId() {
        for name in ["美团外卖", "meituan waimai", "\"Meituan Waimai\"", "meituan-waimai"] {
            XCTAssertEqual(AppGuides.match(name, in: [meituan])?.id, "meituan-waimai", name)
        }
        XCTAssertNil(AppGuides.match("美团", in: [meituan]))  // another app
    }

    func testPromptListsGuidesOnlyWhenThereAreAny() {
        XCTAssertEqual(AppGuides.prompt([]), "")
        let prompt = AppGuides.prompt([meituan])
        XCTAssertTrue(prompt.contains("`guide APP`"))
        XCTAssertTrue(prompt.contains("美团外卖 / Meituan Waimai"))
        XCTAssertTrue(prompt.contains("Never load one for an app the goal does not use"))
    }

    func testGuideActionParsesAndIsNotAGesture() throws {
        let act = try Actions.parseCommand("guide 美团外卖")
        XCTAssertEqual(act["action"]?.str, "guide")
        XCTAssertEqual(act["text"]?.str, "美团外卖")
        XCTAssertTrue(Actions.notebookActions.contains("guide"))
        XCTAssertFalse(Actions.gestures.contains("guide"))
    }

    func testLoadedGuideStaysInThePromptAndUnknownOnesAreRefused() async {
        let loop = AgentLoop(phone: nil, screen: nil, actor: nil, planner: nil, trace: nil)
        loop.guides = [meituan]
        let unknown = await loop.loadGuide("淘宝")
        XCTAssertTrue(unknown.hasPrefix("no guide for 淘宝; guides: 美团外卖"), unknown)
        loop.guided = [AppGuide(id: "meituan-waimai", names: ["美团外卖", "Meituan Waimai"], text: "- tap the price")]
        let again = await loop.loadGuide("美团外卖")
        XCTAssertTrue(again.hasPrefix("already loaded"), again)
        XCTAssertTrue(loop.actorUserPrompt().contains("Guide for 美团外卖 / Meituan Waimai:\n- tap the price"))
    }
}

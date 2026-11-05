import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IPhoneAgent

/// The on-device screen tree (UITree*): listing, `tap #ID`, and the free line's actor seeing both.
@MainActor final class UITreeTests: XCTestCase {
    private func tree() -> UITree {
        let a = UINode("button", [100, 200, 300, 260], label: "Sign in")
        let b = UINode("text", [20, 1000, 120, 1030], label: String(repeating: "长", count: 50))
        let row = UINode("row", [0, 990, 540, 1040], children: [b])
        for (i, n) in [a, row, b].enumerated() { n.id = i + 1 }
        return UITree(w: 540, h: 1170, nodes: [a, row])
    }

    func testListingNumbersElementsWithoutLayoutRows() {
        let listing = tree().listing
        XCTAssertTrue(listing.contains("#1 button \"Sign in\" at 370 196"), listing)
        XCTAssertTrue(listing.contains("#2 text \"" + String(repeating: "长", count: 40) + "\" at 129 867"), listing)
        XCTAssertFalse(listing.contains(" row "))
        XCTAssertTrue(listing.hasSuffix("To tap one of these you may write: tap #ID"))
    }

    func testResolveTapID() {
        let t = tree()
        XCTAssertEqual(t.resolve("THINK: sign in\nDO: tap #1"), "THINK: sign in\nDO: tap 370 196")
        XCTAssertEqual(t.resolve("DO： tap #2\nDO: tap #1"), "DO： tap 129 867\nDO: tap 370 196")
        XCTAssertEqual(t.resolve("DO: tap #9"), "DO: tap #9", "an unknown id is left for the parser to reject")
        XCTAssertEqual(t.resolve("DO: tap 10 20"), "DO: tap 10 20")
    }

    func testBuildFindsAFilledButton() async throws {
        let made = await UITree.build(jpeg: Self.screen())
        let built = try XCTUnwrap(made)
        XCTAssertEqual(built.w, 540)
        let hit = built.elements.first { $0.box[0] <= 270 && 270 <= $0.box[2] && $0.box[1] <= 610 && 610 <= $0.box[3] }
        XCTAssertNotNil(hit, built.listing)
    }

    func testFreeLineActorSeesTheListingAndTapsByID() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: the button\nDO: tap #1" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        agent.screenTree = true
        let planned = try await agent.nextActions()
        let prompt = try XCTUnwrap(actor.prompts.first)
        XCTAssertTrue(prompt.contains("Screen elements (id, role, label, center x y in 0-1000):\n#1 "), prompt)
        let made = await UITree.build(jpeg: ModelImage.forModel(Self.screen()))
        let built = try XCTUnwrap(made)
        let (x, y) = built.point(built.elements[0])
        XCTAssertEqual(planned.first?.act["x"], .int(x))
        XCTAssertEqual(planned.first?.act["y"], .int(y))
    }

    func testOtherLinesSendThePromptAsBefore() async throws {
        let screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: x\nDO: tap 100 200" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.nextActions()
        XCTAssertFalse(try XCTUnwrap(actor.prompts.first).contains("Screen elements"))
    }

    /// A white 540 x 1170 screen with one dark filled button.
    static func screen() -> Data {
        let ctx = CGContext(data: nil, width: 540, height: 1170, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 1170))
        ctx.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 170, y: 1170 - 635, width: 200, height: 50))  // y flipped: top 585 ... 635
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

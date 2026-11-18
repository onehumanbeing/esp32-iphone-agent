import CoreGraphics
import XCTest
@testable import IPhoneAgent

/// Black bars cropped off decoded frames (Letterbox), for every device; an iPhone's stream has none.
final class LetterboxTests: XCTestCase {
    private let pad = CGSize(width: 1640, height: 2360)      // 11" iPad, portrait native pixels
    private let phone = CGSize(width: 1206, height: 2622)    // iPhone 17 Pro

    /// A width x height frame, black, with `content` filled light gray (or `fill`).
    private func frame(_ width: Int, _ height: Int, content: CGRect?, fill: UInt8 = 180) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        if let content {
            for y in Int(content.minY)..<Int(content.maxY) {
                for x in Int(content.minX)..<Int(content.maxX) { pixels[y * width + x] = fill }
            }
        }
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    private func crop(_ image: CGImage, screen: CGSize, _ box: inout Letterbox) -> CGRect? {
        box.content(width: image.width, height: image.height) { Letterbox.isBlack(image, $0) }
    }

    func testAnIPhoneStreamIsLeftWhole() {
        var box = Letterbox(screen: phone)
        let image = frame(718, 1560, content: CGRect(x: 0, y: 0, width: 718, height: 1560))
        XCTAssertNil(crop(image, screen: phone, &box))
        let landscape = frame(1560, 718, content: CGRect(x: 0, y: 0, width: 1560, height: 718))  // a landscape video
        XCTAssertNil(crop(landscape, screen: phone, &box))
    }

    func testUnknownScreenCropsNothing() {
        var box = Letterbox()
        XCTAssertNil(crop(frame(1200, 1200, content: CGRect(x: 0, y: 183, width: 1200, height: 834)), screen: .zero, &box))
    }

    func testSquareFrameWithALandscapeIPad() {
        var box = Letterbox(screen: pad)
        let image = frame(1200, 1200, content: CGRect(x: 0, y: 183, width: 1200, height: 834))
        XCTAssertEqual(crop(image, screen: pad, &box), CGRect(x: 0, y: 183, width: 1200, height: 834))
        XCTAssertEqual(box.landscape, true)
    }

    func testSquareFrameWithAPortraitIPad() {
        var box = Letterbox(screen: pad)
        let image = frame(1200, 1200, content: CGRect(x: 183, y: 0, width: 834, height: 1200))
        XCTAssertEqual(crop(image, screen: pad, &box), CGRect(x: 183, y: 0, width: 834, height: 1200))
        XCTAssertEqual(box.landscape, false)
    }

    /// A frame of the screen's shape is the screen, black pillars and all: a landscape video app shows them itself, and
    /// cropping them would move every coordinate. (A portrait iPad in a landscape display streams 580x834 anyway.)
    func testScreenShapedFramesKeepTheirOwnBlackParts() {
        var box = Letterbox(screen: pad)
        let pillars = frame(1200, 834, content: CGRect(x: 310, y: 0, width: 580, height: 834))
        XCTAssertNil(crop(pillars, screen: pad, &box))
        XCTAssertNil(crop(frame(580, 834, content: CGRect(x: 0, y: 0, width: 580, height: 834)), screen: pad, &box))
    }

    /// A dark app's edges are not bars: a frame of another shape whose "bars" show content is left whole.
    func testContentWhereBarsWouldBeIsNotCropped() {
        var box = Letterbox(screen: pad)
        let image = frame(1200, 1200, content: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        XCTAssertNil(crop(image, screen: pad, &box))
        let thinLine = frame(1200, 1200, content: CGRect(x: 0, y: 183, width: 1200, height: 834))
        var pixels = thinLine  // a light status line in the top bar: not black
        let ctx = CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 1200,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(thinLine, in: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 1200 - 60, width: 1200, height: 40))  // CG's origin is bottom-left: y 20-60 from the top
        pixels = ctx.makeImage()!
        XCTAssertNil(crop(pixels, screen: pad, &box))
    }

    /// An all-black square fits both ways: the orientation chosen last decides, and without one nothing is cropped.
    func testAmbiguousFramesFollowTheLastOrientation() {
        let dark = frame(1200, 1200, content: nil)
        var fresh = Letterbox(screen: pad)
        XCTAssertNil(crop(dark, screen: pad, &fresh))
        var known = Letterbox(screen: pad, landscape: false)
        XCTAssertEqual(crop(dark, screen: pad, &known), CGRect(x: 183, y: 0, width: 834, height: 1200))
    }

    func testFitIsCentredAndEven() {
        XCTAssertEqual(Letterbox.fit(1640.0 / 2360, width: 1200, height: 1200), CGRect(x: 183, y: 0, width: 834, height: 1200))
        XCTAssertEqual(Letterbox.fit(2360.0 / 1640, width: 1200, height: 1200), CGRect(x: 0, y: 183, width: 1200, height: 834))
        let r = Letterbox.fit(2752.0 / 2064, width: 1200, height: 1200)  // 13"
        XCTAssertEqual(Int(r.height) % 2, 0)
        XCTAssertEqual(r.midY, 600, accuracy: 1)
    }

    /// With the bars cropped the frame is the screen, so the geometry maps nothing.
    func testCroppedFrameNeedsNoMapping() {
        let g = ScreenGeometry(screenAspect: 2360.0 / 1640, frameAspect: 1200.0 / 834, orientation: 3)
        XCTAssertEqual(g.contentRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(g.screenPoint(fromFrame: CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7))
    }
}

/// iPad coordinates (PadGeometry) and what an iPhone never gets.
@MainActor final class IPadLoopTests: XCTestCase {
    func testActionsMapOntoALetterboxedScreen() throws {
        let g = ScreenGeometry(screenAspect: 2, frameAspect: 0.5, orientation: 3)  // content: y 0.375-0.625
        let tap = try PadGeometry.toScreen(["action": .str("tap"), "x": .int(500), "y": .int(450)], g)
        XCTAssertEqual(tap["x"]?.double ?? 0, 500, accuracy: 1e-6)
        XCTAssertEqual(tap["y"]?.double ?? 0, 300, accuracy: 1e-6)
        let swipe = try PadGeometry.toScreen(["action": .str("swipe"), "x1": .int(500), "y1": .int(400), "x2": .int(500), "y2": .int(600)], g)
        XCTAssertEqual(swipe["y1"]?.double ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(swipe["y2"]?.double ?? 0, 900, accuracy: 1e-6)
        let path = try PadGeometry.toScreen(["action": .str("path"), "points": .arr([.arr([.int(0), .int(500)]), .arr([.int(1000), .int(500)])])], g)
        XCTAssertEqual(points(path), [CGPoint(x: 0, y: 500), CGPoint(x: 1000, y: 500)])
        XCTAssertThrowsError(try PadGeometry.toScreen(["action": .str("tap"), "x": .int(500), "y": .int(100)], g), "on the bar")
        let key = try PadGeometry.toScreen(["action": .str("key"), "combo": .str("enter")], g)
        XCTAssertEqual(key, ["action": .str("key"), "combo": .str("enter")])
    }

    func testAScreenShapedFrameMapsToItself() throws {
        let g = ScreenGeometry(screenAspect: 1640.0 / 2360, frameAspect: 834.0 / 1200, orientation: 1)
        let tap = try PadGeometry.toScreen(["action": .str("tap"), "x": .int(123), "y": .int(987)], g)
        XCTAssertEqual(tap["x"]?.double ?? 0, 123, accuracy: 1e-6)
        XCTAssertEqual(tap["y"]?.double ?? 0, 987, accuracy: 1e-6)
    }

    /// A screen that keeps turning while the model looks: each such reply is dropped, at most `turnRetries` times,
    /// then the run stops instead of paying for looks forever.
    func testAnIPadThatKeepsTurningStopsTheLook() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        let portrait = ScreenGeometry(screenAspect: 0.5, frameAspect: 0.5, orientation: 1)
        let landscape = ScreenGeometry(screenAspect: 2, frameAspect: 2, orientation: 3)
        screen.geometry = portrait
        let actor = FakeModel { _ in
            screen.geometry = screen.geometry == portrait ? landscape : portrait  // turned during every reply
            return "THINK: stale\nDO: tap 500 500"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        do {
            _ = try await agent.step()
            XCTFail("an endless rotation must end the look")
        } catch let e as BlindError {
            XCTAssertEqual(e.reason, AgentLoop.turningReason)
        }
        XCTAssertEqual(actor.prompts.count, AgentLoop.turnRetries + 1)
        XCTAssertTrue(phone.taps.isEmpty)
    }

    /// The iPhone's rules stay its own: no Dynamic Island on an iPad (its top-center safe area is small), and an
    /// iPhone's turns to its default display only when the board has an iPad's.
    func testNoDynamicIslandOnAnIPad() {
        XCTAssertNil(IslandGuard.zone(top: 24, size: CGSize(width: 820, height: 1180)))   // portrait iPad
        XCTAssertNil(IslandGuard.zone(top: 24, size: CGSize(width: 1180, height: 820)))   // landscape
        XCTAssertNotNil(IslandGuard.zone(top: 62, size: CGSize(width: 402, height: 874))) // iPhone with an island
    }

    func testThePromptNamesTheDevice() {
        XCTAssertEqual(DeviceKind.name, DeviceKind.isPad ? "iPad" : "iPhone")
        XCTAssertTrue(AgentLoop.effect(["action": .str("open"), "app": .str("X"), "changed": .bool(false), "opened": .str("not_found")])
            .contains("the name this \(DeviceKind.name) shows"))
    }
}

/// After a full GOP, firmware 0.2.5 sent the old tail's P-frames again after the next IDR (an iPad's rotation): the
/// decoder skips units stamped before the last IDR, never an IDR or a config.
final class OldGOPUnitTests: XCTestCase {
    private func unit(_ ms: UInt32, idr: Bool = false, config: Bool = false) -> AccessUnit {
        AccessUnit(data: Data(), idr: idr, config: config, snap: false, boardMs: ms)
    }

    func testUnitsFromBeforeTheLastIDRAreSkipped() {
        XCTAssertTrue(H264Decoder.belongsToAnEarlierGOP(unit(90_000), idrMs: 100_000))
        XCTAssertFalse(H264Decoder.belongsToAnEarlierGOP(unit(100_040), idrMs: 100_000))
        XCTAssertFalse(H264Decoder.belongsToAnEarlierGOP(unit(90_000), idrMs: nil), "before any IDR")
        XCTAssertFalse(H264Decoder.belongsToAnEarlierGOP(unit(90_000, idr: true), idrMs: 100_000))
        XCTAssertFalse(H264Decoder.belongsToAnEarlierGOP(unit(90_000, config: true), idrMs: 100_000), "a resend's config")
        XCTAssertFalse(H264Decoder.belongsToAnEarlierGOP(unit(1_000), idrMs: 4_000_000), "a board that restarted")
    }
}

/// The iPad's keyboards name the other layout on the key left of A (2026-11-17 trace).
final class PadKeyboardTests: XCTestCase {
    func testTheSwitchKeyNamesTheOtherLayout() {
        XCTAssertEqual(KeyboardLayout.padLayout(["abc", "a", "s", ".?123", "拼"]), .pinyin)
        XCTAssertEqual(KeyboardLayout.padLayout(["拼音", "a", "s", ".?123"]), .english, "not pinyin for its 拼音 key")
        XCTAssertEqual(KeyboardLayout.padLayout([".?123", "z"]), .english)
        XCTAssertNil(KeyboardLayout.padLayout(["Settings"]), "no keyboard: the shared reading decides")
    }
}

/// iPad: another app's keyboard (Spotlight's, during a run) keeps no room in this app's layout; its own does, and an
/// iPhone's always does.
final class LocalKeyboardTests: XCTestCase {
    func testOnlyThisAppsKeyboardMovesTheLayoutOnAnIPad() {
        XCTAssertTrue(LocalKeyboard.avoids(pad: false, localShown: false), "iPhone: as before")
        XCTAssertTrue(LocalKeyboard.avoids(pad: false, localShown: true))
        XCTAssertTrue(LocalKeyboard.avoids(pad: true, localShown: true), "iPad: a field of its own")
        XCTAssertFalse(LocalKeyboard.avoids(pad: true, localShown: false), "iPad: Spotlight's keyboard")
    }
}

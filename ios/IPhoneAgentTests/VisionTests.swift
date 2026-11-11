import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IPhoneAgent

/// Port of server/tests/test_vision.py, with the synthetic frames drawn by CoreGraphics.
final class VisionTests: XCTestCase {
    static let W = 498, H = 1080  // a mirrored iPhone frame
    var W: Double { Double(Self.W) }
    var H: Double { Double(Self.H) }

    /// A synthetic home screen: gradient background, optional button, pointer dot and checkmark.
    func screen(pointer: (Double, Double)? = nil, button: Bool = false, checked: Bool = false, island: Bool = false,
                spinner: Int? = nil) -> Data {
        let ctx = CGContext(data: nil, width: Self.W, height: Self.H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(Self.H))  // draw with a top-left origin, like PIL
        ctx.scaleBy(x: 1, y: -1)
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
            CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        for y in 0..<Self.H {
            ctx.setFillColor(rgb(40, 60 + y / 10, 120))
            ctx.fill(CGRect(x: 0, y: y, width: Self.W, height: 1))
        }
        if button {
            ctx.setFillColor(rgb(250, 250, 250))
            ctx.fill(CGRect(x: 150, y: 400, width: 201, height: 201))
        }
        if island {  // the run's Live Activity label in the Dynamic Island, above the topMask line
            ctx.setFillColor(rgb(255, 255, 255))
            ctx.fill(CGRect(x: 120, y: 12, width: 260, height: 40))
        }
        if let spinner {  // something that animates by itself, e.g. a progress bar
            ctx.setFillColor(rgb(spinner, spinner, spinner))
            ctx.fill(CGRect(x: 300, y: 300, width: 120, height: 24))
        }
        if let (x, y) = pointer {
            ctx.setFillColor(rgb(200, 200, 200))
            ctx.fillEllipse(in: CGRect(x: x - 12, y: y - 12, width: 25, height: 25))
        }
        if checked {
            ctx.setStrokeColor(rgb(255, 149, 0))
            ctx.setLineWidth(4)
            ctx.addLines(between: [CGPoint(x: 430, y: 495), CGPoint(x: 438, y: 505), CGPoint(x: 452, y: 485)])
            ctx.strokePath()
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / W, y: y / H) }

    /// A list scrolled by a tenth of the screen: Vision.scroll finds the shift; a new screen or none is not a scroll.
    func testScrollIsFoundFromTheShift() {
        func list(_ offset: Int) -> Data {
            let ctx = CGContext(data: nil, width: Self.W, height: Self.H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(Self.H))
            ctx.scaleBy(x: 1, y: -1)
            for y in 0..<Self.H {  // bands of unrelated grays (no period), moved up by `offset` pixels
                let k = UInt64((y + offset) / 18)
                let v = CGFloat((k &* 2_654_435_761 >> 7) % 256) / 255
                ctx.setFillColor(CGColor(gray: v, alpha: 1))
                ctx.fill(CGRect(x: 0, y: y, width: Self.W, height: 1))
            }
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out as Data
        }
        let up = Vision.scroll(list(0), list(108))
        XCTAssertEqual(up ?? 0, 0.1, accuracy: 0.02)
        XCTAssertEqual(Vision.scroll(list(108), list(0)) ?? 0, -0.1, accuracy: 0.02)
        XCTAssertNil(Vision.scroll(list(0), list(0)), "nothing moved")
        XCTAssertNil(Vision.scroll(screen(), screen(button: true)), "a change in place is no scroll")
    }

    func testPointerMoveIsNotAScreenChange() {
        XCTAssertFalse(Vision.changed(screen(pointer: (260, 856)), screen(pointer: (272, 856)),
                                      ignore: [p(260, 856), p(272, 856)]))
    }

    func testNewContentIsAScreenChange() {
        XCTAssertTrue(Vision.changed(screen(pointer: (260, 856)), screen(pointer: (260, 856), button: true)))
    }

    func testOurIslandLabelAndPointerAreNotAChange() {
        // 2026-11-06 Duolingo: a tap under CHECK changed nothing, but "Look" -> "Tap" in the island read as a change
        XCTAssertFalse(Vision.changed(screen(pointer: (250, 960)), screen(pointer: (250, 960), island: true),
                                      ignore: [p(250, 960)]))
        XCTAssertFalse(Vision.changed(screen(pointer: (100, 300), island: true), screen(pointer: (400, 900)),
                                      ignore: [p(100, 300), p(400, 900)]))
    }

    func testMissingFrameCountsAsChanged() {
        XCTAssertTrue(Vision.changed(nil, screen()))
    }

    func testPointerIsFoundFromANudge() throws {
        let found = try XCTUnwrap(Vision.pointer(screen(pointer: (262, 856)), screen(pointer: (274, 856)),
                                                 near: CGPoint(x: 0.5, y: 0.8), shift: 12 / W))
        XCTAssertEqual(found.x * W, 262, accuracy: 3)
        XCTAssertEqual(found.y * H, 856, accuracy: 3)
    }

    func testPointerNotFoundWhenNothingMoved() {
        let frame = screen(pointer: (262, 856))
        XCTAssertNil(Vision.pointer(frame, frame, near: CGPoint(x: 0.5, y: 0.8), shift: 12 / W))
    }

    func testSmallCheckmarkCountsAsAChange() {
        XCTAssertTrue(Vision.changed(screen(pointer: (100, 500)), screen(pointer: (100, 500), checked: true)))
    }

    func testMaskedPointerMoveIsNotAChange() {
        XCTAssertFalse(Vision.changed(screen(pointer: (100, 500)), screen(pointer: (300, 500)),
                                      ignore: [p(100, 500), p(300, 500)]))
    }

    func testThePointerOutsideItsMasksIsNotAChange() {
        // drifted off its masks: where it was and where it is now are two round spots, not a result
        XCTAssertFalse(Vision.changed(screen(pointer: (100, 500)), screen(pointer: (300, 700))))
        XCTAssertFalse(Vision.changed(screen(), screen(pointer: (300, 700))))
        XCTAssertTrue(Vision.changed(screen(pointer: (100, 500)), screen(pointer: (300, 700), checked: true)))
    }

    func testSomethingThatMovedWhileTheModelLookedIsNotAResult() {
        let seen = screen(spinner: 230), ahead = screen(spinner: 90), after = screen(spinner: 160)
        let quiet = Vision.motion(seen, ahead)
        XCTAssertFalse(quiet.isEmpty)
        XCTAssertTrue(Vision.changed(seen, after))
        XCTAssertFalse(Vision.changed(seen, after, quiet: quiet))
        XCTAssertTrue(Vision.changed(seen, screen(checked: true, spinner: 160), quiet: quiet))  // a result elsewhere
    }

    func testABigChangeLeavesNothingQuiet() {
        XCTAssertTrue(Vision.motion(screen(), screen(button: true)).isEmpty)
        XCTAssertTrue(Vision.motion(screen(), screen()).isEmpty)
    }

    func testPointerFarFromTheTargetIsFoundWithAFullScreenSearch() throws {
        let before = screen(pointer: (354, 136)), after = screen(pointer: (366, 136))
        XCTAssertNil(Vision.pointer(before, after, near: CGPoint(x: 0.9, y: 0.1), shift: 12 / W))  // outside the window
        let found = try XCTUnwrap(Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: 12 / W,
                                                 reach: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(found.x * W, 354, accuracy: 3)
        XCTAssertEqual(found.y * H, 136, accuracy: 3)
    }

    func testSomethingMovingByItselfIsNeverThePointer() throws {
        // a pointer-sized element that moves on its own (a clock hand) also moves during the nudge
        let base = screen(pointer: (250, 500)), before = screen(pointer: (262, 500)), after = screen(pointer: (274, 500))
        XCTAssertNotNil(Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.46), shift: 12 / W))
        let quiet = Vision.motion(base, before)
        XCTAssertNil(Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.46), shift: 12 / W, quiet: quiet))
        // what moved elsewhere leaves the real pointer findable
        let elsewhere = Vision.motion(screen(spinner: 230), screen(spinner: 90))
        let found = try XCTUnwrap(Vision.pointer(screen(pointer: (262, 856)), screen(pointer: (274, 856)),
                                                 near: CGPoint(x: 0.5, y: 0.8), shift: 12 / W, quiet: elsewhere))
        XCTAssertEqual(found.x * W, 262, accuracy: 3)
    }

    func testChangedAtLooksOnlyAroundThePoint() {
        let before = screen(), after = screen(button: true)  // the button covers x 150-351, y 400-601
        XCTAssertTrue(Vision.changed(before, after, at: CGPoint(x: 250 / W, y: 500 / H)))
        XCTAssertFalse(Vision.changed(before, after, at: CGPoint(x: 0.5, y: 0.9)))  // a tile elsewhere still there
        let moved = screen(pointer: (100, 900))
        XCTAssertFalse(Vision.changed(before, moved, at: CGPoint(x: 100 / W, y: 900 / H), ignore: [CGPoint(x: 100 / W, y: 900 / H)]))
    }

    /// Issue #111: Vision's completion handler and a throwing `perform` both try to resume; only one may.
    func testOnceLetsExactlyOneCallerThrough() {
        let once = Vision.Once(), lock = NSLock()
        var wins = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if once.take() { lock.lock(); wins += 1; lock.unlock() }
        }
        XCTAssertEqual(wins, 1)
        XCTAssertFalse(once.take())
    }
}

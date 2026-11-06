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
    func screen(pointer: (Double, Double)? = nil, button: Bool = false, checked: Bool = false, island: Bool = false) -> Data {
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

    func testPointerFarFromTheTargetIsFoundWithAFullScreenSearch() throws {
        let before = screen(pointer: (354, 136)), after = screen(pointer: (366, 136))
        XCTAssertNil(Vision.pointer(before, after, near: CGPoint(x: 0.9, y: 0.1), shift: 12 / W))  // outside the window
        let found = try XCTUnwrap(Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: 12 / W,
                                                 reach: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(found.x * W, 354, accuracy: 3)
        XCTAssertEqual(found.y * H, 136, accuracy: 3)
    }

    func testChangedAtLooksOnlyAroundThePoint() {
        let before = screen(), after = screen(button: true)  // the button covers x 150-351, y 400-601
        XCTAssertTrue(Vision.changed(before, after, at: CGPoint(x: 250 / W, y: 500 / H)))
        XCTAssertFalse(Vision.changed(before, after, at: CGPoint(x: 0.5, y: 0.9)))  // a tile elsewhere still there
        let moved = screen(pointer: (100, 900))
        XCTAssertFalse(Vision.changed(before, moved, at: CGPoint(x: 100 / W, y: 900 / H), ignore: [CGPoint(x: 100 / W, y: 900 / H)]))
    }
}

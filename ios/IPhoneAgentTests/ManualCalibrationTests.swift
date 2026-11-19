import XCTest
@testable import IPhoneAgent

/// Manual calibration on a phone whose pointer runs far (a high Tracking Speed, Wiki #1177: iPhone 15 Pro Max,
/// 200 units from home put the pointer on the right edge and that tap was kept as the calibration).
@MainActor final class ManualCalibrationTests: XCTestCase {
    /// A simulated phone: landed = a · units + b per axis, held on the screen.
    struct Phone {
        var a: (x: Double, y: Double), b: (x: Double, y: Double)
        func land(_ ux: Int, _ uy: Int) -> CGPoint {
            CGPoint(x: min(max(a.x * Double(ux) + b.x, 0), 1), y: min(max(a.y * Double(uy) + b.y, 0), 1))
        }
    }
    // 250 units cross the screen; home rests a little right of and below the corner (a touch probe measured 0.142 x)
    let fast = Phone(a: (1 / 250, 1 / 300), b: (0.14, 0.04))

    func testEdgeTapIsNotKeptAndASmallerMoveIsTried() {
        let first = fast.land(AutoCalibrator.manualMoves[0], AutoCalibrator.manualMoves[0])
        XCTAssertTrue(AutoCalibrator.onEdge(first), "200 units put this pointer on the right edge")
        let second = fast.land(AutoCalibrator.manualMoves[1], AutoCalibrator.manualMoves[1])
        XCTAssertFalse(AutoCalibrator.onEdge(second))
    }

    func testTwoPointsFitScaleAndHomeOffset() throws {
        let move = AutoCalibrator.manualMoves[1]
        let p = fast.land(move, move)
        let (ux, uy) = AutoCalibrator.manualSecondStop(move: move, at: p)
        let q = fast.land(ux, uy)
        XCTAssertFalse(AutoCalibrator.onEdge(q), "the board's click stays on the screen")
        let (lx, ly) = try XCTUnwrap(AutoCalibrator.manualLines([
            (Double(move), Double(move), Double(p.x), Double(p.y)), (Double(ux), Double(uy), Double(q.x), Double(q.y))]))
        XCTAssertEqual(lx.a, fast.a.x, accuracy: 1e-9)
        XCTAssertEqual(ly.a, fast.a.y, accuracy: 1e-9)
        XCTAssertEqual(lx.b, fast.b.x, accuracy: 1e-9)
        XCTAssertEqual(ly.b, fast.b.y, accuracy: 1e-9)
        // a tap near the right edge lands where it should; the one-point fit (home = corner) misses it by far
        let far = fast.land(lx.units(for: 0.9), ly.units(for: 0.9))
        XCTAssertEqual(far.x, 0.9, accuracy: 0.01)
        XCTAssertEqual(far.y, 0.9, accuracy: 0.01)
        let onePoint = fast.land(Int((0.9 * Double(move) / p.x).rounded()), Int((0.9 * Double(move) / p.y).rounded()))
        XCTAssertGreaterThan(abs(onePoint.x - 0.9), AutoCalibrator.rejectAbove)
    }

    func testClickOnTheEdgeGivesNoFit() {
        XCTAssertNil(AutoCalibrator.manualLines([(ux: 100, uy: 100, fx: 0.5, fy: 0.4), (ux: 300, uy: 300, fx: 0.99, fy: 0.9)]))
    }
}

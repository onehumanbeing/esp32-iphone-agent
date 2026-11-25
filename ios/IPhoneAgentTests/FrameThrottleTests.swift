import XCTest
@testable import IPhoneAgent

final class FrameThrottleTests: XCTestCase {
    func testLastFrameArrivesWithoutAnotherSubmission() {
        let queue = DispatchQueue(label: "test.frames")
        let done = expectation(description: "last frame after the screen becomes idle")
        var frames: [Int] = []
        let throttle = FrameThrottle<Int>(queue: queue, interval: 0.05) { frame in
            frames.append(frame)
            if frame == 3 { done.fulfill() }
        }
        queue.sync {
            throttle.submit(1)
            throttle.submit(2)
            throttle.submit(3)
            XCTAssertEqual(frames, [1])
        }
        wait(for: [done], timeout: 2)
        queue.sync { XCTAssertEqual(frames, [1, 3]) }
    }

    func testStopDiscardsPendingFrame() {
        let queue = DispatchQueue(label: "test.frames.stop")
        let done = expectation(description: "past the pending deadline")
        var frames: [Int] = []
        let throttle = FrameThrottle<Int>(queue: queue, interval: 0.05) { frames.append($0) }
        queue.sync {
            throttle.submit(1)
            throttle.submit(2)
            throttle.reset()
            queue.asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        queue.sync { XCTAssertEqual(frames, [1]) }
    }

    func testRestartDoesNotFlushOldFrame() {
        let queue = DispatchQueue(label: "test.frames.restart")
        let done = expectation(description: "new session's final frame")
        var frames: [Int] = []
        let throttle = FrameThrottle<Int>(queue: queue, interval: 0.05) { frame in
            frames.append(frame)
            if frame == 4 { done.fulfill() }
        }
        queue.sync {
            throttle.submit(1)
            throttle.submit(2)
            throttle.reset()
            throttle.submit(3)
            throttle.submit(4)
        }
        wait(for: [done], timeout: 2)
        queue.sync { XCTAssertEqual(frames, [1, 3, 4]) }
    }
}

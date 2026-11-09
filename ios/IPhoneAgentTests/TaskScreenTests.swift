import Combine
import XCTest
@testable import IPhoneAgent

@MainActor final class TaskScreenTests: XCTestCase {
    func testDefaultAirPlayAndInvalidSettingFallBack() {
        let saved = UserDefaults.standard.object(forKey: CaptureBackend.key)
        defer { UserDefaults.standard.set(saved, forKey: CaptureBackend.key) }
        UserDefaults.standard.removeObject(forKey: CaptureBackend.key)
        XCTAssertEqual(CaptureBackend.current, .airPlay)
        UserDefaults.standard.set("unknown", forKey: CaptureBackend.key)
        XCTAssertEqual(CaptureBackend.current, .airPlay)
    }

    func testSwitchingSourcesMovesFramesAndMetadataTogether() {
        let first = Source(frame: Data([1]), aspect: 0.5)
        let second = Source(frame: Data([2]), aspect: 0.75)
        let screen = TaskScreen(source: first, frames: first.$frame, isConnected: { true })
        XCTAssertEqual(screen.frame, first.frame)
        XCTAssertEqual(screen.aspect, first.aspect)

        screen.select(second, frames: second.$frame)
        XCTAssertEqual(screen.frame, second.frame)
        XCTAssertEqual(screen.aspect, second.aspect)
        first.frame = Data([3])
        XCTAssertEqual(screen.frame, Data([2]))  // the old subscription was removed
        second.frame = Data([4])
        XCTAssertEqual(screen.frame, Data([4]))

        screen.select(first, frames: first.$frame)
        XCTAssertEqual(screen.frame, Data([3]))
        second.frame = nil
        XCTAssertEqual(screen.frame, Data([3]))
        first.frame = nil
        XCTAssertNil(screen.frame)
        XCTAssertFalse(screen.live)
    }

    func testStaleFramesFollowTheSelectedSource() {
        let airPlay = Source(frame: Data([1]))
        let local = Source(frame: Data([2]))
        let screen = TaskScreen(source: airPlay, frames: airPlay.$frame, isConnected: { true })
        XCTAssertFalse(screen.stale)
        airPlay.stale = true
        XCTAssertTrue(screen.stale)
        screen.select(local, frames: local.$frame)
        XCTAssertFalse(screen.stale)
        local.stale = true
        XCTAssertTrue(screen.stale)
    }

    func testLostControlLinkPausesWithoutDiscardingTheScreen() {
        var connected = true
        let source = Source(frame: Data([1]))
        let screen = TaskScreen(source: source, frames: source.$frame, isConnected: { connected })
        XCTAssertTrue(screen.live)
        connected = false
        XCTAssertFalse(screen.live)
        XCTAssertEqual(screen.frame, source.frame)
        connected = true
        XCTAssertTrue(screen.live)
    }

    func testDelegatesChecksAndActionWaitToSelectedSource() async {
        let first = Source(frame: Data([1]))
        let second = Source(frame: nil)
        second.stopped = true
        let screen = TaskScreen(source: first, frames: first.$frame, isConnected: { true })
        XCTAssertNoThrow(try screen.checkAvailability())
        screen.select(second, frames: second.$frame)
        XCTAssertThrowsError(try screen.checkAvailability())
        let spots = [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.3, y: 0.5)]
        await screen.afterAction(since: 42, ignoring: spots)
        XCTAssertEqual(second.ignoredSpots, spots)
        XCTAssertEqual(second.waitedSince, 42)
        XCTAssertNil(first.waitedSince)
    }

    func testChangingPreferenceDoesNotImplicitlySwitchTheRouter() {
        let saved = UserDefaults.standard.object(forKey: CaptureBackend.key)
        defer { UserDefaults.standard.set(saved, forKey: CaptureBackend.key) }
        let source = Source(frame: Data([1]))
        let screen = TaskScreen(source: source, frames: source.$frame, isConnected: { true })
        UserDefaults.standard.set(CaptureBackend.onDevice.rawValue, forKey: CaptureBackend.key)
        source.frame = Data([2])
        XCTAssertEqual(screen.frame, Data([2]))
        XCTAssertTrue(screen.live)
    }

    func testStoppedLocalCaptureReportsItsOwnAvailability() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
        let capture = ScreenCaptureFeed()
        XCTAssertThrowsError(try capture.checkAvailability())
    }

    func testUnavailableDevicesIgnoreSavedOnDeviceChoice() throws {
        guard !CaptureBackend.onDeviceAvailable else { throw XCTSkip("Requires a device without screen recording") }
        let saved = UserDefaults.standard.object(forKey: CaptureBackend.key)
        defer { UserDefaults.standard.set(saved, forKey: CaptureBackend.key) }
        UserDefaults.standard.set(CaptureBackend.onDevice.rawValue, forKey: CaptureBackend.key)
        XCTAssertEqual(CaptureBackend.current, .airPlay)
    }

    func testCaptureSizePreservesPortraitAndLandscapeAspect() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
        XCTAssertEqual(ScreenCaptureFeed.captureSize(for: CGSize(width: 390, height: 844)),
                       CGSize(width: 960, height: 2078))
        XCTAssertEqual(ScreenCaptureFeed.captureSize(for: CGSize(width: 844, height: 390)),
                       CGSize(width: 960, height: 444))
    }

    func testWaitingForFrameReportsStoppedCapture() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
        let capture = ScreenCaptureFeed()
        do {
            _ = try await capture.image(timeout: 0)
            XCTFail("A stopped capture cannot supply a frame")
        } catch {
            XCTAssertTrue(error is ScreenCaptureError, "Capture failure must not be silently treated as task cancellation")
        }
    }

    func testWaitingForFrameHonorsTaskCancellation() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires iOS 27") }
        let capture = ScreenCaptureFeed()
        let task = Task { try await capture.image(timeout: 0) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not keep waiting for a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private final class Source: ScreenSource {
        @Published var frame: Data?
        var live: Bool { frame != nil }
        let updated = 1.0
        let capturedAt = 1.0
        let aspect: Double
        var stale = false
        var stopped = false
        var ignoredSpots: [CGPoint] = []
        var waitedSince: Double?

        init(frame: Data?, aspect: Double = 0.5) { self.frame = frame; self.aspect = aspect }
        func afterAction(since: Double, ignoring spots: [CGPoint]) async {
            waitedSince = since
            ignoredSpots = spots
        }
        func checkAvailability() throws {
            if stopped { throw ScreenCaptureError(message: "stopped") }
        }
    }
}

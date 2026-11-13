import CoreVideo
import XCTest
@testable import IPhoneAgent

/// `video` chunk reassembly (docs/ble-protocol.md).
final class VideoTests: XCTestCase {
    typealias F = VideoAssembler.Flags

    func chunk(_ seq: UInt16, _ flags: F, _ payload: [UInt8], ms: UInt32? = nil) -> Data {
        var d = Data([UInt8(seq & 0xff), UInt8(seq >> 8), flags.rawValue])
        if let ms { d.append(contentsOf: [UInt8(ms & 0xff), UInt8(ms >> 8 & 0xff), UInt8(ms >> 16 & 0xff), UInt8(ms >> 24)]) }
        d.append(contentsOf: payload)
        return d
    }

    let sps: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2]
    let idr: [UInt8] = [0, 0, 0, 1, 0x65, 9, 9]
    let p: [UInt8] = [0, 0, 0, 1, 0x41, 7]

    func testInOrderChunksMakeAccessUnits() {
        var a = VideoAssembler()
        XCTAssertEqual(a.add(chunk(0, [.start, .end, .config], sps, ms: 1000))?.config, true)
        XCTAssertNil(a.add(chunk(1, [.start, .idr], Array(idr[0..<5]), ms: 1001)))
        let unit = a.add(chunk(2, [.end, .idr], Array(idr[5...])))
        XCTAssertEqual(unit, AccessUnit(data: Data(idr), idr: true, config: false, snap: false, boardMs: 1001))
        XCTAssertEqual(a.add(chunk(3, [.start, .end], p, ms: 1200))?.data, Data(p))
        XCTAssertEqual(a.drops, 0)
    }

    func testGapDropsUntilTheNextKeyUnit() {
        var a = VideoAssembler()
        _ = a.add(chunk(10, [.start, .end, .idr], idr, ms: 1))
        XCTAssertNil(a.add(chunk(11, [.start], p, ms: 2)))
        XCTAssertNil(a.add(chunk(13, [.end], p)))           // 12 lost: the half unit is dropped
        XCTAssertEqual(a.drops, 1)
        XCTAssertNil(a.add(chunk(14, [.start, .end], p, ms: 3)))  // a P-frame after a gap is useless
        XCTAssertNotNil(a.add(chunk(15, [.start, .end, .config], sps, ms: 4)))  // recovered on CONFIG
        XCTAssertNotNil(a.add(chunk(16, [.start, .end], p, ms: 5)))
    }

    func testALateChunkFromTheOtherLinkIsStaleNotAGap() {
        var a = VideoAssembler()
        _ = a.add(chunk(100, [.start, .end, .idr], idr, ms: 1))
        XCTAssertNotNil(a.add(chunk(101, [.start, .end], p, ms: 2)))
        XCTAssertNil(a.add(chunk(99, [.start, .end], p, ms: 0)))   // BLE, after newer Wi-Fi chunks
        XCTAssertNil(a.add(chunk(101, [.start, .end], p, ms: 2)))  // a duplicate
        XCTAssertEqual(a.drops, 0)
        XCTAssertNotNil(a.add(chunk(102, [.start, .end], p, ms: 3)))  // still in step
        XCTAssertNil(a.add(chunk(40000, [.start, .end], p, ms: 4)))  // far off: a real gap
        XCTAssertGreaterThan(a.drops, 0)
    }

    func testRecoversOnIDRAndWrapsSeq() {
        var a = VideoAssembler()
        _ = a.add(chunk(65534, [.start, .end, .idr], idr, ms: 1))
        XCTAssertNotNil(a.add(chunk(65535, [.start, .end], p, ms: 2)))
        XCTAssertNotNil(a.add(chunk(0, [.start, .end], p, ms: 3)))  // u16 wrap is not a gap
        XCTAssertEqual(a.drops, 0)
        XCTAssertNil(a.add(chunk(5, [.start, .end], p, ms: 4)))
        XCTAssertEqual(a.drops, 4)
        let unit = a.add(chunk(6, [.start, .end, .idr, .snap], idr, ms: 5))
        XCTAssertEqual(unit?.snap, true)
    }

    func testWaitsForAKeyUnitAtStartAndIgnoresBench() {
        var a = VideoAssembler()
        XCTAssertNil(a.add(chunk(0, [.start, .end], p, ms: 1)))
        XCTAssertNil(a.add(chunk(1, [.bench], [UInt8](repeating: 0, count: 100))))
        XCTAssertEqual(a.benchBytes, 103)
        XCTAssertNotNil(a.add(chunk(2, [.start, .end, .idr], idr, ms: 2)))
    }

    func testAnnexBSplitsNALUnits() {
        let units = annexBUnits(Data(sps + [0, 0, 1, 0x68, 5] + idr))
        XCTAssertEqual(units.map { $0.first! & 0x1f }, [7, 8, 5])
        XCTAssertEqual(units[0], Data([0x67, 1, 2]))
    }
}


/// A snap acknowledgement cannot stand in for a newly decoded image.
@MainActor final class VideoFeedTests: XCTestCase {
    func testSnapRejectsAcknowledgementWithoutANewDecodedImage() async throws {
        let device = FrameDevice(), feed = VideoFeed()
        feed.device = device
        feed.show(Data([1]), width: 10, height: 20)
        do {
            _ = try await feed.snap(decodeWait: 0.02)
            XCTFail("An acknowledged snap with only the old frame must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no new screen image"))
        }
        XCTAssertEqual(feed.frame, Data([1]))
        XCTAssertTrue(feed.broken)
    }

    func testSnapWaitsForDecodedImageAfterAcknowledgement() async throws {
        let device = FrameDevice(), feed = VideoFeed()
        feed.device = device
        device.onSend = { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(25))
                feed.show(Data([2]), width: 10, height: 20)
            }
        }
        _ = try await feed.snap(decodeWait: 0.5)
        XCTAssertEqual(feed.frame, Data([2]))
        XCTAssertFalse(feed.broken)
    }

    func testSnapWaitsForTheDecoderToWorkThroughTheGOP() async throws {
        let decoder = H264Decoder(), feed = VideoFeed(decoder: decoder)
        let device = FrameDevice()
        feed.device = device
        device.onSend = { _ in
            decoder.queue.async { Thread.sleep(forTimeInterval: 0.3) }  // a long GOP still decoding after the ack
            decoder.queue.async { DispatchQueue.main.async { feed.show(Data([3]), width: 10, height: 20) } }
        }
        _ = try await feed.snap(decodeWait: 0.05)
        XCTAssertEqual(feed.frame, Data([3]))
    }

    func testAReplayedOlderFrameIsNotShown() async throws {
        let decoder = H264Decoder(), feed = VideoFeed(decoder: decoder)
        func frame(_ b: UInt8, ms: UInt32, snap: Bool = false) -> H264Decoder.Frame {
            H264Decoder.Frame(jpeg: Data([b]), width: 10, height: 20, decodeMs: 1,
                              unit: AccessUnit(data: Data(repeating: 0, count: 500), idr: false, config: false, snap: snap, boardMs: ms))
        }
        for f in [frame(1, ms: 5000), frame(2, ms: 1000), frame(3, ms: 5000), frame(4, ms: 2000, snap: true), frame(5, ms: 6000)] {
            decoder.onFrame?(f)
            try await Task.sleep(for: .milliseconds(15))
            if f.jpeg == Data([2]) { XCTAssertEqual(feed.frame, Data([1])) }  // the replay from the IDR stays hidden
            if f.jpeg == Data([4]) { XCTAssertEqual(feed.frame, Data([4])) }  // a snap still shows
        }
        XCTAssertEqual(feed.frame, Data([5]))
        feed.resetStream()
        decoder.onFrame?(frame(6, ms: 100))  // a rebooted board starts its clock over
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(feed.frame, Data([6]))
    }

    func testLateDecodedImageFromDisconnectedLinkCannotReplaceTheScreen() async throws {
        let decoder = H264Decoder(), feed = VideoFeed(decoder: decoder)
        feed.show(Data([1]), width: 10, height: 20)
        let previous = feed.updated
        feed.linkLost()
        let old = H264Decoder.Frame(jpeg: Data([9]), width: 10, height: 20, decodeMs: 1,
                                    unit: AccessUnit(data: Data(), idr: true, config: false, snap: false, boardMs: 0))
        decoder.onFrame?(old)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(feed.frame, Data([1]))
        XCTAssertEqual(feed.updated, previous)
        XCTAssertTrue(feed.broken)
        feed.show(Data([2]), width: 10, height: 20)
        XCTAssertEqual(feed.frame, Data([2]))
        XCTAssertFalse(feed.broken)
    }

    func testSnapRejectsNewImageWhenSubsequentVideoChunksWereLost() async {
        let device = FrameDevice(), feed = VideoFeed()
        feed.device = device
        device.onSend = { _ in
            feed.show(Data([2]), width: 10, height: 20)
            feed.receive(Data([0, 0, 0]))
            feed.receive(Data([2, 0, 0]))  // a sequence gap invalidates that image
        }
        do {
            _ = try await feed.snap(decodeWait: 0.02)
            XCTFail("A newer image followed by a video gap must not pass as a healthy snap")
        } catch {
            XCTAssertTrue(feed.broken)
        }
    }

    func testAResumedUnitIsTakenAfterAGapWithoutWaitingForAKeyframe() {
        func chunk(_ seq: UInt16, _ flags: VideoAssembler.Flags, ms: UInt32) -> Data {
            Data([UInt8(seq & 0xff), UInt8(seq >> 8), flags.rawValue, UInt8(ms & 0xff), UInt8(ms >> 8 & 0xff), 0, 0, 7])
        }
        var a = VideoAssembler()
        XCTAssertNotNil(a.add(chunk(1, [.start, .end, .idr], ms: 10)))
        XCTAssertNil(a.add(chunk(5, [.start, .end], ms: 30)))  // after a gap a plain unit waits for a keyframe
        let resumed = a.add(chunk(9, [.start, .end, .resume], ms: 20))
        XCTAssertEqual(resumed?.boardMs, 20)
        XCTAssertNotNil(a.add(chunk(10, [.start, .end], ms: 40)))
    }

    func testResumePointFollowsDecodedUnitsAndIsForgottenOnDecoderErrors() async throws {
        let decoder = H264Decoder(), feed = VideoFeed(decoder: decoder)
        XCTAssertNil(feed.resumeMs)
        feed.receive(Data([1, 0, 0x05 | 0x08, 5, 0, 0, 0, 0, 0, 0, 1, 0x67]))  // config: not a resume point
        XCTAssertNil(feed.resumeMs)
        feed.receive(Data([2, 0, 0x07, 9, 0, 0, 0, 0, 0, 0, 1, 0x65]))  // IDR stamped 9
        XCTAssertEqual(feed.resumeMs, 9)
        decoder.onError?("decode failed")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertNil(feed.resumeMs)
    }

    func testAResentGOPIsThinnedAndItsLastFrameStillShows() {
        let decoder = H264Decoder()
        var frames: [Int] = []
        decoder.onFrame = { frames.append(Int($0.unit.boardMs)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        let done = expectation(description: "the held last frame comes out")
        decoder.queue.async {
            for i in 1...50 {  // a burst, as when the board resends the GOP
                decoder.emitThinned(buffer!, ms: 1, unit: AccessUnit(data: Data([1]), idr: false, config: false, snap: false,
                                                                     boardMs: UInt32(i)))
            }
            decoder.queue.asyncAfter(deadline: .now() + H264Decoder.emitGap * 2) { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(frames.first, 1)
        XCTAssertEqual(frames.last, 50)
        XCTAssertLessThanOrEqual(frames.count, 3)
    }

    func testStoppingSnapDoesNotWaitForABlockedDecoderQueue() async {
        let decoder = H264Decoder()
        decoder.queue.suspend()
        defer { decoder.queue.resume() }
        let device = FrameDevice(), feed = VideoFeed(decoder: decoder)
        feed.device = device
        let waiting = Task { try await feed.snap(decodeWait: 10) }
        await Task.yield()
        waiting.cancel()
        let stopped = expectation(description: "Cancelled while the decoder queue is still blocked")
        Task {
            do {
                _ = try await waiting.value
                XCTFail("Cancellation must leave the frame wait")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 1)
    }
}

@MainActor private final class FrameDevice: HIDDevice {
    var links = 1
    var connected = true
    var onSend: ((String) -> Void)?
    func send(_ command: String) async throws -> String { onSend?(command); return "ok" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

/// Wi-Fi video datagrams back in order (VideoReorder; docs/ble-protocol.md, "Wi-Fi video").
final class VideoReorderTests: XCTestCase {
    func d(_ seq: UInt16) -> Data { Data([UInt8(seq & 0xff), UInt8(seq >> 8), 0, 0xAB]) }
    func seqs(_ chunks: [Data]) -> [UInt16] { chunks.map { UInt16($0[0]) | UInt16($0[1]) << 8 } }

    func testInOrderPassesThroughAndDuplicatesAreDropped() {
        var r = VideoReorder()
        XCTAssertEqual(seqs(r.add(d(7), at: 0).chunks), [7])
        XCTAssertEqual(seqs(r.add(d(8), at: 0).chunks), [8])
        XCTAssertEqual(r.add(d(8), at: 0).chunks, [])  // duplicate (a resend that came anyway)
        XCTAssertEqual(r.add(d(3), at: 0).chunks, [])  // late
        XCTAssertEqual(r.nacks, 0)
    }

    func testGapIsNackedAndFilledInOrder() {
        var r = VideoReorder()
        _ = r.add(d(10), at: 0)
        let out = r.add(d(13), at: 0.01)
        XCTAssertEqual(out.chunks, [])
        XCTAssertEqual(out.requests, [.nack(11, 12)])
        XCTAssertEqual(r.add(d(14), at: 0.02).requests, [])  // same gap: no second nack yet
        XCTAssertEqual(seqs(r.add(d(12), at: 0.03).chunks), [])
        XCTAssertEqual(seqs(r.add(d(11), at: 0.04).chunks), [11, 12, 13, 14])
        XCTAssertEqual(r.recovered, 1)
        XCTAssertEqual(r.tick(at: 1).requests, [])
    }

    func testRenacksThenGivesUpWithResync() {
        var r = VideoReorder()
        _ = r.add(d(1), at: 0)
        _ = r.add(d(4), at: 0)
        XCTAssertEqual(r.tick(at: 0.05).requests, [])
        XCTAssertEqual(r.tick(at: 0.09).requests, [.nack(2, 3)])
        XCTAssertEqual(r.tick(at: 0.15).requests, [])
        XCTAssertEqual(r.tick(at: 0.18).requests, [.nack(2, 3)])  // asked again while the link is congested
        let out = r.tick(at: 1.0)
        XCTAssertEqual(out.requests, [.resync])
        XCTAssertEqual(seqs(out.chunks), [4])  // delivered past the hole; the assembler waits for the IDR
        XCTAssertEqual(r.lost, 1)
        XCTAssertEqual(seqs(r.add(d(5), at: 1.1).chunks), [5])
    }

    func testResyncsAtMostOnceEveryTwoSeconds() {
        var r = VideoReorder()
        _ = r.add(d(1), at: 0)
        _ = r.add(d(3), at: 0)
        XCTAssertEqual(r.tick(at: 1.0).requests, [.resync])
        _ = r.add(d(5), at: 1.1)  // the resent GOP loses a chunk too
        XCTAssertFalse(r.tick(at: 2.2).requests.contains(.resync))  // still nacking, no second restart yet
        XCTAssertEqual(r.tick(at: 3.0).requests, [.resync])
    }

    func testSeqWrapAndANewGapBehindTheFilledOne() {
        var r = VideoReorder()
        _ = r.add(d(65534), at: 0)
        XCTAssertEqual(r.add(d(1), at: 0).requests, [.nack(65535, 0)])
        _ = r.add(d(3), at: 0)
        let filled = r.add(d(65535), at: 0.02)
        XCTAssertEqual(seqs(filled.chunks), [65535])
        XCTAssertEqual(filled.requests, [.nack(0, 0)])  // the rest of the hole, asked for again at once
        let out = r.add(d(0), at: 0.03)
        XCTAssertEqual(seqs(out.chunks), [0, 1])
        XCTAssertEqual(out.requests, [.nack(2, 2)])  // 2 is still missing before 3
    }

    func testBoardRestartFarAheadStartsOver() {
        var r = VideoReorder()
        _ = r.add(d(100), at: 0)
        XCTAssertEqual(seqs(r.add(d(30000), at: 0).chunks), [30000])
    }
}

@MainActor final class StillScreenTests: XCTestCase {
    override func setUp() async throws { StepWaits.reset() }
    override func tearDown() async throws { StepWaits.reset() }

    /// A screen that changes on every frame (a video playing): one full wait per step, then short ones.
    func testMovingScreenWaitsInFullOncePerStep() async {
        let screen = FakeStillScreen()
        let feeding = Task { while !Task.isCancelled { screen.changed = now(); try? await Task.sleep(nanoseconds: 50_000_000) } }
        defer { feeding.cancel() }
        var start = now()
        await screen.settled(quiet: 0.5, least: 0.3, most: 3)
        XCTAssertGreaterThan(now() - start, 2.9)
        XCTAssertTrue(StepWaits.moving)
        start = now()
        await screen.settled()
        await screen.settled(quiet: 0.5, least: 1.0, most: 4)
        XCTAssertLessThan(now() - start, 2 * StepWaits.movingCap + 0.5)
        XCTAssertGreaterThan(StepWaits.settle, 3.5)
        StepWaits.reset()  // the next step waits in full again
        start = now()
        await screen.settled(quiet: 0.5, least: 0.3, most: 3)
        XCTAssertGreaterThan(now() - start, 2.9)
    }

    /// A short wait that runs out (the pointer's own small caps) says nothing about the screen.
    func testShortTimeoutDoesNotCapLaterWaits() async {
        let screen = FakeStillScreen()
        let feeding = Task { while !Task.isCancelled { screen.changed = now(); try? await Task.sleep(nanoseconds: 50_000_000) } }
        await screen.settled(quiet: 0.5, least: 0.3, most: 1)
        feeding.cancel()
        XCTAssertFalse(StepWaits.moving)
    }

    /// A screen that goes still is not capped: it settles as before, and a still one stays quick.
    func testSettlingScreenIsNotMarkedMoving() async {
        let screen = FakeStillScreen()
        screen.changed = now()
        let start = now()
        await screen.settled()
        XCTAssertLessThan(now() - start, 1.5)
        XCTAssertFalse(StepWaits.moving)
    }

    /// AirPlay repeats a still screen: the same image again must not count as a change, or `settled` never ends.
    func testRepeatedImageDoesNotCountAsAChange() async throws {
        let feed = VideoFeed()
        feed.show(Data([1, 2, 3]), width: 10, height: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        let first = feed.changed
        XCTAssertGreaterThan(first, 0)
        feed.show(Data([1, 2, 3]), width: 10, height: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(feed.changed, first)
        XCTAssertGreaterThan(feed.updated, first)
        feed.show(Data([4, 5, 6]), width: 10, height: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(feed.changed, first)
    }

    func testSettledEndsWhileStillFramesKeepArriving() async {
        let screen = FakeStillScreen()
        let start = now()
        let feeding = Task { while !Task.isCancelled { screen.updated = now(); try? await Task.sleep(nanoseconds: 200_000_000) } }
        await screen.settled(quiet: 0.5, least: 0.3, most: 4)
        feeding.cancel()
        XCTAssertLessThan(now() - start, 1.5)
    }

    /// Frames that differ only at the pointer (it fades for seconds after a tap) are still; new content is not.
    func testSettledIgnoresThePointerButNotContent() async {
        let v = VisionTests(), spot = v.p(260, 856)
        func feeding(_ screen: FakeStillScreen, _ frames: [Data]) -> Task<Void, Never> {
            screen.frames = frames
            return Task {
                while !Task.isCancelled {
                    screen.changed = now()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        func took(_ frames: [Data], ignoring: [CGPoint]) async -> Double {
            let screen = FakeStillScreen(), start = now(), feed = feeding(screen, frames)
            await screen.settled(quiet: 0.5, least: 0.3, most: 2, ignoring: ignoring)
            feed.cancel()
            return now() - start
        }
        let fading = [v.screen(pointer: (260, 856)), v.screen()]
        let x = await took(fading, ignoring: [spot])
        XCTAssertLessThan(x, 1.2)
        let y = await took(fading, ignoring: [])
        XCTAssertGreaterThan(y, 1.9)  // without spots: as before, any new frame
        let z = await took([v.screen(), v.screen(button: true)], ignoring: [spot])
        XCTAssertGreaterThan(z, 1.9)
    }
}

@MainActor private final class FakeStillScreen: ScreenSource {
    var live = true
    /// When set, every read shows the next of these: a check never sees the frame it saw last. (Fed on a timer, a
    /// slow CI runner checked in step with the feed, always saw the same frame and called changing content still.)
    var frames: [Data] = []
    private var reads = 0
    private var shown: Data? = Data([0xff, 0xd8])
    var frame: Data? {
        get {
            guard !frames.isEmpty else { return shown }
            reads += 1
            return frames[(reads - 1) % frames.count]
        }
        set { shown = newValue }
    }
    var updated = 0.0
    var changed = now() - 10
    var capturedAt = 0.0
    var aspect = 0.46
}

@MainActor final class WifiVideoFeedTests: XCTestCase {
    /// Shuffled datagrams with one loss, put back in order by VideoReorder, rebuild every access unit.
    func testReorderedDatagramsReachTheAssemblerInOrder() {
        let t = VideoTests()
        let chunks = [t.chunk(0, [.start, .end, .config], t.sps, ms: 1), t.chunk(1, [.start, .idr], Array(t.idr[0..<5]), ms: 2),
                      t.chunk(2, [.end, .idr], Array(t.idr[5...])), t.chunk(3, [.start, .end], t.p, ms: 3)]
        var r = VideoReorder(), a = VideoAssembler(), units: [AccessUnit] = []
        for (i, c) in [chunks[0], chunks[2], chunks[3], chunks[1]].enumerated() {
            for x in r.add(c, at: Double(i) * 0.01).chunks { if let u = a.add(x) { units.append(u) } }
        }
        XCTAssertEqual(units.map(\.config), [true, false, false])
        XCTAssertEqual(units[1].data, Data(t.idr))
        XCTAssertEqual(a.drops, 0)
    }
}

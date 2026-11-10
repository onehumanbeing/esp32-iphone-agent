import CoreGraphics
import UIKit
import XCTest
@testable import IPhoneAgent

/// The action phase's waits (2026-11-11): what a step spends between the model's reply and the first gesture, settles
/// on screens that keep moving, the pointer's second reading, a far landing, and the Home key's check.
@MainActor final class ActionSpeedTests: XCTestCase {
    override func tearDown() {
        StepWaits.reset()
        super.tearDown()
    }

    private func calibrationFile() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    // MARK: reply to the first gesture

    /// The plan the reply brings is recorded before the gesture; its steps-list update counts in `parse` and `record`.
    func testTheTimingLineSplitsTheTimeFromReplyToTheFirstGesture() async throws {
        let model = FakeModel { _ in "THINK: open it\nPLAN: 1. tap the icon\nDO: tap 500 500" }
        let screen = FakeScreen()
        screen.frame = VisionTests().screen()
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: model, planner: nil, trace: nil)
        let metrics = Metrics()
        agent.metrics = metrics
        agent.onStep = { Thread.sleep(forTimeInterval: 0.05) }  // a slow steps list
        _ = try await agent.step()
        let timing = try XCTUnwrap(metrics.steps.last)
        XCTAssertGreaterThanOrEqual(timing.parseMs, 45)  // the plan row, before the tap
        XCTAssertGreaterThanOrEqual(timing.leadMs, timing.parseMs + timing.gateMs - 1)
        XCTAssertGreaterThanOrEqual(timing.recordMs, 95)  // the plan row and the tap row
        XCTAssertGreaterThan(timing.motionMs, 0)  // found alongside the gesture, still timed
    }

    func testAStepWithoutAModelReplyHasNoLead() {
        var step = Metrics.Step()
        step.lead(replied: 0, decided: 10, gating: 11, at: 12)
        XCTAssertEqual(step.leadMs, 0)
        step.lead(replied: 10, decided: 10.2, gating: 10.5, at: 10.6)
        XCTAssertEqual(step.leadMs, 600, accuracy: 1)
        XCTAssertEqual(step.parseMs, 200, accuracy: 1)
        XCTAssertEqual(step.gateMs, 100, accuracy: 1)
    }

    // MARK: screens that keep moving

    func testChangesOnlyWhereTheScreenMovedByItselfAreNotAChangeWhenBusy() {
        let v = VisionTests()
        let busy = CGRect(x: 280 / v.W, y: 280 / v.H, width: 160 / v.W, height: 64 / v.H)
        XCTAssertTrue(Vision.changed(v.screen(spinner: 40), v.screen(spinner: 230)))
        XCTAssertFalse(Vision.changed(v.screen(spinner: 40), v.screen(spinner: 230), busy: [busy]))
        XCTAssertTrue(Vision.changed(v.screen(spinner: 40), v.screen(button: true, spinner: 230), busy: [busy]))
    }

    /// A spinner going on through the wait does not hold it to `most` when it was seen moving before the gesture.
    func testSettledEndsOnAScreenThatOnlyMovesWhereItMovedBefore() async {
        let v = VisionTests()
        let busy = CGRect(x: 280 / v.W, y: 280 / v.H, width: 160 / v.W, height: 64 / v.H)
        func took(_ frames: [Data], busy: [CGRect]) async -> Double {
            let screen = CyclingScreen(frames), start = now()
            let feed = Task { while !Task.isCancelled { screen.changed = now(); try? await Task.sleep(nanoseconds: 100_000_000) } }
            await screen.settled(quiet: 0.5, least: 0.3, most: 2, busy: busy)
            feed.cancel()
            return now() - start
        }
        let spinning = [v.screen(spinner: 40), v.screen(spinner: 230)]
        let quick = await took(spinning, busy: [busy])
        XCTAssertLessThan(quick, 1.3)
        let capped = await took(spinning, busy: [])
        XCTAssertGreaterThan(capped, 1.9)  // without the spot: as before
        let content = await took([v.screen(spinner: 40), v.screen(button: true, spinner: 230)], busy: [busy])
        XCTAssertGreaterThan(content, 1.9)  // new content elsewhere still counts
    }

    /// No landing check (a pointer wiggle) on a screen that kept moving through a whole wait this step.
    func testNoLandingCheckWhileTheScreenKeepsMoving() async {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = VisionTests().screen()
        phone.landed = CGPoint(x: 0.5, y: 0.52)
        let agent = AgentLoop(phone: phone, screen: screen, actor: nil, planner: nil, trace: nil)
        agent.record(nil, ["action": .str("tap"), "x": .int(500), "y": .int(500)])
        var spots: [CGPoint] = []
        StepWaits.moving = true
        _ = await agent.tapResult(screen.frame, &spots, [])
        XCTAssertNil(agent.steps.last?["landed"])
        StepWaits.moving = false
        _ = await agent.tapResult(screen.frame, &spots, [])
        XCTAssertNotNil(agent.steps.last?["landed"])
    }

    // MARK: a far landing

    func testAFirstConfirmedFarLandingReHomesAndOnlyASecondOneCalibrates() {
        let pixels = CGSize(width: 1000, height: 2000), target = CGPoint(x: 0.2, y: 0.2), far = CGPoint(x: 0.6, y: 0.5)
        var r = Recalibration()
        XCTAssertTrue(r.measured(target, far, pixels: pixels, confirmed: true))  // re-home
        XCTAssertFalse(r.pending)
        XCTAssertFalse(r.measured(target, far, pixels: pixels, confirmed: true))  // far again: calibrate
        XCTAssertTrue(r.pending)
        XCTAssertTrue(r.tap())
        XCTAssertFalse(r.rehomed)

        var near = Recalibration()  // a good landing in between: the next far one re-homes again
        XCTAssertTrue(near.measured(target, far, pixels: pixels, confirmed: true))
        near.measured(target, CGPoint(x: 0.201, y: 0.2), pixels: pixels, confirmed: false)
        XCTAssertTrue(near.measured(target, far, pixels: pixels, confirmed: true))
        XCTAssertFalse(near.pending)

        var single = Recalibration()  // one reading only (not past maxMiss): as before
        XCTAssertFalse(single.measured(target, CGPoint(x: 0.2, y: 0.26), pixels: pixels))
        XCTAssertTrue(single.pending)
    }

    /// The far reading is confirmed from the same wiggle's move back (one wiggle, not two); the next tap starts from
    /// the corner instead of a recalibration. A screen still for a while is not watched another 0.3 s first.
    func testAFarLandingIsConfirmedByTheMoveBackAndReHomes() async throws {
        let device = FakeDevice(), screen = FakeScreen()
        let pointer = Pointer(device: device, calibrationFile: calibrationFile(), screen: screen)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        var ux = 240, uy = 400  // the pointer really is at (0.6, 0.5)
        func show() {
            screen.frame = Self.dot(CGPoint(x: Double(ux) / 400, y: Double(uy) / 800))
            screen.updated = now()
        }
        show()
        screen.updated = now() - 5  // the screen has been still
        var nudged: Double?
        let started = now()
        device.onSend = { command in
            let parts = command.split(separator: " ")
            if command == "home" { (ux, uy) = (0, 0) }
            guard parts.first == "move", parts.count >= 3, let dx = Int(parts[1]), let dy = Int(parts[2]) else { return }
            if command == "move 12 0", nudged == nil { nudged = now() }
            (ux, uy) = (ux + dx, uy + dy)
            show()
        }
        let landed = await pointer.landing(0.2, 0.2)
        let found = try XCTUnwrap(landed)
        XCTAssertEqual(Double(found.x), 0.6, accuracy: 0.02)
        XCTAssertEqual(Double(found.y), 0.5, accuracy: 0.02)
        XCTAssertEqual(device.sent.filter { $0 == "move 12 0" }.count, 1)  // one wiggle gave both readings
        XCTAssertLessThan(try XCTUnwrap(nudged) - started, 0.3)  // no extra watch on a still screen
        XCTAssertFalse(pointer.recalibration.pending)
        XCTAssertTrue(pointer.recalibration.rehomed)

        device.sent = []
        try await pointer.tap(0.2, 0.2)
        XCTAssertEqual(device.sent.first { $0 != "release" }, "home")  // from the corner, no calibration probes
        XCTAssertFalse(device.sent.contains("move 150 150"))
    }

    /// A pointer 6 px wide on a white 200 x 400 screen.
    static func dot(_ p: CGPoint) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: p.x * 200 - 4, y: p.y * 400 - 4, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.9)!
    }

    // MARK: the steps list

    /// A reload reads again only the runs whose steps changed (the current one), not all of them every step.
    func testRunsReloadReadsOnlyChangedRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ run: String, _ text: String) throws {
            let dir = root.appendingPathComponent(run)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("steps.jsonl"), atomically: false, encoding: .utf8)
        }
        try write("20261110-100000", "{\"kind\": \"task\", \"task\": \"Old A\"}\n")
        try write("20261111-100000", "{\"kind\": \"task\", \"task\": \"New\"}\n")
        let old = root.appendingPathComponent("20261110-100000/steps.jsonl"), date = Date(timeIntervalSince1970: 1_762_800_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: old.path)
        let store = RunStore(traces: TraceStore(root: root))
        store.reload()
        XCTAssertEqual(store.runs.map(\.task), ["New", "Old A"])

        // the old run's file is not read again while its size and date stay (same size, date put back)
        try write("20261110-100000", "{\"kind\": \"task\", \"task\": \"Old B\"}\n")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: old.path)
        // the current run grows
        try write("20261111-100000", "{\"kind\": \"task\", \"task\": \"New\"}\n{\"kind\": \"step\", \"action\": \"tap\"}\n")
        store.reload()
        XCTAssertEqual(store.runs.map(\.task), ["New", "Old A"])
        XCTAssertEqual(store.runs.first?.steps.count, 1)
    }
}

/// Every read of `frame` shows the next of `frames` (like VideoTests' still screen).
@MainActor private final class CyclingScreen: ScreenSource {
    var live = true
    let frames: [Data]
    private var reads = 0
    var frame: Data? {
        reads += 1
        return frames[(reads - 1) % frames.count]
    }
    var updated = 0.0
    var changed = now() - 10
    var capturedAt = 0.0
    var aspect = 0.46
    init(_ frames: [Data]) { self.frames = frames }
}

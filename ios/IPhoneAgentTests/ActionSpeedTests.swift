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

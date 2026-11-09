import Combine
import XCTest
@testable import IPhoneAgent

/// While a run waits in the background for its screen, every change notice from the app model re-renders the
/// whole UI tree on the main thread. Waiting must not keep sending them.
@MainActor final class BackgroundWaitTests: XCTestCase {
    private var app: AppModel { AppModel.shared }
    private var sink: AnyCancellable?
    private var notices = 0

    override func setUp() async throws {
        notices = 0
        sink = app.objectWillChange.sink { [weak self] _ in self?.notices += 1 }
    }

    override func tearDown() async throws {
        sink = nil
        app.isBackground = { UIApplication.shared.applicationState == .background }
        app.recover(nil)
        app.runMood = nil
        app.homeHint = nil
        app.startupBoardIssue = false
    }

    /// The startup wait for the first frame, in the background with the board gone (no board in the simulator).
    func testStartupWaitInBackgroundSendsFewChangeNotices() async throws {
        try XCTSkipIf(app.board.connected || MockMode.on, "needs the simulator's board-less state")
        app.isBackground = { true }
        let seconds = 2.0
        let began = now()
        app.startupDeadline = began + seconds
        do {
            _ = try await app.waitForStartupFrame(boundary: StartupFrameBoundary(requestedAt: began), snapMode: false)
            XCTFail("no board: the wait must end at the deadline")
        } catch is CancellationError {
            XCTFail("not cancelled")
        } catch {}
        let elapsed = now() - began
        let perSecond = Double(notices) / elapsed
        print(String(format: "background startup wait: %d change notices in %.1f s (%.1f/s)", notices, elapsed, perSecond))
        // Entering the board stage changes `recovering`, the mood and the hint once each; nothing after that.
        XCTAssertLessThanOrEqual(notices, 4)
        XCTAssertLessThan(perSecond, 2.5)
    }

    /// One wait-loop iteration per 100 ms with an unchanged stage (as while mirroring is off): no notices.
    func testRepeatedUnchangedWaitStageSendsNoNotices() {
        let stage = Recovery.Stage(part: .mirroring, ask: false)
        app.recover(stage)
        app.homeHint = stage.line
        notices = 0
        for _ in 0..<50 {  // 5 s of iterations
            if stage != app.recovering { app.recover(stage) }
            app.homeHint = stage.line
        }
        XCTAssertEqual(notices, 0)
        app.homeHint = Recovery.Stage(part: .mirroring, ask: true).line
        XCTAssertEqual(notices, 1, "a new line is still shown")
    }

    /// Waiting for a lost link polls slower than waiting for frames that may already be on the way.
    func testStartupPollBacksOffWhileTheLinkIsDown() {
        XCTAssertGreaterThanOrEqual(AppModel.startupPoll(waiting: true), 0.5)
        XCTAssertLessThanOrEqual(AppModel.startupPoll(waiting: false), 0.1)
    }

    // MARK: - background summary

    private func totals(_ n: Int, cpu: Double = 0) -> BackgroundCounters {
        BackgroundCounters(hintWrites: n, hintChanges: n / 10, modelNotices: n, videoUnits: n, framesDecoded: n,
                           faceTicks: n, cpu: cpu, mainCPU: cpu / 2)
    }

    func testSummaryLogsOncePerMinuteWithDeltas() {
        var summary = MinuteSummary()
        var lines: [String] = []
        for t in 0...150 {  // a tick a second for 150 s in the background
            if let line = summary.tick(totals(t * 10, cpu: Double(t) * 0.5), at: Double(t), active: true) { lines.append(line) }
        }
        XCTAssertEqual(lines.count, 2, "at 60 s and 120 s, nothing per tick")
        XCTAssertTrue(lines[0].hasPrefix("background 60 s: hint writes 600 (changed 60), app model notices 600 (10.0/s)"), lines[0])
        XCTAssertTrue(lines[0].contains("CPU 30.0 s (50%), main thread 15.0 s (25%)"), lines[0])
        XCTAssertTrue(lines[1].contains("hint writes 600 "), "the second minute counts only its own writes: \(lines[1])")
    }

    func testSummaryClosesAStintOfAtLeastTenSeconds() {
        var summary = MinuteSummary()
        XCTAssertNil(summary.tick(totals(0), at: 0, active: false), "not in the background: nothing")
        XCTAssertNil(summary.tick(totals(0), at: 1, active: true))
        XCTAssertNil(summary.tick(totals(5), at: 6, active: false), "a 5 s stint is not worth a line")
        XCTAssertNil(summary.tick(totals(5), at: 10, active: true))
        let line = summary.tick(totals(25), at: 40, active: false)
        XCTAssertEqual(line?.hasPrefix("background (ended) 30 s: hint writes 20 "), true, line ?? "nil")
        XCTAssertNil(summary.tick(totals(30), at: 41, active: false))
    }

    func testDiagnosticSummaryNamesTheTopFrameOnly() throws {
        let tree = try JSONSerialization.data(withJSONObject: ["callStacks": [["threadAttributed": true, "callStackRootFrames": [[
            "binaryName": "SwiftUI", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 0x1234,
            "subFrames": [["binaryName": "IPhoneAgent", "binaryUUID": "B", "offsetIntoBinaryTextSegment": 0xabc]],
        ]]]]])
        XCTAssertEqual(CrashReports.summary("cpu exception", detail: "30 s CPU in 60 s", build: "7", tree: tree),
                       "cpu exception, 30 s CPU in 60 s, build 7, top SwiftUI+0x1234, app IPhoneAgent+0xabc")
        XCTAssertEqual(CrashReports.summary("hang", detail: "2.0 s", build: "7", tree: Data()), "hang, 2.0 s, build 7, top ?")
    }

    func testRunMarkerSurvivesForTheNextLaunchOnly() {
        RunMarker.set("startup: waiting, mirroring")
        RunMarker.clear()
        XCTAssertNil(RunMarker.takePrevious(), "a run that ended leaves nothing")
        UserDefaults.standard.set("running", forKey: "runMarker")  // as a process that died mid-run left it
        XCTAssertEqual(RunMarker.takePrevious()?.stage, "running")
        XCTAssertNil(RunMarker.takePrevious(), "read once")
    }

    func testCPUCountersMove() {
        let cpu = ProcessCPU.seconds(), main = ProcessCPU.mainThreadSeconds()
        var x = 0.0
        for i in 0..<3_000_000 { x += sqrt(Double(i)) }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThan(ProcessCPU.seconds(), cpu)
        XCTAssertGreaterThan(ProcessCPU.mainThreadSeconds(), main, "the tests run on the main thread")
    }
}

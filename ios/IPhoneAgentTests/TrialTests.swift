import XCTest
@testable import IPhoneAgent

/// The free line stays out of builds without IA_TRIAL_ORIGIN, and only adds headers to model requests.
@MainActor final class TrialTests: XCTestCase {
    func testOpenSourceBuildHasNoFreeLine() {
        XCTAssertFalse(Trial.available)
        XCTAssertFalse(Trial.isTrial("https://api.openai.com/v1"))
        XCTAssertNotEqual(ModelProvider.infer(baseURL: "", model: ""), .handsyTrial)
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!, info: [:])
        XCTAssertFalse(settings.isConfigured(.handsyTrial))
    }

    func testModelRequestsNeedARun() {
        XCTAssertThrowsError(try Trial.shared.headers())  // tests and intent analysis never use the free line
    }

    func testRequestHeadersAreAddedAndAFailureSendsNothing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.headers = []
        StubProtocol.respond = { _ in (200, "application/json", "{\"choices\": [{\"message\": {\"content\": \"DO: wait\"}}]}") }
        let llm = LLMClient(baseURL: "http://test/v1", model: "m", session: URLSession(configuration: config),
                            headers: { ["X-Run-ID": "run-1"] })
        _ = try await llm.chat(system: "s", text: "t")
        XCTAssertEqual(StubProtocol.headers.last?["X-Run-ID"], "run-1")

        let refused = LLMClient(baseURL: "http://test/v1", model: "m", session: URLSession(configuration: config),
                                headers: { throw TrialError.runsOnly })
        do { _ = try await refused.chat(system: "s", text: "t"); XCTFail("sent without a run") } catch {}
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    // MARK: - run_end on release (why a free-line run ended; enum and counts only)

    private func end(_ trace: [JObject]) -> RunEnd { RunEnd(steps: trace, moves: 3, calls: 4, firmware: "0.2.4") }

    func testRunEndReasonComesFromTheLastRecord() {
        XCTAssertEqual(end([["action": .str("tap")], ["action": .str("done")]]).reason, .done)
        XCTAssertEqual(end([["action": .str("done")]]).outcome, "done")
        XCTAssertEqual(end([["action": .str("stopped")]]).reason, .userStop)
        XCTAssertEqual(end([["action": .str("help"), "reason": .str("x")], ["action": .str("stopped")]]).reason, .helpStop)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str("3 errors in a row")]]).reason, .failErrors)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(AgentLoop.stallReason + " in 12 steps")]]).reason, .stall)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(AgentLoop.stepLimitReason)]]).reason, .stepLimit)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.board))]]).reason, .boardLost)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.mirroring))]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(BlindError().reason)]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str("the alarm app is not installed")]]).reason, .modelFail)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str("x")]]).outcome, "failed")
        XCTAssertEqual(end([["action": .str("error"), "reason": .str("HTTP 503")]]).reason, .modelError)
        XCTAssertEqual(end([]).reason, .other)
    }

    func testRunEndBodyIsSmallAndHasNoContent() throws {
        let body = RunEnd(steps: [["action": .str("fail"), "reason": .str("secret task text")]], moves: 3, calls: 4,
                          firmware: "0.2.4").json
        XCTAssertEqual(Set(body.keys), ["outcome", "reason", "stage", "steps", "calls", "app_version", "fw"])
        XCTAssertEqual(body["reason"] as? String, "model_fail")
        XCTAssertEqual(body["stage"] as? String, "running")
        XCTAssertEqual(body["steps"] as? Int, 3)
        XCTAssertEqual(body["calls"] as? Int, 4)
        let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("secret"))  // the model's reason text never leaves the phone
        XCTAssertNil(RunEnd(reason: .startFailed, stage: .startup).json["fw"])
        XCTAssertEqual(RunEnd(reason: .startFailed, stage: .startup).outcome, "failed")
        XCTAssertEqual(RunEnd(reason: .userStop, stage: .startup).outcome, "stopped")
        XCTAssertEqual(RunEnd(reason: .stall, stage: .running, steps: 99_999).json["steps"] as? Int, 10_000)
    }
}

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

    // MARK: - Handsy key (a plan's key instead of the free runs)

    func testAKeyedRunSendsTheKeyAndNoLease() async throws {
        let trial = Trial.shared
        trial.setKey("  hsk_test_abc \n")
        defer { trial.setKey("") }
        XCTAssertEqual(trial.key, "hsk_test_abc")
        XCTAssertThrowsError(try trial.headers())  // still runs only
        try await trial.precheck()
        try await trial.begin()  // no enrollment, no lease request
        let headers = try trial.headers()
        XCTAssertEqual(headers["Authorization"], "Bearer hsk_test_abc")
        XCTAssertNotNil(UUID(uuidString: headers["X-Run-ID"] ?? ""))
        XCTAssertNil(headers["X-Lease-ID"])
        XCTAssertNil(headers["X-Device-ID"])
        trial.end(nil)
        XCTAssertThrowsError(try trial.headers())
    }

    func testARefusedKeyKeepsItsOwnTextAndIsFinal() {
        let invalid = LLMClient.freeLineError(status: 401, errorText: #"{"status": "refused", "reason": "key_invalid"}"#)
        XCTAssertEqual(invalid?.message, TrialError.keyRefused.localizedDescription)
        XCTAssertEqual(invalid?.kind, "handsy_key")
        let empty = LLMClient.freeLineError(status: 402, errorText: #"{"status": "refused", "reason": "key_balance"}"#)
        XCTAssertEqual(empty?.message, TrialError.keyEmpty.localizedDescription)
        XCTAssertNil(LLMClient.keyError(#"{"status": "busy", "reason": "quota"}"#))
        XCTAssertTrue(TrialError.keyEmpty.ownText)
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
        // the gateway reads "0.2.5"; the app shows v0.2.5 (2026-11-13)
        let board = try XCTUnwrap(FirmwareVersion("v0.2.5"))
        XCTAssertEqual(RunEnd(reason: .userStop, stage: .running, firmware: board.plain).json["fw"] as? String, "0.2.5")
        XCTAssertEqual(board.description, "v0.2.5")
        XCTAssertEqual(RunEnd(reason: .startFailed, stage: .startup).outcome, "failed")
        XCTAssertEqual(RunEnd(reason: .userStop, stage: .startup).outcome, "stopped")
        XCTAssertEqual(RunEnd(reason: .stall, stage: .running, steps: 99_999).json["steps"] as? Int, 10_000)
    }

    func testRefusalsThatEndTheRun() {
        for reason in ["lease_ended", "lease_idle", "lease_time_exhausted", "lease_invalid", "admin_paused",
                       "task_call_limit"] {
            XCTAssertTrue(LLMClient.trialRunEnded(#"{"status": "busy", "reason": "\#(reason)"}"#), reason)
        }
        for body in [#"{"status": "busy", "reason": "queue_full"}"#, #"{"status": "waiting", "reason": "lease_idle"}"#,
                     "upstream error", ""] {
            XCTAssertFalse(LLMClient.trialRunEnded(body), body)  // full or waiting: worth asking again
        }
    }

    // MARK: - free-line requests

    private func stubbed(headers: (() throws -> [String: String])? = nil) -> LLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.headers = []
        return LLMClient(baseURL: "http://test/v1", model: "m", session: URLSession(configuration: config), headers: headers)
    }

    private func delta(_ text: String, finish: String? = nil) -> String {
        let end = finish.map { ", \"finish_reason\": \"\($0)\"" } ?? ""
        return "data: {\"choices\": [{\"delta\": {\"content\": \"\(text)\"}\(end)}]}\n\n"
    }

    func testStreamCutBeforeItsEndIsAnError() async throws {
        let llm = stubbed()
        let cut = delta("DO: ta"), finished = delta("DO: wait", finish: "stop")
        StubProtocol.respond = { _ in (200, "text/event-stream", cut) }  // no [DONE], no finish_reason
        do { _ = try await llm.chat(system: "s", text: "t"); XCTFail("a cut stream passed as a reply") } catch {
            XCTAssertTrue(error is LLMError)
        }
        XCTAssertEqual(StubProtocol.seen.count, 1)

        StubProtocol.respond = { _ in (200, "text/event-stream", finished) }
        let reply = try await llm.chat(system: "s", text: "t")  // ended by its finish_reason
        XCTAssertEqual(reply.text, "DO: wait")

        StubProtocol.respond = { _ in
            (200, "text/event-stream", #"data: {"error": {"code": "busy", "message": "Handsy Free is busy"}}"# + "\n\n")
        }
        do { _ = try await llm.chat(system: "s", text: "t"); XCTFail("expected the gateway's error") } catch {
            XCTAssertEqual(error.localizedDescription, "Handsy Free is busy")  // its own error, not the cut stream
        }
    }

    func testRetriesOfOneCallKeepTheirRequestID() async throws {
        let llm = stubbed(headers: { ["X-Run-ID": "run-1"] })
        StubProtocol.respond = { body in
            body["temperature"] == nil
                ? (200, "application/json", #"{"choices": [{"message": {"content": "DO: wait"}}]}"#)
                : (400, "application/json", #"{"error": {"message": "Unsupported value: 'temperature'."}}"#)
        }
        _ = try await llm.chat(system: "s", text: "t")
        _ = try await llm.chat(system: "s", text: "next step")
        let ids = StubProtocol.headers.map { $0["X-Request-ID"] }
        XCTAssertEqual(ids.count, 3)
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])  // the retry without temperature: the same call
        XCTAssertNotEqual(ids[1], ids[2])  // a new call

        let own = stubbed()
        _ = try await own.chat(system: "s", text: "t")
        XCTAssertNil(StubProtocol.headers.last?["X-Request-ID"])  // own endpoints get no free-line headers
    }

    func testFreeLineWaitsLongerThanItsWorstCase() {
        let url = URL(string: "https://free.example/v1")!
        XCTAssertGreaterThanOrEqual(LLMClient.timeouts(baseURL: url, freeLine: true).request, 75)
        XCTAssertEqual(LLMClient.timeouts(baseURL: url, freeLine: false).request, 30)
        XCTAssertEqual(LLMClient.timeouts(baseURL: URL(string: "https://openrouter.ai/api/v1")!, freeLine: false).request, 60)
    }

    func testFreeLineIgnoresAdvancedOverrides() async throws {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!, info: [:])
        settings.selectProvider(.handsyTrial)
        settings.plannerModel = "my-model"
        settings.actorModel = "my-model"
        settings.tokenParam = "max_completion_tokens"
        settings.extraBody = #"{"max_tokens": 8192, "temperature": 1, "top_p": 0.5}"#
        for role in ["planner", "actor"] {
            let client = try await settings.client(role)
            XCTAssertEqual(client.model, Trial.model)
            XCTAssertTrue(client.extra.isEmpty)
            XCTAssertEqual(client.tokenParam, "max_tokens")
        }
        settings.selectProvider(.openAI)  // an own endpoint keeps them
        settings.actorModel = "my-model"
        settings.extraBody = #"{"top_p": 0.5}"#
        let own = try await settings.client("actor")
        XCTAssertEqual(own.model, "my-model")
        XCTAssertEqual(own.extra["top_p"] as? Double, 0.5)
    }

    func testFinalRefusalsAreNeverAskedAgain() async {
        let llm = stubbed()
        for (status, body) in [(503, #"{"status": "busy", "reason": "quota"}"#),
                               (429, #"{"status": "busy", "reason": "rate_limit_day"}"#),
                               (503, #"{"status": "busy", "reason": "lease_idle"}"#),
                               (503, #"{"status": "busy", "reason": "task_call_limit"}"#),
                               (401, #"{"detail": "unknown device"}"#)] {
            StubProtocol.seen = []
            StubProtocol.respond = { _ in (status, "application/json", body) }
            do { _ = try await llm.chat(system: "s", text: "t"); XCTFail(body) } catch {}
            XCTAssertEqual(StubProtocol.seen.count, 1, body)
        }
        XCTAssertTrue(LLMClient.trialUsedUp(#"{"status": "busy", "reason": "quota"}"#))
        XCTAssertFalse(LLMClient.trialUsedUp(#"{"status": "busy", "reason": "queue_full"}"#))
        XCTAssertFalse(LLMClient.trialUsedUp("daily quota"))
    }

    func testLineSideFailuresReadAsBusy() {
        let busy = LLMError.lineBusy
        for (status, body) in [(503, #"{"status": "busy", "reason": "spark_overheat"}"#),
                               (503, #"{"status": "busy", "reason": "all_slots_in_use"}"#),
                               (503, #"{"status": "busy", "reason": "global_cooldown"}"#),
                               (502, "bad gateway"), (500, ""),
                               (503, #"{"status": "busy", "reason": "lease_idle"}"#),
                               (503, #"{"status": "busy", "reason": "admin_paused"}"#), (401, "")] {
            let e = LLMClient.freeLineError(status: status, errorText: body)
            XCTAssertEqual(e?.message, busy, body)
            XCTAssertNotNil(e?.reason, body)  // the exact cause stays for logs and usage stats
        }
        XCTAssertEqual(LLMClient.freeLineError(status: 503, errorText: #"{"status": "busy", "reason": "lease_idle"}"#)?.reason,
                       "lease_idle")
        XCTAssertEqual(LLMClient.freeLineError(status: 503, errorText: #"{"reason": "lease_idle", "status": "busy"}"#)?.kind,
                       LLMError.trialRunEnded.kind)  // ends the run
        XCTAssertEqual(LLMClient.freeLineError(status: 503, errorText: #"{"status": "busy", "reason": "quota"}"#)?.message,
                       TrialError.usedUp.localizedDescription)
        XCTAssertEqual(LLMClient.freeLineError(status: 429, errorText: #"{"status": "busy", "reason": "rate_limit_day"}"#)?.message,
                       TrialError.usedUpToday.localizedDescription)
        XCTAssertNil(LLMClient.freeLineError(status: 400, errorText: #"{"error": {"message": "bad max_tokens"}}"#))

        let timeout = LLMClient.freeLineError(URLError(.timedOut))
        XCTAssertEqual(timeout.localizedDescription, busy)
        XCTAssertTrue(ModelRequestFailure.isTimeout(timeout))  // the agent still retries it once
        XCTAssertEqual(ModelRequestFailure.message(timeout), busy)
        XCTAssertEqual(LLMClient.freeLineError(URLError(.networkConnectionLost)).localizedDescription, busy)
        XCTAssertTrue(LLMClient.freeLineError(URLError(.cancelled)) is URLError)
        let event = LLMError(message: "Handsy Free is busy", reason: "busy"), consent = LLMError(message: "Allow first")
        XCTAssertEqual(LLMClient.freeLineError(event).localizedDescription, busy)
        XCTAssertEqual(LLMClient.freeLineError(consent).localizedDescription, "Allow first")  // the user's own step
        XCTAssertEqual(LLMError.trialRunEnded.message, busy)
    }

    func testClaimRefusalsReadAsBusyExceptTheirOwn() {
        for reason in ["all_slots_in_use", "queue_full", "spark_hot", "gpu_budget_hour", "telemetry_stale",
                       "global_cooldown", "recording_fault", "overflow_full", nil] {
            XCTAssertEqual(TrialError.refused(status: 503, reason: reason).localizedDescription,
                           TrialError.busy.localizedDescription, reason ?? "-")
        }
        XCTAssertEqual(TrialError.refused(status: 503, reason: "quota").localizedDescription, TrialError.usedUp.localizedDescription)
        XCTAssertEqual(TrialError.refused(status: 429, reason: "rate_limit_day").localizedDescription,
                       TrialError.usedUpToday.localizedDescription)
        XCTAssertEqual(TrialError.refused(status: 429, reason: nil).localizedDescription, TrialError.cooldown.localizedDescription)
        XCTAssertTrue(TrialError.cooldown.ownText)
        XCTAssertFalse(TrialError.busy.ownText)
        for text in [TrialError.busy, .waiting(0)].compactMap(\.errorDescription) + [LLMError.lineBusy] {
            for word in ["idle", "time", "error", "GPU", "temperature", "server", "slow"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(text): \(word)")
            }
        }
    }

    func testStepHeaderIsShortNumericAndCapped() {
        var step = Metrics.Step(frameMs: 1140, llmMs: 2310, hidMs: 420)
        step.settleMs = 3940
        XCTAssertEqual(step.header(gap: 6.08), "llm=2.3,frame=1.1,hid=0.4,settle=3.9,mode=stream,gap=6.1")
        step.snap = true
        step.frameMs = 1e9
        XCTAssertEqual(step.header(gap: -1), "llm=2.3,frame=999.9,hid=0.4,settle=3.9,mode=snap,gap=0.0")
        XCTAssertLessThanOrEqual(step.header(gap: 1e12).count, 80)
    }

    func testStepReportIsSentOnceAfterAReply() {
        let report = StepReport()
        report.finished(Metrics.Step())
        XCTAssertEqual(report.take(), [:])  // no reply to count the gap from
        report.replied(at: 100)
        report.finished(Metrics.Step(frameMs: 500, llmMs: 2000, hidMs: 100))
        XCTAssertEqual(report.take(at: 104),
                       [StepReport.header: "llm=2.0,frame=0.5,hid=0.1,settle=0.0,mode=stream,gap=4.0"])
        XCTAssertEqual(report.take(at: 105), [:])  // a retry of the same request does not send it again
        report.finished(Metrics.Step())
        report.clear()  // a new run
        XCTAssertEqual(report.take(), [:])
    }
}

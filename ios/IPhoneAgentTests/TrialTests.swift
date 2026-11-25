import XCTest
@testable import IPhoneAgent

/// The free line stays out of builds without IA_TRIAL_ORIGIN, and only adds headers to model requests.
@MainActor final class TrialTests: XCTestCase {
    private var keysOffered = Trial.keysOffered
    override func setUp() { super.setUp(); keysOffered = Trial.keysOffered; Trial.keysOffered = true }  // the store build's key path
    override func tearDown() { Trial.keysOffered = keysOffered; super.tearDown() }

    func testOnlyTheStoreBuildHasKeys() {
        Trial.keysOffered = false  // TestFlight and builds from this repository
        let trial = Trial.shared
        trial.setKey(Self.testKey)
        defer { trial.setKey("") }
        XCTAssertFalse(trial.hasKey)
        XCTAssertFalse(trial.keyed)  // a saved key never turns the free line off there
        XCTAssertTrue(HandsyKeyOffer.handle(URL(string: "iphoneagent://key?k=" + Self.testKey)!))  // the link is taken...
        XCTAssertNil(trial.offeredKey)  // ...and offers nothing
    }

    func testOpenSourceBuildHasNoFreeLine() throws {
        try XCTSkipIf(Trial.available, "this build has IA_TRIAL_ORIGIN (Config/Local.xcconfig): not the open-source build")
        XCTAssertFalse(Trial.available)
        XCTAssertFalse(Trial.isTrial("https://api.openai.com/v1"))
        XCTAssertNotEqual(ModelProvider.infer(baseURL: "", model: ""), .handsyTrial)
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!, info: [:])
        XCTAssertFalse(settings.isConfigured(.handsyTrial))
    }

    func testModelRequestsNeedARun() {
        XCTAssertThrowsError(try Trial.shared.headers())  // tests and intent analysis never use the free line
    }

    // MARK: - Manina AI key (a plan's key instead of the free runs)

    static let testKey = "hsk_test_" + String(repeating: "a", count: 43)

    func testOnlyAWholeKeyCountsAsAKey() {
        XCTAssertTrue(Trial.looksLikeKey(Self.testKey))
        XCTAssertTrue(Trial.looksLikeKey("hsk_live_" + String(repeating: "Z9_-", count: 10) + "abc"))
        for bad in ["", "hsk_", "hsk_live_abc", "sk-" + String(repeating: "a", count: 48), "hsk_prod_" + String(repeating: "a", count: 43),
                    Self.testKey + "a", "hsk_test_" + String(repeating: "a", count: 42) + "!"] {
            XCTAssertFalse(Trial.looksLikeKey(bad), bad)
        }
        let trial = Trial.shared
        trial.setKey("hsk_live_abc")  // an old build saved such text: it is no key, the free line stays
        defer { trial.setKey("") }
        XCTAssertFalse(trial.hasKey)
        XCTAssertFalse(trial.keyed)
    }

    func testAKeyedRunSendsTheKeyAndNoLease() async throws {
        let trial = Trial.shared
        trial.setKey("  " + Self.testKey + " \n")
        defer { trial.setKey("") }
        XCTAssertEqual(trial.key, Self.testKey)
        XCTAssertThrowsError(try trial.headers())  // still runs only
        try await trial.precheck()
        try await trial.begin()  // no enrollment, no lease request
        let headers = try trial.headers()
        XCTAssertEqual(headers["Authorization"], "Bearer " + Self.testKey)
        XCTAssertNotNil(UUID(uuidString: headers["X-Run-ID"] ?? ""))
        XCTAssertNil(headers["X-Lease-ID"])
        XCTAssertNil(headers["X-Device-ID"])
        trial.end(nil)
        XCTAssertThrowsError(try trial.headers())
    }

    // MARK: - A lease left by a process killed mid-run (2026-11-20: an app install; the next start read "busy")

    func testALeaseLeftByThePreviousProcessIsReleasedAtLaunch() async {
        let trial = Trial.shared
        defer { Trial.leftover = nil }
        Trial.leftover = Trial.Leftover(lease: "7fa6045a-lease", leaseToken: "lt")
        var sent: [Trial.Leftover] = []
        await trial.releaseLeftover { sent.append($0); return URLError(.notConnectedToInternet) }
        XCTAssertEqual(sent.map(\.lease), ["7fa6045a-lease"])
        XCTAssertNotNil(Trial.leftover)  // never reached the gateway: kept for the next try
        await trial.releaseLeftover { sent.append($0); return nil }
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(Trial.leftover)
        await trial.releaseLeftover { sent.append($0); return nil }
        XCTAssertEqual(sent.count, 2)  // nothing left: nothing sent
        Trial.leftover = Trial.Leftover(lease: "x", leaseToken: "lt")
        await trial.releaseLeftover { _ in TrialError.refused(status: 404, reason: "lease_not_found") }
        XCTAssertNil(Trial.leftover)  // a refusal is final
        XCTAssertEqual(RunEnd(reason: .appRestart, stage: .running).json["reason"] as? String, "app_restart")
    }

    func testTheHeldRunIsOnRecordUntilItIsReleased() async throws {
        let trial = Trial.shared
        Trial.leftover = nil
        trial.setKey(Self.testKey)
        defer { trial.setKey(""); Trial.leftover = nil }
        try await trial.begin()
        XCTAssertNotNil(Trial.leftover?.keyRun)
        XCTAssertEqual(Trial.leftover?.keyRun, trial.runID)
        trial.end(RunEnd(reason: .userStop, stage: .running))
        XCTAssertNil(Trial.leftover)
    }

    func testASlowPhoneIsThreeLongStallsInTwoMinutes() {
        XCTAssertFalse(PhoneLoad.isSlow([0, 10], at: 20))
        XCTAssertTrue(PhoneLoad.isSlow([0, 10, 20], at: 30))
        XCTAssertFalse(PhoneLoad.isSlow([0, 10, 20], at: 125))  // the first one is out of the window
    }

    func testAnUpdateIsNamedForTwoDaysAndNotOnTheFirstLaunch() {
        let d = UserDefaults(suiteName: "os-update-test")!
        d.removePersistentDomain(forName: "os-update-test")
        OSUpdate.note("26.3", at: 0, defaults: d)
        XCTAssertNil(OSUpdate.recent(at: 1, defaults: d))  // first launch: no update seen
        OSUpdate.note("27.2.1", at: 100, defaults: d)
        XCTAssertEqual(OSUpdate.recent(at: 200, defaults: d), "27.2.1")
        XCTAssertNil(OSUpdate.recent(at: 100 + OSUpdate.recentFor + 1, defaults: d))
    }

    func testAPlayTapThatEndsAPullDoesNotRun() {
        let now = Date()
        XCTAssertTrue(HomeView.pullTapped(pulling: true, ended: .distantPast, now: now))
        XCTAssertTrue(HomeView.pullTapped(pulling: false, ended: now.addingTimeInterval(-0.3), now: now))
        XCTAssertFalse(HomeView.pullTapped(pulling: false, ended: now.addingTimeInterval(-2), now: now))
        XCTAssertFalse(HomeView.pullTapped(pulling: false, ended: .distantPast, now: now))
    }

    func testAStoppedRunSaysWhoStoppedIt() {
        var end = RunEnd(reason: .userStop, stage: .running)
        XCTAssertNil(end.json["by"])
        end.by = "live_activity"
        XCTAssertEqual(end.json["by"] as? String, "live_activity")
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
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(StuckGuard.reason)]]).reason, .stall, "held moves, not the model")
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(PingPongGuard.stuck)]]).reason, .stall)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(AgentLoop.stepLimitReason)]]).reason, .stepLimit)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.board))]]).reason, .boardLost)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.mirroring))]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.mirroring, after: 7200))]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(Recovery.reason(.locked))]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str(BlindError().reason)]]).reason, .blindMirroring)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str("the alarm app is not installed")]]).reason, .modelFail)
        XCTAssertEqual(end([["action": .str("fail"), "reason": .str("x")]]).outcome, "failed")
        XCTAssertEqual(end([["action": .str("error"), "reason": .str("HTTP 503")]]).reason, .modelError)
        XCTAssertEqual(end([]).reason, .other)
    }

    func testRunEndBodyIsSmallAndHasNoContent() throws {
        let body = RunEnd(steps: [["action": .str("fail"), "reason": .str("secret task text")]], moves: 3, calls: 4,
                          firmware: "0.2.4").json
        XCTAssertEqual(Set(body.keys), ["outcome", "reason", "stage", "steps", "calls", "app_version", "fw", "unchanged_max"])
        XCTAssertEqual(body["reason"] as? String, "model_fail")
        XCTAssertEqual(body["stage"] as? String, "running")
        XCTAssertEqual(body["steps"] as? Int, 3)
        XCTAssertEqual(body["calls"] as? Int, 4)
        let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("secret"))  // the model's reason text never leaves the phone
        XCTAssertNil(RunEnd(reason: .startFailed, stage: .startup).json["fw"])
        // 1.0.10: the input link and the longest run of gestures that changed nothing (counts and an enum only)
        func g(_ changed: Bool) -> JObject { ["action": .str("tap"), "changed": .bool(changed)] }
        let hold: JObject = ["action": .str(RepeatGuard.action)]
        XCTAssertEqual(RunEnd.longestUnchanged([g(false), g(false), hold, g(false), g(true), g(false)]), 3, "a hold doesn't break the run")
        var linked = RunEnd(steps: [g(false), ["action": .str("done")]], moves: 1, calls: 1, firmware: nil)
        linked.transport = "ble"
        XCTAssertEqual(linked.json["transport"] as? String, "ble")
        XCTAssertEqual(linked.json["unchanged_max"] as? Int, 1)
        // the gateway reads "0.2.5"; the app shows v0.2.5 (2026-11-13)
        let board = try XCTUnwrap(FirmwareVersion("v0.2.5"))
        XCTAssertEqual(RunEnd(reason: .userStop, stage: .running, firmware: board.plain).json["fw"] as? String, "0.2.5")
        XCTAssertEqual(board.description, "v0.2.5")
        var start = RunEnd(reason: .startFailed, stage: .startup)
        start.step = StartupFailure.Step.firstFrame.rawValue
        XCTAssertEqual(start.json["step"] as? String, "first_frame")
        XCTAssertNil(RunEnd(reason: .done, stage: .running).json["step"])
    }

    /// 2026-11-13: a failed start says where and why in fixed words, never the error's own text.
    func testStartupFailureKinds() {
        func kind(_ error: Error, cancelled: Bool = false, step: StartupFailure.Step = .stream, board: Bool = true,
                  status: BoardStatus = BoardStatus(usb: "ok"), mirroring: Bool = true, inFront: Bool = false) -> String {
            StartupFailure.kind(error, cancelled: cancelled, step: step, boardConnected: board, status: status,
                                mirroring: mirroring, inFront: inFront)
        }
        let secret = DeviceError(message: "secret task text")
        XCTAssertEqual(kind(secret, cancelled: true), "cancelled")
        XCTAssertEqual(kind(CancellationError()), "cancelled")
        XCTAssertEqual(kind(TrialError.busy, step: .trialClaim), "busy")
        XCTAssertEqual(kind(TrialError.usedUp, step: .trialClaim), "trial_refused")
        XCTAssertEqual(kind(secret, board: false), "board_lost")
        XCTAssertEqual(kind(secret, status: BoardStatus(usb: "off")), "usb_off")
        XCTAssertEqual(kind(secret, status: BoardStatus(usb: "off", hid: "ok"), mirroring: false), "mirroring_off")
        XCTAssertEqual(kind(secret, mirroring: false), "mirroring_off")
        XCTAssertEqual(kind(secret, step: .leaveApp, inFront: true), "on_screen")
        XCTAssertEqual(kind(DeviceError(message: "timeout")), "timeout")
        XCTAssertEqual(kind(URLError(.timedOut)), "timeout")
        XCTAssertEqual(kind(secret, step: .firstFrame), "no_frame")
        XCTAssertEqual(kind(secret), "other")
        XCTAssertEqual(StartupFailure.Step.allCases.map(\.rawValue),
                       ["stream", "home_bar", "leave_app", "first_frame", "trial_claim", "agent_start"])
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
            (200, "text/event-stream", #"data: {"error": {"code": "busy", "message": "Manina AI Free is busy"}}"# + "\n\n")
        }
        do { _ = try await llm.chat(system: "s", text: "t"); XCTFail("expected the gateway's error") } catch {
            XCTAssertEqual(error.localizedDescription, "Manina AI Free is busy")  // its own error, not the cut stream
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

    func testAContentFilterRefusalSaysWhyOnEveryLine() {
        for body in [#"{"error": {"code": "sensitive_words_detected", "message": "..."}}"#,
                     #"{"error": {"code": "data_inspection_failed"}}"#, "finish_reason content_filter"] {
            XCTAssertTrue(LLMError.contentFiltered(body), body)
        }
        XCTAssertFalse(LLMError.contentFiltered(#"{"status": "busy", "reason": "all_slots_in_use"}"#))
        let free = LLMClient.freeLineError(status: 503, errorText: #"{"status": "busy", "reason": "content_filtered"}"#)
        XCTAssertEqual(free?.message, LLMError.contentRefused, "not read as busy: Continue on the same page would fail again")
        XCTAssertEqual(free?.kind, "content_filter")
        XCTAssertTrue(LLMError.serverFailed("api.example.com", 500, "boom").contains("api.example.com"))
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
        let timeUp = LLMClient.freeLineError(status: 503, errorText: #"{"status": "busy", "reason": "lease_ended"}"#)
        XCTAssertEqual(timeUp?.message, LLMError.trialTimeUp.message, "time up is said as it is")
        XCTAssertEqual(timeUp?.kind, LLMError.trialRunEnded.kind)
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
        let event = LLMError(message: "Manina AI Free is busy", reason: "busy"), consent = LLMError(message: "Allow first")
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

    /// The run's far landings and recalibrations ride along, counts only; none: the header is as before.
    /// Where llm and gap went (first token, the time after the gesture, …), within the gateway's 12 pairs and 160
    /// characters, the pointer counts kept; the run's first request says how long the start took.
    func testStepReportSplitsTheStepAndTheStart() {
        let report = StepReport()
        report.runStarted(at: 10)
        report.opened(seconds: 6.25)
        XCTAssertEqual(report.take(at: 31)[StepReport.header], "start=21.0,open=6.2")
        XCTAssertNil(report.take(at: 32)[StepReport.header], "the start is sent once")
        report.farLanding()
        report.replied(at: 100)
        var step = Metrics.Step(frameMs: 500, llmMs: 6000, hidMs: 100)
        (step.firstTokenMs, step.afterMs, step.verdictMs, step.landingMs, step.imageMs, step.treeMs) = (2600, 3100, 400, 900, 120, 30)
        report.finished(step)
        let value = report.take(at: 105)[StepReport.header] ?? ""
        XCTAssertTrue(value.hasPrefix("llm=6.0,frame=0.5,hid=0.1,settle=0.0,mode=stream,gap=5.0,far=1,recal=0,ttft=2.6,after=3.1"), value)
        XCTAssertFalse(value.contains("treems"), "under 50 ms: not sent")
        XCTAssertLessThanOrEqual(value.split(separator: ",").count, StepReport.maxPairs, value)
        XCTAssertLessThanOrEqual(value.count, StepReport.maxLength, value)
    }

    func testStepReportCarriesThePointersTrouble() {
        let report = StepReport()
        report.farLanding(); report.farLanding(); report.recalibrated()
        report.replied(at: 100)
        report.finished(Metrics.Step(frameMs: 500, llmMs: 2000, hidMs: 100))
        let value = report.take(at: 104)[StepReport.header] ?? ""
        XCTAssertEqual(value, "llm=2.0,frame=0.5,hid=0.1,settle=0.0,mode=stream,gap=4.0,far=2,recal=1")
        XCTAssertLessThanOrEqual(value.count, 160, "the gateway drops a longer value")
        report.clear()
        report.replied(at: 200)
        report.finished(Metrics.Step())
        XCTAssertFalse((report.take(at: 201)[StepReport.header] ?? "").contains("far="), "a new run starts at 0")
    }
}

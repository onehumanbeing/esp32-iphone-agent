import XCTest
@testable import IPhoneAgent

@MainActor final class LocalCopyTests: XCTestCase {
    private let text = "  你好，world 🌍\n日本語 한국어 e\u{301}\t  "

    func testPacketPreservesFullUnicodeAndRequiresTheActualCopyAcknowledgement() throws {
        var session = LocalCopySession()
        let id = try session.begin(text, at: 1)
        XCTAssertFalse(session.completed(id, at: 2))
        let packet = try JSONDecoder().decode(LocalCopySession.Packet.self, from: Data(session.claim(at: 2).utf8))
        XCTAssertEqual(packet.id, id)
        XCTAssertEqual(Array(packet.text.utf8), Array(text.utf8))
        XCTAssertFalse(session.completed(id, at: 3), "fetch is not copy completion")
        try session.acknowledge(id: id.uuidString, text: packet.text, at: 3)
        XCTAssertTrue(session.completed(id, at: 4))
    }

    func testClaimAcknowledgementConcurrencyExpiryAndCancellationAreSingleUse() throws {
        var session = LocalCopySession()
        let id = try session.begin(text, at: 1)
        XCTAssertThrowsError(try session.begin("other", at: 2))
        XCTAssertThrowsError(try session.acknowledge(id: id.uuidString, text: text, at: 2))
        _ = try session.claim(at: 2)
        XCTAssertThrowsError(try session.claim(at: 3))
        XCTAssertThrowsError(try session.acknowledge(id: UUID().uuidString, text: text, at: 3))
        XCTAssertThrowsError(try session.acknowledge(id: id.uuidString, text: text.trimmingCharacters(in: .whitespacesAndNewlines), at: 3))
        XCTAssertThrowsError(try session.acknowledge(id: id.uuidString, text: text, at: 21))
        session.cancel()
        XCTAssertThrowsError(try session.claim(at: 2))
        let next = try session.begin(text, at: 25)
        session.cancel(id)
        XCTAssertEqual(session.pending?.packet.id, next)
        _ = try session.claim(at: 26)
        try session.acknowledge(id: next.uuidString, text: text, at: 27)
        XCTAssertThrowsError(try session.acknowledge(id: next.uuidString, text: text, at: 28))
        XCTAssertFalse(session.completed(id, at: 28))
        XCTAssertFalse(session.completed(next, at: 46))
    }

    func testCopyReadBackIsByteExactIncludingNormalization() throws {
        var session = LocalCopySession()
        let id = try session.begin("e\u{301}", at: 1)
        _ = try session.claim(at: 2)
        XCTAssertThrowsError(try session.acknowledge(id: id.uuidString, text: "é", at: 3))
        try session.acknowledge(id: id.uuidString, text: "e\u{301}", at: 4)
        XCTAssertTrue(session.completed(id, at: 5))
    }

    func testDiagnosticLeaseAndProgressDistinguishMissingTriggerFromMissingCopyReceipt() throws {
        var session = LocalCopySession()
        let id = try session.begin(text, at: 1, timeout: 60, requiresBoard: false)
        XCTAssertEqual(session.pending?.requiresBoard, false)
        XCTAssertTrue(session.progress.contains("request text"))
        XCTAssertTrue(session.timeoutMessage.contains("never requested"))
        _ = try session.claim(at: 25)
        XCTAssertTrue(session.progress.contains("received text"))
        XCTAssertTrue(session.timeoutMessage.contains("did not confirm"))
        try session.acknowledge(id: id.uuidString, text: text, at: 60)
        XCTAssertTrue(session.completed(id, at: 60))
        XCTAssertFalse(session.completed(id, at: 61))
        session.cancel()
        XCTAssertThrowsError(try session.begin(text, at: 1, timeout: .nan))
        XCTAssertNil(session.pending)
    }

    func testConnectedBoardOnAnotherUSBHostIsRejectedBeforeAnyTrigger() {
        let issue = LocalCopyPreflight.issue(boardConnected: true, usb: "ok", keyboard: false, mouse: false,
                                            button: true)
        XCTAssertTrue(issue?.contains("not the Mac") == true,
                      "BLE connected and USB ok can both be true when the board controls the Mac")
        XCTAssertNotNil(LocalCopyPreflight.issue(boardConnected: true, usb: "asleep", keyboard: true, mouse: true,
                                                button: true))
        XCTAssertNotNil(LocalCopyPreflight.issue(boardConnected: true, usb: "ok", keyboard: true, mouse: false,
                                                button: true))
        XCTAssertNil(LocalCopyPreflight.issue(boardConnected: true, usb: "ok", keyboard: true, mouse: true,
                                             button: true))
        XCTAssertNil(LocalCopyPreflight.issue(boardConnected: true, usb: "ok", keyboard: true, mouse: false,
                                             button: false))
    }

    func testAtomicUnicodeRouteReceivesTheEntireFieldWithoutLegacyHopOrSeparatePaste() async throws {
        let phone = FakeGestures(), agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        var received: [String] = []
        agent.onWrite = { _ in XCTFail("legacy foreground clipboard hop must not run"); return false }
        agent.onUnicodeInput = { text in received.append(text); try await phone.key("cmd+v"); return ("pasted", "one exact text") }
        let note = try await agent.perform(["action": .str("type"), "text": .str(text)])
        XCTAssertEqual(received, [text])
        XCTAssertEqual(phone.calls, ["key"])
        XCTAssertEqual(note?.field, "pasted")
        XCTAssertEqual(agent.localInput?.state, .attempted)
        let duplicate = try await agent.perform(["action": .str("key"), "combo": .str("cmd+v")])
        XCTAssertEqual(duplicate?.field, "typed")
        XCTAssertEqual(phone.calls, ["key"])
    }

    func testPasteApprovalStopsBeforeModelOrGestureAndRequiresUserHandling() async throws {
        let phone = FakeGestures(), screen = FakeScreen(), model = FakeModel { _ in "DO: wait" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: nil, trace: nil)
        agent.localInput = .init(state: .attempted)
        var promptVisible = true, asks = 0
        agent.pasteApprovalReader = { _ in promptVisible }
        agent.onHelp = { _ in
            XCTAssertTrue(model.prompts.isEmpty)
            XCTAssertTrue(phone.calls.isEmpty)
            asks += 1; promptVisible = false
            return .resume
        }
        _ = try await agent.nextActions()
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(model.prompts.count, 1)
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testPasteApprovalWithoutUserHandlerNeverAsksModelToClickAllow() async throws {
        let phone = FakeGestures(), model = FakeModel { _ in "DO: tap 500 540" }
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        agent.localInput = .init(state: .attempted)
        agent.pasteApprovalReader = { _ in true }
        do { _ = try await agent.nextActions(); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(model.prompts.isEmpty)
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testPermissionLabelsAreSpecificToPaste() {
        XCTAssertTrue(PasteApproval.shown(["“Notes” would like to paste from “ESP32 Agent”", "Allow Paste", "Don’t Allow Paste"]))
        XCTAssertFalse(PasteApproval.shown(["Allow", "Don't Allow", "Photos"]))
        XCTAssertFalse(PasteApproval.shown(["Paste", "Copy"]))
        XCTAssertTrue(PasteApproval.shown(["允许粘贴", "不允许粘贴"]))
    }

    func testQuotedTypePreservesWhitespaceEscapesAndUnicodeBytes() throws {
        let json = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let command = try Actions.parseCommand("type " + json)
        XCTAssertEqual(Array(try XCTUnwrap(command["text"]?.str).utf8), Array(text.utf8))
        XCTAssertThrowsError(try Actions.parseCommand("type \"unterminated"))
        XCTAssertThrowsError(try Actions.parseCommand(#"type "bad\q""#))
        XCTAssertEqual(try Actions.parseCommand("type hello world")["text"], .str("hello world"))
    }

    func testUnicodeTypeEndsTheBatchBeforePasteReturnOrMoreInput() throws {
        let command = "DO: type \"你好\\nsecond line\"\nDO: key cmd+v\nDO: key enter"
        XCTAssertEqual(try Actions.parseActions(command).map { $0["action"]?.str }, ["type"])
        let tap: JObject = ["action": .str("tap"), "x": .int(500), "y": .int(500)]
        let paste: JObject = ["action": .str("key"), "combo": .str("cmd+v")]
        XCTAssertEqual(Actions.blindSafe([tap, paste]).count, 1)
        XCTAssertEqual(Actions.blindSafe([paste, tap]).count, 1)
        XCTAssertFalse(LocalInput.needsClipboard("plain ASCII"))
        for value in ["é", "e\u{301}", "你好", "🌍", "a\nb", "\t"] {
            XCTAssertTrue(LocalInput.needsClipboard(value), value)
        }
    }

    func testMissingSetupDoesNotFallBackToTransliterationOrLegacyClipboard() async throws {
        let phone = FakeGestures(), agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.onWrite = { _ in XCTFail("no legacy clipboard fallback"); return false }
        let result = try await agent.perform(["action": .str("type"), "text": .str(text)])
        XCTAssertEqual(result?.field, "typed")
        XCTAssertEqual(agent.localInput?.state, .invalid)
        XCTAssertTrue(phone.calls.isEmpty)
        XCTAssertTrue((agent.phone as? FakeGestures)?.calls.isEmpty == true)
    }

    func testLostPasteAcknowledgementCannotAuthorizeDuplicatePasteAfterRestore() async throws {
        let phone = FakeGestures(), agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.onUnicodeInput = { _ in
            agent.markLocalPasteAttempt()
            try await phone.key("cmd+v")
            throw DeviceError(message: "lost acknowledgement")
        }
        do { _ = try await agent.perform(["action": .str("type"), "text": .str(text)]); XCTFail() }
        catch { XCTAssertEqual(agent.localInput?.state, .attempted) }
        let restored = AgentLoop(phone: phone, screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        restored.restore(task: "new test note", steps: agent.steps)
        let result = try await restored.perform(["action": .str("key"), "combo": .str("cmd+v")])
        XCTAssertEqual(result?.field, "typed")
        XCTAssertEqual(phone.calls, ["key"])
    }

    func testASCIIStillUsesTheExistingHIDPath() async throws {
        let phone = FakeGestures(), agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: nil, planner: nil, trace: nil)
        agent.onUnicodeInput = { _ in XCTFail("ASCII uses HID"); return ("typed", "unexpected") }
        _ = try await agent.perform(["action": .str("type"), "text": .str("hello")])
        XCTAssertEqual((agent.phone as? FakeGestures)?.calls, ["type"])
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testReplayHandsUnicodeAndPasteToTheModelEvenWithMatchingReference() {
        let actions: [JObject] = [["action": .str("type"), "text": .str(text)],
                                  ["action": .str("key"), "combo": .str("cmd+v")]]
        for action in actions {
            let step = Replay.Step(action: action, sure: true, frame: Data([0xff, 0xd8]))
            if case .perform = Replay.decide(step, screen: step.frame) { XCTFail("local input must be inspected") }
        }
    }

    func testPacketRejectsEmptyOversizeAndLateReceipts() throws {
        var session = LocalCopySession()
        XCTAssertThrowsError(try session.begin("", at: 1))
        XCTAssertThrowsError(try session.begin(String(repeating: "🌍", count: 16_385), at: 1))
        let id = try session.begin(text, at: 1)
        _ = try session.claim(at: 2)
        session.cancel(id)
        XCTAssertThrowsError(try session.acknowledge(id: id.uuidString, text: text, at: 3))
    }

    func testJevCannotRepeatUnicodeOrTakeOverAfterAnUnknownPaste() async throws {
        XCTAssertNil(JevRules.doLine("TYPE", "Type '你好'", box: nil))
        let jev = LocalInputTestJev(), model = FakeModel { _ in "DO: wait" }
        let prompt = "Goal: test\n\nPlan:\n1. Type '你好'\n\nRecent actions:\n(none)"
            + LocalInput(state: .attempted).prompt
        let decider = JevDeciderModel(inner: model, jev: jev, mode: .jevFirst, race: true)
        _ = try await decider.chat(system: "", text: prompt, image: Data([0xff, 0xd8]), maxTokens: 100, temperature: 0)
        XCTAssertEqual(model.prompts.count, 1)
        XCTAssertEqual(jev.calls, 0)
        let onlyJev = JevDeciderModel(inner: model, jev: jev, mode: .jevOnly, race: false)
        let reply = try await onlyJev.chat(system: "", text: prompt, image: Data([0xff, 0xd8]), maxTokens: 100, temperature: 0)
        XCTAssertTrue(reply.text.contains("fail"))
        XCTAssertEqual(jev.calls, 0)
    }

    func testFailedCopyCannotBeReportedAsDone() async throws {
        let model = FakeModel { _ in "DO: done copied" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: nil, trace: nil)
        agent.localInput = .init(state: .invalid)
        let finished = try await agent.step()
        XCTAssertFalse(finished)
        XCTAssertEqual(agent.steps.last?["action"], .str("wait"))
    }

    func testLongPressReleasesEvenWhenThePressAcknowledgementIsLost() async {
        let device = LocalInputTestDevice()
        device.failPress = true
        do { try await LocalCopyTrigger.press(device, wait: {}); XCTFail() }
        catch { XCTAssertEqual(device.commands, ["press", "release"]) }
    }

    func testLongPressReleasesWhenCancelledWhileHolding() async {
        let device = LocalInputTestDevice()
        do { try await LocalCopyTrigger.press(device, wait: { throw CancellationError() }); XCTFail() }
        catch { XCTAssertEqual(device.commands, ["press", "release"]) }
    }

}

@MainActor private final class LocalInputTestJev: JevStepping {
    var calls = 0
    func step(_ input: JevStepInput) async throws -> JevAnswer {
        calls += 1
        return JevAnswer(accept: true, do: "type 你好")
    }
}

@MainActor private final class LocalInputTestDevice: HIDDevice {
    var links = 1
    var connected = true
    var commands: [String] = []
    var failPress = false
    func send(_ command: String) async throws -> String {
        commands.append(command)
        if command == "press", failPress { throw DeviceError(message: "press acknowledgement lost") }
        return "ok"
    }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

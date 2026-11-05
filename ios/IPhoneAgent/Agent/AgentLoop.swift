import Foundation

/// The screen feed is gone; acting now would be guessing.
struct BlindError: LocalizedError {
    var reason = "lost the phone screen: reconnect Screen Mirroring"
    var errorDescription: String? { reason }
}

/// What AgentLoop does on the phone (Pointer, or a fake in tests).
@MainActor protocol Gestures: AnyObject {
    var device: HIDDevice { get }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws
    func drag(_ points: [CGPoint], hold: Bool) async throws
    func type(_ text: String) async throws
    func key(_ combo: String) async throws
    func goHome() async throws
    func openApp(_ name: String) async throws
    func goBack() async throws
    func reset() async throws
}

extension Pointer: Gestures {}

/// See-think-act loop: a planner model writes the plan, an actor model picks each step. Port of agent.py.
@MainActor final class AgentLoop: ObservableObject {
    struct Planned {
        var act: JObject
        var shot: Data?  // every action of one reply is drawn on the same screenshot
    }

    let phone: Gestures?
    let screen: ScreenSource?
    var actor: ChatModel?, planner: ChatModel?
    let trace: TraceStore?
    let maxSteps: Int, maxFailures: Int
    var metrics: Metrics?

    @Published var task = ""
    @Published var plan = ""
    @Published var steps: [JObject] = []
    @Published private(set) var shots: [Int: Data] = [:]  // step index -> screenshot the model decided on
    @Published private(set) var running = false
    var pointerAt = CGPoint.zero  // last pointer position (screen fractions)
    /// When the last gesture ended: the model never decides on a frame from before it.
    var lastActed = 0.0
    /// Awaited before every look and every gesture (the app holds the run while its own UI is in front).
    var gate: (() async throws -> Void)?
    static let maxTokens = ["planner": 1500, "actor": 1000, "reader": 2000]
    private var job: Task<Void, Never>?
    var onFinish: (() -> Void)?
    /// Paused for the board to come back (a line for the UI), or nil when going on.
    /// Recovery from a lost link: the link state (from the app), each stage as it changes (nil = live again),
    /// and what to redo once live (stream on, fresh frame, release, re-home).
    var link: (() -> Recovery.Link)?
    var onRecover: ((Recovery.Stage?) -> Void)?
    var restore: (() async throws -> Void)?
    var recoveryLimit = Recovery.limit
    var onStep: (() -> Void)?
    /// What the agent is busy with between steps, for the Dynamic Island (looking, thinking, about to act).
    var onDoing: ((Doing) -> Void)?
    /// Every model request, answered or failed (timing and token counts, for usage stats).
    var onModelCall: ((ModelCall) -> Void)?
    enum Doing { case looking, waiting, planning, thinking, retrying, acting(JObject) }
    /// Hints from a saved intent's checklist, appended to the actor's system prompt (empty = the original prompt).
    var hints: [String] = []
    /// A saved intent's recorded steps, done without the model while the screen matches (Replay).
    var replay = Replay()
    /// What this run collected (read / note / progress), shown to the actor every step (AgentLoop+Memory).
    @Published var notebook = Notebook()
    /// Long-term memory (nil in tests that don't use it); the entries recalled for this task go in the prompts.
    var memory: MemoryStore?
    private(set) var recalled: [MemoryEntry] = []
    /// Earlier turns of the chat this run belongs to (ChatContext), for planner and actor.
    var chatContext = ""
    /// Lessons the actor offered (learn); kept only when the run ends with done.
    var learned: [String] = []
    /// Puts text on the clipboard for `write` (the app hops to the front to do it). True = ready to paste.
    var onWrite: ((String) async throws -> Bool)?
    /// "Needs your help": asked when the actor gives up or errors repeat; nil = end the run as before.
    var onHelp: ((String) async -> HelpChoice)?
    private var helpAsked = 0
    /// Connection revision of the accepted/restored look; a reconnect invalidates its actions.
    private var acceptedLookLinks: Int?
    private enum InvalidatedLook: Error { case connectionChanged }
    enum HelpChoice { case resume, skip, stop }
    /// Before a risky step (paying, sending, deleting, account settings) the actor asks; nil or the setting
    /// off = it goes on by itself. Continue = do it, Skip = don't, Stop = end the run.
    var onConfirm: ((String) async -> HelpChoice)?
    static let askBeforeRiskyKey = "askBeforeRisky"
    var askMode: AskMode?  // nil = the stored setting
    /// Free line: the actor sees the screen's element list (UITree, built here) and may answer `tap #ID`.
    var screenTree = false
    /// Who answered the last request (servedModel, e.g. "handsy-jev" when Jev took the step).
    private(set) var lastServed: String?

    init(phone: Gestures?, screen: ScreenSource?, actor: ChatModel?, planner: ChatModel?, trace: TraceStore?,
         maxSteps: Int = 40, maxFailures: Int = 3) {
        self.phone = phone; self.screen = screen; self.actor = actor; self.planner = planner
        self.trace = trace; self.maxSteps = maxSteps; self.maxFailures = maxFailures
    }

    /// traceStarted: the caller already opened the run's trace folder (so a failed start is logged too).
    func start(_ task: String, traceStarted: Bool = false) throws {
        if running { throw DeviceError(message: "agent already running") }
        guard screen?.live == true else { throw DeviceError(message: "no phone screen: start Screen Mirroring first") }
        self.task = task; plan = ""; steps = []; shots = [:]
        notebook = Notebook(); learned = []
        recalled = memory?.recall(chatContext.isEmpty ? task : task + "\n" + chatContext) ?? []
        pointerAt = .zero
        lastActed = 0
        helpAsked = 0
        acceptedLookLinks = nil
        replay.restart()
        if !traceStarted { trace?.start(task: task) }
        running = true
        job = Task { [weak self] in
            await self?.run()
            self?.running = false
            self?.onFinish?()
        }
    }

    func stop() {
        if let job { job.cancel() } else { running = false }  // a shown (demo) run has no job
    }

    func clear() throws {
        if running { throw DeviceError(message: "stop the agent first") }
        task = ""; plan = ""; steps = []; shots = [:]
        acceptedLookLinks = nil
    }

    func record(_ shot: Data? = nil, _ step: JObject) {
        if let shot { shots[steps.count] = shot }
        steps.append(JObject([("t", .num(now())), ("shot", .bool(shot != nil))]).merging(step))
        trace?.write(kind: "step", step)
        onStep?()
    }

    /// The board or mirroring went away mid-run: pause ("waiting for the board") until the screen is live
    /// again, up to `reconnectWait` s, instead of failing the run.
    /// The screen is gone (board, hotspot or mirroring lost): pause the run until it is back, in stages.
    /// Returns how many seconds it took, or nil if the screen was there all along. Never ends the run for a
    /// lost link before Recovery.limit.
    func waitForScreen(poll: Double = 0.5, forceRestore: Bool = false,
                       deadline: Double? = nil) async throws -> Double? {
        guard let screen, forceRestore || !screen.live else { return nil }
        let deadline = deadline ?? now() + recoveryLimit
        var recovery = Recovery(at: now(), limit: max(0, deadline - now()))
        var shown: Recovery.Stage?
        defer { if shown != nil { onRecover?(nil) } }
        while true {
            try Task.checkCancellation()
            guard now() < deadline else { throw BlindError(reason: Recovery.reason(shown?.part ?? .board)) }
            var state = link?() ?? Recovery.Link(connected: phone?.device.connected ?? true, sta: nil,
                                        ap: screen.live ? "streaming" : nil, frameAt: screen.live ? now() : 0)
            if forceRestore, state.connected, state.sta != 0, state.ap == "streaming" {
                // In snap mode no new frame arrives until restore requests it. The restore handler,
                // not this synthetic timestamp, must validate the newly decoded image.
                guard restore != nil else { throw BlindError() }
                state.frameAt = now()
            }
            switch recovery.next(state, at: now()) {
            case .live where screen.live || forceRestore:
                let restoringLinks = phone?.device.links
                do { try await restore?() }
                catch {
                    try Task.checkCancellation()
                    if connectionChanged(since: restoringLinks) { break }
                    throw error
                }
                guard !connectionChanged(since: restoringLinks), screen.live else { break }
                await screen.settled()
                try Task.checkCancellation()
                guard now() < deadline else { throw BlindError(reason: Recovery.reason(shown?.part ?? .board)) }
                guard !connectionChanged(since: restoringLinks) else { break }
                return now() - recovery.started
            case .live: break
            case .wait(let stage):
                if stage != shown { shown = stage; onRecover?(stage) }
            case .giveUp(let reason):
                throw BlindError(reason: reason)
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1e9))
        }
    }

    private func connectionChanged(since revision: Int?) -> Bool {
        guard let device = phone?.device else { return false }
        return !device.connected || revision.map { device.links != $0 } == true
    }

    func ask(_ role: String, _ llm: ChatModel, _ system: String, _ prompt: String,
                     temperature: Double = 0, retryTimeout: Bool = true,
                     reconnectUntil: Double? = nil) async throws -> (String, Double, Data?) {
        var prompt = prompt
        var reconnectDeadline = reconnectUntil
        while true {
            try await gate?()
            let forceRestore = connectionChanged(since: acceptedLookLinks)
            if (forceRestore || screen?.live == false) && reconnectDeadline == nil {
                reconnectDeadline = now() + recoveryLimit
            }
            if let lost = try await waitForScreen(forceRestore: forceRestore, deadline: reconnectDeadline) {
                let restoredLinks = phone?.device.links
                record(nil, ["action": .str("reconnected"), "reason": .str(String(format: "connection lost for %.0f s and restored", lost))])
                let note = "\n\nNote: the connection was lost and restored; re-check the screen before acting."
                if !prompt.hasSuffix(note) { prompt += note }
                try await gate?()  // the user may have opened this app while it was paused
                if connectionChanged(since: restoredLinks) {
                    acceptedLookLinks = restoredLinks
                    continue
                }
                acceptedLookLinks = restoredLinks
            }
            guard let screen, screen.live else { throw BlindError() }  // never let the model act blind
            let frame = screen.frame, started = now(), requestLinks = phone?.device.links
            let sent = frame.map(ModelImage.forModel)  // the model's copy; the trace keeps the full frame
            // the tree of exactly the frame sent, so `tap #ID` lands on what the model saw
            var tree: UITree?
            if role == "actor", screenTree, let sent { tree = await UITree.build(jpeg: sent) }
            let text = prompt + (tree?.listing ?? "")
            onDoing?(retryTimeout ? .waiting : .retrying)
            let reporting = llm as? ModelProgressReporting
            reporting?.onProgress = { [weak self] progress in
                switch progress {
                case .waiting: self?.onDoing?(retryTimeout ? .waiting : .retrying)
                case .receiving: self?.onDoing?(role == "planner" ? .planning : .thinking)
                }
            }
            defer { reporting?.onProgress = nil }
            let reply: ChatResult
            let maxTokens = Self.maxTokens[role] ?? 1000
            do {
                DebugLog.write("model request starting (\(role)): \(llm.model), maxTokens \(maxTokens), image \((sent?.count ?? 0) / 1024) KB")
                reply = try await llm.chat(system: system, text: text, image: sent,
                                           maxTokens: maxTokens, temperature: temperature)
            } catch {
                if !Task.isCancelled {
                    onModelCall?(ModelCall(role: role, model: llm.model, reply: nil, error: error, imageKB: (sent?.count ?? 0) / 1024))
                }
                try Task.checkCancellation()
                if connectionChanged(since: requestLinks) {
                    DebugLog.write("model request interrupted by a changed board connection; restoring before retry")
                    acceptedLookLinks = requestLinks
                    if reconnectDeadline == nil { reconnectDeadline = now() + recoveryLimit }
                    continue
                }
                guard retryTimeout, ModelRequestFailure.isTimeout(error), !Task.isCancelled else { throw error }
                DebugLog.write("model request timed out (\(role)); retrying once with a fresh screen")
                onDoing?(.retrying)
                try await Task.sleep(for: .seconds(2))
                // Re-enter the gate and screen checks before retrying; no gesture is repeated.
                return try await ask(role, llm, system, prompt, temperature: temperature, retryTimeout: false,
                                     reconnectUntil: reconnectDeadline)
            }
            let seconds = ((now() - started) * 100).rounded() / 100
            metrics?.llm(first: reply.firstToken, total: reply.total)
            onModelCall?(ModelCall(role: role, model: llm.model, reply: reply, error: nil, imageKB: (sent?.count ?? 0) / 1024))
            let answer = tree?.resolve(reply.text) ?? reply.text
            lastServed = reply.servedModel
            var rec: JObject = ["role": .str(role), "model": .str(llm.model), "prompt": .str(text),
                                "reply": .str(reply.text), "seconds": .num(seconds)]
            if let tree {
                rec["tree_ms"] = .num(((tree.ocrSeconds + tree.cvSeconds) * 1000).rounded())
                if answer != reply.text { rec["resolved"] = .str(answer) }
            }
            if let first = reply.firstToken { rec["first_token_s"] = .num((first * 100).rounded() / 100) }
            if lastActed > 0 { rec["frame_after_action_s"] = .num(((screen.capturedAt - lastActed) * 100).rounded() / 100) }
            trace?.write(frame, kind: "llm", rec.merging(reply.diagnostics))
            try Task.checkCancellation()
            if connectionChanged(since: requestLinks) {
                DebugLog.write("model reply discarded: board connection changed; restoring the screen before another look")
                acceptedLookLinks = requestLinks
                if reconnectDeadline == nil { reconnectDeadline = now() + recoveryLimit }
                continue
            }
            acceptedLookLinks = requestLinks
            return (answer, seconds, frame)
        }
    }

    func run() async {
        var failures = 0
        do {
            if replay.current == nil { try await replan() }
            for _ in 0..<maxSteps {
                do {
                    if plan.isEmpty {  // a saved intent's steps first (ScriptRunner); the model plans once they're over
                        switch try await scriptStep() {
                        case .next: continue
                        case .ended: return finish()
                        case .handOver: try await replan()
                        }
                    }
                    if try await step() {
                        guard steps.last?["action"]?.str == "fail", try await askForHelp() else { return finish() }
                        continue
                    }
                    failures = 0
                } catch is InvalidatedLook {
                    // No gesture was sent. Replanning re-enters the forced restore before its look.
                    try await replan(stuck: true)
                    failures = 0
                } catch let e where e is BlindError || e is CancellationError || Task.isCancelled {
                    throw e
                } catch let e as LLMError where e.kind == "rate_limit_day" {
                    throw e  // no point retrying today: ends the run with the message
                } catch {  // a bad reply or a dropped link: recover, don't crash
                    record(nil, ["action": .str("hiccup"), "reason": .str(String(error.localizedDescription.prefix(300)))])
                    let linkLost = error is DeviceError && screen?.live == false  // the next look waits for it (waitForScreen)
                    failures += linkLost ? 0 : 1  // a lost link is not the agent's fault
                    if failures >= maxFailures {
                        record(nil, ["action": .str("fail"), "reason": .str("\(failures) errors in a row")])
                        guard try await askForHelp() else { return finish() }
                        failures = 0
                        continue
                    }
                    await screen?.settled()
                    try await replan(stuck: true)
                }
            }
            record(nil, ["action": .str("fail"), "reason": .str("step limit reached")])
        } catch let e where e is CancellationError || Task.isCancelled {
            record(nil, ["action": .str("stopped")])
        } catch let e as BlindError {
            record(nil, ["action": .str("fail"), "reason": .str(e.reason)])
        } catch {  // e.g. the planner itself is unreachable
            record(nil, ["action": .str("error"), "reason": .str(ModelRequestFailure.message(error))])
        }
        finish()
    }

    /// Pauses for the user (at most twice a run). True = go on from the current screen with a new plan.
    private func askForHelp() async throws -> Bool {
        guard let onHelp, helpAsked < 2 else { return false }
        helpAsked += 1
        let reason = steps.last?["reason"]?.str ?? ""
        record(nil, ["action": .str("help"), "reason": .str(reason)])
        let choice = await onHelp(reason)
        try Task.checkCancellation()
        switch choice {
        case .stop:
            record(nil, ["action": .str("stopped")])
            return false
        case .resume:
            record(nil, ["action": .str("takeover"), "reason": .str("the user did this part by hand: \(reason)")])
        case .skip:
            record(nil, ["action": .str("skipped"), "reason": .str("the user asked to skip this step: \(reason)")])
        }
        await screen?.settled()
        try await replan(stuck: true)
        return true
    }

    /// The actor asked before a risky step. True = the run is over (stopped).
    private func confirm(_ reason: String) async throws -> Bool {
        guard let onConfirm, (askMode ?? .current).asks(reason) else {
            record(nil, ["action": .str("confirmed"), "reason": .str("go ahead (no need to ask for this): \(reason)")])
            return false
        }
        let choice = await onConfirm(reason)
        try Task.checkCancellation()
        switch choice {
        case .stop:
            record(nil, ["action": .str("stopped")])
            return true
        case .resume:
            record(nil, ["action": .str("confirmed"), "reason": .str("the user said yes, do it now: \(reason)")])
        case .skip:
            record(nil, ["action": .str("skipped"), "reason": .str("the user said no, do not do this: \(reason)")])
            await screen?.settled()
            try await replan(stuck: true)
        }
        return false
    }

    /// The actor's system prompt: the original, plus an intent's checklist as hints.
    var actorPrompt: String {
        let base = Prompts.actor + "\n" + AssistiveTouchSpots.rule + background
        let all = hints + replay.hints
        return all.isEmpty ? base : base + "\n\nHints for this task:\n" + all.map { "- " + $0 }.joined(separator: "\n")
    }

    func finish() {
        keepLessons()
        if let metrics { trace?.writeMetrics(metrics.snapshot()) }
    }

    /// One see-think-act round (one or more actions). Returns true when the task is over.
    func step() async throws -> Bool {
        var timing = Metrics.Step()
        let acts = try await nextActions()
        timing.llmMs = (acts[0].act["think_s"]?.double ?? 0) * 1000
        let seen = acts[0].shot
        var spots = [pointerAt]  // where the pointer was and goes: pointer moves are not screen changes
        let stuck = repeating(acts[0].act)
        defer { metrics?.step(timing) }
        for (i, planned) in acts.enumerated() {
            var act = planned.act
            let name = act["action"]?.str ?? ""
            if name == "replan" || stuck {
                record(planned.shot, act)
                try await replan(stuck: stuck)
                return false
            }
            if name == "confirm" {
                record(planned.shot, act)
                return try await confirm(act["reason"]?.str ?? "")
            }
            if Actions.notebookActions.contains(name) {
                try await notebookAction(&act)
                record(planned.shot, act)
                if name == "write" { return false }
                continue
            }
            if name == "done" { attachNotebook(&act) }
            if name != "done" && name != "fail" {
                try await gate?()
                guard !connectionChanged(since: acceptedLookLinks) else {
                    throw InvalidatedLook.connectionChanged
                }
                onDoing?(.acting(act))  // the thought (on the first act) names the target
                let started = now()
                try await perform(act)
                lastActed = now()
                let s = lastActed - started
                timing.hidMs += s * 1000
                act["act_s"] = .num((s * 100).rounded() / 100)
                spots += pointerPath(act)
                pointerAt = spots.last!
            }
            record(planned.shot, act)
            if name == "done" || name == "fail" { return true }
            let following = i < acts.count - 1 ? acts[i + 1].act["action"]?.str : nil
            if name == "tap" && (following == "type" || following == "key") {  // a missed tap never opened the field
                timing.frameMs += await settle()
                if !Vision.changed(seen, screen?.frame, ignore: spots) {
                    steps[steps.count - 1]["changed"] = .bool(false)
                    return false  // skip the rest; the actor looks again
                }
            }
        }
        timing.frameMs += await settle()
        // feedback for the next round (a notebook action alone moves nothing: no verdict)
        guard !Actions.notebookActions.contains(steps.last?["action"]?.str ?? "") else { return false }
        steps[steps.count - 1]["changed"] = .bool(Vision.changed(seen, screen?.frame, ignore: spots))
        return false
    }

    func settle() async -> Double {
        let started = now()
        onDoing?(.looking)
        await screen?.afterAction(since: lastActed)
        return (now() - started) * 1000
    }

    /// The previous round changed nothing on screen, so a tap may have landed off target.
    var missed: Bool { steps.last?["changed"] == .bool(false) }

    /// True when the actor picks the same action as its last limit-1 moves and the last one did nothing.
    /// Repeating a move that still changes the screen (e.g. scrolling down a long list) is progress, not a loop.
    func repeating(_ act: JObject, limit: Int = 3) -> Bool {
        let moves = steps.filter { $0["plan"] == nil }.suffix(limit - 1)
        return moves.count == limit - 1 && moves.allSatisfy { Actions.key($0) == Actions.key(act) }
            && moves.last?["changed"] != .bool(true)
    }

    func replan(stuck: Bool = false) async throws {
        guard let planner else { throw LLMError(message: "no planner model") }
        var prompt = "Goal: \(task)"
        if stuck {
            let last = steps.last ?? JObject()
            prompt += "\n\nThe previous plan got stuck (last event: \(pyStr(last["action"])) \(last["reason"]?.str ?? "")):"
                + "\n\(plan)\nLook at the current screen and plan from here, another way if needed."
        }
        let system = Prompts.plannerApp + "\n" + AssistiveTouchSpots.rule + background
        let (reply, seconds, frame) = try await ask("planner", planner, system, prompt)
        let (en, zh) = Actions.parsePlan(reply)
        plan = en
        record(frame, ["action": .str(stuck ? "replan (stuck)" : "plan"), "plan": .str(en), "plan_zh": .str(zh),
                       "think_s": .num(seconds)])
    }

    func nextActions() async throws -> [Planned] {
        guard let actor else { throw LLMError(message: "no actor model") }
        // actions and their effect only: echoing earlier thoughts makes the model repeat them instead of looking
        let hidden: Set<String> = ["t", "plan", "plan_zh", "think_s", "act_s", "shot", "thought", "thought_zh", "changed", "replay", "jev"]
        let history = steps.suffix(8).filter { $0["plan"] == nil }.map { s -> String in
            let effect = s["changed"] == .bool(true) ? " -> screen changed"
                : s["changed"] == .bool(false) ? " -> screen did NOT change" : ""
            return String(PyJSON.dumps(s.without(hidden)).prefix(300)) + effect
        }.joined(separator: "\n")
        let collected = notebook.isEmpty ? "" : "\n\n" + notebook.summary()
        var prompt = "Goal: \(task)\n\nPlan:\n\(plan)\n\nRecent actions:\n\(history.isEmpty ? "(none)" : history)"
            + collected + "\n\nNext action?"
        var reply = ""
        for attempt in 0..<3 {  // retry unparseable replies, a little less deterministically
            let (text, seconds, frame) = try await ask("actor", actor, actorPrompt, prompt, temperature: 0.4 * Double(attempt))
            reply = text
            var acts: [JObject]
            do { acts = try Actions.parseActions(text) } catch { continue }
            if missed, let last = steps.last, Actions.key(acts[0]) == Actions.key(last) {  // same move that did nothing
                prompt += "\n\nYou just proposed \(PyJSON.dumps(Actions.key(acts[0]))) again, but it changed nothing last "
                    + "time. Choose a different action (another position, a shorter swipe, or another way)."
                continue
            }
            acts[0]["think_s"] = .num(seconds)
            if lastServed == "handsy-jev" { acts[0]["jev"] = .bool(true) }  // the free line's Jev took this step
            return acts.map { Planned(act: $0, shot: frame) }
        }
        throw Actions.ParseError(message: "actor gave no valid action: \(reply.prefix(200))")
    }

    func perform(_ a: JObject) async throws {
        guard let phone else { throw DeviceError(message: "no phone") }
        func p(_ k: String) -> Double { (a[k]?.double ?? 0) / 1000 }
        switch a["action"]?.str {
        case "tap": try await phone.tap(p("x"), p("y"), aim: a["precise"]?.bool ?? false || missed)
        case "swipe": try await phone.swipe(p("x1"), p("y1"), p("x2"), p("y2"), hold: true)
        case "path": try await phone.drag(points(a).map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }, hold: true)
        case "circle": try await phone.drag(circle(p("x"), p("y"), p("r"), aspect: screen?.aspect ?? 9 / 19.5), hold: true)
        case "type": try await phone.type(a["text"]?.str ?? "")
        case "key": try await phone.key(a["combo"]?.str ?? "")
        case "home": try await phone.goHome()
        case "open": try await phone.openApp(a["app"]?.str ?? "")
        case "back": try await phone.goBack()
        case "wait": break
        case let other: throw Actions.ParseError(message: "unknown action \(other ?? "nil")")
        }
    }

    /// Show a run without running it (demo data).
    func showMock(task: String, plan: String, steps: [JObject], running: Bool) {
        self.task = task
        self.plan = plan
        self.steps = steps
        self.running = running
    }

    /// Python's str() of a value in an f-string (None for a missing key).
    private func pyStr(_ v: JValue?) -> String {
        guard let v else { return "None" }
        if case .str(let s) = v { return s }
        return PyJSON.dumps(v)
    }
}

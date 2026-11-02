import Combine
import Foundation
import UIKit

/// Working mode: Start → the character takes off → the phone goes to the Home Screen and the agent runs, with
/// the Live Activity as its UI, a low-fps video of the mirror stream, "needs your help" pauses, notifications,
/// and the review editor at the end.
extension AppModel {

    var moveCount: Int { agent.steps.filter { !StepText.notMoves.contains($0["action"]?.str ?? "") }.count }
    var runID: String { traces.dir?.lastPathComponent ?? "" }

    /// Start a task (or a saved intent: its checklist goes to the actor as hints).
    func run(_ task: String, intent: SavedTask? = nil) async {
        guard !startingAgent, !agent.running, !recorder.busy else { return }
        if intent?.builtin == "diagnostics" { return await sendDiagnostics() }
        currentIntent = intent
        var task = task
        if ChatContext.isContinue(task), let last = threads.current.turns.last {  // "continue": the last task, from where it stopped
            task = last.ask
        }
        lastTask = task
        agent.chatContext = ChatContext.render(threads.current.turns)
        agent.hints = intent?.checklist ?? []
        agent.replay = intent.map(Replay.init(intent:)) ?? Replay()
        if !agent.replay.steps.isEmpty { DebugLog.write("replay: \(agent.replay.steps.count) recorded steps") }
        await startAgent(task)
    }

    /// Own the startup task for every entry point, including shortcuts and consent/recovery retries.
    func startAgent(_ task: String) async {
        guard !startingAgent, !agent.running else { return }
        startingAgent = true
        tab = .agent
        startupBoardIssue = false
        lastRunDoing = nil
        startupDeadline = now() + Recovery.limit
        homeHint = String(localized: "Preparing the run…")
        defer {
            startingAgent = false
            departing = false
            homeHint = nil
            startupTask = nil
            if !agent.running {
                recovering = nil
                notifier.clearLinkAsks()
            }
        }
        let job = Task { await self.prepareAgent(task) }
        startupTask = job
        await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
    }

    /// Start couldn't go ahead: log it and say so over Home (the Start button shakes).
    private func blocked(_ text: String) {
        say(text)
        Haptics.failure()
        toast = Toast(text: text)
    }

    private func prepareAgent(_ task: String) async {
        if MockMode.on { return mockRun(task) }
        guard !Task.isCancelled else { return }
        guard settings.isConfigured else {
            Analytics.capture("run_blocked", ["reason": "model_not_set"])
            blocked(String(localized: "Set up the model in Settings first."))
            return
        }
        guard AIConsent.granted(settings.baseURL) else {
            Analytics.capture("run_blocked", ["reason": "ai_consent"])
            aiConsentRun = task
            return
        }
        guard await calibrator.ensureCalibrated() else {
            Analytics.capture("run_blocked", ["reason": "not_calibrated"])
            blocked(String(localized: "The pointer isn't calibrated yet."))
            return
        }
        guard !Task.isCancelled else { return }
        do {
            if settings.provider == .handsyTrial { try await Trial.shared.begin() }  // free line: take it before leaving
            agent.actor = try await settings.client("actor")
            agent.planner = try await settings.client("planner")
        } catch is CancellationError {
            return  // Cancel while waiting for the free line
        } catch {
            Analytics.capture("run_blocked", ["reason": "model_client"])
            say("LLM: \(error.localizedDescription)")
            if case TrialError.usedUp = error { blocked(error.localizedDescription) }
            else if settings.provider == .handsyTrial {
                blocked(String(localized: "The free line is busy. Try again in a minute, or switch to your own model."))
            } else { blocked(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }
        // Start is tapped in this app, so: Live Activity, go Home, let the screen settle, THEN the first
        // frame for the planner. Each sub-step is timed in the log.
        let t0 = now()
        func mark(_ what: String) { DebugLog.write(String(format: "start: %@ (+%.0f ms)", what, (now() - t0) * 1000)) }
        traces.start(task: task)  // the run folder exists from here: a failed start keeps its log and video
        Analytics.capture("run_started", settings.analyticsModel.merging(
            ["from_intent": currentIntent != nil, "frame_mode": FrameMode.current == .snap ? "snap" : "stream"]) { $1 })
        startVideo()
        FrameMode.fallback = nil  // each run starts in the chosen mode
        let snapMode = FrameMode.current == .snap
        live.start(task: task, runID: runID, limit: agent.maxSteps)
        mark("Live Activity requested")
        do {
            // Ready the screen while still in front: iOS cannot start the video decoder in the background.
            if snapMode {
                if feed.streamOn { try await startupBoardCommand { try await feed.stream(false) } }
                mark("snap-per-step mode (stream off)")
            } else {
                try await startupBoardCommand { try await feed.stream(true) }  // reconnect before resuming startup
                mark("stream on")
                // Leave only with a decoded screen in hand: right after mirroring starts the stream needs a
                // moment (pre-warm took ~2 s in the 2026-10-19 log); without it the run waits for a snap.
                let readyBy = now() + 10
                while (prewarmJob != nil || !feed.live || feed.broken) && now() < readyBy {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                mark(feed.live && !feed.broken ? "screen ready" : "no screen after 10 s; going on")
            }
            try? await pointer.aimHomeBar()  // the flick then starts with "See you later!"
            mark("pointer on the home bar")
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "agent") { [weak self] in
                self?.say("iOS is ending background time; BLE status keeps the run going")
                self?.endBackgroundTask()
            }
            departing = true  // "See you later!" and the flick together
            homeHint = nil
            live.show(.leavingApp, mood: .acting)
            let requestedAt = appIsBackgrounded && backgroundEnteredAt > 0 ? backgroundEnteredAt : now()
            let frameBoundary = StartupFrameBoundary(requestedAt: requestedAt)
            let away = try await leaveForRun()
            try Task.checkCancellation()
            guard away else {  // never let the agent start on its own app
                throw DeviceError(message: String(localized: "ESP32 Agent is still on screen"))
            }
            departing = false
            homeHint = nil
            mark("app in background")
            if let prewarm = prewarmJob { await prewarm.value; mark("pre-warm done") }  // its snap holds the board
            let frameSource = try await waitForStartupFrame(boundary: frameBoundary, snapMode: snapMode)
            try Task.checkCancellation()
            guard appIsBackgrounded,
                  frameBoundary.accepts(capturedAt: feed.capturedAt, backgroundEnteredAt: backgroundEnteredAt) else {
                if !appIsBackgrounded { throw onScreenError() }
                throw DeviceError(message: String(localized: "The board answered, but no new screen image arrived. Keep Screen Mirroring connected and try again."))
            }
            mark("first frame: " + frameSource)
            try agent.start(task, traceStarted: true)
            mark("agent started")
            say("started: \(task)")
            began(task, early: true)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            Trial.shared.end()  // free line
            Analytics.capture("run_ended", ModelUsage().props.merging([
                "outcome": cancelled ? "stopped" : "failed", "phase": "startup", "steps": 0,
                "seconds": Int(now() - t0), "from_intent": currentIntent != nil
            ]) { $1 })
            Analytics.flush()
            say(cancelled ? String(localized: "Run start cancelled.") : "cannot start: \(error.localizedDescription)")
            traces.write(feed.frame, kind: "step", ["action": .str(cancelled ? "stopped" : "error"),
                                                    "reason": .str(cancelled ? "cancelled before agent start" : "cannot start: \(error.localizedDescription)")])
            videoSink = nil
            saveVideoFrame(feed.frame)
            videoDir = nil
            live.end(cancelled ? (.idle, String(localized: "Stopped")) : (.failure, error.localizedDescription))
            endBackgroundTask()
            Task { try? await feed.stream(false); prewarmStream() }  // back on only if the app is open
            runs.reload()
            runMood = cancelled ? nil : .failure
            if !cancelled {
                notifier.post(.trouble, title: String(localized: "Could not start"),
                              body: error.localizedDescription + "\n" + String(localized: "Tap to send diagnostics to the developer."),
                              run: runID)
                openReview(run: runID)
            }
        }
    }

    /// Emergency stop: cancel the agent and release the mouse button.
    func stopAgent() async {
        startupTask?.cancel()
        if startingAgent && calibrator.busy { calibrator.cancel() }
        answerHelp(.stop)
        mockJob?.cancel()
        agent.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)  // let a gesture in flight finish its own release
        if board.connected && !MockMode.on {
            do { try await pointer.reset() } catch { say("release failed: \(error.localizedDescription)") }
        }
    }

    /// A run began: the character thinks, the Live Activity appears, the video starts.
    /// early: the Live Activity and the video were started before the agent (a real run's start sequence).
    func began(_ task: String, early: Bool = false) {
        moodReset?.cancel()
        runMood = .thinking
        paused = false
        runStarted = Date()
        runUsage = ModelUsage()
        if !early {
            live.start(task: task, runID: runID, limit: agent.maxSteps)
            if !MockMode.on { startVideo() }  // always: the review needs it, even for a run that stops at once
        }
        runs.reload()
    }

    /// After each recorded step: a short "acting" hop, then back to thinking while the model looks again.
    func stepped() {
        runs.reload()
        guard agent.running, let last = agent.steps.last, help == nil else { return }
        let moved = !StepText.notMoves.contains(last["action"]?.str ?? "")
        runMood = moved ? .acting : .thinking
        live.update(mood: runMood ?? .thinking, step: moveCount, line: StepText.line(last), phase: paused ? .paused : .running)
        if moved {
            moodReset?.cancel()
            moodReset = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, self?.agent.running == true, self?.help == nil else { return }
                self?.runMood = .thinking
            }
        }
    }

    /// Between steps: what the character says in the Dynamic Island and where its eyes go.
    func doing(_ d: AgentLoop.Doing) {
        lastRunDoing = d
        guard agent.running, help == nil, recovering == nil else { return }
        switch d {
        case .looking: live.show(.looking, mood: .thinking)
        case .waiting: live.show(.waiting, mood: .thinking)
        case .planning: live.show(.planning, mood: .thinking)
        case .thinking: live.show(.thinking, mood: .thinking)
        case .retrying: live.show(.retrying, mood: .thinking)
        case .acting(let act): live.show(.acting(act), mood: .acting)
        }
    }

    /// A model request finished or failed: counted for the run, and one usage-stats event (no content).
    func modelCalled(_ call: ModelCall) {
        runUsage.add(call)
        Analytics.capture("model_request", settings.analyticsModel(call))
        Analytics.flush()
    }

    /// The run ended: outcome on the character, Live Activity and a notification; then the review opens.
    func ended() {
        Trial.shared.end()  // free line
        videoSink = nil
        saveVideoFrame(feed.frame)  // the last screen too, however the run ended
        videoDir = nil
        help = nil
        takingOver = false
        recovering = nil
        notifier.clearHelp()
        notifier.clearLinkAsks()
        let last = agent.steps.last
        let outcome = Outcome(last: last?["action"]?.str, running: false)
        let seconds = Date().timeIntervalSince(runStarted)
        Analytics.capture("run_ended", runUsage.props.merging(["outcome": "\(outcome)", "steps": moveCount,
                                                               "seconds": Int(seconds), "from_intent": currentIntent != nil]) { $1 })
        Analytics.flush()
        runMood = outcome.mood
        live.end((outcome.mood, last.map(StepText.line) ?? ""))
        runs.reload()
        let summary = String(localized: "\(moveCount) steps · \(seconds.durationText)")
        switch outcome {
        case .done:
            Haptics.success()
            let answer = last?["answer"]?.str ?? agent.task
            notifier.post(.done, title: String(localized: "Done: \(answer)"), body: summary, run: runID)
        case .failed:
            let why = last?["reason"]?.str ?? ""
            notifier.post(.failed, title: String(localized: "Not finished: \(why)"), body: summary, run: runID)
        default: break
        }
        if let intent = currentIntent {
            intents.record(intent.id, RunStat(run: runID, ok: outcome == .done, seconds: seconds))
        }
        threads.append(ChatTurn(ask: agent.task, run: runID, outcome: last?["action"]?.str ?? "stopped",
                                answer: last?["answer"]?.str ?? last?["reason"]?.str ?? "",
                                items: agent.notebook.items,
                                summary: outcome == .done ? "" : ChatContext.stopSummary(steps: agent.steps, plan: agent.plan,
                                                                                         notebook: agent.notebook),
                                stats: Run.statsText(steps: moveCount, seconds: seconds, calls: runUsage.calls,
                                                     tokens: runUsage.promptTokens + runUsage.completionTokens)))
        if outcome != .stopped || UIApplication.shared.applicationState == .active { openReview(run: runID) }
        moodReset?.cancel()
        moodReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, self?.agent.running == false else { return }
            self?.runMood = nil
        }
    }

    func agentFinished() {
        ended()
        if let last = agent.steps.last { say("finished: \(last["action"]?.str ?? "") \(last["reason"]?.str ?? last["answer"]?.str ?? "")") }
        Task { try? await feed.stream(false); prewarmStream() }  // back on only if the app is open
        endBackgroundTask()
    }

    func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        backgroundTask = .invalid
    }

    // MARK: - review

    func outcome(for run: Run) -> Outcome {
        run.outcome(isActive: run.id == runID && (startingAgent || agent.running))
    }

    /// Opens the review editor for a run (with its intent, if it ran one).
    func openReview(run id: String) {
        runs.reload()
        guard let run = runs.run(id) else { return }
        let intent = intents.items.first { $0.refRun == id || $0.runs.contains { $0.run == id } }
        review = ReviewDraft(run: run, intent: intent)
    }

    /// The model rewrites the prompt and checklist from the trace and the user's corrections.
    func optimize(_ draft: ReviewDraft) async throws -> (prompt: String, hints: [String]) {
        if MockMode.on {
            try await Task.sleep(nanoseconds: 1_400_000_000)
            return (String(localized: "Open Clock › Alarms, tap +, type 0700 for the time, set Repeat to every day, then tap Save"),
                    [String(localized: "Type the time instead of scrolling the wheel"),
                     String(localized: "The + button is at the top right of Alarms"),
                     String(localized: "Check all seven days under Repeat, then tap Back")])
        }
        let reply = try await settings.client("planner").chat(system: ReviewDraft.optimizerPrompt,
                                                              text: draft.optimizerInput(), image: nil,
                                                              maxTokens: 800, temperature: 0.2)
        guard let result = ReviewDraft.parseOptimized(reply.text) else {
            throw LLMError(message: String(localized: "The model gave no improved prompt."))
        }
        return result
    }

    // MARK: - needs your help

    /// The agent is stuck, or asks before a risky step: pause, tell the user (Live Activity + a notification
    /// whose buttons answer it) and wait for their choice.
    func needsHelp(_ reason: String, confirm: Bool = false) async -> AgentLoop.HelpChoice {
        help = reason.isEmpty ? String(localized: "I'm stuck on this step.") : reason
        runMood = confirm ? .listening : .failure
        let line = confirm ? String(localized: "OK to do this? \(help ?? "")") : String(localized: "Needs your help: \(help ?? "")")
        live.update(mood: runMood ?? .failure, step: moveCount, line: line, phase: .help, status: confirm ? .confirm : .help)
        if confirm {
            notifier.post(.confirm, title: String(localized: "OK to go on?"),
                          body: String(localized: "\(help ?? "") Press and hold for Continue, Skip or Stop."), run: runID)
        } else {
            notifier.post(.help, title: String(localized: "Needs your help"),
                          body: String(localized: "\(help ?? "") Press and hold for Take Over, Skip or Stop."), run: runID)
        }
        return await withCheckedContinuation { helpWait = $0 }
    }

    func answerHelp(_ choice: AgentLoop.HelpChoice) {
        guard let wait = helpWait else { return }
        resumeAsked = now()  // Continue tapped in this app: the run sends it away before looking again
        helpWait = nil
        help = nil
        takingOver = false
        notifier.clearHelp()
        runMood = choice == .stop ? .idle : .thinking
        live.update(mood: runMood ?? .thinking, step: moveCount, line: String(localized: "Going on from here…"), phase: .running,
                    status: .looking)
        wait.resume(returning: choice)
    }

    /// The user does the step by hand, then taps Continue.
    func takeOver() {
        guard help != nil else { return }
        takingOver = true
        live.update(mood: .listening, step: moveCount, line: String(localized: "Your turn. Tap Continue when you're done."),
                    phase: .help, status: .yourTurn)
        notifier.post(.takeover, title: String(localized: "Your turn"),
                      body: String(localized: "Do the step yourself, then tap Continue."), run: runID)
    }

    /// Live Activity buttons.
    func control(_ command: AgentCommand) async {
        switch command {
        case .stop: await stopAgent()
        case .resume: answerHelp(.resume)
        case .skip: answerHelp(.skip)
        case .takeOver: takeOver()
        case .stopRecording: await recorder.stop()
        case .pause: pause()
        case .unpause: unpause()
        }
    }

    /// Notification actions; tapping the notification itself opens the review.
    func notificationAction(_ action: Notifier.Action?, run: String, kind: Notifier.Kind? = nil) {
        if action == .report || (action == nil && kind == .trouble) {
            review = nil  // the confirmation sits on the root view
            askDiagnostics = true
            return
        }
        switch action {
        case .stop?: Task { await stopAgent() }
        case .resume?: answerHelp(.resume)
        case .skip?: answerHelp(.skip)
        case .takeOver?: takeOver()
        case .retry?: Task { await self.run(lastTask, intent: currentIntent) }
        case .report?: break  // handled above
        case .review?, nil:
            if agent.running { tab = .agent } else if !run.hasPrefix("rec-") && review == nil { openReview(run: run) }
        }
    }

    // MARK: - recording the run

    /// Saves the mirror stream at ~2 fps into the run folder (video/<ms>.jpg), for the review's video view.
    private func startVideo() {
        guard let dir = traces.dir?.appendingPathComponent("video") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        videoDir = dir
        videoSink = feed.$frame.compactMap { $0 }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] jpeg in self?.saveVideoFrame(jpeg) }
    }

    /// Each frame is written at once, so a run that stops or fails early still has its video.
    func saveVideoFrame(_ jpeg: Data?) {
        guard let jpeg, let dir = videoDir else { return }
        try? jpeg.write(to: dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jpg"))
    }

    /// The built-in "Send diagnostics" intent: no board, model or free line slot needed.
    private func sendDiagnostics() async {
        guard Trial.available else { notice = String(localized: "Diagnostics can't be sent from this build."); return }
        startingAgent = true
        defer { startingAgent = false }
        notice = await DiagnosticReport.send(self)
    }
}

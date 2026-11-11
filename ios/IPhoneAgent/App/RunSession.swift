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
        var task = task, resume = false
        if ChatContext.isContinue(task), let last = threads.current.turns.last {  // "continue": the last task, from where it stopped
            task = last.ask
            resume = canResume && agent.task == task  // its plan and steps are still here: go on from its screen
        }
        lastTask = task
        agent.chatContext = ChatContext.render(threads.current.turns)
        agent.hints = intent?.checklist ?? []
        agent.replay = intent.map(Replay.init(intent:)) ?? Replay()
        if !agent.replay.steps.isEmpty { DebugLog.write("replay: \(agent.replay.steps.count) recorded steps") }
        await startAgent(task, resume: resume)
    }

    /// Own the startup task for every entry point, including shortcuts and consent/recovery retries.
    /// resume: the stopped run goes on (see RunResume.swift).
    func startAgent(_ task: String, resume: Bool = false) async {
        guard !startingAgent, !agent.running else { return }
        startingAgent = true
        handoffStop = AsyncStream<Void>.makeStream()
        runUsage = ModelUsage()  // a failed start counts its keyboard check too
        tab = .agent
        startupBoardIssue = false
        lastRunDoing = nil
        startupDeadline = now() + Recovery.limit
        homeHint = String(localized: "Preparing the run…")
        RunMarker.set("startup")
        defer {
            if !agent.running { RunMarker.clear() }
            startingAgent = false
            departing = false
            homeHint = nil
            startupTask = nil
            if !agent.running {
                recovering = nil
                notifier.clearLinkAsks()
            }
        }
        let job = Task {
            var usedInput = false
            await prepareAgent(task, resume: resume, usedInput: &usedInput)
            // Startup can exit after calibration but before opening a trace for this run.
            if usedInput { await returnInput(checkKeyboard: false, traceStarted: false) }
        }
        startupTask = job
        await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
    }

    /// Start couldn't go ahead: log it and say so over Home (the Start button shakes).
    private func blocked(_ text: String) {
        say(text)
        Haptics.failure()
        toast = Toast(text: text)
    }

    private func prepareAgent(_ task: String, resume: Bool, usedInput: inout Bool) async {
        if MockMode.on {
            // Demo data sends nothing, but a run still asks first when a model is set up: the demo shows the
            // same consent a real run opens.
            let pending = settings.pendingConsent
            if settings.isConfigured, pending.model || pending.jev { aiConsentRun = task; return }
            return mockRun(task)
        }
        guard !Task.isCancelled else { return }
        guard settings.isConfigured else {
            Analytics.capture("run_blocked", ["reason": "model_not_set"])
            blocked(String(localized: "Set up the model in Settings first."))
            return
        }
        runModelRevision = settings.configurationRevision
        let pending = settings.pendingConsent
        guard !pending.model, !pending.jev else {
            Analytics.capture("run_blocked", ["reason": "ai_consent"])
            aiConsentRun = task
            return
        }
        // The board has power but no USB host (a charger, a power bank, a hub): nothing it sends reaches this
        // iPhone. Say so now, not after the leave-app gestures fail.
        if board.connected, board.status?.usb == "off" {
            try? await board.refreshStatus()  // the last status may be older than the plug
            if board.connected, board.status?.usb == "off" {
                Analytics.capture("run_blocked", ["reason": "usb_off"])
                blocked(String(localized: "The board has power, but it isn't plugged into this iPhone. Plug it into this iPhone's USB-C port and try again."))
                return
            }
        }
        usedInput = calibrator.busy || (!pointer.calibrated && calibrator.boardReady)
        guard await calibrator.ensureCalibrated() else {
            Analytics.capture("run_blocked", ["reason": "not_calibrated"])
            blocked(String(localized: "The pointer isn't calibrated yet."))
            return
        }
        guard !Task.isCancelled else { return }
        do {
            if settings.provider == .handsyTrial { try await Trial.shared.precheck() }  // free line: open? (lease later)
            let actor = try await settings.client("actor")
            let jev = settings.jevActor(around: actor)  // Jev on, asked from the app
            if jev != nil, !JevConfig.ownActive { _ = try? await Trial.shared.jevTicket() }  // fetch it now, not inside the first step
            agent.actor = jev ?? actor
            agent.planner = try await settings.client("planner")
            agent.checkpointModel = try await settings.checkpointClient()
            agent.screenTree = settings.provider == .handsyTrial || jev != nil  // the tree also helps the model
            agent.serverTree = jev == nil && Settings.serverTree(settings.provider)
            agent.compactTree = settings.provider == .handsyTrial && TreeSource.current == .device  // Debug only
            if settings.provider == .handsyTrial { DebugLog.write("tree source: \(agent.serverTree ? "server" : "device")") }
        } catch is CancellationError {
            return  // Cancel while waiting for the free line
        } catch {
            Analytics.capture("run_blocked", ["reason": "model_client"])
            say("LLM: \(error.localizedDescription)")
            if (error as? TrialError)?.ownText == true { blocked(error.localizedDescription) }
            else if settings.provider == .handsyTrial { blocked(TrialError.busy.localizedDescription) }  // the line's side
            else { blocked(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }
        // Start is tapped in this app, so: Live Activity, go Home, let the screen settle, THEN the first
        // frame for the planner. Each sub-step is timed in the log.
        let t0 = now()
        func mark(_ what: String) { DebugLog.write(String(format: "start: %@ (+%.0f ms)", what, (now() - t0) * 1000)) }
        // the run folder exists from here: a failed start keeps its log and video. A resumed run goes on in its own.
        if !(resume && traces.dir != nil) { traces.start(task: task) }
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
            try Task.checkCancellation()
            usedInput = true
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
            let away = try await (resume ? waitForSwitchBack() : leaveForRun())
            try Task.checkCancellation()
            guard away else {  // never let the agent start on its own app
                throw DeviceError(message: String(localized: "\(AppName.current) is still on screen"))
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
            if settings.provider == .handsyTrial {  // free line: the lease only now, with everything ready for the first call
                try await Trial.shared.begin(wait: Recovery.limit) { self.live.show(.waiting, mood: .thinking) }
                try Task.checkCancellation()
                mark(Trial.shared.keyed ? "Handsy key run (no lease)" : "free line lease")
            }
            try agent.start(task, traceStarted: true, resume: resume)
            RunMarker.set("running")
            usedInput = false  // The running agent now owns cleanup.
            mark("agent started")
            say("started: \(task)")
            began(task, early: true)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if usedInput {  // before the lease ends: the keyboard check may still ask the model
                await returnInput(checkKeyboard: appIsBackgrounded)
                usedInput = false
            }
            Trial.shared.end(RunEnd(reason: cancelled ? .userStop : .startFailed, stage: .startup,
                                    firmware: board.status?.fw?.description))  // free line
            Analytics.capture("run_ended", runUsage.props.merging([
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
            await Task { try? await self.feed.stream(false) }.value
            prewarmStream()
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

    /// Wait for whichever task owns input to finish cleanup ("Stopping…" until then).
    func stopAgent() async {
        stopping = true
        defer { stopping = false }
        handoffStop.continuation.finish()
        let startup = startupTask
        startup?.cancel()
        if startingAgent && calibrator.busy { calibrator.cancel(releasePointer: false) }
        answerHelp(.stop)
        mockJob?.cancel()
        let owned = startup != nil || agent.running  // that owner's cleanup returns input
        agent.stop()
        await agent.waitUntilStopped()
        await startup?.value
        if !owned && board.connected && !MockMode.on {  // nothing owned input (calibration, harness): release here
            do { try await pointer.reset() } catch { say("release failed: \(error.localizedDescription)") }
        }
    }

    /// Return input to the user while preserving the plan, steps, and notebook for resume.
    func returnInput(checkKeyboard: Bool, traceStarted: Bool = true) async {
        guard !MockMode.on else { return }
        returningInput = true
        defer { returningInput = false }
        let deadline = ContinuousClock.now + .seconds(30)
        let link = board.commands.links
        let handoff = InputHandoff(device: board.commands, checkKeyboard: checkKeyboard,
                                   userCancelled: { self.stopping || !self.settings.restoreKeyboardAfterRun },
                                   log: { self.say($0) },
                                   trace: traceStarted ? { self.traces.write(kind: "handoff", $0) } : nil)
        let result = await handoff.run {
            guard self.appIsBackgrounded && self.settings.restoreKeyboardAfterRun else { return }
            guard self.board.connected, self.board.commands.links == link else { throw DeviceError(message: "board reconnected") }
            try await KeyboardHandoff.finish(by: deadline, stop: self.handoffStop.stream) {
                try await KeyboardHandoff.restore(device: self.board.commands, screen: self.feed, model: self.agent.actor,
                                                  enabled: { self.settings.restoreKeyboardAfterRun },
                                                  stillInTargetApp: {
                    self.appIsBackgrounded && self.runModelRevision == self.settings.configurationRevision
                        && !self.settings.pendingConsent.model
                }, onCall: { self.modelCalled($0) }) {
                    _ = try await self.feed.currentFrame(maxAge: 0)
                }
            }
        }
        if let message = result.release?.notice(on: link, lastShown: &lastPartialReleaseNoticeLink) { notice = message }
        if let message = result.notice { notice = message }
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
        RunMarker.clear()
        Trial.shared.end(RunEnd(steps: agent.steps, moves: moveCount, calls: runUsage.calls,
                                firmware: board.status?.fw?.description))  // free line
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
        DebugLog.write("run usage: \(runUsage.summaryLine)")
        runMood = outcome.mood
        live.end((outcome.mood, last.map(StepText.line) ?? ""), asksVerdict: outcome == .done)
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
            learnIntent(intent, run: runID, steps: agent.steps, done: outcome == .done)
        }
        threads.append(ChatTurn(ask: agent.task, run: runID, outcome: last?["action"]?.str ?? "stopped",
                                answer: last?["answer"]?.str ?? last?["reason"]?.str ?? "",
                                items: agent.notebook.items,
                                summary: outcome == .done ? "" : ChatContext.stopSummary(steps: agent.steps, plan: agent.plan,
                                                                                         notebook: agent.notebook),
                                stats: Run.statsText(steps: moveCount, seconds: seconds, calls: runUsage.calls,
                                                     tokens: runUsage.tokens)))
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
        prewarmStream()
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
        let worded = [TouchCheck.reason: TouchCheck.advice, NoProgress.reason: NoProgress.advice]
        let shown = worded[reason] ?? help ?? ""  // the panel words it from the reason
        let line = confirm ? String(localized: "OK to do this? \(shown)") : String(localized: "Needs your help: \(shown)")
        live.update(mood: runMood ?? .failure, step: moveCount, line: line, phase: .help, status: confirm ? .confirm : .help)
        if confirm {
            notifier.post(.confirm, title: String(localized: "OK to go on?"),
                          body: String(localized: "\(shown) Press and hold for Continue, Skip or Stop."), run: runID)
        } else {
            notifier.post(.help, title: String(localized: "Needs your help"),
                          body: String(localized: "\(shown) Press and hold for Take Over, Skip or Stop."), run: runID)
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
    /// While paused the person has the phone; those frames are not part of the run.
    func saveVideoFrame(_ jpeg: Data?) {
        guard !paused else { return }
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

import Foundation

/// What AgentLoop does on the phone (Pointer, or a fake in tests).
@MainActor protocol Gestures: AnyObject {
    var device: HIDDevice { get }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws
    func drag(_ points: [CGPoint], hold: Bool) async throws
    /// nil: all of it went in; else what did not (Pointer.type).
    func type(_ text: String) async throws -> String?
    /// `type`, with what is left to paste when the pinyin keyboard could not give a word (HanTyper.Stop.rest).
    func typeStop(_ text: String) async throws -> HanTyper.Stop?
    func key(_ combo: String) async throws
    func clearField() async throws -> String?  // nil: the focused field is empty (FieldClearer)
    /// again: the previous step was Home too and changed little (Pointer.goHome).
    func goHome(again: Bool) async throws
    /// The Home key alone, never a flick after it.
    func homeKey() async throws
    func openApp(_ name: String) async throws -> OpenResult
    func goBack() async throws
    func reset() async throws
    /// Where the pointer really is after a tap that changed nothing (pixels only, learned for later taps).
    func landing(_ x: Double, _ y: Double) async -> CGPoint?
    /// Whether the pointer shows on screen at all (TouchCheck); nil = can't tell.
    func pointerSeen(near p: CGPoint) async -> Bool?
}

extension Pointer: Gestures {}

extension Gestures {
    func landing(_ x: Double, _ y: Double) async -> CGPoint? { nil }  // fakes and boards that can't see the pointer
    func pointerSeen(near p: CGPoint) async -> Bool? { nil }
    func homeKey() async throws { try await goHome(again: false) }  // fakes
    func typeStop(_ text: String) async throws -> HanTyper.Stop? { try await type(text).map { .init(note: $0) } }  // fakes
}

/// See-think-act loop, one model call per step, like a coding agent's CLI loop: the model sees the goal, its own
/// plan, what each recent action did and the screen; it keeps the plan up to date (PLAN:) and says when it is done.
@MainActor final class AgentLoop: ObservableObject {
    struct Planned {
        var act: JObject
        var shot: Data?  // every action of one reply is drawn on the same screenshot
        /// The reply was started before this step, from a nearly settled frame. Checked again before the gesture.
        var speculative = false
    }

    let phone: Gestures?
    let screen: ScreenSource?
    var actor: ChatModel?, planner: ChatModel?
    var checkpointModel: ChatModel?, checkpoints = Checkpoints()  // some rounds go to the planner (AgentLoop+Checkpoint)
    /// Copies the plan's RECORD fields off each screen in the background (Recorder.swift); no Jev, no tree headers.
    var reader: ChatModel?, recorder = RecorderState()
    let trace: TraceStore?
    /// maxSteps is only a safety cap (a Duolingo lesson is ~80 rounds; 40 cut it in half, 2026-11-06). A run that
    /// is stuck stops sooner: `maxStalls` rounds in a row that changed nothing on screen. Either way the user is asked.
    let maxSteps: Int, maxFailures: Int, maxStalls: Int
    var metrics: Metrics?

    @Published var task = ""
    @Published var plan = ""
    @Published var steps: [JObject] = []
    @Published private(set) var shots: [Int: Data] = [:]  // step index -> screenshot the model decided on
    @Published private(set) var running = false
    var pointerAt = CGPoint.zero  // last pointer position (screen fractions)
    var touchCheck = TouchCheck()  // gestures acknowledged by the board but not reaching the iPhone
    var progress = NoProgress()  // the same action repeated while the screen stays much the same
    /// When the last gesture ended: the model never decides on a frame from before it.
    var lastActed = 0.0
    /// Awaited before every look and every gesture (the app holds the run while its own UI is in front).
    var gate: (() async throws -> Void)?
    /// True while `pausedBeforeGesture` is inside `gate`. A pause during a look (no gesture chosen yet) does not
    /// set it, so Continue still runs the action decided from the screen after the pause.
    var droppingChosenGesture = false
    var chosenGestureDropped = false
    /// The last round sent nothing because the person paused: it says nothing about the screen.
    var roundDroppedByPause = false
    /// Ceilings, not budgets: tokens cost only when written. Henry 2026-11-19: the actor's 1000 cut every README
    /// write of a 25-order run (11 retries, never finished). A reply still cut at its ceiling is asked once more
    /// with `cutRetryTokens` (the gateway lowers anything above its own ceiling, never refuses it).
    static let maxTokens = ["planner": 8000, "actor": 8000, "reader": 8000]
    static let cutRetryTokens = 16_000
    private var job: Task<Void, Never>?
    var beforeFinish: (() async -> Void)?
    var onFinish: (() -> Void)?
    /// Paused for the board to come back (a line for the UI), or nil when going on.
    /// Recovery from a lost link: the link state (from the app), each stage as it changes (nil = live again),
    /// and what to redo once live (stream on, fresh frame, release, re-home).
    var link: (() -> Recovery.Link)?
    /// What the phone played lately (AudioFeed.heard), "" when silent: one more observation in each step's prompt.
    var heard: (() -> String)?
    var onRecover: ((Recovery.Stage?) -> Void)?
    var restore: (() async throws -> Void)?
    var recoveryLimit = Recovery.limit
    var onStep: (() -> Void)?
    /// What the agent is busy with between steps, for the Dynamic Island (looking, thinking, about to act).
    var onDoing: ((Doing) -> Void)?
    /// Every model request, answered or failed (timing and token counts, for usage stats).
    var onModelCall: ((ModelCall) -> Void)?
    enum Doing { case looking, waiting, planning, thinking, retrying, wrapping, acting(JObject) }
    static let slowAnswer = 8.0  // seconds with no token before the island says Wait
    /// Hints from a saved intent's checklist, appended to the actor's system prompt (empty = the original prompt).
    var hints: [String] = []
    var inventory = Inventory()  // a task over many items: list, confirm, then act (AgentLoop+Inventory)
    var eachChecked = Set<String>()  // each orders whose first item the model has checked (AgentLoop+Each)
    var eachDone = Set<String>()  // cards each has already opened this run
    var cache = ActionCache()  // taps that follow the same tap each time, done by code (ActionCache)
    var cachedSteps = 0
    var typeStats = TypeStats()  // pinyin stops and paste fallbacks this run, for run_ended
    var steering: [String] = []  // words the user added while the run goes, for the next round (AgentLoop+Steer)
    /// A saved intent's recorded steps, done without the model while the screen matches (Replay).
    var replay = Replay()
    /// What this run collected (read / note / progress), shown to the actor every step (AgentLoop+Memory).
    @Published var notebook = Notebook()
    /// Long-term memory (nil in tests that don't use it); the entries recalled for this task go in the prompts.
    var memory: MemoryStore?
    private(set) var recalled: [MemoryEntry] = []
    /// Earlier turns of the chat this run belongs to (ChatContext), for planner and actor.
    var chatContext = ""
    /// The Dynamic Island's touch area in 0-1000 units (IslandGuard.zone), nil = none on this iPhone.
    var island: () -> CGRect? = { nil }
    /// The run starts on the Home Screen (RunSession left for it): `open` the app a task names, hold Home swipes.
    var startsOnHome = false
    /// Enter after typing (Wiki #1007 N2/N7), not tied to any app: see SendGuard.
    var sendGuard = SendGuard()
    /// The app the run's start opened by its URL scheme (RunSession): autoOpen only records it.
    var openedAtStart: String?
    /// A script's part is running (ScriptRunner.subGoal): its done needs no planner check, the script goes on.
    var inPart = false
    /// Lessons the actor offered (learn); kept only when the run ends with done.
    var learned: [String] = []
    /// Tool answers this run ("Looked up", newest last) and the tools it may call (fixed at the start: same prompt).
    var lookedUp: [String] = []
    var fileView: String?  // the last long `file` result (a listing, a file's text), for the next round only
    var viewedSinceWrite: Set<String> = []  // paths `file view` read since the run last wrote a file
    var resultWritten = false  // a `file` write that worked this run (the README, a table)
    var autoResult: (path: String, text: String)?  // the result the app saved from the notebook (saveListResult)
    /// A saved plan for this run (PlanCache), set before start: the first round goes to the actor with it.
    var cachedPlan: String?
    private(set) var usedCachedPlan = false
    /// The plan the planner wrote in the run's first round (or the cached one used): what PlanCache keeps.
    var firstPlan: String?
    var handedBack = false  // everything collected: the phone is the user's again, the result is written without it
    var handBackRounds = 0
    var onHandBack: (() async -> Void)?  // the app lets go of the phone (pointer, island)
    var tools: [ToolSpec] = []
    /// Apps with a guide on the server (set before start: same system prompt all run) and the guides loaded.
    var guides: [AppGuide] = []
    var guided: [AppGuide] = []
    var pageFrames: [Data] = []  // the screens of the page on screen, since it opened (NoteCheck)
    /// When this run (not a resume of it) started, and the result folders there were then (MemoryFiles).
    var filesSince = Date()
    /// Spots (0-1000) where a tap of this run opened the AssistiveTouch menu (AssistiveTouchGuard).
    var assistiveHits: [CGPoint] = []
    var resultsAtStart = ""
    /// The run's notes on disk as they are made (LiveNotes); `resultName` names their folder (the intent's name).
    var liveNotes = LiveNotes()
    var resultName: String?
    var runFolder: String?  // where this run's results go (RunFolder), fixed at its start
    var scrollGain = 1.0  // how far this phone's lists glide past a swipe (ScrollMeter), 1 = not at all
    var foldersAtStart: Set<String> = []  // top-level folders there were then
    /// RateLimit: the background read of the last round's screen, the lines it read, and a hit that stops the run.
    var limitCheck: Task<(Data, [DemoAnalysis.Line], String?), Never>?
    var limitFrame: Data?
    var limitLines: [DemoAnalysis.Line] = []
    var limitHit: String?
    /// Puts text on the clipboard for `write` (the app hops to the front to do it). True = ready to paste.
    var onWrite: ((String) async throws -> Bool)?
    /// The text put on the clipboard at the run's start (ClipboardCarry), and the clipboard's changeCount now.
    var carried: ClipboardCarry?
    var clipboardCount: (() -> Int)?
    /// "Needs your help": asked when the actor gives up or errors repeat; nil = end the run as before.
    var onHelp: ((String) async -> HelpChoice)?
    /// The words for the user while help is asked, when the reason is only for the record (errorsReason).
    private(set) var helpMessage: String?
    private var helpAsked = 0
    /// Connection revision of the accepted/restored look; a reconnect invalidates its actions.
    var acceptedLookLinks: Int?
    /// iPad: the screen's orientation and shape when the accepted look was taken (nil on iPhone). A rotation since
    /// then puts its coordinates somewhere else, so its actions are dropped and the model looks again.
    var acceptedLookGeometry: ScreenGeometry?
    private enum InvalidatedLook: Error { case connectionChanged, geometryChanged }
    enum HelpChoice: Equatable { case resume, skip, stop, restart }
    /// Attended unless the run was started with the setting or the shortcut parameter.
    var policy = RunPolicy.attended {
        didSet { recoveryLimit = policy.recoveryLimit }
    }
    /// Unattended restarts already used this run (Home Screen, then the task again).
    var restarts = 0
    /// Set when an unattended attempt starts over, so the next look knows to reopen the app.
    var restartNote = ""
    /// Resumes a help card that `chooseHelp` has given up waiting on (the app clears the banner).
    var onHelpTimeout: ((HelpChoice) -> Void)?
    /// True while this app is the one on screen. Mirroring repair stops instead of fighting the person.
    var userInFront: () -> Bool = { false }
    /// Start the next model look once the screen is nearly settled. Off unless Settings turns it on.
    var speculate = false
    let framePrep = FramePrep()
    var pendingLook: PendingLook?
    struct LookClock { var imageMs = 0.0, treeMs = 0.0, firstTokenMs = 0.0, firstDoMs = 0.0, streamEndMs = 0.0 }
    var lookClock = LookClock()
    var verdictSpent = 0.0, landingSpent = 0.0
    var specUsed = false, specCancelled = false
    private var lastStepEnded = 0.0
    private var timingIndex = 0
    var deviceHealth: () -> DeviceHealth.Snapshot = { .ok }
    var onNotice: ((String, Notifier.Kind) -> Void)?
    private var lowPowerNoted = false
    private var batteryWarned = false
    private var powerHeld = false
    var mirrorPart: Recovery.Part?
    var mirrorPartSince = 0.0
    var mirrorAttempts = 0
    var mirrorBackoffUntil = 0.0
    var mirrorSuspicious = false
    /// The run's own reasons to ask (the help panel words them for people).
    static let stepLimitReason = "step limit reached", stallReason = "the screen did not change"
    /// The end of a fail step's reason after `maxFailures` failed rounds ("3 errors in a row"): the run's record,
    /// RunPolicy and Trial match it; the user reads ModelRequestFailure.streakMessage.
    static let errorsReason = "errors in a row"
    /// Before a risky step (paying, sending, deleting, account settings) the actor asks; nil or the setting
    /// off = it goes on by itself. Continue = do it, Skip = don't, Stop = end the run.
    var onConfirm: ((String) async -> HelpChoice)?
    static let askBeforeRiskyKey = "askBeforeRisky"
    var askMode: AskMode?  // nil = the stored setting
    /// Free line: the actor sees the screen's element list (UITree, built here) and may answer `tap #ID`.
    var screenTree = false
    /// The free line: Spark builds the tree of the sent frame and lists it; the reply brings it back for `tap #ID`.
    var serverTree = false
    /// The free line with Tree source › On-device (Debug): the phone's tree in Spark's compact listing and numbering.
    var compactTree = false
    /// The last tree sent and its frame, for ScreenDiff; `screenDiff` is what changed from the tree before it.
    var lastTreeTexts: [String]?, lastTreeFrame: Data?, screenDiff: String?
    var lookTree: UITree?, lookFrame: Data?  // the actor's last look and its frame: its OCR, read once (lookLines)
    var shotLines: (shot: Data, lines: [DemoAnalysis.Line])?
    var seenLines = SeenLines(), recordAudits = 0  // RecordAudit
    var readPastStart = false  // the last screen read: its dated items all before the goal's dates
    var treeWait = FramePrep.treeWait  // a look waits this long for the on-device tree (tests on a slow runner: longer)
    /// Trees late in a row this run. A slow phone (iPhone X: OCR 3.4-7 s) never has it in time: each look waited
    /// 1.2 s for nothing and the OCR held the CPU (2026-11-23, 6 of 6 looks late); from `FramePrep.lateLimit` on, none is built.
    var treesLate = 0
    var wantsTree: Bool { screenTree && !serverTree && treesLate < FramePrep.lateLimit }
    var listRead = false, backChecked = false  // the list read past the goal's dates; a scroll back up was refused once
    /// Who answered the last request (servedModel, e.g. "handsy-jev" when Jev took the step).
    var lastServed: String?

    init(phone: Gestures?, screen: ScreenSource?, actor: ChatModel?, planner: ChatModel?, trace: TraceStore?,
         maxSteps: Int = 300, maxFailures: Int = 3, maxStalls: Int = 12) {
        self.phone = phone; self.screen = screen; self.actor = actor; self.planner = planner
        self.trace = trace; self.maxSteps = maxSteps; self.maxFailures = maxFailures; self.maxStalls = maxStalls
    }

    /// traceStarted: the caller already opened the run's trace folder (so a failed start is logged too).
    /// resume: go on with the stopped run of this task (its plan, steps and notes) from the screen in front now.
    func start(_ task: String, traceStarted: Bool = false, resume: Bool = false) throws {
        if running { throw DeviceError(message: "agent already running") }
        guard screen?.live == true else { throw DeviceError(message: "no phone screen: start Screen Mirroring first") }
        let resuming = resume && task == self.task && !steps.isEmpty
        JevGate.hold = false
        if !resuming {
            self.task = task; plan = ""; steps = []; shots = [:]
            recorder.task?.cancel(); recorder = RecorderState()
            notebook = Notebook(); learned = []; lookedUp = []; fileView = nil; viewedSinceWrite = []; resultWritten = false; autoResult = nil; handedBack = false; handBackRounds = 0; guided = []; listRead = false; backChecked = false
            filesSince = Date(); resultsAtStart = MemoryFiles.open().results(); assistiveHits = []; liveNotes = LiveNotes()
            runFolder = nil; foldersAtStart = []  // a new task gets its own folder, not the last run's
            limitCheck = nil; limitFrame = nil; limitLines = []; limitHit = nil
            metrics?.runStarted()
        }
        StepReport.shared.clear()
        UITree.ocrCache.clear()  // a new run never reuses the last run's OCR
        InputSource.shared.reset()  // the user may have switched keyboards between runs
        recalled = memory?.recall(chatContext.isEmpty ? task : task + "\n" + chatContext) ?? []
        tools = ToolStore.shared.active
        DebugLog.write("tools: " + (tools.isEmpty ? "none" : tools.map(\.id).joined(separator: ", ")))  // the system prompt is not in the trace
        pointerAt = .zero
        (touchCheck, progress, checkpoints) = (TouchCheck(), NoProgress(), Checkpoints())
        steering = []
        if !resume { (cache, cachedSteps, eachChecked, eachDone, typeStats) = (ActionCache(), 0, [], [], TypeStats()) }
        (seenLines, recordAudits) = (SeenLines(), 0)
        inventory = Inventory(task: task, until: replay.until != nil)
        lastActed = 0
        helpAsked = 0
        restarts = 0
        restartNote = ""
        sendGuard = SendGuard()
        (mirrorPart, mirrorPartSince, mirrorAttempts, mirrorBackoffUntil, mirrorSuspicious) = (nil, 0, 0, 0, false)
        (lowPowerNoted, batteryWarned, powerHeld) = (false, false, false)
        droppingChosenGesture = false
        chosenGestureDropped = false
        acceptedLookLinks = nil
        acceptedLookGeometry = nil
        replay.restart()
        if !traceStarted { trace?.start(task: task) }
        trace?.write(kind: "policy", policy.trace)
        usedCachedPlan = false
        if !resuming { firstPlan = nil }
        if !resuming, let saved = cachedPlan, !saved.isEmpty {  // the planner's first round is skipped (PlanCache)
            plan = saved
            firstPlan = saved
            usedCachedPlan = true
            checkpoints.lastAt = 0
            record(nil, ["action": .str("plan"), "plan": .str(saved), "plan_zh": .str(saved), "cached": .bool(true)])
            DebugLog.write("plan: the intent's saved plan (\(saved.count) chars); no planner for the first round")
        }
        cachedPlan = nil
        if resuming { record(nil, ["action": .str("resumed"), "reason": .str("the run had stopped; it goes on from the screen in front now")]) }
        running = true
        job = Task { [weak self] in
            guard let self else { return }
            await run()
            // Stop cancels the run. Let cleanup finish before another run can start or resume.
            if let beforeFinish { await Task { await beforeFinish() }.value }
            running = false
            job = nil
            onFinish?()
        }
    }

    /// A run from Runs put back in memory so it can go on, also after a relaunch: its task, steps and last plan.
    /// The screenshots are not in the trace's steps; the notebook comes back from its last checkpoint row.
    func restore(task: String, steps: [JObject]) {
        guard !running else { return }
        self.task = task; self.steps = steps; shots = [:]
        plan = steps.last { $0["action"]?.str == "plan" }?["plan"]?.str ?? ""
        notebook = Self.savedNotebook(steps); learned = []
    }

    func stop() {
        pendingLook?.task.cancel()
        pendingLook = nil
        if let job { job.cancel() } else { running = false }  // a shown (demo) run has no job
    }

    func waitUntilStopped() async { await job?.value }

    func clear() throws {
        if running { throw DeviceError(message: "stop the agent first") }
        task = ""; plan = ""; steps = []; shots = [:]
        acceptedLookLinks = nil
        acceptedLookGeometry = nil
    }

    /// One action as the debug log shows it: the action without bookkeeping, and what came of it (2026-11-17: the
    /// log had each step's timings but not what the step did; that was only in the trace on the phone).
    nonisolated static func logLine(_ step: JObject) -> String? {
        guard let name = step["action"]?.str, name != "plan" else { return nil }
        let shown = Actions.key(step).without(["action", "result", "reason", "opened", "timing", "planner", "cached", "plan_zh"])
        let args = shown.keys.map { k in "\(k)=\(String(PyJSON.dumps(shown[k]!, ascii: false).prefix(60)))" }.joined(separator: " ")
        let outcome = [step["opened"]?.str, step["result"]?.str, step["reason"]?.str].compactMap { $0 }.first.map { " -> " + $0.prefix(120) } ?? ""
        return "\(name) \(args)" + outcome
    }

    func record(_ shot: Data? = nil, _ step: JObject) {
        if let shot { shots[steps.count] = shot }
        steps.append(JObject([("t", .num(now())), ("shot", .bool(shot != nil))]).merging(step))
        trace?.write(kind: "step", step)
        if let line = Self.logLine(step) { DebugLog.write("step \(steps.count): \(line)") }  // what was done, beside the timings
        let listed = now()
        onStep?()
        StepWaits.record += now() - listed  // measured: the steps list reloads on the main thread (2026-11-11)
    }

    /// The board or mirroring went away mid-run: pause ("waiting for the board") until the screen is live
    /// again, up to `reconnectWait` s, instead of failing the run.
    /// The screen is gone (board, hotspot or mirroring lost): pause the run until it is back, in stages.
    /// Returns how many seconds it took, or nil if the screen was there all along. Never ends the run for a
    /// lost link before Recovery.limit.
    func waitForScreen(poll: Double = 0.5, forceRestore: Bool = false,
                       deadline: Double? = nil) async throws -> Double? {
        guard let screen, forceRestore || !screen.live || link?().inputGone == true else { return nil }
        let deadline = deadline ?? now() + recoveryLimit
        var recovery = Recovery(at: now(), limit: max(0, deadline - now()))
        var shown: Recovery.Stage?
        defer { if shown != nil { onRecover?(nil) } }
        while true {
            try Task.checkCancellation()
            try screen.checkAvailability()
            guard now() < deadline else { throw BlindError(reason: Recovery.reason(shown?.part ?? .board, lan: shown?.lan ?? false)) }
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
                guard now() < deadline else { throw BlindError(reason: Recovery.reason(shown?.part ?? .board, lan: shown?.lan ?? false)) }
                guard !connectionChanged(since: restoringLinks) else { break }
                return now() - recovery.started
            case .live: break
            case .wait(let stage):
                if stage != shown { shown = stage; onRecover?(stage) }
                if stage.part != mirrorPart { mirrorPart = stage.part; mirrorPartSince = now() }
                await healMirroring(stage)
            case .giveUp(let reason):
                throw BlindError(reason: reason)
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1e9))
        }
    }

    func connectionChanged(since revision: Int?) -> Bool {
        guard let device = phone?.device else { return false }
        return !device.connected || link?().inputGone == true || revision.map { device.links != $0 } == true
    }

    /// iPad: the screen rotated or the mirrored shape changed since `revision` (never on iPhone: no geometry).
    private func geometryChanged(since revision: ScreenGeometry?) -> Bool {
        guard let revision else { return false }
        return !revision.matches(screen?.geometry)
    }

    func ask(_ role: String, _ llm: ChatModel, _ system: String, _ prompt: String,
                     temperature: Double = 0, retryTimeout: Bool = true,
                     reconnectUntil: Double? = nil, budget: Int? = nil) async throws -> (String, Double, Data?) {
        var prompt = prompt
        var reconnectDeadline = reconnectUntil
        var turned = 0  // iPad: replies dropped for a rotation in this ask (never on iPhone)
        if handedBack { return try await askWithoutScreen(role, llm, system, prompt, temperature: temperature, budget: budget) }
        while true {
            try await gate?()
            // a stale frame (the stream broke after the last action) is fetched again, never sent
            let forceRestore = connectionChanged(since: acceptedLookLinks) || screen?.stale == true
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
            var frame = screen.frame
            let frameAt = screen.capturedAt, started = now(), requestLinks = phone?.device.links
            let requestGeometry = screen.geometry
            let wantTree = role == "actor" && wantsTree
            // the frame prepared for this look when the screen has not changed since: its image and tree are
            // (being) built, a newer copy of the same screen would start them over (2026-11-18: 14 of 21 looks)
            if let now = frame, let prepared = framePrep.frame, prepared != now {
                let pointer = pointerAt
                if await !Vision.off({ Vision.changed(prepared, now, ignore: [pointer]) }) { frame = prepared }
            }
            var sent: Data?
            var tree: UITree?
            if let frame {
                framePrep.start(frame, wantTree: wantTree)  // nothing new when it is the prepared frame
                if let ready = await framePrep.take(frame, wantTree: wantTree, treeWait: treeWait), ready.image.count > 0 {
                    sent = ready.image
                    tree = ready.tree
                    lookClock.imageMs = ready.imageMs
                    lookClock.treeMs = ready.treeMs
                    if ready.treeLate {
                        treesLate += 1
                        DebugLog.write(String(format: "tree late: not built within %.1f s, the look goes without it", treeWait)
                                       + (wantsTree ? "" : "; no tree for the rest of the run (late \(treesLate) times in a row)"))
                    } else if let tree { treesLate = 0; DebugLog.write("step " + tree.timingLine) }
                }
            }
            if sent == nil {
                let imageStarted = now()
                sent = frame.map(ModelImage.forModel)  // the model's copy; the trace keeps the full frame
                lookClock.imageMs = (now() - imageStarted) * 1000
            }
            if role == "actor", screenTree {
                let ms = { (s: Double) in Int((s * 1000).rounded()) }
                StepWaits.tree = tree.map { "device total \(ms($0.totalSeconds)) ocr \(ms($0.ocrSeconds)) cv \(ms($0.cvSeconds))" }
                    ?? (serverTree ? "server" : "none")
            }
            // the same place and format as Spark's: appended to the user text, after the prompt
            if let tree, sent != lastTreeFrame {  // a retry or a second ask on the same frame keeps the line
                let texts = ScreenDiff.texts(tree)
                screenDiff = lastTreeTexts.flatMap { ScreenDiff.line(from: $0, to: texts) }
                (lastTreeTexts, lastTreeFrame) = (texts, sent)
            }
            if role == "actor" {
                (lookTree, lookFrame) = (tree, frame)
                if let tree, !recordFields.isEmpty { seenLines.add(tree.lines.map(\.text)) }
            }
            if role == "actor", let frame, let sent { offerToRecorder(full: frame, sent: sent) }
            let text = prompt + (tree == nil ? "" : screenDiff ?? "") + (tree.map { compactTree ? $0.compactListing : $0.listing } ?? "")
            // Henry 2026-11-18: Wait until the first token, then Think, flipped twice per call (68 times in one run).
            // Think from the start; Wait only when the line is slow to answer.
            let busy: Doing = role == "planner" ? .planning : .thinking
            onDoing?(retryTimeout ? busy : .retrying)
            let slow = retryTimeout ? Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(Self.slowAnswer * 1e9))
                self?.onDoing?(.waiting)
            } : nil
            let reporting = llm as? ModelProgressReporting
            reporting?.onProgress = { [weak self] progress in
                if progress == .receiving { slow?.cancel(); self?.onDoing?(busy) }
            }
            defer { reporting?.onProgress = nil; slow?.cancel() }
            let reply: ChatResult
            let maxTokens = budget ?? Self.maxTokens[role] ?? 8000
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
            if reply.finishReason == "length", maxTokens < Self.cutRetryTokens, !Task.isCancelled {
                DebugLog.write("model reply cut at \(maxTokens) tokens (\(role)); asking once more with \(Self.cutRetryTokens)")
                return try await ask(role, llm, system, prompt, temperature: temperature, retryTimeout: retryTimeout,
                                     reconnectUntil: reconnectDeadline, budget: Self.cutRetryTokens)
            }
            let seconds = ((now() - started) * 100).rounded() / 100
            if role == "actor" { StepWaits.replied = now() }
            metrics?.llm(first: reply.firstToken, total: reply.total)
            if role == "actor" { StepReport.shared.replied() }
            if role == "actor" {
                lookClock.firstTokenMs = (reply.firstToken ?? 0) * 1000
                lookClock.firstDoMs = (reply.firstDo ?? 0) * 1000
                lookClock.streamEndMs = reply.total * 1000
            }
            onModelCall?(ModelCall(role: role, model: llm.model, reply: reply, error: nil, imageKB: (sent?.count ?? 0) / 1024))
            let built = tree != nil
            if !built, role == "actor", serverTree, let data = reply.tree { tree = UITree(json: data) }
            // Spark and the compact listing number ids over all candidates (treetext.by_listing_id)
            let answer = tree?.resolve(reply.text, spark: !built || compactTree) ?? reply.text
            lastServed = reply.servedModel
            var rec: JObject = ["role": .str(role), "model": .str(llm.model), "prompt": .str(text),
                                "reply": .str(reply.text), "seconds": .num(seconds)]
            if let tree, !built {
                rec["tree"] = .str("spark")
                if answer != reply.text { rec["resolved"] = .str(answer) }
            } else if let tree {
                rec["tree"] = .str("device")
                rec["tree_ms"] = .num((tree.totalSeconds * 1000).rounded())  // wall clock: ocr and cv overlap
                if answer != reply.text { rec["resolved"] = .str(answer) }
            }
            if let first = reply.firstToken { rec["first_token_s"] = .num((first * 100).rounded() / 100) }
            if let firstDo = reply.firstDo { rec["first_do_s"] = .num((firstDo * 100).rounded() / 100) }
            // the sent frame's capture time, not the latest frame's (read after the reply, it hid stale frames)
            if lastActed > 0 { rec["frame_after_action_s"] = .num(((frameAt - lastActed) * 100).rounded() / 100) }
            trace?.write(frame, kind: "llm", rec.merging(reply.diagnostics))
            try Task.checkCancellation()
            if geometryChanged(since: requestGeometry) {
                turned += 1
                guard turned <= Self.turnRetries else { throw BlindError(reason: Self.turningReason) }
                DebugLog.write("model reply discarded (\(turned) of \(Self.turnRetries)): the screen rotated or the mirrored "
                               + "shape changed; looking again once it holds still")
                await steadyGeometry()
                continue
            }
            if connectionChanged(since: requestLinks) {
                DebugLog.write("model reply discarded: board connection changed; restoring the screen before another look")
                acceptedLookLinks = requestLinks
                if reconnectDeadline == nil { reconnectDeadline = now() + recoveryLimit }
                continue
            }
            acceptedLookLinks = requestLinks
            acceptedLookGeometry = requestGeometry
            return (answer, seconds, frame)
        }
    }

    func run() async {
        var failures = 0, stalls = 0, rounds = 0
        var cutOffs = 0  // of this streak's failures: model answers that timed out or were cut off
        var scripting = replay.current != nil  // a saved intent's steps first (ScriptRunner), then the model
        // the task's app guide is read from the server (up to 5 s) while the app opens, not after it (2026-11-25:
        // the wait from the line's lease to the first model call was 23 s for one run in ten)
        let guiding = Task { @MainActor in await self.guideAtStart() }
        defer { guiding.cancel() }
        do {
            if startsOnHome, !scripting, !steps.contains(where: { Actions.gestures.contains($0["action"]?.str ?? "") || $0["action"]?.str == "resumed" }),
               let app = AppNames.only(in: task) {
                do { try await autoOpen(app) } catch let e where !(e is CancellationError) && !Task.isCancelled && !(e is BlindError) {
                    DebugLog.write("auto open: \(e.localizedDescription); the model goes on")
                }
            }
            if foldersAtStart.isEmpty { foldersAtStart = RunFolder.folders() }
            if runFolder == nil {
                runFolder = RunFolder.from(steps) ?? LiveNotes.newFolder(resultName ?? task, since: filesSince, files: MemoryFiles.open(since: filesSince))
            }
            if let runFolder { liveNotes.use(runFolder, files: MemoryFiles.open()) }
            await guiding.value
            while true {
                try await holdForPower()
                rounds += 1
                if handedBack {
                    handBackRounds += 1
                    if handBackRounds > HandBack.rounds || failures >= 2 {
                        DebugLog.write("hand back: the write-up did not finish; the notes stand as the result")
                        record(nil, ["action": .str("done"), "answer": .str(""), "reason": .str("the notes are the result")])
                        return finish()
                    }
                }
                if rounds > stepLimit || stalls >= maxStalls {
                    let reason = stalls >= maxStalls ? "\(Self.stallReason) in \(stalls) steps" : Self.stepLimitReason
                    record(nil, ["action": .str("fail"), "reason": .str(reason)])
                    switch try await askForHelp() {
                    case .stop: return finish()
                    case .goOn: rounds = 0; stalls = 0
                    case .restart: rounds = 0; stalls = 0; failures = 0
                    }
                    continue
                }
                do {
                    if scripting {
                        switch try await scriptStep() {
                        case .next: continue
                        case .ended: return finish()
                        case .handOver: scripting = false
                        }
                    }
                    if try await step() {
                        guard steps.last?["action"]?.str == "fail" else { return finish() }
                        switch try await askForHelp() {
                        case .stop: return finish()
                        case .goOn: stalls = 0
                        case .restart: rounds = 0; stalls = 0; failures = 0
                        }
                        continue
                    }
                    failures = 0
                    modelBackoffs = 0
                    if roundDroppedByPause { continue }  // no gesture, no stall (the next look takes the flag)
                    stalls = steps.last?["changed"] == .bool(false) ? stalls + 1 : 0
                    if handedBack { continue }  // no screen to check or be stuck on
                    try await checkLink(unchanged: stalls)
                    if try await stuck() {
                        switch try await askForHelp() {
                        case .stop: return finish()
                        case .goOn: stalls = 0
                        case .restart: rounds = 0; stalls = 0; failures = 0
                        }
                    }
                } catch is InvalidatedLook {
                    failures = 0  // no gesture was sent; the next look restores the screen first
                } catch let e where e is BlindError || e is CancellationError || Task.isCancelled {
                    throw e
                } catch let e as LLMError where e.kind == "rate_limit_day" || e.kind == "trial_run_ended" {
                    throw e  // retrying can't help (today's quota, or the free line ended the run): ends it with the message
                } catch {  // a bad reply or a dropped link: recover, don't crash
                    if policy.unattended, RunPolicy.backsOff(error) {
                        let delay = policy.backoff(attempt: modelBackoffs)
                        modelBackoffs += 1
                        record(nil, ["action": .str("hiccup"),
                                     "reason": .str("model busy, waiting \(Int(delay)) s: \(String(error.localizedDescription.prefix(200)))")])
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    modelBackoffs = 0
                    let cutOff = ModelRequestFailure.cutOff(error)
                    record(nil, ["action": .str("hiccup"), "kind": .str(ModelRequestFailure.kind(error)),
                                 "reason": .str(cutOff ? ModelRequestFailure.cutOffHiccup : String(error.localizedDescription.prefix(300)))])
                    let linkLost = error is DeviceError && screen?.live == false  // the next look waits for it (waitForScreen)
                    failures += linkLost ? 0 : 1  // a lost link is not the agent's fault
                    if failures == 1 { cutOffs = 0 }
                    if cutOff, !linkLost { cutOffs += 1 }
                    if failures >= maxFailures, workComplete() {
                        // 2026-11-20: 25 rides collected and saved, then the closing reply was cut three times and
                        // the run ended in help although the work was done. Now it ends as done, the result kept.
                        DebugLog.write("errors: \(failures) in a row after the work was complete; the run ends as done")
                        var act: JObject = ["action": .str("done"), "answer": .str(""),
                                            "reason": .str("the model failed \(failures) times in a row after the work was complete: the result is saved")]
                        attachNotebook(&act)
                        record(nil, act)
                        return finish()
                    }
                    if failures >= maxFailures {
                        record(nil, ["action": .str("fail"), "reason": .str("\(failures) \(Self.errorsReason)"),
                                     "message": .str(ModelRequestFailure.streakMessage(failures, cutOff: cutOffs >= failures))])
                        switch try await askForHelp() {
                        case .stop: return finish()
                        case .goOn: failures = 0
                        case .restart: rounds = 0; stalls = 0; failures = 0
                        }
                        continue
                    }
                    await screen?.settled()
                }
            }
        } catch let e where e is CancellationError || Task.isCancelled {
            record(nil, ["action": .str("stopped")])
        } catch let e as BlindError {
            record(nil, ["action": .str("fail"), "reason": .str(e.reason)])
        } catch {  // e.g. the model itself is unreachable
            record(nil, ["action": .str("error"), "reason": .str(ModelRequestFailure.message(error))])
        }
        finish()
    }

    /// Unplugged and under 10%: wait (and say so) instead of running the battery down. Never types anything.
    private func holdForPower() async throws {
        let snap = deviceHealth()
        if policy.unattended, snap.lowPower, !lowPowerNoted {
            lowPowerNoted = true
            onNotice?(String(localized: "Low Power Mode is on, so Auto-Lock is 30 seconds and the screen may lock."), .power)
        }
        if policy.unattended, DeviceHealth.shouldWarn(snap), !batteryWarned {
            batteryWarned = true
            onNotice?(String(localized: "Battery is under 30% and the iPhone is unplugged."), .power)
        }
        guard policy.unattended, DeviceHealth.shouldPause(snap) else { return }
        if !powerHeld {
            powerHeld = true
            record(nil, ["action": .str("hiccup"), "reason": .str("battery under 10% and unplugged; waiting for power")])
            onNotice?(String(localized: "Battery is under 10% and the iPhone is unplugged. Plug it in; the run is waiting."), .power)
        }
        let deadline = now() + policy.recoveryLimit
        while DeviceHealth.shouldPause(deviceHealth()) {
            if now() >= deadline {
                record(nil, ["action": .str("fail"), "reason": .str("the battery stayed under 10%")])
                throw BlindError(reason: String(localized: "the battery stayed under 10% and the iPhone was unplugged"))
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try Task.checkCancellation()
        }
        powerHeld = false
    }

    private enum AfterHelp { case stop, goOn, restart }
    private var modelBackoffs = 0

    /// The person's choice, or the policy's if unattended and `helpTimeout` passes with no answer.
    func chooseHelp(_ reason: String, confirm: Bool = false) async -> (HelpChoice, Bool) {
        let answer = confirm ? onConfirm : onHelp
        guard let answer else { return (.stop, false) }
        guard let timeout = policy.helpTimeout else { return (await answer(reason), false) }
        let fallback = policy.fallback(reason: reason, confirm: confirm, restarts: restarts)
        let once = OnceFlag()
        return await withCheckedContinuation { (c: CheckedContinuation<(HelpChoice, Bool), Never>) in
            Task { @MainActor in
                let choice = await answer(reason)
                if once.claim() { c.resume(returning: (choice, false)) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard once.claim() else { return }
                self.onHelpTimeout?(fallback)
                c.resume(returning: (fallback, true))
            }
        }
    }

    /// Pauses for the user (at most twice a run, unless unattended is restarting on its own).
    private func askForHelp() async throws -> AfterHelp {
        if policy.helpTimeout == nil {
            guard onHelp != nil, helpAsked < 2 else { return .stop }
        } else if onHelp == nil { return .stop }
        let reason = steps.last?["reason"]?.str ?? ""
        helpMessage = steps.last?["message"]?.str
        defer { helpMessage = nil }
        var help: JObject = ["action": .str("help"), "reason": .str(reason)]
        if let helpMessage { help["message"] = .str(helpMessage) }
        record(nil, help)
        let (choice, automatic) = await chooseHelp(reason)
        try Task.checkCancellation()
        switch choice {
        case .stop:
            record(nil, ["action": .str("stopped"), "by": .str(automatic ? "policy" : "user")])
            return .stop
        case .restart:
            guard policy.unattended, restarts < policy.maxRestarts else {
                record(nil, ["action": .str("stopped"), "by": .str("policy")])
                return .stop
            }
            restarts += 1
            restartNote = "This attempt was restarted from the Home Screen. Reopen the task's app and continue the goal."
            record(nil, ["action": .str("restarted"), "reason": .str("unattended: starting again from the Home Screen")])
            replay.restart()
            try await phone?.goHome(again: false)
            await screen?.settled()
            return .restart
        case .resume:
            helpAsked += 1
            record(nil, ["action": .str("takeover"), "reason": .str("the user did this part by hand: \(reason)")])
        case .skip:
            helpAsked += 1
            record(nil, ["action": .str("skipped"), "reason": .str(automatic
                ? "unattended: nobody answered, so this step was skipped: \(reason)"
                : "the user asked to skip this step: \(reason)")])
        }
        await screen?.settled()
        return .goOn
    }

    /// The actor asked before a risky step. True = the run is over (stopped).
    /// Unattended never approves one on its own: no answer, or "don't ask", becomes a skip.
    /// `always`: asked in every ask mode (the send guard: no setting lets a broken message go out unseen).
    func confirm(_ reason: String, always: Bool = false) async throws -> Bool {
        let mode = askMode ?? .current
        // The batch check holds deletes and changes, not a message the task asked to send (2026-11-23: "清空输入框"
        // in the task made the send of "好的，明天见！" wait for an answer nobody saw)
        let batch = inventory.needed && mode != .never && AskMode.kind(reason) != .send
        let asks = onConfirm != nil && (always || mode.asks(reason) || batch)
        if !asks {
            if policy.unattended {
                record(nil, ["action": .str("skipped"), "confirmed_by": .str("policy"),
                             "reason": .str("not done unattended (a risky step is never approved on its own): \(reason)")])
                return false
            }
            record(nil, ["action": .str("confirmed"), "reason": .str("go ahead (no need to ask for this): \(reason)")])
            return false
        }
        if inventory.needed { Analytics.capture("confirm_shown", ["kind": "inventory", "items": notebook.items.count]) }
        let (choice, automatic) = await chooseHelp(inventoryReason(reason), confirm: true)
        try Task.checkCancellation()
        switch choice {
        case .stop:
            record(nil, ["action": .str("stopped"), "by": .str(automatic ? "policy" : "user")])
            return true
        case .resume:
            record(nil, ["action": .str("confirmed"), "reason": .str("the user said yes, do it now: \(reason)")])
        case .skip, .restart:
            // `.restart` is not a confirm answer. A timeout never returns it for a confirm; if it did, still don't do the step.
            record(nil, ["action": .str("skipped"), "confirmed_by": .str(automatic ? "policy" : "user"),
                         "reason": .str(automatic
                            ? "not done unattended (nobody answered): \(reason)"
                            : "the user said no, do not do this: \(reason)")])
            await screen?.settled()
        }
        return false
    }

    /// The actor's system prompt: the original, plus an intent's checklist as hints.
    var actorPrompt: String {
        let base = BriefThink.apply(Prompts.actor) + "\n" + AssistiveTouchSpots.rule(geometry: screen?.geometry) + background
            + ToolStore.prompt(tools) + AppGuides.prompt(guides) + resultsSection + Calls.prompt(task)
        let all = hints + replay.hints + (restartNote.isEmpty ? [] : [restartNote])
        return all.isEmpty ? base : base + "\n\nHints for this task:\n" + all.map { "- " + $0 }.joined(separator: "\n")
    }

    /// A part of the step after its gestures that took over a second, logged (2026-11-18: 17.9 s after a tap, unseen).
    static func logSlow(_ what: String, since t: Double) {
        let s = now() - t
        if s >= 1 { DebugLog.write(String(format: "slow: %@ took %.1f s", what, s)) }
    }

    func timed<T>(_ what: String, _ body: () async throws -> T) async rethrows -> T {
        let t = now(), before = MainLag.shared.phase
        MainLag.shared.phase = what
        defer { Self.logSlow(what, since: t); MainLag.shared.phase = before }
        return try await body()
    }

    func timed<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
        let t = now(), before = MainLag.shared.phase
        MainLag.shared.phase = what
        defer { Self.logSlow(what, since: t); MainLag.shared.phase = before }
        return try body()
    }

    func finish() {
        keepLessons()
        let last = steps.last { !["plan", "timing", "verdict"].contains($0["action"]?.str ?? "") }?["action"]?.str
        liveNotes.finish(done: last == "done", task: task, files: MemoryFiles.open(since: filesSince),
                         asResult: handedBack && !resultWritten)
        if let metrics { trace?.writeMetrics(metrics.snapshot()) }
    }

    /// One see-think-act round (one or more actions). Returns true when the task is over.
    func step() async throws -> Bool {
        var timing = Metrics.Step()
        let began = now()
        if lastStepEnded > 0 { timing.housekeepingMs = max(0, (began - lastStepEnded) * 1000) }
        (verdictSpent, landingSpent) = (0, 0)
        StepWaits.reset()
        if policy.unattended, DeviceHealth.isHot(deviceHealth()) {
            // Initial estimate. A serious thermal state slows the phone; a short pause lets it cool.
            try await Task.sleep(nanoseconds: UInt64(DeviceHealth.thermalPause * 1_000_000_000))
        }
        MainLag.shared.phase = "look"
        let acts = try await decide()  // nextActions, once more for a repeat that changed nothing
        MainLag.shared.phase = "gestures"
        let decided = now()
        timing.firstTokenMs = lookClock.firstTokenMs
        timing.firstDoMs = lookClock.firstDoMs
        timing.streamEndMs = lookClock.streamEndMs
        timing.imageMs = lookClock.imageMs
        timing.treeMs = lookClock.treeMs
        timing.specUsed = specUsed
        timing.specCancelled = specCancelled
        (specUsed, specCancelled) = (false, false)
        JevGate.hold = Self.modelLooksNext(acts.map { $0.act["action"]?.str ?? "" })
        timing.llmMs = (acts[0].act["think_s"]?.double ?? 0) * 1000
        let seen = acts[0].shot
        var spots = [pointerAt]  // where the pointer was and goes: pointer moves are not screen changes
        var quiet: Task<(rects: [CGRect], s: Double), Never>?  // what moved on its own while the model looked (motion)
        func still() async -> [CGRect] { await quiet?.value.rects ?? [] }  // not a result of these gestures
        let confirmed = lastSent?["action"]?.str == "confirmed"  // a risky round
        defer {
            timing.settleMs = StepWaits.settle * 1000
            timing.snap = StepWaits.snaps > 0 || FrameMode.current == .snap
            timing.recordMs = StepWaits.record * 1000
            timing.tree = StepWaits.tree
            timing.verdictMs = verdictSpent
            timing.landingMs = landingSpent
            timing.stepIndex = timingIndex
            timingIndex += 1
            timing.afterMs = lastActed > decided ? (now() - lastActed) * 1000 : 0
            MainLag.shared.phase = "between steps"
            timing.otherMs = max(0, (now() - began) * 1000 - timing.llmMs - timing.frameMs - timing.hidMs
                                 - timing.leadMs - timing.verdictMs - timing.landingMs)
            StepWaits.reset()
            metrics?.step(timing)
            StepReport.shared.finished(timing)
            if !steps.isEmpty { steps[steps.count - 1]["timing"] = .obj(timing.object) }
            trace?.write(kind: "timing", timing.object)
            lastStepEnded = now()
        }
        await handBackIfCollected(acts)
        for (i, planned) in acts.enumerated() {
            var act = planned.act
            let name = act["action"]?.str ?? ""
            if handedBack, !HandBack.allowed.contains(name) {
                act["reason"] = .str(HandBack.refusal)
                record(nil, act)
                continue
            }
            if i == 0, planned.speculative, let shot = planned.shot {
                let nowFrame = screen?.frame
                let pointer = pointerAt
                let moved = await Vision.off { Vision.changed(shot, nowFrame, ignore: [pointer]) }
                if moved {
                    record(nil, ["action": .str("stale_look"), "reason": .str("the screen changed after the early look")])
                    return false
                }
            }
            if name == "confirm" {
                record(planned.shot, act)
                return try await confirm(act["reason"]?.str ?? "")
            }
            if name == "collect" || name == "find" || name == "each" {  // works the list itself; the next look starts where it ended
                onDoing?(.acting(act))
                switch name {
                case "collect": try await collect(&act)
                case "find": try await find(&act)
                default: try await each(&act)
                }
                record(planned.shot, act)
                return false
            }
            if Actions.notebookActions.contains(name) {
                if name == "tool" || name == "guide" { onDoing?(.acting(act)) }  // the island says what it looks up while it waits
                try await notebookAction(&act)
                record(planned.shot, act)
                if name == "write" { return false }
                // a file or snap that did not work: the model sees why before a done in the same round ends the run
                if name == "file" || name == "snap", !(act["reason"]?.str ?? "").hasPrefix("ok") { return false }
                continue
            }
            fileView = nil  // read once; a gesture changes the subject
            if name == "done" { attachNotebook(&act) }
            if name != "done" && name != "fail" {
                let gating = now()
                if i == 0, let limit = await takeLimitCheck() {  // nothing sent past the app's own limit
                    limitHit = limit
                    return false
                }
                if try await pausedBeforeGesture() {
                    if i == 0 { JevGate.hold = false }  // nothing was sent; the next look may use Jev
                    roundDroppedByPause = i == 0
                    return false
                }
                guard !connectionChanged(since: acceptedLookLinks) else {
                    throw InvalidatedLook.connectionChanged
                }
                guard !geometryChanged(since: acceptedLookGeometry) else {
                    throw InvalidatedLook.geometryChanged
                }
                onDoing?(.acting(act))  // the thought (on the first act) names the target
                if quiet == nil { quiet = Self.motion(seen, screen?.frame) }  // the screen just before acting
                let started = now()
                if timing.leadMs == 0 { timing.lead(replied: StepWaits.replied, decided: decided, gating: gating, at: started) }
                // after a tap in the same round the pointer moved again unseen: find it before pressing
                let earlierTap = acts[..<i].contains { $0.act["action"]?.str == "tap" }
                // and what the model aimed at may have moved: an answer row reflows as tiles leave it, and the
                // later taps hit gaps or other words (2026-11-06, Duolingo: right answers undone). Look again then.
                if earlierTap, name == "tap", let x = act["x"]?.double, let y = act["y"]?.double {
                    let checked = now()
                    timing.frameMs += await settle(ignoring: spots, busy: await still())
                    let (frame, at, mask) = (screen?.frame, CGPoint(x: x / 1000, y: y / 1000), spots)
                    let moved = await Vision.off { Vision.changed(seen, frame, at: at, ignore: mask) }
                    DebugLog.write(String(format: "step: target check before tap %d took %.1f s", i + 1, now() - checked))
                    if moved {
                        DebugLog.write("step: the target of tap \(i + 1) changed since the model looked; looking again")
                        verdict(true)
                        return false
                    }
                }
                if name == "swipe", let refusal = scrollBackRefusal(act) {
                    act["result"] = .str(refusal)
                    record(planned.shot, act)
                    return false
                }
                if name == "swipe" { SwipeClamp.apply(&act, limit: SwipeClamp.limit / max(1, scrollGain)) }
                // the screen the model saw shows the field as typed: nothing typed or cleared earlier in this round
                let fresh = !acts[..<i].contains { ["type", "clear", "say"].contains($0.act["action"]?.str ?? "") }
                let check: TapCheck
                if name == "tap" {
                    check = await checkTap(&act, shot: planned.shot ?? seen, earlierTap: earlierTap, fresh: fresh)
                } else if Actions.isEnter(act) {
                    check = await sendCheck(act, on: planned.shot ?? seen, fresh: fresh)
                } else {
                    check = .send
                }
                switch check {
                case .send: break
                case .held(let why):
                    act["result"] = .str(why)
                    record(planned.shot, act)
                    return false
                case .ask(let why), .askAlways(let why):  // the code's own check: a tap that pays or cannot be undone, a send
                    act["result"] = .str("not sent: the user is asked first (\(why))")
                    record(planned.shot, act)
                    return try await confirm(why, always: check == .askAlways(why))
                }
                if let note = try await perform(act, aim: earlierTap) { act[note.field] = .str(note.value) }
                lastActed = now()
                let s = lastActed - started
                timing.hidMs += s * 1000
                act["act_s"] = .num((s * 100).rounded() / 100)
                spots += pointerPath(act, geometry: screen?.geometry)
                pointerAt = spots.last!
            }
            record(planned.shot, act)
            if name == "done" || name == "fail" { return true }
            let following = i < acts.count - 1 ? acts[i + 1].act["action"]?.str : nil
            if name == "tap" && (following == "type" || following == "key" || following == "clear") {  // a missed tap never opened the field
                timing.frameMs += await settle(ignoring: spots, busy: await still())
                if screen?.behind == true {  // iPad: no frame shows whether the tap opened the field; look again
                    unseen()
                    return false
                }
                if !(try await tapChanged(seen, &spots, quiet: await still(), confirmed: confirmed)) {
                    verdict(false)
                    confirmStill(quiet: await still())
                    return false  // skip the rest; the actor looks again
                }
            }
        }
        timing.motionMs = (await quiet?.value.s ?? 0) * 1000
        MainLag.shared.phase = "after gestures: frame and verdict"
        let moving = await still()
        if canSpeculate, let screen {
            let earlyStarted = now()
            await screen.settled(quiet: Self.earlyQuiet, least: Self.earlyLeast, most: 1.5, ignoring: spots, busy: moving)
            timing.frameMs += (now() - earlyStarted) * 1000
            let early = screen.frame
            let mask = spots
            let busy = moving
            let big = await Vision.off { Vision.bigChange(seen, early, ignore: mask) }
            let small: Bool
            if big {
                small = true
            } else {
                small = await Vision.off { Vision.changed(seen, early, ignore: mask, quiet: busy) }
            }
            let target = tapTarget()
            let near: Bool
            if let target {
                near = await Vision.off { Vision.changed(seen, early, at: target, ignore: mask) }
            } else {
                near = false
            }
            let needsLanding = !big && target != nil && !Self.changedNearTarget(near)
            if !needsLanding {
                verdict(small)
                confirmStill(quiet: busy, final: false)  // before the speculative prompt is built from the steps
                prepareFrame(early)
                startSpeculative()
                let rest = now()
                await screen.settled(quiet: 0.5, least: 0, most: 4, ignoring: spots, busy: moving)
                timing.frameMs += (now() - rest) * 1000
                if let early, let later = screen.frame, early != later,
                   await Vision.off({ Vision.changed(early, later, ignore: mask, quiet: busy) }) {
                    cancelSpeculative("screen moved")
                    verdict(await Vision.off { Vision.changed(seen, later, ignore: mask, quiet: busy) })
                    prepareFrame(later)
                }
                confirmStill(quiet: busy)  // the rest of the wait is done: a frame that came in it counts now
                try await timed("follow cache") { try await followCache(seen: seen) }
                timed("checkpoint") { saveCheckpoint() }
                return false
            }
        }
        timing.frameMs += await settle(ignoring: spots, busy: moving)
        // feedback for the next round (a notebook action alone moves nothing: no verdict)
        guard !Actions.notebookActions.contains(steps.last?["action"]?.str ?? "") else { return false }
        if screen?.behind == true {  // iPad: the frame is from before the action; "did NOT change" would be a guess
            unseen()
            return false
        }
        prepareFrame(screen?.frame)
        let (frame, mask) = (screen?.frame, spots)
        let changed: Bool
        if steps.last?["action"]?.str == "tap" {
            let t = now()
            changed = try await tapChanged(seen, &spots, quiet: moving, confirmed: confirmed)
            Self.logSlow("tap check", since: t)
        }
        else { changed = await Vision.off { Vision.changed(seen, frame, ignore: mask, quiet: moving) } }
        if changed, try await closedAssistiveMenu() { verdict(false); return false }
        if changed { await timed("feed") { await noteFeed(seen: seen) } }
        if changed, let now = screen?.frame {  // this page's screens: a scroll adds one, anything else starts over
            pageFrames = steps.last?["action"]?.str == "swipe" ? Array((pageFrames + [now]).suffix(NoteCheck.pageScreens)) : [now]
        }
        verdict(changed)
        confirmStill(quiet: moving)
        if screen?.frame != frame { prepareFrame(screen?.frame) }
        try await timed("follow cache") { try await followCache(seen: seen) }
        timed("checkpoint") { saveCheckpoint() }
        return false
    }

    /// Put before the prompt when the last reply had no DO line.
    static let formatAgain = "Your last reply had no DO line. Reply only in the THINK / PLAN / DO format, never JSON, "
        + "tool calls or a description of the screen.\n\n"

    /// A change in the tap's own neighborhood is a hit: the pointer does not need to be wiggled to confirm it.
    static func changedNearTarget(_ near: Bool) -> Bool { near }

    func nextActions() async throws -> [Planned] {
        guard let actor else { throw LLMError(message: "no actor model") }
        takeSteering()
        let prompt = actorUserPrompt()
        if let early = try await takeSpeculative(prompt) { return early }
        var reply = ""
        let checkpoint = checkpointReason
        // An unparseable reply is asked again at temperature 0 with the format first: a warmer retry was worse
        // (2026-11-17 gateway records: 16% off-format at 0, 41% at 0.4-0.8).
        for attempt in 0..<3 {
            var (text, seconds, frame) = try await askRound(attempt == 0 ? checkpoint : nil, actor,
                                                            attempt == 0 ? prompt : Self.formatAgain + prompt, temperature: 0)
            var acts: [JObject]
            do { acts = try Actions.parseActions(text) } catch {
                reply = text
                DebugLog.write("actor reply off-format (try \(attempt + 1)): \(text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
                continue
            }
            if acts[0]["repaired"] != nil { DebugLog.write("actor reply repaired into DO lines") }
            if checkpoint == nil, !inPart, let checked = try await confirmDone(acts, prompt),
               let theirs = try? Actions.parseActions(checked.0) {
                (text, seconds, frame, acts) = (checked.0, seconds + checked.1, checked.2 ?? frame, theirs)
            }
            reply = text
            if let new = Actions.planBlock(text), new != plan {  // the model keeps its own plan up to date
                if firstPlan == nil, checkpoints.answered { firstPlan = new }  // the planner's first plan (PlanCache)
                plan = new
                record(frame, ["action": .str("plan"), "plan": .str(new), "plan_zh": .str(new)])
            }
            acts[0]["think_s"] = .num(seconds)
            if lastServed == "handsy-jev" { acts[0]["jev"] = .bool(true) }  // Jev took this step
            if checkpoints.answered, lastServed != Trial.model { acts[0]["planner"] = .bool(true) }  // a checkpoint round
            return acts.map { Planned(act: $0, shot: frame) }
        }
        throw Actions.ParseError(message: "actor gave no valid action: \(reply.prefix(200))")
    }

    /// Show a run without running it (demo data).
    func showMock(task: String, plan: String, steps: [JObject], running: Bool) {
        self.task = task
        self.plan = plan
        self.steps = steps
        self.running = running
    }
}

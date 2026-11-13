import ActivityKit
import Foundation

/// Starts, updates and ends the Live Activity of a run or a recording. While the agent works the app is in
/// the background, so this is the user's view of the run; the app updates it whenever BLE wakes it.
///
/// The face springs to a gesture's target when an action updates `look` and morphs on a mood change. The
/// random idle gaze loop is kept but off: cosmetic updates make the whole island flicker.
/// Updates go through a token bucket (burst 2, then 1 per second), so the system never sees more than ~1/s.
///
/// While a run goes, every update carries a stale date `staleAfter` ahead, and a keep-alive resends the state
/// when nothing went out for `keepAliveEvery`. Suspended by iOS (only bluetooth-central keeps it alive), the
/// app sends nothing, the date passes and the widget shows "×" eyes and "Paused by iOS — tap to continue".
@MainActor final class LiveActivityController {
    /// Highest: with another Live Activity running (Maps navigation, music) iOS shows the most relevant one in the
    /// Dynamic Island, and a run's activity without a score (0) lost to them (Henry, 2026-11-11).
    static let relevance = 100.0
    typealias State = AgentActivityAttributes.ContentState
    private var activity: Activity<AgentActivityAttributes>?
    private var recentlyEnded: Activity<AgentActivityAttributes>?
    private var recentEndTask: Task<Void, Never>?
    private var last: State?    // the newest state (sent or waiting for a token)
    private var sent: State?
    private var tokens = 2.0, refilled = 0.0
    private var flush: Task<Void, Never>?
    private var darting: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var sentAt = 0.0
    private var freshUntil: Date?   // the stale date of the last update
    private var staleSeen: Date?    // when an update found the previous one already stale
    private var stuckTapAt: Date?   // the user opened the app from a stale activity

    init() {
        // A run that ended with its process (killed, crashed) left its activity behind: it would go stale and
        // offer "tap to continue" for a run that is gone. Finished ones (kept for the review) stay.
        Task { [weak self] in
            for leftover in Activity<AgentActivityAttributes>.activities
            where leftover.id != self?.activity?.id && !leftover.content.state.finished {
                if leftover.content.state.phase == .standby, let self, self.activity == nil {  // waiting: keep it
                    (self.activity, self.last, self.sent) = (leftover, leftover.content.state, leftover.content.state)
                    continue
                }
                DebugLog.write("Live Activity: removed one left running by an earlier launch")
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(task: String, runID: String, limit: Int, phase: AgentActivityAttributes.Phase = .running,
               since: Date = Date()) {
        end(nil)
        stuckTapAt = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return DebugLog.write("Live Activity: disabled in Settings") }
        let line: String, status: IslandStatus
        switch phase {
        case .countdown: (line, status) = (String(localized: "Recording starts after the countdown."), .getReady)
        case .recording: (line, status) = (String(localized: "Do the task yourself. I'm watching."), .watching)
        default: (line, status) = (String(localized: "Reading the screen…"), .looking)
        }
        var state = State(mood: phase == .running || phase == .help ? .thinking : .listening, step: 0, limit: limit,
                          line: line, phase: phase, since: since)
        apply(status, to: &state)
        do {
            activity = try Activity.request(attributes: AgentActivityAttributes(task: task, runID: runID, name: Settings.storedAgentName),
                                            content: .init(state: state, staleDate: markSent(state), relevanceScore: Self.relevance))
            last = state
            sent = state
            tokens = 1
            refilled = now()
            startKeepAlive()
            DebugLog.write("Live Activity: started (\(phase.rawValue)) run \(runID)")
            if status.waits { startDarting() }
        } catch {
            activity = nil
            DebugLog.write("Live Activity: start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - standby (Henry 2026-11-13)

    /// Between runs the island waits with up to three intents and New Task (Settings › Standby in Dynamic Island).
    /// Lower relevance than a run: navigation or music win the island while nothing runs. A run replaces it
    /// (`start` ends it); after a run, its activity turns into the standby one (`end`), since an app in the
    /// background cannot start a new Live Activity. iOS ends any activity after 8 hours: the next `standby` call
    /// from the foreground starts a new one.
    static let standbyRelevance = 10.0
    /// The intents for the island, or nil when standby is off or something runs (set by the app).
    var standbyPicks: (() -> [StandbyPick]?)?
    var isStandby: Bool { last?.phase == .standby }

    static func standbyState(_ picks: [StandbyPick]) -> State {
        var state = State(mood: .sleeping, step: 0, limit: 0, line: String(localized: "Tap New Task, or run an intent."),
                          phase: .standby)
        state.label = String(localized: "Ready")
        state.labelFull = String(localized: "Ready for a task")
        state.minimalLabel = String(localized: "Ready")
        state.picks = picks
        return state
    }

    func standby(_ picks: [StandbyPick]) {
        if let activity, activity.activityState != .active && activity.activityState != .stale {
            (self.activity, last, sent) = (nil, nil, nil)  // ended by iOS (8 hours) or swiped away
        }
        let state = Self.standbyState(picks)
        if let activity {
            guard isStandby, last != state else { return }  // a run's activity: leave it to the run
            (last, sent) = (state, state)
            Task { await activity.update(.init(state: state, staleDate: nil, relevanceScore: Self.standbyRelevance)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: AgentActivityAttributes(task: "", runID: AgentActivityAttributes.standbyID,
                                                                                name: Settings.storedAgentName),
                                            content: .init(state: state, staleDate: nil, relevanceScore: Self.standbyRelevance))
            (last, sent) = (state, state)
            DebugLog.write("Live Activity: standby (\(picks.count) intents)")
        } catch {
            DebugLog.write("Live Activity: standby failed: \(error.localizedDescription)")
        }
    }

    func endStandby() { if isStandby { end(nil) } }

    /// Step counter, the model's words, the mood; `status` also changes what the character says and where it looks.
    func update(mood: Mood, step: Int, line: String, phase: AgentActivityAttributes.Phase? = nil, status: IslandStatus? = nil,
                since: Date? = nil) {
        guard var state = last else { return }
        state.mood = mood
        state.step = step
        state.line = line
        if let phase { state.phase = phase }
        if let since { state.since = since }
        if let status { apply(status, to: &state) }
        push(state)
    }

    /// What the character is doing now: looking / thinking (the eyes dart) or a gesture (the eyes go to its target).
    func show(_ status: IslandStatus, mood: Mood? = nil) {
        guard var state = last, !state.finished else { return }
        apply(status, to: &state)
        if let mood { state.mood = mood }
        push(state)
    }

    /// Shows the outcome for a while, then the system removes it. Tapping it opens the review.
    /// How long a done run asks ✓ / ✗ in the island before it is ended (then only the Lock Screen keeps it).
    static let verdictWindow: TimeInterval = 90

    func end(_ outcome: (mood: Mood, line: String)?, asksVerdict: Bool = false) {
        recentEndTask?.cancel()  // a previous run still asking: ended now
        stopUpdates()
        stuckTapAt = nil
        guard let activity else { return }
        var state = last ?? State(mood: .idle, step: 0, limit: 0, line: "")
        if let outcome {
            state.mood = outcome.mood
            state.line = outcome.line
            if state.phase == .running || state.phase == .help { apply(.ended(outcome.mood), to: &state) }
        }
        state.finished = true
        state.asksVerdict = asksVerdict && outcome != nil
        state.waitingSince = nil
        DebugLog.write("Live Activity: ended" + (outcome.map { " (\($0.mood.rawValue))" } ?? ""))
        self.activity = nil
        last = nil
        sent = nil
        let ask = state.asksVerdict
        let completion = Task {
            if ask {  // ended activities leave the Dynamic Island at once: it stays up while it asks
                let until = Date().addingTimeInterval(Self.verdictWindow)
                await activity.update(.init(state: state, staleDate: until, relevanceScore: Self.relevance))
                try? await Task.sleep(nanoseconds: UInt64(Self.verdictWindow * 1_000_000_000))
            }
            // standby on: after the verdict window (or the answer), or 20 s of the outcome, the island waits again;
            // not when a new run took over (`activity`) or the run was deleted (`recentlyEnded` cleared)
            if outcome != nil, self.standbyPicks?() != nil {
                if !ask { try? await Task.sleep(nanoseconds: 20_000_000_000) }
                if self.activity == nil, self.recentlyEnded?.id == activity.id, let picks = self.standbyPicks?() {
                    let waiting = Self.standbyState(picks)
                    await activity.update(.init(state: waiting, staleDate: nil, relevanceScore: Self.standbyRelevance))
                    if self.activity == nil { (self.activity, self.last, self.sent) = (activity, waiting, waiting) }
                    DebugLog.write("Live Activity: back to standby")
                    return
                }
            }
            var final = state
            final.asksVerdict = false
            await activity.end(.init(state: final, staleDate: nil),
                               dismissalPolicy: outcome == nil ? .immediate : .after(.now + 15 * 60))
        }
        if outcome != nil {
            recentlyEnded = activity
            recentEndTask = completion
        }
    }

    /// The user answered ✓ / ✗: the island stops asking (the Lock Screen keeps the outcome).
    func verdictGiven() { recentEndTask?.cancel() }

    /// A deleted run must also disappear from the Lock Screen, including its retained finished activity.
    func dismiss(runID: String) {
        var matches = Activity<AgentActivityAttributes>.activities.filter { $0.attributes.runID == runID }
        if let activity, activity.attributes.runID == runID {
            matches.append(activity)
            stopUpdates()
            self.activity = nil
            last = nil
            sent = nil
        }
        let pending = recentlyEnded?.attributes.runID == runID ? recentEndTask : nil
        pending?.cancel()  // a done run still asking ✓ / ✗: stop waiting
        if let recentlyEnded, recentlyEnded.attributes.runID == runID {
            matches.append(recentlyEnded)
            self.recentlyEnded = nil
            recentEndTask = nil
        }
        var seen: Set<String> = []
        let unique = matches.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return }
        Task {
            await pending?.value  // the earlier delayed-dismissal end must finish before immediate removal
            for activity in unique { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - status and eyes

    private func apply(_ status: IslandStatus, to state: inout State) {
        if status.waits {
            if state.label != status.short || state.waitingSince == nil { state.waitingSince = Date() }
        } else { state.waitingSince = nil }
        state.minimalLabel = status.minimal ?? status.short
        state.label = status.short
        state.labelFull = status.full
        if let look = status.look {
            state.lookX = look.x
            state.lookY = look.y
        }
        if status.waits { startDarting() } else { stopDarting() }
    }

    /// While waiting: glance somewhere else every 1.4-2.2 s, mostly sideways, never twice at the same spot.
    private func startDarting() {
        // Off: ActivityKit does not say which presentation is visible, and repeated cosmetic updates
        // animate the entire island. Action-driven gaze and mood updates stay on.
        guard Self.idleGazeEnabled else { return }
        guard darting == nil else { return }
        darting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 1_400_000_000...2_200_000_000))
                guard !Task.isCancelled, let self, var state = self.last, !state.finished else { return }
                var x = state.lookX
                while abs(x - state.lookX) < 0.5 { x = [-0.9, -0.55, 0, 0.55, 0.9].randomElement()! }
                state.lookX = x
                state.lookY = Double.random(in: -0.35...0.15)
                self.push(state)
            }
        }
    }

    private func stopDarting() {
        darting?.cancel()
        darting = nil
    }

    // MARK: - rate limit

    /// Sends now if a token is left, else once one refills (the newest state wins).
    private func push(_ state: State) {
        guard activity != nil, state != last || state != sent else { return }
        last = state
        guard flush == nil else { return }  // a send is already scheduled; it picks up `last`
        refill()
        if tokens >= 1 { return send() }
        let wait = (1 - tokens) * Self.perSecond
        flush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.flush = nil
            self.refill()
            self.send()
        }
    }

    private static let perSecond = 1.0, burst = 2.0
    private static let idleGazeEnabled = false

    private func refill() {
        let t = now()
        tokens = min(Self.burst, tokens + (t - refilled) / Self.perSecond)
        refilled = t
    }

    private func send(force: Bool = false) {
        guard let activity, let state = last, force || state != sent else { return }
        tokens -= 1
        sent = state
        let content = ActivityContent(state: state, staleDate: markSent(state), relevanceScore: Self.relevance)
        Task { await activity.update(content) }
    }

    private func stopUpdates() {
        stopDarting()
        flush?.cancel()
        flush = nil
        keepAlive?.cancel()
        keepAlive = nil
        freshUntil = nil
        staleSeen = nil
    }

    // MARK: - stale while suspended

    /// Updates come several times a step (look, think, act; at most ~1/s by the bucket) and stop only while the
    /// model answers: about 14 s on average, 20+ s at worst, the free line up to its 75 s request timeout.
    /// The keep-alive covers those long waits, so the date only has to outlast the keep-alive's longest gap
    /// (`keepAliveEvery` + one check, 15 s) with room for a busy main thread. 30 s does that twice over and
    /// alone still clears the slowest normal step; a suspension shorter than that recovers by itself unseen.
    static let staleAfter: TimeInterval = 30
    static let keepAliveEvery: TimeInterval = 10
    static let keepAliveCheck: TimeInterval = 5

    /// The stale date of an update sent at `date`: none outside a running run (waiting for the user, paused,
    /// recording, finished), so those never show the stuck face.
    nonisolated static func staleDate(for state: State, at date: Date) -> Date? {
        state.canGoStale ? date.addingTimeInterval(staleAfter) : nil
    }

    /// Resend the unchanged state to push the stale date out: a run goes and nothing went out for a while.
    nonisolated static func needsKeepAlive(_ state: State?, sentAgo: TimeInterval) -> Bool {
        guard let state else { return false }
        return state.canGoStale && sentAgo >= keepAliveEvery
    }

    /// The user tapped the Live Activity: the app is in front now. If the system was showing it stale (or the
    /// update that woke the run cleared that moments ago), the tap meant "continue", not "show me the app".
    func opened() {
        let now = Date()
        let staleNow = freshUntil.map { $0 <= now } ?? false
        let justCleared = staleSeen.map { now.timeIntervalSince($0) < Self.keepAliveCheck * 2 } ?? false
        guard activity != nil, staleNow || justCleared else { return }
        stuckTapAt = now
        DebugLog.write("Live Activity: opened while stale; the run goes on")
    }

    /// True once after `opened()` saw a stale activity, so the run sends the app away again by itself.
    /// The model call the suspension cut short may take its whole timeout first, so the tap counts for 90 s.
    func takeStuckTap() -> Bool {
        defer { stuckTapAt = nil }
        guard let at = stuckTapAt else { return false }
        return Date().timeIntervalSince(at) < 90
    }

    /// The stale date of an update going out now; notes when the previous one had already passed.
    private func markSent(_ state: State) -> Date? {
        let date = Date()
        if let freshUntil, freshUntil <= date {
            staleSeen = date
            DebugLog.write(String(format: "Live Activity: was stale for %.0f s", date.timeIntervalSince(freshUntil)))
        }
        sentAt = now()
        freshUntil = Self.staleDate(for: state, at: date)
        return freshUntil
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveCheck * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard self.flush == nil, Self.needsKeepAlive(self.last, sentAgo: now() - self.sentAt) else { continue }
                self.refill()
                if self.tokens >= 1 { self.send(force: true) }
            }
        }
    }
}

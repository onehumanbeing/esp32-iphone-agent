import Foundation

/// Self-healing runs: a lost board, hotspot or mirroring pauses the run (AgentLoop.waitForScreen); this side
/// reports each stage (log, Live Activity, in-app banner, a notification when the user has to act) and
/// restores the board's state once the screen is live again.
extension AppModel {

    func wireRecovery() {
        agent.link = { [unowned self] in
            Recovery.Link(connected: board.connected && board.status?.inputState != nil, sta: board.status?.sta, ap: board.status?.ap,
                          net: board.status?.net,
                          frameAt: feed.frozen ? 0 : FrameMode.current == .snap ? now() : feed.updated,  // snap mode: restore snaps a fresh one
                          stalled: feed.frozen || feed.undecodable, needsPointer: board.status?.needsWirelessPointer == true,
                          usb: phoneUSB, locked: phoneLocked)
        }
        agent.onRecover = { [weak self] stage in
            guard let self, self.linkRecoveryDisplay == nil else { return }
            self.recover(stage)
        }
        agent.restore = { [weak self] in try await self?.restoreRun() }
    }

    /// Surface a disconnect even while a model HTTP request is still in flight.
    func beginLinkRecoveryDisplay() {
        guard agent.running else { return }
        if linkRecoveryDisplay == nil { linkRecoveryDisplay = Recovery(at: now()) }
        refreshLinkRecoveryDisplay()
    }

    /// UI only: the existing tick and BLE status callback drive this; AgentLoop owns hardware recovery.
    func refreshLinkRecoveryDisplay() {
        guard agent.running, var display = linkRecoveryDisplay else {
            linkRecoveryDisplay = nil
            return
        }
        let link = Recovery.Link(connected: board.connected && board.status?.inputState != nil, sta: board.status?.sta, ap: board.status?.ap,
                                 net: board.status?.net,
                                 frameAt: feed.frozen ? 0 : FrameMode.current == .snap ? now() : feed.updated,
                                 stalled: feed.frozen || feed.undecodable, needsPointer: board.status?.needsWirelessPointer == true,
                                 usb: phoneUSB, locked: phoneLocked)
        switch display.next(link, at: now()) {
        case .wait(let stage):
            linkRecoveryDisplay = display
            if stage != recovering { recover(stage) }
        case .live:
            linkRecoveryDisplay = nil
            recover(nil)
            if let lastRunDoing { doing(lastRunDoing) }
        case .giveUp:
            linkRecoveryDisplay = display  // the agent's bounded recovery decides the outcome
        }
    }

    func recover(_ stage: Recovery.Stage?) {
        let was = recovering
        recovering = stage
        guard let stage else {
            if agent.running { RunMarker.set("running") }
            notifier.clearLinkAsks()
            runMood = .thinking
            return
        }
        if was == nil { recoverySince = Date() }
        if stage.part != .board, was == nil || was?.part == .board, let up = board.status?.up, up < 60_000 {
            DebugLog.write("recover: board rebooted \(up / 1000) s ago (reset: \(board.status?.rst ?? "?"))")
        }
        DebugLog.write("recover: \(stage.logLine)")
        if stage.part == .frames && stage.ask { updateMirrorHint(staleNow: true) }  // "reconnect mirroring"
        if agent.running { RunMarker.set("running, recovering \(stage.part)\(stage.ask ? ", asked the user" : "")") }
        runMood = .listening
        live.update(mood: .listening, step: moveCount, line: stage.line, phase: .running, status: stage.status)
        if stage.ask { notifier.post(kind(stage.part), title: title(stage), body: stage.line, run: runID) }
    }

    /// Live again: the board may have rebooted (stream off, button state unknown) and the screen moved on.
    func restoreRun() async throws {
        DebugLog.write(String(format: "recover: live again after %.0f s", Date().timeIntervalSince(recoverySince)))
        if FrameMode.current == .stream && !feed.streamOn { try await feed.stream(true) }
        DebugLog.write("recover: fresh frame (" + (try await feed.currentFrame()) + ")")
        try await pointer.reset()  // a gesture cut off mid-way may have left the button down
        DebugLog.write("recover: button released, pointer re-homed; going on from step \(moveCount)")
        live.update(mood: .thinking, step: moveCount, line: String(localized: "Back online. Going on from here…"),
                    phase: .running, status: .looking)
    }

    /// The board's USB state as a sign that the iPhone is locked; a wireless-HID board has no USB link to it.
    private var phoneUSB: String? { board.status?.isWirelessHID == true ? nil : board.status?.usb }

    private func kind(_ part: Recovery.Part) -> Notifier.Kind {
        switch part {
        case .board, .cable, .pointer: return .board
        case .locked: return .locked
        case .hotspot: return .wifi
        case .mirroring, .frames: return .mirroring
        }
    }

    private func title(_ stage: Recovery.Stage) -> String {
        switch stage.part {
        case .pointer: return String(localized: "Pair the Bluetooth pointer")
        case .cable: return String(localized: "Plug the board into this iPhone")
        case .board: return String(localized: "Board disconnected")
        case .locked: return String(localized: "Unlock iPhone to continue")
        case .hotspot: return stage.lan ? String(localized: "Board left the Wi-Fi") : String(localized: "iPhone left the board's Wi-Fi")
        case .mirroring: return String(localized: "Start Screen Mirroring to continue")
        case .frames: return String(localized: "Waiting for a screen image")
        }
    }
}

/// Bluetooth-HID boards: Screen Mirroring goes stale on long use (2026-11-20: the board's GOP full, frames frozen,
/// the agent tapped from stale frames; stopping and restarting mirroring fixed it). A tip on Home, never a gate:
/// once mirroring has streamed for `longSession`, or right after frozen video (the board's `fz`, or a run's
/// recovery asking to reconnect mirroring). × hides it until mirroring restarts; "Don't show again" is kept.
struct MirrorHint: Equatable {
    static let longSession = 30.0 * 60  // continuous mirroring before the tip comes up by itself
    static let neverKey = "mirrorHintNever"

    enum Trigger: String { case stale, long }

    private(set) var since: Double?  // this mirroring session's start
    private(set) var staleSeen = false
    private(set) var dismissed = false

    /// The board's heartbeat: mirroring stopped resets everything (a restart is what the tip asks for).
    mutating func status(streaming: Bool, frozen: Bool, at t: Double) {
        guard streaming else { self = MirrorHint(); return }
        if since == nil { since = t }
        if frozen { staleSeen = true }
    }

    mutating func stale() { staleSeen = true }
    mutating func dismiss() { dismissed = true }

    /// Why it shows now, nil when it doesn't.
    func trigger(ble: Bool, never: Bool, at t: Double) -> Trigger? {
        guard ble, !never, !dismissed, let since else { return nil }
        if staleSeen { return .stale }
        return t - since >= Self.longSession ? .long : nil
    }
}

extension AppModel {
    /// From the 1 s board status and from run recovery; publishes only on a change.
    func updateMirrorHint(_ s: BoardStatus? = nil, staleNow: Bool = false) {
        if let s { mirrorHint.status(streaming: s.ap == "streaming", frozen: s.fz == 1, at: now()) }
        if staleNow { mirrorHint.stale() }
        let ble = board.status.map { $0.isWirelessHID || $0.hidm == "ble" } ?? false
        let trigger = mirrorHint.trigger(ble: ble, never: UserDefaults.standard.bool(forKey: MirrorHint.neverKey), at: now())
        guard (trigger != nil) != mirrorHintShown else { return }
        mirrorHintShown = trigger != nil
        if let trigger {
            DebugLog.write("mirror hint: shown (\(trigger.rawValue))")
            Analytics.capture("mirror_hint_shown", ["trigger": trigger.rawValue])
        }
    }

    /// ×: hidden until mirroring restarts. `forever`: never again on this install.
    func dismissMirrorHint(forever: Bool) {
        mirrorHint.dismiss()
        if forever { UserDefaults.standard.set(true, forKey: MirrorHint.neverKey) }
        Analytics.capture(forever ? "mirror_hint_never" : "mirror_hint_dismissed")
        updateMirrorHint()
    }
}

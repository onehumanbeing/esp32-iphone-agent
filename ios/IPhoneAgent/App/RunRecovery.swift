import Foundation

/// Self-healing runs: a lost board, hotspot or mirroring pauses the run (AgentLoop.waitForScreen); this side
/// reports each stage (log, Live Activity, in-app banner, a notification when the user has to act) and
/// restores the board's state once the screen is live again.
extension AppModel {

    func wireRecovery() {
        agent.link = { [unowned self] in
            recoveryLink
        }
        agent.onRecover = { [weak self] stage in
            guard let self, self.linkRecoveryDisplay == nil else { return }
            self.recover(stage)
        }
        agent.restore = { [weak self] in try await self?.restoreRun() }
    }

    var recoveryLink: Recovery.Link {
        if onDeviceCapture {
            // A static local screen is still usable; it does not depend on the board's Wi-Fi or AirPlay.
            return Recovery.Link(connected: board.connected, sta: nil, ap: "streaming",
                                 frameAt: screen.live ? now() : 0)
        }
        return Recovery.Link(connected: board.connected, sta: board.status?.sta, ap: board.status?.ap,
                             frameAt: feed.frozen ? 0 : FrameMode.current == .snap ? now() : feed.updated,
                             stalled: feed.frozen)
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
        let link = recoveryLink
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

    func recoveryStatus(_ stage: Recovery.Stage) -> IslandStatus {
        guard onDeviceCapture, stage.part == .frames else { return stage.status }
        return IslandStatus(short: String(localized: "Waiting frame…"),
                            full: String(localized: "Waiting for a screen image…"), look: nil,
                            minimal: String(localized: "Frame"))
    }

    func recoveryLine(_ stage: Recovery.Stage) -> String {
        onDeviceCapture && stage.part == .frames ? recoveryStatus(stage).full : stage.line
    }

    func recover(_ stage: Recovery.Stage?) {
        let was = recovering
        recovering = stage
        guard let stage else {
            notifier.clearLinkAsks()
            runMood = .thinking
            return
        }
        if was == nil { recoverySince = Date() }
        if stage.part != .board, was == nil || was?.part == .board, let up = board.status?.up, up < 60_000 {
            DebugLog.write("recover: board rebooted \(up / 1000) s ago (reset: \(board.status?.rst ?? "?"))")
        }
        DebugLog.write("recover: \(stage.logLine)")
        runMood = .listening
        live.update(mood: .listening, step: moveCount, line: recoveryLine(stage), phase: .running, status: recoveryStatus(stage))
        if stage.ask { notifier.post(kind(stage.part), title: title(stage.part), body: recoveryLine(stage), run: runID) }
    }

    /// Live again: the board may have rebooted (stream off, button state unknown) and the screen moved on.
    func restoreRun() async throws {
        DebugLog.write(String(format: "recover: live again after %.0f s", Date().timeIntervalSince(recoverySince)))
        if onDeviceCapture {
            try screen.checkAvailability()
        } else {
            if FrameMode.current == .stream && !feed.streamOn { try await feed.stream(true) }
            DebugLog.write("recover: fresh frame (" + (try await feed.currentFrame()) + ")")
        }
        try await pointer.reset()  // a gesture cut off mid-way may have left the button down
        DebugLog.write("recover: button released, pointer re-homed; going on from step \(moveCount)")
        live.update(mood: .thinking, step: moveCount, line: String(localized: "Back online. Going on from here…"),
                    phase: .running, status: .looking)
    }

    private func kind(_ part: Recovery.Part) -> Notifier.Kind {
        switch part {
        case .board: return .board
        case .hotspot: return .wifi
        case .mirroring, .frames: return .mirroring
        }
    }

    private func title(_ part: Recovery.Part) -> String {
        switch part {
        case .board: return String(localized: "Board disconnected")
        case .hotspot: return String(localized: "iPhone left the board's Wi-Fi")
        case .mirroring: return String(localized: "Start Screen Mirroring to continue")
        case .frames: return String(localized: "Waiting for a screen image")
        }
    }
}

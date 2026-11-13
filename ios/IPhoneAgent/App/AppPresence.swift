import Foundation
import GameController
import UIKit

/// Whether this iPhone itself has a mouse plugged in (the board's USB HID), as iOS lists it to GameController.
/// Only a "yes" is trusted: discovery is asynchronous, so an empty list right after launch proves nothing.
@MainActor enum PhoneMouse {
    static func start() { _ = GCMouse.mice() }  // begins discovery; mice then arrive by notification
    static var connected: Bool { !GCMouse.mice().isEmpty }
}

/// The agent works on the phone this app runs on, so the app must be out of the way: Start sends it to the
/// Home Screen (and checks that iOS really put it in the background), and a run holds while it is in front.
extension AppModel {

    var appIsBackgrounded: Bool { isBackground() }

    /// Each fallback is a distinct gesture; never treat the board's ACK as a successful departure.
    func leaveApp() async throws -> Bool {
        let began = now()
        var used: AppDeparture.Method?
        let away = try await AppDeparture(isBackground: { self.appIsBackgrounded },
                               isConnected: { self.board.connected }, attempt: { method in
            used = method
            switch method {
            case .homeKey: _ = try await self.board.commands.send("homescreen", timeout: 3)
            case .shortcut: _ = try await self.board.commands.send("key cmd+h", timeout: 3)
            case .swipe: try await self.pointer.homeSwipe()
            }
        }, waitForBackground: { try await self.waitForBackground($0, stopOnBoardLoss: true) },
           waitForConnection: {
            if self.startingAgent { try await self.waitForStartupBoard() }
            else { _ = try await self.agent.waitForScreen() }
        }, failed: { method, error in
            DebugLog.write("leave app: \(method.rawValue) failed: \(error.localizedDescription)")
            if error is BoardTimeout || !self.board.connected {
                self.startupBoardUnavailable(disconnected: !self.board.connected)
            }
        }, log: DebugLog.write).leave()
        // Which gesture really sends the app home, and how fast (a slow one shows the app switcher first).
        Analytics.capture("app_left", ["method": used?.rawValue ?? "none", "away": away,
                                       "ms": Int((now() - began) * 1000)])
        return away
    }

    /// Leave for a run. If the board took every gesture and this iPhone still shows the app, the board's USB goes
    /// to another device (a Mac, say): stop before the agent sends it anything more. Asking the user to swipe up
    /// is only for a board that isn't answering.
    func leaveForRun() async throws -> Bool {
        if try await leaveApp() { return true }
        if startupBoardIssue || !board.connected { return try await askUserToLeave() }
        // Why the gestures didn't take (2026-11-11: users with the board plugged in got "isn't controlling"):
        // its USB unused (a charger, a hub, nothing), or this iPhone has it and only the Home gestures failed.
        try? await board.refreshStatus()
        let usb = board.status?.usb ?? "?", mouse = PhoneMouse.connected
        DebugLog.write("leave app: the board took every gesture, the app stayed in front (usb \(usb), mouse on this iPhone: \(mouse))")
        Analytics.capture("app_left_failed", ["usb": usb, "mouse": mouse])
        if board.status?.needsUSBHost == true {
            throw DeviceError(message: String(localized: "The board has power, but it isn't plugged into this iPhone. Plug it into this iPhone's USB-C port and try again."))
        }
        // A newly powered USB board may drop input reports until it settles.
        if let retry = AutoCalibrator.usbStartupRetry(board.status) {
            DebugLog.write(String(format: "leave app: the board is up %.0f s; trying again in %.0f s", retry.uptime, retry.delay))
            homeHint = String(localized: "The board just started. One moment…")
            try await Task.sleep(nanoseconds: UInt64(retry.delay * 1e9))
            homeHint = nil
            if try await leaveApp() { return true }
        }
        if mouse || PhoneMouse.connected { return try await askUserToLeave() }  // the board drives this iPhone: the user swipes up once
        if board.status?.isWirelessHID == true {
            throw DeviceError(message: String(localized: "Check the Bluetooth board pairing and AssistiveTouch settings on this iPhone."))
        }
        throw DeviceError(message: String(localized: "The board isn't controlling this iPhone. Plug it into this iPhone's USB-C port and try again."))
    }

    /// Keep the manual instruction visible; a normal disconnect pauses this wait and retries departure.
    func askUserToLeave() async throws -> Bool {
        var remaining = 30.0
        defer { homeHint = nil }
        while remaining > 0 {
            homeHint = startupBoardIssue
                ? String(localized: "The board isn't responding. Move it closer to your iPhone, or swipe up to continue.")
                : String(localized: "Swipe up to go to the Home Screen, and I'll start.")
            let began = now()
            if try await waitForBackground(remaining, stopOnBoardLoss: true) { return true }
            remaining -= now() - began
            guard !board.connected else { return false }
            try await waitForStartupBoard()
            if try await leaveApp() { return true }
        }
        return false
    }

    /// A startup has no AgentLoop recovery yet, so report a failed link immediately here.
    func startupBoardUnavailable(disconnected: Bool) {
        guard startingAgent, !agent.running, !MockMode.on else { return }
        startupBoardIssue = true
        let status: IslandStatus = disconnected ? .waitingForBoard : .boardSlow
        homeHint = status.full
        live.show(status, mood: .listening)
        if disconnected { recover(.init(part: .board, ask: false)) }
    }

    /// Pause a startup on normal BLE loss, then restore streaming and continue in the same task.
    func waitForStartupBoard() async throws {
        let began = now()
        var waited = false
        while true {
            while !board.connected || board.status?.inputState == nil || board.status?.needsWirelessPointer == true {
                try Task.checkCancellation()
                let part: Recovery.Part = board.connected && board.status?.isWirelessHID == true ? .pointer : .board
                guard now() < startupDeadline else { throw DeviceError(message: Recovery.reason(part)) }
                waited = true
                let stage = Recovery.Stage(part: part, ask: now() - began >= Recovery.quiet[part]!)
                if stage != recovering {
                    DebugLog.write(String(format: "startup board wait: %@ after %.1f s", stage.logLine, now() - began))
                    recover(stage)
                }
                homeHint = stage.line
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            try Task.checkCancellation()
            if waited && FrameMode.current == .stream {
                do { try await feed.stream(true) }
                catch {
                    try Task.checkCancellation()
                    if !board.connected { continue }
                    throw error
                }
            }
            if waited {
                recover(nil)
                startupBoardIssue = false
                homeHint = nil
                live.show(.leavingApp, mood: .acting)
            }
            return
        }
    }

    func startupBoardCommand(_ operation: () async throws -> Void) async throws {
        while true {
            try await waitForStartupBoard()
            do { try await operation(); return }
            catch {
                try Task.checkCancellation()
                guard !board.connected else { throw error }
                startupBoardUnavailable(disconnected: true)
            }
        }
    }

    /// The app came back on screen during startup. When we had asked the user to fix something (usually by
    /// tapping our Live Activity), say that, not "still on screen" (2026-10-19: mirroring had stalled).
    func onScreenError() -> DeviceError {
        if let stage = recovering, stage.ask, stage.part != .board {
            return DeviceError(message: stage.line)
        }
        return DeviceError(message: String(localized: "\(AppName.current) is still on screen"))
    }

    /// Try a short stream wait, then explicitly snap; a static Home Screen must not stall startup.
    func waitForStartupFrame(boundary: StartupFrameBoundary, snapMode: Bool) async throws -> String {
        let began = now()
        var recovery = Recovery(at: began, limit: max(0, startupDeadline - began))
        // A still Home Screen sends no new frame on its own: nudge the cursor almost at once instead of waiting 3 s
        // for one (2026-10-20 log: 3 s idle, then the nudge brought the frame).
        var streamDeadline = snapMode ? began : began + 0.5
        var requestedMotion = false
        var receivedSnapshot = false
        var motionAt = 0.0
        var stallLogged = false
        var source = "live"
        // The board got no frame from AirPlay since before the cursor moved: the sender stalled while its
        // session stays up (heartbeats), and only restarting Screen Mirroring helps; ask for it now, not in 20 s.
        func airplayStalled() -> Bool {
            if feed.frozen { return true }  // no keyframe will come by itself
            guard motionAt > 0, now() - motionAt > 4, let vage = board.status?.vage, vage > 0 else { return false }
            return Double(vage) / 1000 > now() - motionAt + 1
        }
        func hasFrame() -> Bool {
            feed.frame != nil && !feed.broken
                && boundary.accepts(capturedAt: feed.capturedAt, backgroundEnteredAt: backgroundEnteredAt)
        }
        var logged = 0.0
        var shownStage: Recovery.Stage?, shownPoll = 0.0  // for the log: transitions only
        RunMarker.set("startup: waiting for the first frame")
        while true {
            if now() - logged >= 1 {  // why there is no usable frame yet, once a second
                logged = now()
                let threshold = boundary.threshold(backgroundEnteredAt: backgroundEnteredAt)
                DebugLog.write(String(format: "startup wait %.1f s: frame %@, captured %+.1f s vs boundary, last arrived %.1f s ago, broken %@, mirroring %@, stream %@, board %@, board's last AirPlay frame %@ ago, heap %@ KB",
                                      now() - began, feed.frame == nil ? "none" : "yes", feed.capturedAt - threshold, now() - feed.updated,
                                      "\(feed.broken)", "\(feed.mirroring)", "\(feed.streamOn)", "\(board.connected)",
                                      board.status?.vage.map { String(format: "%.1f s", Double($0) / 1000) } ?? "?",
                                      board.status?.heap.map { "\($0 / 1024)" } ?? "?"))
            }
            guard now() < startupDeadline else { throw DeviceError(message: Recovery.reason(.frames)) }
            try Task.checkCancellation()
            guard appIsBackgrounded else { throw onScreenError() }
            if hasFrame(), board.connected, board.status?.inputState != nil, board.status?.needsWirelessPointer != true, !snapMode || receivedSnapshot {
                await feed.settled(most: 1.5)  // the nudged cursor keeps fading for seconds; the Home Screen is still
                try Task.checkCancellation()
                if hasFrame(), board.connected, board.status?.inputState != nil, board.status?.needsWirelessPointer != true, appIsBackgrounded {
                    if recovering != nil { recover(nil) }
                    return source
                }
            }
            let stalled = airplayStalled() || feed.undecodable
            if stalled && !stallLogged {
                stallLogged = true
                DebugLog.write(feed.undecodable ? "startup: frames arrive but none decodes (a lost packet; no keyframe yet); Screen Mirroring has to restart"
                               : "startup: the board has had no AirPlay frame since before the cursor moved; Screen Mirroring stalled")
            }
            let link = Recovery.Link(connected: board.connected && board.status?.inputState != nil, sta: board.status?.sta, ap: board.status?.ap,
                                     frameAt: hasFrame() ? now() : 0, stalled: stalled, needsPointer: board.status?.needsWirelessPointer == true)
            var waiting = false, stage: Recovery.Stage?
            switch recovery.next(link, at: now()) {
            case .live: break
            case .wait(let s):
                stage = s
                waiting = s.part != .frames  // board, hotspot or mirroring down
                if s != recovering { recover(s) }
                homeHint = s.line
            case .giveUp(let reason): throw DeviceError(message: reason)
            }
            let poll = Self.startupPoll(waiting: waiting)
            if stage != shownStage || poll != shownPoll {
                DebugLog.write(String(format: "startup wait: %@ at %.1f s, poll %.1f s",
                                      stage?.logLine ?? "links up", now() - began, poll))
                shownStage = stage
                shownPoll = poll
                RunMarker.set("startup: " + (stage.map { "waiting, \($0.part)\($0.ask ? ", asked the user" : "")" } ?? "waiting for a frame"))
            }
            if !board.connected || board.status?.inputState == nil || board.status?.needsWirelessPointer == true {
                try await waitForStartupBoard()
                continue
            }
            if now() < streamDeadline {
                try await Task.sleep(nanoseconds: UInt64(poll * 1e9))
                continue
            }
            do {
                if !requestedMotion {
                    // A static Home frame may predate its notification. Move only the cursor to request
                    // a genuinely newer image; no tap, model call, or timestamp tolerance is involved.
                    try await pointer.point(0.5, 0.5, aim: false)
                    try Task.checkCancellation()
                    guard appIsBackgrounded else { throw onScreenError() }
                    try await pointer.point(0.55, 0.5, aim: false)
                    requestedMotion = true
                    motionAt = now()
                    // The cursor change is streamed within a second; snapping the whole GOP over BLE
                    // (12-60 s) is only the fallback when that frame doesn't come.
                    if !snapMode {
                        streamDeadline = now() + 3
                        continue
                    }
                }
                try Task.checkCancellation()
                // Frames still arriving means the stream is behind (an in-app animation queued over BLE), not
                // stuck: a snap would resend the whole GOP on the same link and only add to it (17:48 log: the
                // 32 s snap ended in a BLE drop).
                if !snapMode, !feed.broken, feed.streamOn, now() - feed.updated < 2 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                if !snapMode && feed.continuous() {
                    // In step over Wi-Fi: a still screen sends nothing new, so nudge the cursor again (a snap
                    // would resend the whole GOP and stall the stream).
                    requestedMotion = false
                    streamDeadline = now() + 3
                    continue
                }
                let remaining = max(0.1, startupDeadline - now())
                try await feed.snap(timeout: min(feed.snapTimeout, remaining))
                receivedSnapshot = true
                source = "snap"
            } catch {
                try Task.checkCancellation()
                guard appIsBackgrounded else { throw error }
                DebugLog.write("startup frame: " + error.localizedDescription)
                if !board.connected { startupBoardUnavailable(disconnected: true) }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Before each look and gesture of a run. If the agent itself brought the app to the front (it tapped our
    /// Live Activity, a notification or an intent), or Continue was just tapped here, send the app away at once;
    /// if the user opened it, wait until they leave. The model never sees or taps this app's own screens.
    func holdWhileInFront() async throws {
        guard !appIsBackgrounded, agent.running, !MockMode.on else { return }
        if let text = pendingClipboard {  // the agent came here for `write`: only a foreground app may set it
            UIPasteboard.general.string = text
            clipboardWritten = UIPasteboard.general.hasStrings
            pendingClipboard = nil
            DebugLog.write("clipboard: wrote \(text.count) chars for the agent")
        }
        let stuckTap = live.takeStuckTap()  // the user tapped a stale Live Activity: "tap to continue"
        let ours = stuckTap || now() - agent.lastActed < 3 || now() - resumeAsked < 5
        DebugLog.write("run: ESP32 Agent is in front (\(stuckTap ? "tapped a stale Live Activity" : ours ? "after an agent action" : "opened by the user")); holding")
        let since = now()
        var away = false
        if ours { away = try await leaveApp() }
        if !away {
            homeHint = String(localized: "Paused while you're here. Go to the Home Screen and I'll go on.")
            live.show(.pausedInApp, mood: .thinking)
            defer { homeHint = nil }
            while !appIsBackgrounded {
                try Task.checkCancellation()
                if !feed.live {
                    _ = try await agent.waitForScreen()
                    live.show(.pausedInApp, mood: .thinking)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        _ = await feed.fresh(since: since, timeout: 3)  // a frame of the screen that is in front now
        await feed.settled()
        DebugLog.write("run: app in background again, going on")
    }

    /// How often the startup wait looks for its first frame: often while frames may be on the way, slower
    /// while a link is down (no frame can come until it is back, and the app is in the background).
    static func startupPoll(waiting: Bool) -> Double { waiting ? 0.5 : 0.1 }

    private func waitForBackground(_ seconds: Double, stopOnBoardLoss: Bool = false) async throws -> Bool {
        let deadline = now() + seconds
        while !appIsBackgrounded {
            try Task.checkCancellation()
            if stopOnBoardLoss && !board.connected { return false }
            if now() > deadline { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        return true
    }
}

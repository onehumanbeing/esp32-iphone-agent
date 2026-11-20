import Foundation
import UIKit

/// Calibrates the pointer like a 3D printer's auto bed levelling, on the calibration board: a white
/// full-screen grid (CalibrationBoard) over the app. The board homes the pointer, clicks at known mouse
/// distances and the app catches the taps (TouchProbe), then fits mouse units → screen per axis. When no tap
/// arrives it falls back to finding the pointer in the mirrored video (pixel diff, then the vision model).
/// If both fail the board offers Try Again and "Tap the pointer yourself" (manual needs the grid behind it).
/// It never starts by itself: when calibration is needed and the mouse and mirroring are up, the Agent page
/// shows a Calibrate button; a run calibrates first if needed; Settings › Calibration starts it too.
@MainActor final class AutoCalibrator: ObservableObject {
    enum Phase: Equatable {
        case idle, homing, probeA, probeB, verifying, done, needsTap, failed

        /// 1...4 while working.
        var step: Int? {
            switch self {
            case .homing: return 1
            case .probeA: return 2
            case .probeB: return 3
            case .verifying: return 4
            default: return nil
            }
        }
    }

    struct Progress: Equatable { var done: Int, total: Int }

    static let tolerance = 0.015  // fraction of the screen; a bigger miss calibrates again
    /// A calibration whose check misses by more is wrong (issue #96: ±49.8%, pinned at an edge) and is not kept.
    static let rejectAbove = 0.06

    @Published var phase = Phase.idle
    @Published var reason = ""  // why the last run started
    @Published var progress: Progress?  // probe clicks
    /// Why the last run failed, in words for the board (e.g. clicks not reaching the screen).
    @Published var problem: String?
    /// The calibration board is up.
    @Published private(set) var boardOpen = false
    /// The small success toast ("Pointer calibrated ±0.6%").
    @Published var toast = false
    /// Manual calibration: the user's last tap was on the screen edge, the pointer is now parked closer to the corner.
    @Published var manualRetry = false
    unowned let app: AppModel
    var link = -1  // board link the pointer was last calibrated on
    private var hide: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var previous: Data??  // the calibration before this run (`Pointer.snapshot`), put back if it fails

    init(app: AppModel) { self.app = app }

    var busy: Bool { phase.step != nil }

    /// Calibration needs both the control link and a working pointer.
    var boardReady: Bool { app.board.connected && app.board.status?.inputReady == true }
    var mirroring: Bool { app.board.status?.ap == "streaming" }

    /// Calibration is due: never done, the screen shape changed, or the learned correction drifted.
    var needed: Bool {
        let p = app.pointer
        guard p.calibrated else { return true }
        if let aspect = p.aspect, abs(aspect - DeviceScreen.aspect) > 0.02 { return true }
        if rotated { return true }
        return p.drift > Self.tolerance
    }

    /// iPad: the screen was rotated (or the mirrored shape changed) since the calibration. Never on iPhone.
    var rotated: Bool {
        guard DeviceKind.isPad, !MockMode.on, !app.pointer.absolute, let current = app.feed.geometry else { return false }
        return !app.pointer.matches(geometry: current)
    }

    /// The calibration can be used now. iPhone: calibrated, as always; iPad: and made in this orientation.
    var hasValidCalibration: Bool { app.pointer.calibrated && !rotated }

    /// Show the Calibrate button: due, and everything it needs is up.
    var offer: Bool { (needed || MockMode.on && !app.pointer.calibrated) && (MockMode.on || boardReady && mirroring) && !busy && !boardOpen }

    /// Open the board and calibrate automatically (Calibrate button, Settings, debug entry).
    func calibrate(why: String = String(localized: "requested")) {
        guard !busy else { return }
        Task { await run(why: why) }
    }

    /// Before a run: calibrate if needed and wait for it. True when the pointer is calibrated.
    func ensureCalibrated() async -> Bool {
        while busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !Task.isCancelled else { return false }
        app.pointer.adopt(app.feed.geometry)  // iPad: this orientation's saved calibration (nil on iPhone: nothing)
        if !hasValidCalibration && boardReady {
            if DeviceKind.isPad && app.feed.geometry == nil { _ = try? await app.feed.currentFrame(maxAge: 5, wait: 5) }
            await run(why: String(localized: "before a run"))
        }
        return hasValidCalibration
    }

    /// One automatic calibration, on the board when the app is in front.
    func run(why: String) async {
        // An open keyboard would take the board's test taps (and type into the field): close it first.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        reason = why
        problem = nil
        progress = nil
        toast = false
        if DeviceScreen.foreground { openBoard() }
        app.pointer.adopt(app.feed.geometry)  // iPad: the snapshot below is this orientation's
        previous = app.pointer.snapshot()
        let job = Task { await runOnce() }
        current = job
        await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
        if Task.isCancelled { cancel(releasePointer: false) }
        current = nil
        previous = nil
    }

    private func openBoard() {
        boardOpen = true
        app.probe.begin()
    }

    private func closeBoard() {
        boardOpen = false
        app.probe.end()
    }

    /// The board's Back button: stop whatever runs and close the board.
    func cancel(releasePointer: Bool = true) {
        current?.cancel()
        if busy || phase == .needsTap { app.say("calibration: cancelled") }
        putBack()
        progress = nil
        phase = app.pointer.calibrated ? .done : .idle
        closeBoard()
        if releasePointer { Task { _ = try? await app.pointer.reset() } }
    }

    private func runOnce() async {
        if MockMode.on { return await mockRun() }
        app.say("calibration: \(reason)")
        var noTaps = false
        if boardOpen {
            do {
                var result = try await tunedTouchCalibrate()
                if shaky(result), await waitForYoungBoard() { result = try await tunedTouchCalibrate() }
                switch result {
                case .done(let error): return finished(error)
                case .noTaps: noTaps = true
                case .failed(let why): app.say("calibration: touch probe failed: \(why)")
                }
            } catch {
                if Task.isCancelled { return }
                app.say("calibration: touch probe: \(error.localizedDescription)")
            }
        }
        if Task.isCancelled { return }
        progress = nil
        await videoCalibrate(noTaps: noTaps)
    }

    /// Right after it powers up, the board's USB drops reports for up to a minute: moves land short and clicks
    /// go missing (2026-11-11, users' diagnostics: probe clicks 3 of 10 arrived, 15-60 s after power-up; check
    /// taps rejected far off). A calibration that went wrong then is tried once more after the board settled.
    static func usbStartupRetry(_ status: BoardStatus?) -> (uptime: Double, delay: Double)? {
        guard let status, !status.isWirelessHID, status.inputState != nil, let ms = status.up else { return nil }
        let uptime = Double(ms) / 1000
        guard uptime < 90 else { return nil }
        return (uptime, max(60 - uptime, 10))
    }

    private func shaky(_ r: TouchResult) -> Bool {
        if case .done(let error) = r { return error > Self.rejectAbove }
        return true
    }

    /// Waits for a board that powered up moments ago; false (at once) for one that has been up a while.
    private func waitForYoungBoard() async -> Bool {
        try? await app.board.refreshStatus()
        guard let retry = Self.usbStartupRetry(app.board.status) else { return false }
        app.say(String(format: "calibration: the board is up %.0f s; trying again in %.0f s", retry.uptime, retry.delay))
        reason = String(localized: "the board just started; trying again")
        progress = nil
        try? await Task.sleep(nanoseconds: UInt64(retry.delay * 1e9))
        return !Task.isCancelled
    }

    /// Touch calibration. iPad over Bluetooth: a homing that brought down a system panel or stopped short of the top
    /// changes how far home pushes up (HomeTuning, kept per model and orientation) and calibration starts again,
    /// three times at most.
    private func tunedTouchCalibrate() async throws -> TouchResult {
        for attempt in 0... {
            do {
                return try await touchCalibrate(full: true)
            } catch let miss as HomeTuning.Miss {
                let landscape = DeviceScreen.size.width > DeviceScreen.size.height
                let n = HomeTuning.value(landscape: landscape)
                let what: String
                switch miss {
                case .panel: what = "brought down a system panel"
                case .short(let below): what = String(format: "stopped %.1f%% below the top", below * 100)
                }
                if miss == .panel, !(await closePanel()) {
                    app.say("calibration: home pushing up \(n) reports \(what), and it did not go away")
                    return .failed("a system panel covers the app")
                }
                guard attempt < 3, let next = HomeTuning.next(after: miss, from: n) else {
                    app.say("calibration: home pushing up \(n) reports \(what); no other count to try")
                    return .failed("homing \(what)")
                }
                HomeTuning.store(next, landscape: landscape)
                app.say("calibration: home pushing up \(n) reports \(what); trying \(next)")
            }
        }
        return .failed("homing")
    }

    /// Notification Center covers the app: the pointer going down to the bottom edge puts it away (iPad Air M3,
    /// 2026-11-20). No swipe: a swipe up from the bottom edge that arrives once the panel is gone turns the app into
    /// a window, and calibration needs it full screen. True once the app is in front again (up to 3 s).
    private func closePanel() async -> Bool {
        _ = try? await app.board.commands.send("move 0 2000 40")  // to the bottom edge, where the pointer stops
        app.pointer.forgetPosition()
        for _ in 0..<30 where !DeviceScreen.sceneActive { try? await Task.sleep(nanoseconds: 100_000_000) }
        app.say(DeviceScreen.sceneActive ? "calibration: the panel went away" : "calibration: a panel still covers the app")
        return DeviceScreen.sceneActive
    }

    /// The fallback: find the pointer in the mirrored video.
    private func videoCalibrate(noTaps: Bool) async {
        let diagnosis = noTaps ? noTapsText : nil
        guard mirroring else { return failed(diagnosis ?? String(localized: "Mirroring is off, so the pointer can't be seen.")) }
        guard FrameMode.current == .stream else {  // the video finder needs the live stream
            app.say("calibration: video fallback skipped in snap mode")
            return failed(diagnosis ?? String(localized: "Pointer not found on screen."))
        }
        do {
            try await app.feed.stream(true)
            defer { if !app.agent.running { Task { try? await app.feed.stream(false) } } }
            if DeviceKind.isPad { _ = try await app.feed.currentFrame(maxAge: 5, wait: 5) }  // the geometry needs a frame
            let ok = try await app.pointer.startCalibration { [weak self] i in
                self?.phase = [.homing, .probeA, .probeB][min(i, 2)]
            }
            if Task.isCancelled { return }
            guard ok else { return failed(diagnosis ?? String(localized: "Pointer not found on screen.")) }
            phase = .verifying
            guard let error = try await app.pointer.verify() else {
                return failed(diagnosis ?? String(localized: "Check point not found."))
            }
            finished(error)
        } catch {
            if !Task.isCancelled { failed(diagnosis ?? error.localizedDescription) }
        }
    }

    private var noTapsText: String {
        if app.board.status?.isWirelessHID == true {
            return String(localized: "Check the Bluetooth board pairing and AssistiveTouch settings on this iPhone.")
        }
        return String(localized: "Clicks aren't reaching the screen — is AssistiveTouch on and the board plugged into this iPhone?")
    }

    /// error: the check's miss, nil when no check could be made (the calibration is kept, unchecked).
    func finished(_ error: Double?) {
        if let error, error > Self.rejectAbove {
            app.say(String(format: "calibration: check off by ±%.1f%%, not kept", error * 100))
            return failed(Self.rejectedText)
        }
        if rotated { return failed(String(localized: "The screen rotated during calibration. Try again.")) }  // iPad
        previous = nil
        link = app.board.commands.links
        progress = nil
        problem = nil
        phase = .done
        if let error {
            Analytics.capture("calibration_done", ["error_pct": (error * 1000).rounded() / 10])
            app.say(String(format: "calibration: ±%.1f%%", error * 100))
        } else {
            Analytics.capture("calibration_done", ["unchecked": true])
            app.say("calibration: kept, not checked")
        }
        closeBoard()
        toast = true
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = false
        }
    }

    static var rejectedText: String {
        String(localized: "The test tap landed far from its target, so this calibration wasn't saved. In AssistiveTouch › Pointer Devices, set Tracking Speed to the middle and turn Pointer Animations off, then try again.")
    }

    /// A failed or cancelled run leaves the calibration it started with, not a half-made or wrong one.
    private func putBack() {
        guard let previous else { return }
        app.pointer.restore(previous)
        self.previous = nil
    }

    /// The board stays up with the problem, Try Again and "Tap the pointer yourself".
    private func failed(_ why: String) {
        putBack()
        Analytics.capture("calibration_failed")
        progress = nil
        problem = why
        phase = .failed
        app.say("calibration failed: \(why)")
    }

    // MARK: - manual, on the board

    /// Mouse units the pointer is parked from home for the user's tap, smaller each time it ran to an edge.
    /// A high Tracking Speed carries 200 units past the screen (2026-11-19, iPhone 15 Pro Max: the pointer sat on the
    /// right edge, the tap there was kept as the calibration and every run's taps went wide; Wiki #1177).
    static let manualMoves = [200, 100, 50]
    /// A tap this close to the right or bottom edge is a pointer stuck there, not where the move took it.
    static let manualEdge = 0.94

    /// "Tap the pointer yourself": park the pointer at a known spot, the user taps it, then the board clicks once
    /// further out and the app catches that click: two points fit both the scale and where home really is
    /// (the corner isn't (0, 0)). A check click with the agent's own move then decides whether it is kept.
    func startManual() {
        guard boardOpen else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        problem = nil
        manualRetry = false
        phase = .needsTap
        if previous == nil { previous = app.pointer.snapshot() }  // a wrong result puts this back
        current?.cancel()
        current = Task {
            let geometry = app.feed.geometry  // nil on iPhone
            for move in Self.manualMoves {
                do {
                    try await app.pointer.parkForManualCalibration(move: move)
                } catch {
                    return failed(error.localizedDescription)
                }
                let since = now()
                var tap: CGPoint?
                while !Task.isCancelled && phase == .needsTap && tap == nil {
                    tap = await app.probe.tap(since: since, timeout: 1)
                }
                guard let p = tap else { return }  // cancelled
                if let geometry, !geometry.matches(app.feed.geometry) {
                    return failed(String(localized: "The screen rotated during calibration. Try again."))
                }
                app.say(String(format: "calibration: tapped the pointer at (%.3f, %.3f), %d units from home", p.x, p.y, move))
                if Self.onEdge(p) {
                    app.say("calibration: that is the screen edge; parking the pointer closer to the corner")
                    manualRetry = true
                    continue
                }
                return await finishManual(move: move, at: p)
            }
            failed(Self.tooFastText)
        }
    }

    /// Debug (harness `manualcal`): open the board and go straight to "Tap the pointer yourself".
    func debugManual() {
        if !boardOpen { openBoard() }
        startManual()
    }

    /// The user's point, then the board's own two clicks (a second point and the check).
    private func finishManual(move: Int, at p: CGPoint) async {
        phase = .verifying
        let pointer = app.pointer, device = app.board.commands
        do {
            let (ux, uy) = Self.manualSecondStop(move: move, at: p)
            try await pointer.probe(ux, uy)
            var sent = now()
            try await device.send("click")
            guard let q = await app.probe.tap(since: sent, timeout: Self.tapTimeout) else {
                _ = try? await device.send("key esc")  // it may have opened the AssistiveTouch menu
                // clicks don't reach the screen: the user's point alone, as before, unchecked
                app.say("calibration: the board's click didn't arrive; keeping the one-point calibration, unchecked")
                pointer.finishCalibration(x: p.x, y: p.y, move: move)
                return finished(nil)
            }
            app.say(String(format: "calibration: board click %d %d landed (%.3f, %.3f)", ux, uy, q.x, q.y))
            let samples: [(ux: Double, uy: Double, fx: Double, fy: Double)] = [
                (Double(move), Double(move), Double(p.x), Double(p.y)), (Double(ux), Double(uy), Double(q.x), Double(q.y))]
            guard let (lx, ly) = Self.manualLines(samples) else { return failed(Self.tooFastText) }
            pointer.applyProbe(x: lx, y: ly, samples: samples)

            try await pointer.point(Self.check.x, Self.check.y)
            sent = now()
            try await device.send("click")
            guard let c = await app.probe.tap(since: sent, timeout: Self.tapTimeout) else { return finished(nil) }
            let error = max(abs(c.x - Self.check.x), abs(c.y - Self.check.y))
            app.say(String(format: "calibration: manual check at (%.2f, %.2f) landed (%.3f, %.3f), ±%.1f%%",
                           Self.check.x, Self.check.y, c.x, c.y, error * 100))
            pointer.setQuality(error)
            finished(error)
        } catch {
            if !Task.isCancelled { failed(error.localizedDescription) }
        }
    }

    /// The tap is the pointer stuck on the right or bottom edge, not where the move took it.
    static func onEdge(_ p: CGPoint) -> Bool { max(p.x, p.y) > manualEdge }

    /// The board's own click after the user's tap: about the middle of the screen by that tap (home taken as the corner).
    static func manualSecondStop(move: Int, at p: CGPoint) -> (Int, Int) {
        (Int((Double(move) * 0.5 / p.x).rounded()), Int((Double(move) * 0.5 / p.y).rounded()))
    }

    /// Per-axis lines (landed = a · units + b) through the user's tap and the board's click; nil when the click
    /// landed on an edge or didn't move further out.
    static func manualLines(_ s: [(ux: Double, uy: Double, fx: Double, fy: Double)]) -> (ProbeFit.Line, ProbeFit.Line)? {
        guard s.allSatisfy({ ProbeFit.usable($0.fx) && ProbeFit.usable($0.fy) }),
              let x = ProbeFit.line(s.map { ($0.ux, $0.fx) }), let y = ProbeFit.line(s.map { ($0.uy, $0.fy) }) else { return nil }
        return (x, y)
    }

    static var tooFastText: String {
        String(localized: "The pointer runs to the edge of the screen. In Settings › Accessibility › Touch › AssistiveTouch, set Tracking Speed to the middle, then try again.")
    }

    private func mockRun() async {
        for (i, p) in [Phase.homing, .probeA, .probeB, .verifying].enumerated() {
            phase = p
            progress = Progress(done: i * 2, total: 8)
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
        }
        app.pointer.mockCalibrated(quality: 0.006)
        finished(0.006)
    }
}

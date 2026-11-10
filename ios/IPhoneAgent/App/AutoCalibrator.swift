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
    unowned let app: AppModel
    var link = -1  // board link the pointer was last calibrated on
    private var hide: Task<Void, Never>?
    private var current: Task<Void, Never>?
    private var previous: Data??  // the calibration before this run (`Pointer.snapshot`), put back if it fails

    init(app: AppModel) { self.app = app }

    var busy: Bool { phase.step != nil }

    /// The mouse is up (board connected, USB HID mounted).
    var boardReady: Bool { app.board.connected && app.board.status?.usb == "ok" }
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
        guard DeviceKind.isPad, !MockMode.on, let current = app.feed.geometry else { return false }
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
        while busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        app.pointer.adopt(app.feed.geometry)  // iPad: this orientation's saved calibration
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
        await job.value
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
    func cancel() {
        current?.cancel()
        if busy || phase == .needsTap { app.say("calibration: cancelled") }
        putBack()
        progress = nil
        phase = app.pointer.calibrated ? .done : .idle
        closeBoard()
        Task { _ = try? await app.pointer.reset() }
    }

    private func runOnce() async {
        if MockMode.on { return await mockRun() }
        app.say("calibration: \(reason)")
        var noTaps = false
        if boardOpen {
            do {
                switch try await touchCalibrate(full: true) {
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

    /// The fallback: find the pointer in the mirrored video.
    private func videoCalibrate(noTaps: Bool) async {
        let diagnosis = noTaps ? Self.noTapsText : nil
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

    static var noTapsText: String {
        String(localized: "Clicks aren't reaching the screen — is AssistiveTouch on and the board plugged into this iPhone?")
    }

    func finished(_ error: Double) {
        guard error <= Self.rejectAbove else {
            app.say(String(format: "calibration: check off by ±%.1f%%, not kept", error * 100))
            return failed(Self.rejectedText)
        }
        if rotated { return failed(String(localized: "The screen rotated during calibration. Try again.")) }  // iPad
        previous = nil
        link = app.board.commands.links
        progress = nil
        problem = nil
        phase = .done
        Analytics.capture("calibration_done", ["error_pct": (error * 1000).rounded() / 10])
        app.say(String(format: "calibration: ±%.1f%%", error * 100))
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

    /// "Tap the pointer yourself": park the pointer at a known spot, then the next tap on the board is where it is.
    func startManual() {
        guard boardOpen else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        problem = nil
        phase = .needsTap
        current?.cancel()
        current = Task {
            let geometry = app.feed.geometry  // nil on iPhone
            do {
                try await app.pointer.parkForManualCalibration()
            } catch {
                return failed(error.localizedDescription)
            }
            let since = now()
            while !Task.isCancelled && phase == .needsTap {
                if let p = await app.probe.tap(since: since, timeout: 1) {
                    if let geometry, !geometry.matches(app.feed.geometry) {
                        return failed(String(localized: "The screen rotated during calibration. Try again."))
                    }
                    app.say(String(format: "calibration: tapped the pointer at (%.3f, %.3f)", p.x, p.y))
                    app.pointer.finishCalibration(x: p.x, y: p.y)
                    return finished(app.pointer.quality ?? 0.01)
                }
            }
        }
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

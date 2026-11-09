import Combine
import Foundation
import UIKit

/// Asking for the newest firmware (Henry, 2026-11-09): a board behind it may tap off target and drop the link, so
/// every board connection asks for the update. It can be skipped at the user's risk, until the board connects again.
struct FirmwareReminder {
    private(set) var skipped = false

    /// Behind the newest release found and able to take it over Wi-Fi. No release (offline, the check failed) never
    /// blocks, and a board from before OTA keeps its USB note.
    static func outdated(_ current: FirmwareVersion, latest: FirmwareRelease?) -> Bool {
        guard let latest else { return false }
        return current >= Firmware.firstOTA && latest.ver > current
    }

    mutating func skip() { skipped = true }
    /// The board went away: its next connection asks again.
    mutating func boardLeft() { skipped = false }
}

/// Settings › Board › Firmware: finds the newest signed release, sends it to the board over Wi-Fi and waits
/// until the board is back with it. A failed send is retried; the board keeps its old firmware until a whole
/// image is written and checked, and goes back to it on its own if the new one doesn't come up.
@MainActor final class FirmwareUpdater: ObservableObject {
    enum Phase: Equatable { case idle, downloading, sending, restarting, done, failed(String) }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var progress = 0.0
    @Published private(set) var attempt = 0
    @Published private(set) var release: FirmwareRelease?
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?
    @Published var presented = false  // the update sheet on Home (banner tap, or required)
    @Published private(set) var reminder = FirmwareReminder()
    private var link: AnyCancellable?
    private var manifest: URL?
    private unowned let app: AppModel
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var address: (String, String)?  // the board's ip and token for this update
    static let attempts = 3

    init(app: AppModel) {
        self.app = app
        // Skip lasts for this connection only: in memory, and forgotten when the board goes away.
        link = app.board.$connected.removeDuplicates().sink { [weak self] up in
            guard let self, !up else { return }
            reminder.boardLeft()
            if !busy { presented = false }  // a sheet for the old connection; the next one asks again
        }
    }

    var busy: Bool { phase == .downloading || phase == .sending || phase == .restarting }
    var current: FirmwareVersion { Firmware.version(of: app.board.status) }
    var available: Bool { app.board.connected && (release.map { $0.ver > current } ?? false) }
    /// Older than this app works with.
    var belowMinimum: Bool { app.board.connected && current < Firmware.required }
    /// Behind the newest release and able to take it over Wi-Fi: asked for on every connection, can be skipped.
    var outdated: Bool { app.board.connected && FirmwareReminder.outdated(current, latest: release) }
    /// The sheet opens by itself, titled Board Update Required.
    var required: Bool { belowMinimum || outdated }
    /// Below the minimum and possible now: the sheet can't be put off (an old board needing USB, or no release found, can).
    var mustUpdate: Bool { belowMinimum && current >= Firmware.firstOTA && release != nil }
    /// Skipped, or not asked yet because a task runs: Home keeps a warning up, without ×, until the board is updated.
    var showsWarning: Bool { outdated && !mustUpdate && !presented && !busy }
    var taskRunning: Bool { app.agent.running || app.startingAgent || app.recorder.busy }
    /// Why Update can't start now, if it can't.
    var blocker: String? {
        if !app.board.connected { return String(localized: "Connect the board first.") }
        if current < Firmware.firstOTA { return String(localized: "This board needs one update over USB first (hardware/flash.sh).") }
        if taskRunning { return String(localized: "Wait until the task or recording ends.") }
        return nil
    }

    func check() async {
        guard !checking, !busy else { return }
        checking = true
        checkError = nil
        defer { checking = false }
        do { (release, manifest) = try await Firmware.latest() } catch { checkError = error.localizedDescription }
        DebugLog.write("firmware: check: latest \(release?.version ?? "none") from \(manifest?.absoluteString ?? "-"), board "
            + "\(app.board.status?.fw?.description ?? "no fw") connected \(app.board.connected), available \(available), "
            + "required \(required), outdated \(outdated) (skipped \(reminder.skipped))\(checkError.map { ", error: " + $0 } ?? "")")
    }

    /// The board (re)connected: look for a release, and ask for the update if the board needs it.
    func boardConnected() async {
        await check()
        ask()
    }

    /// Opens the sheet when the board needs an update, unless it was skipped for this connection. A running task or
    /// recording isn't interrupted: Home shows the warning and the gate asks again when it ends.
    func ask() {
        guard required, phase == .idle, !presented, !reminder.skipped else { return }
        // A background relaunch (Bluetooth restores the board link) can't show a sheet: ask when the app comes up.
        guard UIApplication.shared.applicationState == .active else { return }
        let versions = "board \(current), latest \(release?.version ?? "none"), minimum \(Firmware.required)"
        DebugLog.write("firmware: update required (\(versions))\(taskRunning ? "; asking after the task" : "")")
        if !taskRunning { presented = true }
    }

    /// Skip Anyway: the old firmware until the board reconnects or the app starts again.
    func skip() {
        reminder.skip()
        presented = false
        DebugLog.write("firmware: update skipped on \(current) (latest \(release?.version ?? "none")) until the board reconnects")
        Analytics.capture("firmware_update_skipped", ["from": current.description, "to": release?.version ?? ""])
    }

    func install() {
        guard !busy, blocker == nil, let release, let manifest else { return }
        Task { await run(release, manifest: manifest) }
    }

    #if DEBUG
    /// harness/fw.sh (HarnessOTA.swift): a build the Mac staged, already checked there; it may be unsigned or the
    /// version the board runs. Returns when the update finished or failed (see `phase`).
    func installStaged(_ release: FirmwareRelease, manifest: URL) async {
        guard !busy, blocker == nil else { return }
        await run(release, manifest: manifest)
    }
    #endif

    /// Back to idle after the result was shown.
    func dismiss() {
        guard !busy else { return }
        if phase == .done { presented = false }
        phase = .idle
        progress = 0
    }

    private func run(_ release: FirmwareRelease, manifest: URL) async {
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true  // the screen stays on until the board is back
        background = UIApplication.shared.beginBackgroundTask(withName: "firmware") { [weak self] in self?.endBackground() }
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            endBackground()
        }
        progress = 0
        attempt = 0
        address = nil
        _ = await boardAddress(within: 0.1)  // now, while BLE is up: the download may outlast the link
        let before = current
        DebugLog.write("firmware: updating \(current) -> \(release.ver)")
        Analytics.capture("firmware_update_started", ["from": current.description, "to": release.version])
        do {
            phase = .downloading
            let image = try await Firmware.image(release, manifest: manifest)
            try? await app.feed.stream(false)  // the radio is the board's to write with
            let upBefore = app.board.status?.up ?? 0
            try await send(image, release, from: before)
            phase = .restarting
            try await waitForBoard(release, upBefore: upBefore)
            phase = .done
            DebugLog.write("firmware: updated: board back on \(current)")
            Analytics.capture("firmware_update_done", ["to": release.version])
        } catch {
            DebugLog.write("firmware: failed: \(error.localizedDescription)")
            Analytics.capture("firmware_update_failed", ["to": release.version, "attempts": attempt])
            let kept = phase == .restarting ? "" : " " + String(localized: "The board still runs its previous firmware.")
            phase = .failed(error.localizedDescription + kept)
        }
    }

    /// Up to three tries; each one waits for the board (it may be reconnecting) and starts the image over.
    private func send(_ image: Data, _ release: FirmwareRelease, from before: FirmwareVersion) async throws {
        var lastError: Error = Firmware.Failure(String(localized: "The board isn't connected."))
        for n in 1...Self.attempts {
            attempt = n
            phase = .sending
            progress = 0
            guard let (ip, token) = await boardAddress(within: 20) else { continue }
            do {
                let started = now()
                DebugLog.write("firmware: try \(n): sending \(image.count) bytes to \(ip) (BLE \(app.board.connected ? "up" : "down"))")
                try await Firmware.push(image, md5: release.md5, host: ip, token: token) { p in
                    Task { @MainActor [weak self] in self?.progress = max(self?.progress ?? 0, p) }
                }
                DebugLog.write(String(format: "firmware: board took the image in %.1f s; restarting", now() - started))
                return
            } catch {
                lastError = error
                DebugLog.write("firmware: try \(n) failed: \(error.localizedDescription)")
                // The answer may have been lost while the board restarts with the new image (a harness
                // reinstall of the same version can't tell by the version: it fails here and is retried).
                if current >= release.ver && current > before { return }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw lastError
    }

    /// The board's address and per-boot token. The image goes over Wi-Fi, so a BLE drop mid-update (a weak
    /// signal, 2026-10-19) doesn't stop it: the last address stays good until the board restarts.
    private func boardAddress(within seconds: Double) async -> (String, String)? {
        let end = now() + seconds
        while now() < end {
            if app.board.connected, let ip = app.board.net?.ip, let token = app.board.net?.vtok,
               !ip.isEmpty, ip != "0.0.0.0", !token.isEmpty { address = (ip, token) }
            if let address { return address }
            if app.board.connected { _ = try? await app.board.readNet(fresh: true) }  // it may have joined Wi-Fi since
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// The board restarts (its uptime starts over) and reconnects. If it reports the old version, the new image
    /// didn't come up and the bootloader went back to the previous one.
    private func waitForBoard(_ release: FirmwareRelease, upBefore: Int) async throws {
        let end = now() + 90
        var restarted = false
        while now() < end {
            if !app.board.connected && !restarted { restarted = true; DebugLog.write("firmware: board went away (restarting)") }
            if app.board.connected, let up = app.board.status?.up, up < upBefore || restarted {
                restarted = true
                if current >= release.ver { return }
                if up > 10_000 {  // up for a while on another version: it went back
                    throw Firmware.Failure(String(localized: "The board went back to its previous firmware (\(current.description)). Nothing was lost; try again later."))
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw Firmware.Failure(String(localized: "The board hasn't come back yet. Keep it plugged in; it will finish on its own and reconnect."))
    }

    private func endBackground() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }
}

import Foundation
import UIKit

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
    @Published private var dismissedVersion = UserDefaults.standard.string(forKey: "firmwareBannerDismissed")
    private var manifest: URL?
    private unowned let app: AppModel
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var address: (String, String)?  // the board's ip and token for this update
    static let attempts = 3

    init(app: AppModel) { self.app = app }

    var busy: Bool { phase == .downloading || phase == .sending || phase == .restarting }
    var current: FirmwareVersion { Firmware.version(of: app.board.status) }
    var available: Bool { app.board.connected && (release.map { $0.ver > current } ?? false) }
    /// This app needs a newer board: the sheet opens by itself and can't be put off.
    var required: Bool { app.board.connected && current < Firmware.required }
    /// Required and possible now: the sheet can't be put off (an old board needing USB, or no release found, can).
    var mustUpdate: Bool { required && current >= Firmware.firstOTA && release != nil }
    var showsBanner: Bool { available && !required && !busy && release?.version != dismissedVersion }
    /// Why Update can't start now, if it can't.
    var blocker: String? {
        if !app.board.connected { return String(localized: "Connect the board first.") }
        if current < Firmware.firstOTA { return String(localized: "This board needs one update over USB first (hardware/flash.sh).") }
        if app.agent.running || app.startingAgent || app.recorder.busy { return String(localized: "Wait until the task or recording ends.") }
        return nil
    }

    func check() async {
        guard !checking, !busy else { return }
        checking = true
        checkError = nil
        defer { checking = false }
        do { (release, manifest) = try await Firmware.latest() } catch { checkError = error.localizedDescription }
    }

    /// The board (re)connected: look for a release, and open the sheet if this app needs it.
    func boardConnected() async {
        await check()
        if required && phase == .idle { presented = true }
    }

    func dismissBanner() {
        dismissedVersion = release?.version
        UserDefaults.standard.set(dismissedVersion, forKey: "firmwareBannerDismissed")
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
            DebugLog.write("firmware: board back on \(current)")
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

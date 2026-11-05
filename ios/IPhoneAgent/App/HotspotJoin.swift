import Foundation
import NetworkExtension

/// Joining the board's Wi-Fi: idle → joining (the system prompt) → verifying (≤ 10 s) → joined, or
/// failed(reason) with Try Again and the manual fallback. A new start cancels the old task, so a re-tap
/// always restarts cleanly and the spinner never sticks.
enum JoinState: Equatable {
    case idle, joining, verifying, joined
    case failed(String)

    var busy: Bool { self == .joining || self == .verifying }
}

extension AppModel {
    /// Start (or restart) the join. `auto`: the page appeared; skipped once it was tried or is done.
    func startJoin(auto: Bool = false) {
        if auto && join != .idle { return }
        joinTask?.cancel()
        joinTask = Task { [weak self] in await self?.runJoin() }
    }

    /// The board restarted (a firmware update, a crash) while the phone was on its Wi-Fi: its access point went
    /// away, and iOS moves to another known network and doesn't come back by itself (2026-10-19). Join it again
    /// once its access point is up, unless the phone found its way back meanwhile.
    func rejoinAfterReboot() {
        Task { [weak self] in
            for _ in 0..<4 {  // the access point needs a few seconds after boot
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.board.connected else { continue }
                if (self.board.status?.sta ?? 0) > 0 { return DebugLog.write("hotspot: back on the board's Wi-Fi after its restart") }
            }
            guard let self, self.board.connected, !self.join.busy else { return }
            DebugLog.write("hotspot: the board restarted and the phone didn't come back to its Wi-Fi; joining again")
            self.join = .idle
            self.startJoin()
        }
    }

    private func runJoin() async {
        Hotspot.watchWiFi()
        if MockMode.on {
            join = .joining
            try? await Task.sleep(nanoseconds: 800_000_000)
            hotspotSSID = board.net?.ssid ?? "ESP32Agent-7C3E"
            join = .joined
            return mockStartMirroring()
        }
        join = .joining
        let net: NetConfig
        do { net = try await board.readNet() } catch {
            say("hotspot: could not read the board's Wi-Fi: \(error.localizedDescription)")
            join = .failed(String(localized: "Couldn't read the board's Wi-Fi. Is the board connected?"))
            return
        }
        guard !Task.isCancelled else { return }
        let ssid = net.ssid ?? "?"
        if await onBoardWiFi(ssid) {  // already there: iOS would show no prompt
            say("hotspot: already on \(ssid)")
            return joined(ssid)
        }
        say("hotspot: NEHotspotConfigurationManager.apply(\(ssid), password \(net.pass?.count ?? 0) chars, joinOnce false)")
        let started = now()
        do {
            try await Hotspot.join(net)
            say(String(format: "hotspot: apply → ok after %.1f s", now() - started))
        } catch let e as NSError {
            say(String(format: "hotspot: apply → %@ after %.1f s", Hotspot.describe(e), now() - started))
            guard !Task.isCancelled else { return }
            if Hotspot.userDenied(e) {
                join = .failed(String(localized: "Join was cancelled."))
            } else {
                manualHotspot = net
                join = .failed(String(localized: "iOS couldn't join automatically. Join by hand with the password below."))
            }
            return
        }
        // apply() can succeed (or show no prompt) without the phone really joining: confirm for up to 10 s.
        join = .verifying
        for _ in 0..<20 {
            guard !Task.isCancelled else { return }
            if await onBoardWiFi(ssid) { return joined(ssid) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let current = await Hotspot.currentSSID()
        say("hotspot: applied, but after 10 s the phone is on \(current ?? "no readable network"), not \(ssid); Wi-Fi link \(Hotspot.wifiLink ? "up" : "none")")
        manualHotspot = net
        join = .failed(Hotspot.wifiLink ? String(localized: "The iPhone didn't switch to the board's Wi-Fi. Join by hand with the password below.")
                                        : Self.wifiOffText)
    }

    private func joined(_ ssid: String) {
        manualHotspot = nil
        hotspotSSID = ssid
        join = .joined
        say("hotspot: joined \(ssid)")
    }

    /// On the board's hotspot, for the See page. The board counts its clients: while it reports, that count is
    /// the truth (joining by hand is seen without the hotspot entitlement, and leaving, e.g. Wi-Fi turned
    /// off, undoes the check). Before that: joined in-app or confirmed by hand, and not on another network.
    func onBoardHotspot(manual: Bool) -> Bool {
        if board.connected, let s = board.status, let sta = s.sta { return sta > 0 || s.ap == "streaming" }
        return otherWiFi == nil && (manual || join == .joined || hotspotSSID != nil)
    }

    /// On the board's network: the current SSID matches, or the board counts a client.
    private func onBoardWiFi(_ ssid: String) async -> Bool {
        if await Hotspot.currentSSID() == ssid { return true }
        return board.connected && (board.status?.sta ?? 0) > 0
    }

    static var wifiOffText: String {
        String(localized: "Wi-Fi looks off. Turn on Wi-Fi in Control Center, then tap Try Again.")
    }

    /// Poll while the See page is up (and when the app comes back): the user may have joined in Settings,
    /// or left (Wi-Fi turned off, another network): then the join is undone so the page asks again.
    func refreshHotspot() async {
        guard !MockMode.on else { return }
        // The board says no client and the phone isn't on its network either (the count lags a join by a few s).
        // iOS reads back only networks this app configured, so a fall-back to home Wi-Fi reads as no network.
        if join == .joined || hotspotSSID != nil, board.connected, board.status?.sta == 0, board.status?.ap != "streaming",
           await Hotspot.currentSSID() != board.net?.ssid {
            hotspotSSID = nil
            join = .failed(Hotspot.wifiLink ? String(localized: "The iPhone left the board's Wi-Fi. Tap Try Again to join it again.")
                                            : Self.wifiOffText)
            DebugLog.write("hotspot: the phone left the board's Wi-Fi (Wi-Fi link \(Hotspot.wifiLink ? "up" : "none"))")
            return
        }
        let current = await Hotspot.currentSSID()
        let ours = board.net?.ssid
        let on = current != nil && (current == ours || (ours == nil && (current?.hasPrefix("ESP32Agent") == true || current?.hasPrefix("iPhoneAgent") == true)))
        let other = on ? nil : current
        if otherWiFi != other { otherWiFi = other }
        if on, hotspotSSID != current {
            hotspotSSID = current
            if !join.busy { join = .joined }
            DebugLog.write("hotspot: detected on \(current ?? "")")
        } else if !on, current != nil, hotspotSSID != nil || join == .joined {
            hotspotSSID = nil  // on another network: not joined, whatever was true before
            if join == .joined { join = .idle }
            DebugLog.write("hotspot: on another network, not the board's")
        }
    }
}

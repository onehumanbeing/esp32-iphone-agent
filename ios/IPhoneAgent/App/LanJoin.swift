import Foundation

/// LAN mode: the board joins the home Wi-Fi as a station instead of opening its hotspot. The switch goes
/// over BLE (`net` write, docs/ble-protocol.md) and the firmware stores it — no reflash. States mirror
/// JoinState for the hotspot; the phone side is verified by the video channel or the current SSID.
enum LanJoinState: Equatable {
    case idle
    case applying          // writing the `net` characteristic
    case boardConnecting   // the board is joining the router (status.net "none" so far)
    case checkingPhone     // the board is on the router; the phone must be able to reach it
    case joined
    case failed(String)

    var busy: Bool { self == .applying || self == .boardConnecting || self == .checkingPhone }
}

/// Wi-Fi passwords the user typed for LAN mode, one per SSID, so switching networks asks at most once.
enum WiFiPasswords {
    static func get(_ ssid: String) -> String? { Keychain.get("wifi-" + ssid) }
    static func set(_ pass: String, for ssid: String) { Keychain.set(pass, for: "wifi-" + ssid) }
}

extension AppModel {
    /// The board's Wi-Fi mode as last reported: "ap" (its hotspot), "sta" (on the LAN), "none" (LAN
    /// configured but not connected). While disconnected, the last `net` read is the hint.
    var boardNetMode: String { board.connected ? (board.status?.net ?? board.net?.mode ?? "ap") : (board.net?.mode ?? "ap") }
    var lanMode: Bool { boardNetMode != "ap" }

    /// Point the board at a home Wi-Fi network. `pass` empty = open network. Errors land in `lanJoin`.
    func startLanJoin(ssid raw: String, pass: String, remember: Bool) {
        let ssid = raw.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, !lanJoin.busy else { return }
        lanJoinTask?.cancel()
        lanJoin = .applying
        lanJoinTask = Task { [weak self] in await self?.runLanJoin(ssid: ssid, pass: pass, remember: remember) }
    }

    private func runLanJoin(ssid: String, pass: String, remember: Bool) async {
        let wasOnLAN = board.status?.net == "sta"
        do { try board.writeNet(NetConfig(mode: "sta", ssid: ssid, pass: pass.isEmpty ? nil : pass)) } catch {
            lanJoin = .failed(error.localizedDescription)
            return
        }
        if remember, !pass.isEmpty { WiFiPasswords.set(pass, for: ssid) }
        say("lan: asked the board to join \(ssid)")
        lanJoin = .boardConnecting
        // Already on a network (changing it): status still says "sta" until the board drops the old one, and that
        // old "sta" is no proof of the new network. Wait for it to leave first (it restarts its Wi-Fi at once).
        if wasOnLAN {
            let left = now() + 8
            while !Task.isCancelled && now() < left && board.status?.net == "sta" {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let deadline = now() + 40
        while !Task.isCancelled && now() < deadline && board.status?.net != "sta" {
            guard board.connected else {
                lanJoin = .failed(String(localized: "The board disconnected. Reconnect it and try again."))
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !Task.isCancelled else { return }
        let config = try? await board.readNet(fresh: true)  // the LAN IP, for the Wi-Fi video channel
        guard board.status?.net == "sta", config?.ssid == nil || config?.ssid == ssid else {
            lanJoin = .failed(String(localized: "The board couldn't join \"\(ssid)\". Check the password, and that this network has a 2.4 GHz band."))
            return
        }
        lanSSID = ssid
        lanJoin = .checkingPhone
        if !wifiVideo.active, await Hotspot.currentSSID() != ssid {
            say("lan: the board is on \(ssid); joining this phone to it")
            try? await Hotspot.join(NetConfig(mode: "sta", ssid: ssid, pass: pass.isEmpty ? nil : pass))
        }
        let phoneDeadline = now() + 12
        while !Task.isCancelled && now() < phoneDeadline {
            let current = await Hotspot.currentSSID()
            if wifiVideo.active || current == ssid {
                lanJoin = .joined
                phoneOnBoardLAN = true
                say("lan: on \(ssid)")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !Task.isCancelled else { return }
        // A different SSID on the phone can still be the same router; only a working video channel proves it.
        lanJoin = .failed(String(localized: "The board is on \"\(ssid)\" now. Join \"\(ssid)\" on this device, or a network on the same router."))
    }

    /// The LAN sheet opened again: a finished (or failed) join from before must not block a new one.
    func resetLanJoin() {
        guard !lanJoin.busy else { return }
        lanJoin = .idle
    }

    /// Back to the board's own hotspot, then the usual one-tap join of it.
    func switchToHotspot() {
        guard !lanJoin.busy else { return }
        lanJoinTask?.cancel()
        lanJoin = .applying
        lanJoinTask = Task { [weak self] in
            guard let self else { return }
            do { try board.writeNet(NetConfig(mode: "ap")) } catch {
                lanJoin = .failed(error.localizedDescription)
                return
            }
            say("lan: asked the board to open its hotspot again")
            let deadline = now() + 15
            while !Task.isCancelled && now() < deadline && board.status?.net != "ap" {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            _ = try? await board.readNet(fresh: true)
            lanSSID = nil
            phoneOnBoardLAN = false
            lanJoin = .idle
            join = .idle
            startJoin()
        }
    }
}

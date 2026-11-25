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

/// The home network the board last joined, to fill in next time: iOS gives this app the phone's current network name
/// only for networks it joined itself (or with location access), so a home network reads as none.
enum LanMemory {
    static let key = "lanLastSSID"
    static var lastSSID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The network to fill in: the phone's own, unless that is the board's hotspot (or none readable), else the last
    /// home network the board joined.
    static func suggestion(current: String?, boardHotspot: String?, last: String?) -> String? {
        if let current, !current.isEmpty, current != boardHotspot, !current.hasPrefix("ESP32Agent") { return current }
        return last
    }
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
    /// "off" (Wi-Fi off for diagnostics, `board.py net off`) is neither the hotspot nor a home network.
    var lanMode: Bool { boardNetMode == "sta" || boardNetMode == "none" }

    /// Point the board at a home Wi-Fi network. `pass` empty = open network. Errors land in `lanJoin`.
    func startLanJoin(ssid raw: String, pass: String, remember: Bool) {
        let ssid = raw.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, !lanJoin.busy else { return }
        lanJoinTask?.cancel()
        lanJoin = .applying
        lanJoinTask = Task { [weak self] in await self?.runLanJoin(ssid: ssid, pass: pass, remember: remember) }
    }

    private func runLanJoin(ssid: String, pass: String, remember: Bool) async {
        let env = LanJoinFlow.Env(
            connected: { [unowned self] in board.connected },
            status: { [unowned self] in board.status },
            writeNet: { [unowned self] in try board.writeNet($0) },
            readNet: { [unowned self] in try? await board.readNet(fresh: true) },
            phoneSSID: { await Hotspot.currentSSID() },
            joinPhone: { try await Hotspot.join($0) },
            videoActive: { [unowned self] in wifiVideo.active },
            savePassword: { WiFiPasswords.set($0, for: $1) },
            log: { [unowned self] in say($0) })
        let joined = await LanJoinFlow.run(ssid: ssid, pass: pass, remember: remember, env: env) { [unowned self] state in
            lanJoin = state
            if state == .checkingPhone { lanSSID = ssid }
        }
        if joined {
            phoneOnBoardLAN = true
            networkSwitched = true
            LanMemory.lastSSID = ssid
        }
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
            // Firmware with the LAN lock restarts into its hotspot (its receiver was not found there otherwise): wait
            // for it to come back and read the hotspot's credentials from it, not from the home network's.
            let deadline = now() + 25
            while !Task.isCancelled && now() < deadline {
                if board.connected, board.status?.net == "ap", let net = try? await board.readNet(fresh: true), net.mode == "ap" { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            lanSSID = nil
            phoneOnBoardLAN = false
            lanJoin = .idle
            join = .idle
            networkSwitched = true
            startJoin()
        }
    }
}

/// The LAN join's steps, apart from the app so they can be tested with a fake board and a virtual clock.
@MainActor enum LanJoinFlow {
    struct Env {
        var connected: () -> Bool
        var status: () -> BoardStatus?
        var writeNet: (NetConfig) throws -> Void
        var readNet: () async -> NetConfig?          // a fresh read: the board's LAN IP and the network it is on
        var phoneSSID: () async -> String?
        var joinPhone: (NetConfig) async throws -> Void
        var videoActive: () -> Bool                  // the Wi-Fi video channel works: the phone reaches the board
        var savePassword: (String, String) -> Void   // (password, ssid)
        var log: (String) -> Void
        /// The board, at this IP, is a client on this iPhone's own Personal Hotspot: the phone is already there.
        var phoneHosts: (String?) -> Bool = { Hotspot.hostsBoard(boardIP: $0) }
        var sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
        var now: () -> Double = { IPhoneAgent.now() }
    }

    static let leaveWait = 8.0, boardWait = 40.0, phoneWait = 12.0

    /// Points the board at `ssid` and checks that the board and this device get there; every state goes to `set`.
    /// True when joined.
    static func run(ssid: String, pass: String, remember: Bool, env: Env, set: (LanJoinState) -> Void) async -> Bool {
        let lost = String(localized: "The board disconnected. Reconnect it and try again.")
        // On a home network every device there sees the board's AirPlay receiver: only firmware with the LAN lock
        // (LanAuth) lets this device alone mirror and keeps the token off the network.
        guard env.connected() else { set(.failed(lost)); return false }
        guard LanAuth.supported(env.status()) else {
            set(.failed(String(localized: "Update the board's firmware first (Settings › Board, on the board's own Wi-Fi). Older firmware lets every device on the home network mirror to the board.")))
            return false
        }
        let net = NetConfig(mode: "sta", ssid: ssid, pass: pass.isEmpty ? nil : pass)
        let wasOnLAN = env.status()?.net == "sta"
        do { try env.writeNet(net) } catch {
            set(.failed(error.localizedDescription))
            return false
        }
        if remember, !pass.isEmpty { env.savePassword(pass, ssid) }
        env.log("lan: asked the board to join \(ssid)")
        set(.boardConnecting)
        // Already on a network (changing it): status still says "sta" until the board drops the old one, and that
        // old "sta" is no proof of the new network. Wait for it to leave first (it restarts its Wi-Fi at once).
        if wasOnLAN {
            let left = env.now() + leaveWait
            while !Task.isCancelled && env.now() < left && env.status()?.net == "sta" { await env.sleep(0.25) }
        }
        let deadline = env.now() + boardWait
        while !Task.isCancelled && env.now() < deadline && env.status()?.net != "sta" {
            guard env.connected() else { set(.failed(lost)); return false }
            await env.sleep(0.5)
        }
        guard !Task.isCancelled else { return false }
        let config = await env.readNet()  // the LAN IP, for the Wi-Fi video channel
        guard env.status()?.net == "sta", config?.ssid == nil || config?.ssid == ssid else {
            set(.failed(String(localized: "The board couldn't join \"\(ssid)\". Check the password, and that this network has a 2.4 GHz band.")))
            return false
        }
        set(.checkingPhone)
        if env.phoneHosts(config?.ip ?? env.status()?.ip) {
            env.log("hotspot: board on this iPhone's Personal Hotspot at \(config?.ip ?? env.status()?.ip ?? "?"); not joining")
            set(.joined)
            return true
        }
        if !env.videoActive(), await env.phoneSSID() != ssid {
            env.log("lan: the board is on \(ssid); joining this phone to it")
            do {
                try await env.joinPhone(net)
            } catch {
                env.log("lan: joining \(ssid) failed: \(Hotspot.describe(error as NSError))")
                if Hotspot.userDenied(error as NSError) {
                    set(.failed(String(localized: "Joining \"\(ssid)\" was declined. Join it in Settings › Wi-Fi, or try again.")))
                    return false
                }
            }
        }
        let phoneDeadline = env.now() + phoneWait
        while !Task.isCancelled && env.now() < phoneDeadline {
            let there = env.videoActive() ? true : await env.phoneSSID() == ssid
            if there {
                set(.joined)
                env.log("lan: on \(ssid)")
                return true
            }
            await env.sleep(0.5)
        }
        guard !Task.isCancelled else { return false }
        // A different SSID on the phone can still be the same router; only a working video channel proves it.
        set(.failed(String(localized: "The board is on \"\(ssid)\" now. Join \"\(ssid)\" on this device, or a network on the same router.")))
        return false
    }
}

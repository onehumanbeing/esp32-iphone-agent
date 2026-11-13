import Foundation

/// The screen feed is gone; acting now would be guessing.
struct BlindError: LocalizedError {
    var reason = "lost the phone screen: reconnect Screen Mirroring"
    var errorDescription: String? { reason }
}

/// Self-healing after a lost link: which part is missing (board, hotspot, mirroring, fresh image), when to ask the user,
/// and when to give up. Pure: the caller polls it with the link state and the time.
struct Recovery {
    /// What the app sees of the link right now.
    struct Link: Equatable {
        var connected: Bool       // BLE link to the board is up
        var sta: Int?             // phones joined to the board's hotspot (nil = unknown)
        var ap: String?           // idle | connected | streaming
        var frameAt: Double       // when the newest decoded frame arrived
        var stalled = false       // the board itself gets no frames from AirPlay: ask the user at once
        var needsPointer = false  // The pointer can disconnect while GATT and mirroring stay up.
    }

    enum Part: Equatable { case board, hotspot, mirroring, frames, pointer }

    struct Stage: Equatable {
        var part: Part
        var ask: Bool  // waited long enough: the user has to do something
    }

    enum Next: Equatable {
        case wait(Stage)
        case live
        case giveUp(String)
    }

    /// How long each part may come back by itself before the user is asked; then the whole limit.
    static let quiet: [Part: Double] = [.board: 30, .pointer: 5, .hotspot: 30, .mirroring: 20, .frames: 20]
    static let limit = 300.0

    let started: Double
    let limit: Double
    private(set) var stage: Stage?
    private var partSince = 0.0

    init(at t: Double, limit: Double = Self.limit) { started = t; self.limit = limit }

    /// Live once the board is back, mirroring streams and a frame newer than the loss has been decoded.
    mutating func next(_ l: Link, at t: Double) -> Next {
        let part: Part? = !l.connected ? .board
            : l.needsPointer ? .pointer
            : l.sta == 0 ? .hotspot
            : l.ap != "streaming" ? .mirroring
            : l.frameAt <= started ? .frames
            : nil
        guard let part else { stage = nil; return .live }
        if part != stage?.part { partSince = t }
        stage = Stage(part: part, ask: t - partSince >= (part == .frames && l.stalled ? 0 : Self.quiet[part]!))
        if t - started >= limit { return .giveUp(Self.reason(part)) }
        return .wait(stage!)
    }

    static func reason(_ part: Part) -> String {
        switch part {
        case .board: return String(localized: "the board did not come back in 5 minutes")
        case .pointer: return String(localized: "The Bluetooth pointer did not reconnect in 5 minutes.")
        case .hotspot: return String(localized: "the iPhone did not rejoin the board's Wi-Fi in 5 minutes")
        case .mirroring: return String(localized: "Screen Mirroring did not come back in 5 minutes")
        case .frames: return String(localized: "no fresh screen image arrived in 5 minutes")
        }
    }
}

extension Recovery.Stage {
    /// For the log: "recover: …".
    var logLine: String {
        switch (part, ask) {
        case (.pointer, _): return "waiting for the Bluetooth pointer to reconnect to this iPhone"
        case (.board, false): return "BLE link lost; reconnecting"
        case (.board, true): return "board still gone; asked the user to check it"
        case (.hotspot, false): return "board up, iPhone not on its hotspot (sta 0); waiting for iOS to rejoin"
        case (.hotspot, true): return "iPhone still off the hotspot; asked the user to join it"
        case (.mirroring, false): return "board and hotspot up, no mirroring session; waiting for iOS to resume mirroring"
        case (.mirroring, true): return "mirroring still off; asked the user to start it"
        case (.frames, false): return "mirroring session active, no fresh decoded image; waiting for a frame"
        case (.frames, true): return "mirroring session active, still no fresh decoded image; asked the user to reconnect mirroring"
        }
    }

    /// Dynamic Island label: compact and full.
    var status: IslandStatus {
        switch (part, ask) {
        case (.pointer, _):
            return IslandStatus(short: String(localized: "Pointer"), full: String(localized: "Waiting for the Bluetooth pointer…"), look: nil)
        case (.board, _):
            return .waitingForBoard
        case (.hotspot, false):
            return IslandStatus(short: String(localized: "Joining Wi-Fi…"), full: String(localized: "Rejoining the board's Wi-Fi…"),
                                look: nil, minimal: String(localized: "Wi-Fi"))
        case (.hotspot, true):
            return IslandStatus(short: String(localized: "Join Wi-Fi"), full: String(localized: "Join the board's Wi-Fi to continue"),
                                look: nil, minimal: String(localized: "Wi-Fi"))
        case (.mirroring, false):
            return IslandStatus(short: String(localized: "Mirroring…"), full: String(localized: "Waiting for mirroring…"),
                                look: nil, minimal: String(localized: "Mirror"))
        case (.mirroring, true):
            return IslandStatus(short: String(localized: "Start Mirroring"),
                                full: String(localized: "Tap Screen Mirroring → \(BoardName.current) to continue"),
                                look: nil, minimal: String(localized: "Mirror"))
        case (.frames, false):
            return IslandStatus(short: String(localized: "Waiting frame…"),
                                full: String(localized: "Mirroring is connected. Waiting for a fresh screen image…"),
                                look: nil, minimal: String(localized: "Frame"))
        case (.frames, true):
            return IslandStatus(short: String(localized: "No new frame"),
                                full: String(localized: "Mirroring is connected, but no new screen image has arrived."),
                                look: nil, minimal: String(localized: "Frame"))
        }
    }

    /// One sentence for the Live Activity line, the in-app banner and the notification body.
    var line: String {
        switch (part, ask) {
        case (.pointer, false): return String(localized: "Waiting for the Bluetooth pointer…")
        case (.pointer, true): return String(localized: "Pair the Bluetooth pointer on this iPhone in AssistiveTouch settings.")
        case (.board, _): return IslandStatus.waitingForBoard.full
        case (.hotspot, false): return String(localized: "The board restarted. Waiting for the iPhone to rejoin its Wi-Fi…")
        case (.hotspot, true): return String(localized: "Join the board's Wi-Fi in Settings › Wi-Fi; the run goes on when it is back.")
        case (.mirroring, false): return String(localized: "Board is back. Waiting for Screen Mirroring to resume…")
        case (.mirroring, true): return String(localized: "Open Control Center, tap Screen Mirroring → \(BoardName.current); the run goes on from here.")
        case (.frames, false): return status.full
        case (.frames, true): return String(localized: "Stop and restart Screen Mirroring → \(BoardName.current); I’ll continue when a fresh image arrives.")
        }
    }
}

import Foundation

/// The board did not answer in time; the link is still up (a disconnect throws DeviceError instead).
struct BoardTimeout: LocalizedError {
    let command: String
    let seconds: Double
    var errorDescription: String? { String(format: "the board did not answer '%@' within %.0f s", command, seconds) }
}

struct DeviceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where command lines go: the BLE link, or a fake board in tests.
@MainActor protocol BoardTransport: AnyObject {
    var isConnected: Bool { get }
    func write(_ line: String) throws
    /// Fire-and-forget: write only if the link can take it right now; false = dropped.
    func writeIfIdle(_ line: String) -> Bool
    /// Bytes one write can carry without a response.
    var maxWrite: Int { get }
    /// Drop the link after a timeout; the transport reconnects on its own (like the old TCP close).
    func dropLink()
}

extension BoardTransport {
    func writeIfIdle(_ line: String) -> Bool { (try? write(line)) != nil }
    var maxWrite: Int { 180 }
}

/// What gestures need from the board (CommandChannel, or a fake in tests).
@MainActor protocol HIDDevice: AnyObject {
    var links: Int { get }
    var connected: Bool { get }
    @discardableResult func send(_ command: String) async throws -> String
    func waitConnected(_ timeout: TimeInterval) async -> Bool
}

/// A FIFO async mutex for main-actor code.
@MainActor final class AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Sends the board commands one at a time and matches replies by request id. Port of device.py.
@MainActor final class CommandChannel: HIDDevice {
    weak var transport: BoardTransport?
    private(set) var links = 0  // bumped on every (re)connect, so gestures know to release and re-home
    private let lock = AsyncLock()
    /// The board serves two centrals (this app and a Mac harness) and notifies replies to both: start our ids
    /// far from the harness's small ones, and drop replies to ids we did not send.
    private var nextID = Int.random(in: 100_000...800_000)
    private var logTimes: [Double] = []
    /// "app <command>" lines relayed from the Mac harness.
    var onAppCommand: ((String) -> Void)?
    private var pending: [Int: CheckedContinuation<BoardReply, Error>] = [:]
    private var last = 0.0, beat = 0.0
    var onTiming: ((String, Double) -> Void)?  // command name, ms
    /// The connected board's status (BoardLink): the StopWatch screen and buttons are only for a board that has them.
    var boardStatus: () -> BoardStatus? = { nil }
    /// A StopWatch button, already mapped (StopWatchUI.action).
    var onButton: ((StopWatchUI.Action) -> Void)?
    private var uiLast: StopWatchUI.Want? = .show(StopWatchUI.idle)  // the newest screen state, sent again after a reconnect
    private var uiWanted: StopWatchUI.Want?  // not on the board yet
    private var uiSent: String?
    private var uiTimes: [Double] = []
    private var uiRetry: Task<Void, Never>?
    private var uiRefresh: Task<Void, Never>?
    var clock: () -> Date = { Date() }      // the `c` key's local time
    private(set) var uiPicks: [UUID] = []    // the standby picks of the last `ui` line the board got, for `btn run <i>`
    /// The StopWatch's quick intents (the newest 5, yellow picks one): set by the app. Sent as a `picks` line when
    /// they change and every 3 minutes; a board that answers it gets no `k` in `ui` lines any more.
    var quickIntents: () -> [StandbyPick] = { [] }
    private var quickSent: (names: [String], at: Double)?
    private var quickBusy = false
    private(set) var quickOn = false

    init(transport: BoardTransport? = nil) { self.transport = transport }

    var connected: Bool { transport?.isConnected ?? false }

    /// The transport (re)connected and subscribed.
    func linkUp() {
        links += 1
        last = now(); beat = last  // fresh link: nothing to keep awake yet
        (uiSent, uiWanted) = (nil, uiLast)  // flushUI sends it once the status says StopWatch
        (quickSent, quickOn) = (nil, false)
    }

    // Invalidate in-flight frames and relative coordinates when only the system pointer drops.
    func inputLinkLost() { links += 1 }

    /// The link dropped: fail everything in flight.
    func linkDown() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: DeviceError(message: "board disconnected")) }
    }

    func handleReply(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("app ") { return onAppCommand?(String(text.dropFirst(4))) ?? () }
        if text.hasPrefix("log ") { return }  // our own log lines, relayed to the harness
        if text.hasPrefix("btn ") { return button(String(text.dropFirst(4))) }
        if text.hasPrefix("blog ") {  // the board's AirPlay log: "blog <board ms> <line>"
            let parts = text.dropFirst(5).split(separator: " ", maxSplits: 1)
            return DebugLog.write("board: " + (parts.count > 1 ? String(parts[1]) : ""))
        }
        guard let reply = BoardReply.parse(line), let c = pending.removeValue(forKey: reply.id) else { return }
        c.resume(returning: reply)
    }

    func waitConnected(_ timeout: TimeInterval) async -> Bool {
        let deadline = now() + timeout
        while !connected && now() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        return connected
    }

    /// Seconds the board may take: replies need up to ~2 s at p99, moves are paced (10 units per 8 ms),
    /// typing is per character.
    nonisolated static func timeout(_ command: String) -> Double {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? "", arg = parts.count > 1 ? parts[1] : ""
        switch name {
        case "move": return 5 + Double(arg.split(separator: " ").compactMap { Int($0) }.map(abs).max() ?? 0) / 10 * 0.012
        case "type":
            // Sized for one chunk. A longer command (older call sites) is capped the same way so the app
            // does not wait out a watchdog reboot. Initial estimate, matched to TypeChunks.maxChars.
            return 5 + 0.1 * Double(min(arg.count, TypeChunks.maxChars))
        case "ping": return 8  // an idle check: tolerate a hiccup rather than drop a healthy board
        case "snap": return 15  // a whole GOP over BLE
        case "bench": return 5 + (Double(arg) ?? 0) / 10  // KB at >= 80 kbps
        default: return 5
        }
    }

    /// Reduce video traffic on a reply timeout before retrying eligible commands.
    var onTimeout: ((String) async -> Void)?

    /// Send one command; returns the text after "ok" (e.g. bench's ms). Throws DeviceError on err/timeout.
    @discardableResult
    func send(_ command: String) async throws -> String {
        do {
            return try await send(command, timeout: nil)
        } catch let e as BoardTimeout {
            guard command != "ping", !command.hasPrefix("stream"), let onTimeout else { throw e }
            await onTimeout(command)
            // The board may already have acted. Retry only queries and commands that reapply the same state.
            let name = command.split(separator: " ", maxSplits: 1).first
            switch name {
            case "home", "pace", "release", "reset", "snap", "bench", "logs", "vdbg", "crash", "res", "fps", "txpower", "coex": break
            default: throw e
            }
            DebugLog.write("cmd retry after timeout: \(command.prefix(40))")
            return try await send(command, timeout: nil)
        }
    }

    /// A timeout is the board being slow (e.g. a snap while it also streams), not a lost link: it throws
    /// BoardTimeout and keeps the connection; only a real CoreBluetooth disconnect fails as link lost.
    @discardableResult
    func send(_ command: String, timeout custom: Double?, checking: () throws -> Void = {}) async throws -> String {
        guard connected, let transport else { throw DeviceError(message: "board not connected") }
        let timeout = custom ?? Self.timeout(command)
        let name = String(command.split(separator: " ").first ?? "")
        await lock.lock()
        defer { lock.unlock() }
        // A cancelled gesture still needs to release held input and wait for the board's reply.
        let releasesInput = command == "release" || command == "reset"
        if !releasesInput { try Task.checkCancellation() }
        try checking()
        let started = now()
        let id = nextID
        nextID += 1
        let reply: BoardReply
        do {
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<BoardReply, Error>) in
                    pending[id] = c
                    do { try transport.write("\(id) \(command)") } catch {
                        pending[id] = nil
                        c.resume(throwing: error)
                        return
                    }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                        self?.fail(id, DeviceError(message: "timeout"))
                    }
                }
            } onCancel: {
                guard !releasesInput else { return }
                Task { @MainActor [weak self] in self?.fail(id, CancellationError()) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let ms = (now() - started) * 1000
            if (error as? DeviceError)?.message == "timeout" {
                if name != "ping" { DebugLog.write(String(format: "cmd #%d %@ → timeout after %.0f ms", id, String(command.prefix(40)), ms)) }
                throw BoardTimeout(command: String(command.prefix(30)), seconds: timeout)
            }
            DebugLog.write(String(format: "cmd #%d %@ → link lost after %.0f ms: %@", id, String(command.prefix(40)), ms,
                                  error.localizedDescription))
            throw DeviceError(message: "board link lost during '\(command.prefix(30))': \(error.localizedDescription)")
        }
        beat = now()  // last reply of any kind
        if command != "ping" {
            last = beat  // last real command: the phone's idle time
            onTiming?(String(command.split(separator: " ").first ?? ""), (now() - started) * 1000)
        }
        if name != "ping" {
            DebugLog.write(String(format: "cmd #%d %@ → %@ %@ (%.0f ms)", id, String(command.prefix(40)),
                                  reply.ok ? "ok" : "err", String(reply.text.prefix(60)), (now() - started) * 1000))
        }
        guard reply.ok else { throw DeviceError(message: "err " + reply.text) }
        return reply.text
    }

    /// Send a debug-log line to the Mac harness through the board (`log <text>`): fire-and-forget, at most
    /// 10 a second, truncated to one write, dropped when the link is busy.
    @discardableResult
    func relayLog(_ text: String) -> Bool {
        guard connected, let transport else { return false }
        let t = now()
        logTimes = logTimes.filter { t - $0 < 1 }
        guard logTimes.count < 10 else { return false }
        let prefix = "\(nextID) log "
        nextID += 1
        var body = text.replacingOccurrences(of: "\n", with: " ")
        while prefix.utf8.count + body.utf8.count > transport.maxWrite && !body.isEmpty { body.removeLast() }
        guard transport.writeIfIdle(prefix + body) else { return false }
        logTimes.append(t)
        return true
    }

    // MARK: - StopWatch screen and buttons

    /// The run's state for the StopWatch screen (nil: `ui off`). Fire-and-forget: only the newest state is kept,
    /// sent when it changed, at most 2 a second, and later (every 0.5 s) while the link is busy. A run or standby
    /// goes again every 5 s (refreshUI): the screen falls back to idle after 10 s without a line. Other boards: nothing.
    func showUI(_ state: AgentActivityAttributes.ContentState?) {
        let want = state.map(StopWatchUI.Want.show) ?? .off
        (uiLast, uiWanted) = (want, want)
        flushUI()
    }

    /// Called on every status too: the first status after a link-up says whether this board is a StopWatch.
    func flushUI() {
        flushPicks()
        guard var want = uiWanted, connected, let transport, StopWatchUI.enabled(boardStatus()) else { return }
        if quickOn, case .show(var state) = want { state.picks = nil; want = .show(state) }  // `picks` has them
        let prefix = "\(nextID) "
        let room = min(StopWatchUI.maxLine, transport.maxWrite - prefix.utf8.count)
        guard case let (body, picks)? = StopWatchUI.command(want, max: room, at: clock())
        else { return uiWanted = nil }
        guard body != uiSent else { return uiWanted = nil }
        let t = now()
        uiTimes = uiTimes.filter { t - $0 < 1 }
        guard uiTimes.count < 2, transport.writeIfIdle(prefix + body) else { return retryUI() }
        nextID += 1
        uiTimes.append(t)
        (uiSent, uiWanted) = (body, nil)
        if let picks, !quickOn { uiPicks = picks }
        startRefresh()
    }

    /// The line on the board's screen once more, unchanged or with the new minute: the board knows the app is there
    /// (awake) while lines come. A finished run has had its 5 s on the screen by then: idle goes instead. `off` is
    /// not repeated.
    func refreshUI() {
        guard case .show(let state)? = uiLast else { return }
        if state.finished { uiLast = .show(StopWatchUI.idle) }
        (uiSent, uiWanted) = (nil, uiLast)
        flushUI()
    }

    private func startRefresh() {
        guard uiRefresh == nil, case .show? = uiLast else { return }
        uiRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, case .show? = self.uiLast else { break }
                self.refreshUI()
            }
            self?.uiRefresh = nil
        }
    }

    /// The quick intents to a StopWatch: when they changed, or 3 minutes after the last time. Older firmware answers
    /// `err`: it keeps the standby picks of the `ui` line.
    func flushPicks() {
        guard connected, !quickBusy, StopWatchUI.enabled(boardStatus()) else { return }
        let picks = Array(quickIntents().prefix(StopWatchUI.maxQuick))
        let names = picks.map { StopWatchUI.truncated($0.name, bytes: StopWatchUI.maxPick) }
        if let sent = quickSent, sent.names == names, now() - sent.at < 180 { return }
        guard let data = try? JSONEncoder().encode(names), let json = String(data: data, encoding: .utf8) else { return }
        quickBusy = true
        Task {
            defer { quickBusy = false }
            do {
                try await send("picks " + json)
                (quickSent, quickOn, uiPicks) = ((names, now()), true, picks.map(\.id))
            } catch {
                quickSent = (names, now())  // older firmware: try again in 3 minutes, `k` meanwhile
                if quickOn { (quickOn, uiSent) = (false, nil) }
            }
        }
    }

    private func retryUI() {
        guard uiRetry == nil else { return }
        uiRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.uiRetry = nil
            self?.flushUI()
        }
    }

    /// What the phone made of the StopWatch's voice, for its screen. Only to a StopWatch.
    func sendVoice(_ result: BoardVoice.Result) {
        guard StopWatchUI.enabled(boardStatus()), let transport else { return }
        let line = StopWatchUI.voiceLine(result, max: transport.maxWrite - "\(nextID) ".utf8.count - 4)
        Task {
            do { try await send(line) } catch { DebugLog.write("stopwatch: \(line.prefix(20)) not sent: \(error.localizedDescription)") }
        }
    }

    /// `btn <verb> [arg]`, sent by the board on its own. Only a StopWatch's are heard.
    private func button(_ text: String) {
        guard StopWatchUI.enabled(boardStatus()) else { return }
        guard let action = StopWatchUI.action(text, picks: uiPicks) else {
            return DebugLog.write("stopwatch: button ignored: \(text.prefix(30))")
        }
        DebugLog.write("stopwatch: button \(text.prefix(30))")
        onButton?(action)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// While idle: ping every few seconds, so a board that went away shows as gone within seconds, and nudge
    /// the pointer now and then so the phone does not auto-lock. Runs until cancelled.
    func keepAwake(idle: Double = 25, heartbeat: Double = 2, screenLive: @escaping () -> Bool,
                   nudgeWhenIdle: @escaping () -> Bool = { false }) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(heartbeat * 1e9))
            if !connected || now() - beat < heartbeat { continue }
            do {
                // 20 s is under a 30 s auto-lock. Initial estimate: HID may reset the idle timer; confirm on a device.
                // The pair of moves nets to no pointer change and does not go through Pointer, so it is not a rehome.
                let wait = nudgeWhenIdle() ? 20.0 : idle
                if now() - last > wait && (screenLive() || nudgeWhenIdle()) {
                    for move in ["move 1 0", "move -1 0"] {
                        try await send(move, timeout: nil) {
                            guard screenLive() else { throw CancellationError() }
                        }
                    }
                } else {
                    try await send("ping")
                }
            } catch is CancellationError {
                continue
            } catch {
                log("board gone: \(error.localizedDescription)")
            }
        }
    }

    var log: (String) -> Void = { print($0) }
}

func now() -> Double { Date().timeIntervalSince1970 }

/// M5Stack StopWatch: its screen shows the run (the Live Activity's state, `ui <json>`) and its buttons send
/// `btn <verb> [arg]`. Only a board whose status says so (board "stopwatch", ui 1) gets or is heard on any of it.
enum StopWatchUI {
    typealias State = AgentActivityAttributes.ContentState
    static let maxLine = 200, maxText = 80, maxPick = 24, maxPicks = 3, maxQuick = 5

    enum Want: Equatable { case off, show(State) }

    /// No run: the app is there and the board shows its character awake (AppModel.mood: idle with a board). No picks.
    static let idle: State = {
        var state = State(mood: .idle, step: 0, limit: 0, line: "", phase: .standby)
        state.picks = []
        return state
    }()

    /// voice: yellow (true, run the heard text) or blue (false, drop it) after the board showed it (BoardVoice).
    enum Action: Equatable { case command(AgentCommand), home, run(UUID), voice(Bool) }

    static func enabled(_ status: BoardStatus?) -> Bool { status?.board == "stopwatch" && status?.ui == 1 }

    /// The keys the firmware reads: mood, phase, step, limit, text, done / total, finished, standby picks, the
    /// local time "HH:mm" (the board has no clock), where the eyes look (x, y; left out at 0) and v 1: this app takes
    /// the board's voice (hold yellow, BoardVoice). Older firmware ignores keys it does not know.
    struct Payload: Encodable, Equatable {
        var c: String
        var m: String, p: String, s: Int, l: Int
        var t: String?
        var d: Int?, n: Int?
        var f: Bool
        var k: [String]?
        var x: Double?, y: Double?
        var v = 1
    }

    /// What the character says, as the expanded island: its words while the run goes, the line otherwise (help, done).
    static func says(_ state: State) -> String {
        state.phase == .running && !state.finished && !state.labelFull.isEmpty ? state.labelFull : state.line
    }

    private static func look(_ v: Double) -> Double? {
        let r = (max(-1, min(1, v)) * 10).rounded() / 10
        return r == 0 ? nil : r
    }

    /// The command line without the request id, at most `max` bytes, and the picks it carries (nil: none).
    /// Too long: the text gets shorter, then goes, then the picks go.
    static func command(_ want: Want, max: Int = maxLine, at time: Date = Date()) -> (String, [UUID]?)? {
        guard case .show(let state) = want else { return "ui off".utf8.count <= max ? ("ui off", nil) : nil }
        let picks = state.picks.map { Array($0.prefix(maxPicks)) }
        var p = Payload(c: clock(time), m: state.mood.rawValue, p: state.phase.rawValue, s: state.step, l: state.limit,
                        t: truncated(says(state).replacingOccurrences(of: "\n", with: " "), bytes: maxText),
                        d: state.done, n: state.total, f: state.finished,
                        k: picks?.map { truncated($0.name, bytes: maxPick) }, x: look(state.lookX), y: look(state.lookY))
        while true {
            if let line = line(p), line.utf8.count <= max { return (line, p.k == nil ? nil : picks?.map(\.id)) }
            if let t = p.t, !t.isEmpty { p.t = String(t.dropLast()) }
            else if p.t != nil { p.t = nil }
            else if p.k != nil { p.k = nil }
            else { return nil }
        }
    }

    static func clock(_ time: Date) -> String {
        let t = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", t.hour ?? 0, t.minute ?? 0)
    }

    private static func line(_ p: Payload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(p)).flatMap { String(data: $0, encoding: .utf8) }.map { "ui " + $0 }
    }

    /// The board shows this much of what was heard (SW_SAID_MAX); the app keeps all of it to run.
    static let maxSaid = 120

    /// `voice heard <text>` or `voice fail <code>` for the board, within `max` bytes.
    static func voiceLine(_ result: BoardVoice.Result, max: Int) -> String {
        switch result {
        case .heard(let text):
            let prefix = "voice heard "
            return prefix + truncated(text.replacingOccurrences(of: "\n", with: " "),
                                      bytes: Swift.max(0, Swift.min(maxSaid, max - prefix.utf8.count)))
        case .failed(let code): return "voice fail " + code
        }
    }

    /// The longest prefix of whole characters within `bytes` UTF-8 bytes.
    static func truncated(_ text: String, bytes: Int) -> String {
        var out = "", used = 0
        for c in text {
            used += c.utf8.count
            if used > bytes { break }
            out.append(c)
        }
        return out
    }

    /// `<verb> [arg]` after "btn ". `run <i>`: the i-th (from 0) of the picks the board was last sent.
    static func action(_ text: String, picks: [UUID]) -> Action? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "stop": return .command(.stop)
        case "pause": return .command(.pause)
        case "unpause": return .command(.unpause)
        case "continue": return .command(.resume)
        case "takeover": return .command(.takeOver)
        case "home": return .home
        case "voice":
            guard parts.count > 1, ["go", "cancel"].contains(parts[1]) else { return nil }
            return .voice(parts[1] == "go")
        case "run":
            guard parts.count > 1, let i = Int(parts[1]), picks.indices.contains(i) else { return nil }
            return .run(picks[i])
        default: return nil
        }
    }
}

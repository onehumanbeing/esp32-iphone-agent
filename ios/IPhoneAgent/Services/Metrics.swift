import Foundation

/// Live numbers for the Diagnostics page; a snapshot goes into every trace (metrics.json).
@MainActor final class Metrics: ObservableObject {
    struct Step: Codable {
        var frameMs = 0.0, llmMs = 0.0, hidMs = 0.0
        var settleMs = 0.0  // of frameMs (and any other wait): time in `settled`
        var snap = false  // a snap was asked for (or the run is in snap mode)

        /// The free line's `X-Handsy-Step` value: this step's timing in seconds, and `gap`, from its model reply to
        /// the next request. Numbers only, each capped, so the value stays short.
        func header(gap: Double) -> String {
            func s(_ v: Double) -> String { String(format: "%.1f", min(max(v, 0), 999.9)) }
            return "llm=\(s(llmMs / 1000)),frame=\(s(frameMs / 1000)),hid=\(s(hidMs / 1000)),"
                + "settle=\(s(settleMs / 1000)),mode=\(snap ? "snap" : "stream"),gap=\(s(gap))"
        }
    }

    // board, from status
    @Published var board: BoardStatus?
    @Published var statusAge = 0.0  // s since the last status notify
    // BLE, measured in the app
    @Published var bleKbps = 0.0
    @Published var mtu = 0
    @Published var drops = 0
    @Published var benchKbps: Double?
    // video
    @Published var fps = 0.0
    @Published var idrIntervalMs: Double?
    @Published var snapMs: Double?
    @Published var decodeMs = 0.0
    @Published var decodeErrors = 0
    @Published var backgroundDecodeErrors = 0
    // agent
    @Published var steps: [Step] = []  // the last 40
    private var stepCount = 0
    @Published var llmFirstMs: Double?
    @Published var llmTotalMs: Double?
    @Published var llmPingMs: Double?
    @Published var hidMs: [String: Double] = [:]  // last round trip per command
    // background
    @Published var backgroundSince: Double?
    @Published var backgroundAlive = 0.0  // s alive in background (current or last stint)
    @Published var suspensions = 0
    @Published var backgroundSummary: String?  // the last once-a-minute background line

    private var windowBytes = 0, windowFrames = 0
    private var windowStart = now()
    private var lastIDR: Double?
    private var lastTick = now()
    private var lastStatus: Double?

    func status(_ s: BoardStatus) {
        board = s
        lastStatus = now()
    }

    func videoBytes(_ n: Int) { windowBytes += n }
    func videoDrops(_ n: Int) { drops += n }
    func frameDecoded(ms: Double) {
        windowFrames += 1
        decodeMs = ms
    }
    func decodeError(background: Bool) {
        decodeErrors += 1
        if background { backgroundDecodeErrors += 1 }
    }
    func idrSeen() {
        let t = now()
        if let lastIDR { idrIntervalMs = (t - lastIDR) * 1000 }
        lastIDR = t
    }
    func snapLatency(_ ms: Double) { snapMs = ms }
    func llm(first: Double?, total: Double) {
        llmFirstMs = first.map { $0 * 1000 }
        llmTotalMs = total * 1000
    }
    func runStarted() { stepCount = 0 }
    func step(_ s: Step) {
        steps = Array((steps + [s]).suffix(40))
        stepCount += 1
        DebugLog.write(String(format: "step %d timing: frame %.0f ms (settle %.0f ms%@), LLM %.0f ms, HID %.0f ms",
                              stepCount, s.frameMs, s.settleMs, s.snap ? ", snap" : "", s.llmMs, s.hidMs))
    }

    /// Called every second by a timer; also detects suspension (a gap far longer than the tick).
    func tick() {
        let t = now()
        if t - lastTick > 5 { suspensions += 1 }
        lastTick = t
        let span = max(t - windowStart, 0.001)
        bleKbps = Double(windowBytes) * 8 / 1000 / span
        fps = Double(windowFrames) / span
        windowBytes = 0; windowFrames = 0; windowStart = t
        statusAge = lastStatus.map { t - $0 } ?? 0
        if let since = backgroundSince { backgroundAlive = t - since }
    }

    func enteredBackground() { backgroundSince = now(); backgroundAlive = 0 }
    func enteredForeground() { backgroundSince = nil }

    /// Everything as JSON-ready values, for metrics.json.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "ble_kbps_app": bleKbps, "mtu": mtu, "drops": drops, "fps": fps, "decode_ms": decodeMs,
            "decode_errors": decodeErrors, "background_decode_errors": backgroundDecodeErrors,
            "background_alive_s": backgroundAlive, "suspensions": suspensions, "hid_ms": hidMs,
            "steps": steps.map { ["frame_ms": $0.frameMs, "llm_ms": $0.llmMs, "hid_ms": $0.hidMs, "settle_ms": $0.settleMs,
                                  "snap": $0.snap] },
        ]
        out["bench_kbps"] = benchKbps
        out["idr_interval_ms"] = idrIntervalMs
        out["snap_ms"] = snapMs
        out["llm_first_ms"] = llmFirstMs
        out["llm_total_ms"] = llmTotalMs
        if let board, let data = try? JSONEncoder().encode(board) {
            out["board"] = try? JSONSerialization.jsonObject(with: data)
        }
        return out
    }
}

/// The previous step's timing, sent once on the next actor request to the free line (`X-Handsy-Step`) so the server
/// can tell app-side waits from its own. Timing only: no task, no screen content.
final class StepReport: @unchecked Sendable {
    static let shared = StepReport()
    static let header = "X-Handsy-Step"
    private let lock = NSLock()
    private var pending: Metrics.Step?
    private var repliedAt: Double?

    /// The actor's reply arrived: `gap` counts from here.
    func replied(at t: Double = now()) { lock.withLock { repliedAt = t } }
    /// The step after that reply is over.
    func finished(_ step: Metrics.Step) { lock.withLock { pending = step } }
    func clear() { lock.withLock { pending = nil; repliedAt = nil } }

    /// The header for the next request, once per step.
    func take(at t: Double = now()) -> [String: String] {
        lock.withLock {
            defer { pending = nil }
            guard let pending, let repliedAt else { return [:] }
            return [Self.header: pending.header(gap: t - repliedAt)]
        }
    }
}

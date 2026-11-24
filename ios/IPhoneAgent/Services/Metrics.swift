import Foundation

/// Live numbers for the Diagnostics page; a snapshot goes into every trace (metrics.json).
@MainActor final class Metrics: ObservableObject {
    struct Step: Codable {
        var frameMs = 0.0, llmMs = 0.0, hidMs = 0.0
        var settleMs = 0.0  // of frameMs (and any other wait): time in `settled`
        var snap = false  // a snap was asked for (or the run is in snap mode)
        /// From the actor's reply to the first gesture command, which neither LLM nor HID counted (2026-11-11: 0.04-2.4 s
        /// a step, 0.9 s on average, in one 14-step run), and its parts: the reply handled and the plan recorded
        /// (`parse`), the pause gate (`gate`), the look at what moved by itself (`motion`).
        var leadMs = 0.0, parseMs = 0.0, gateMs = 0.0, motionMs = 0.0
        /// The rest of the step's time that no field above counts, and of the whole step the time the steps list
        /// took to update after each recorded step (`record`, on the main thread).
        var otherMs = 0.0, recordMs = 0.0
        /// From the last gesture to the step's end, all of it (frame, verdict, landing, re-tap, feed, cache, checkpoint):
        /// 2026-11-18, a step's `other` was 17.9 s, all after its tap, and no field said where.
        var afterMs = 0.0
        var tree = ""  // StepWaits.tree: where the actor's tree was built, and the phone's build ms
        /// Change check, pointer wiggle, image shrink, on-device tree, and the gap between steps.
        var verdictMs = 0.0, landingMs = 0.0, treeMs = 0.0, imageMs = 0.0, housekeepingMs = 0.0
        /// Model stream: first token, first complete DO line, and the end of the stream. 0 when unknown.
        var firstTokenMs = 0.0, firstDoMs = 0.0, streamEndMs = 0.0
        var stepIndex = 0
        var specUsed = false, specCancelled = false, specSavedMs = 0.0

        var object: JObject {
            ["frame_ms": .num(frameMs.rounded()), "settle_ms": .num(settleMs.rounded()),
             "verdict_ms": .num(verdictMs.rounded()), "landing_ms": .num(landingMs.rounded()),
             "llm_ms": .num(llmMs.rounded()), "first_token_ms": .num(firstTokenMs.rounded()),
             "first_do_ms": .num(firstDoMs.rounded()), "stream_end_ms": .num(streamEndMs.rounded()),
             "hid_ms": .num(hidMs.rounded()), "lead_ms": .num(leadMs.rounded()),
             "other_ms": .num(otherMs.rounded()), "after_ms": .num(afterMs.rounded()), "housekeeping_ms": .num(housekeepingMs.rounded()),
             "image_ms": .num(imageMs.rounded()), "tree_ms": .num(treeMs.rounded()),
             "step": .int(stepIndex), "spec_used": .bool(specUsed), "spec_cancelled": .bool(specCancelled),
             "spec_saved_ms": .num(specSavedMs.rounded())]
        }

        /// The reply-to-HID split, the first gesture starting `at` (no reply time, e.g. a scripted step: left at 0).
        mutating func lead(replied: Double, decided: Double, gating: Double, at started: Double) {
            guard replied > 0, started >= replied else { return }
            (leadMs, parseMs, gateMs) = ((started - replied) * 1000, max(0, decided - replied) * 1000, (started - gating) * 1000)
        }

        /// The free line's `X-Handsy-Step` value: this step's timing in seconds, and `gap`, from its model reply to
        /// the next request. Numbers only, each capped, so the value stays short.
        func header(gap: Double) -> String {
            func s(_ v: Double) -> String { String(format: "%.1f", min(max(v, 0), 999.9)) }
            return "llm=\(s(llmMs / 1000)),frame=\(s(frameMs / 1000)),hid=\(s(hidMs / 1000)),"
                + "settle=\(s(settleMs / 1000)),mode=\(snap ? "snap" : "stream"),gap=\(s(gap))"
        }

        /// Where `llm` and `gap` went, for the gateway to tell the network from the phone (2026-11-25: the app's llm
        /// was 2-6 s over the gateway's own call and nothing said why): first token as the app saw it, the image and
        /// the on-device tree made before the request, the change check, the pointer check, all after the gesture.
        /// Only parts that took time, most telling first; an old gateway drops keys it does not know.
        var parts: [String] {
            let all = [("ttft", firstTokenMs), ("after", afterMs), ("verdict", verdictMs), ("land", landingMs),
                       ("img", imageMs), ("treems", treeMs)]
            return all.filter { $0.1 >= 50 }.map { "\($0.0)=" + String(format: "%.1f", min($0.1 / 1000, 999.9)) }
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
        DebugLog.write(String(format: "step %d timing: frame %.0f ms (settle %.0f ms%@), verdict %.0f ms (landing %.0f), "
                              + "LLM %.0f ms (first %.0f, DO %.0f, end %.0f), HID %.0f ms, "
                              + "reply to HID %.0f ms (parse %.0f, gate %.0f, motion %.0f), other %.0f ms (record %.0f, gap %.0f), after gestures %.0f ms",
                              stepCount, s.frameMs, s.settleMs, s.snap ? ", snap" : "", s.verdictMs, s.landingMs,
                              s.llmMs, s.firstTokenMs, s.firstDoMs, s.streamEndMs, s.hidMs,
                              s.leadMs, s.parseMs, s.gateMs, s.motionMs, s.otherMs, s.recordMs, s.housekeepingMs, s.afterMs)
                       + (s.tree.isEmpty ? "" : ", tree \(s.tree)")
                       + (s.specUsed ? ", speculative" : "") + (s.specCancelled ? ", speculative cancelled" : ""))
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

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    func enteredBackground() { backgroundSince = now(); backgroundAlive = 0 }
    func enteredForeground() { backgroundSince = nil }

    /// Everything as JSON-ready values, for metrics.json.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "ble_kbps_app": bleKbps, "mtu": mtu, "drops": drops, "fps": fps, "decode_ms": decodeMs,
            "decode_errors": decodeErrors, "background_decode_errors": backgroundDecodeErrors,
            "background_alive_s": backgroundAlive, "suspensions": suspensions, "hid_ms": hidMs,
            "steps": steps.map { step -> [String: Any] in
                var row: [String: Any] = ["frame_ms": step.frameMs, "llm_ms": step.llmMs, "hid_ms": step.hidMs,
                                          "settle_ms": step.settleMs, "snap": step.snap, "verdict_ms": step.verdictMs,
                                          "landing_ms": step.landingMs, "tree_ms": step.treeMs, "image_ms": step.imageMs,
                                          "housekeeping_ms": step.housekeepingMs, "first_token_ms": step.firstTokenMs,
                                          "first_do_ms": step.firstDoMs, "stream_end_ms": step.streamEndMs,
                                          "other_ms": step.otherMs, "step": step.stepIndex,
                                          "spec_used": step.specUsed, "spec_cancelled": step.specCancelled]
                return row
            },
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
    static let maxPairs = 12, maxLength = 160  // gateway validation.step_timing
    private let lock = NSLock()
    private var pending: Metrics.Step?
    private var repliedAt: Double?
    /// This run's pointer trouble so far: landings found past Pointer.maxMiss, and recalibrations tried. Counts only,
    /// sent with the timing (`far=`, `recal=`) so a run that tapped wrong for long shows why (2026-11-24: 133 steps
    /// of taps ~500 units low, and nothing in the records said so).
    private var far = 0, recal = 0
    func farLanding() { lock.withLock { far += 1 } }
    func recalibrated() { lock.withLock { recal += 1 } }
    /// The run's start, sent once with its first request: seconds from the Run tap (`start`) and of them the app
    /// opened by name before the first look (`open`). 2026-11-25: the claim-to-first-call wait was 23 s for one run
    /// in ten and no record said where it went.
    private var startedAt: Double?, openSeconds: Double?
    func runStarted(at t: Double) { lock.withLock { (startedAt, openSeconds) = (t, nil) } }
    func opened(seconds: Double) { lock.withLock { openSeconds = seconds } }

    /// The actor's reply arrived: `gap` counts from here.
    func replied(at t: Double = now()) { lock.withLock { repliedAt = t } }
    /// The step after that reply is over.
    func finished(_ step: Metrics.Step) { lock.withLock { pending = step } }
    func clear() { lock.withLock { (pending, repliedAt, far, recal) = (nil, nil, 0, 0) } }

    /// The header for the next request, once per step.
    func take(at t: Double = now()) -> [String: String] {
        lock.withLock {
            defer { pending = nil }
            if let startedAt, repliedAt == nil {  // the run's first request
                self.startedAt = nil
                let open = openSeconds.map { String(format: ",open=%.1f", min(max($0, 0), 999.9)) } ?? ""
                return [Self.header: String(format: "start=%.1f", min(max(t - startedAt, 0), 999.9)) + open]
            }
            guard let pending, let repliedAt else { return [:] }
            var value = pending.header(gap: t - repliedAt)
            if far + recal > 0 { value += ",far=\(far),recal=\(recal)" }  // an old gateway drops unknown keys
            // the gateway reads at most 12 pairs of a value up to 160 characters: the parts fill what is left
            for part in pending.parts where value.split(separator: ",").count < Self.maxPairs
                && value.count + part.count + 1 <= Self.maxLength { value += "," + part }
            return [Self.header: value]
        }
    }
}

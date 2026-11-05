import Foundation

/// Stops waiting on a decider that keeps failing (Jev's server or the model): same rule as the gateway's
/// handsy_trial/breaker.py. 3 failures within 60 s open it for 2 min; then one probe call goes through. A good
/// probe closes it, a bad one opens it again for twice as long (at most 10 min). "Jev is unsure" is an answer,
/// not a failure. Memory only: a new run setup (settings, line, relaunch) starts closed. No UI, only the log.
@MainActor final class Breaker {
    let name: String
    private let clock: () -> Double
    private let threshold = 3, window = 60.0, base = 120.0, cap = 600.0
    private var failures: [Double] = []
    private var openUntil = 0.0
    private var cooldown = 120.0
    private var probing = false
    /// For the trace: "open", "probe" or "closed" when the state changed.
    var onChange: ((String) -> Void)?

    init(_ name: String, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.name = name
        self.clock = clock
    }

    var isOpen: Bool { openUntil > 0 && (probing || clock() < openUntil) }

    /// True when a call may go out (closed, or the one probe after the cool-down).
    func allow() -> Bool {
        if openUntil == 0 { return true }
        if probing || clock() < openUntil { return false }
        probing = true
        changed("probe")
        return true
    }

    func record(ok: Bool) {
        let now = clock()
        if ok {
            if openUntil > 0 { changed("closed") }
            failures = []; openUntil = 0; cooldown = base; probing = false
            return
        }
        if probing {  // the probe failed: open again, twice as long
            probing = false
            cooldown = min(cap, cooldown * 2)
            openUntil = now + cooldown
            changed("open")
            return
        }
        failures = failures.filter { now - $0 <= window } + [now]
        if failures.count >= threshold {
            failures = []
            openUntil = now + cooldown
            changed("open")
        }
    }

    /// A call that ended without telling anything (cancelled): let another probe go.
    func release() { probing = false }

    private func changed(_ state: String) {
        DebugLog.write(String(format: "breaker %@: %@%@", name, state,
                              state == "open" ? String(format: " %.0f s", cooldown) : ""))
        onChange?(state)
    }
}

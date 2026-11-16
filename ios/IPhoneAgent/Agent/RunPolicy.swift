import Foundation

/// How a run behaves when nobody is watching. `attended` is today's behavior.
/// Numbers are initial estimates, to be tuned from on-device soak runs.
struct RunPolicy: Equatable {
    var unattended = false
    /// Lost board, hotspot or mirroring. Attended stays at `Recovery.limit` (5 minutes).
    var recoveryLimit: Double = Recovery.limit
    /// nil waits for a person with no limit. Unattended uses 120 seconds.
    var helpTimeout: Double? = nil
    /// What a risky confirm does when nobody answers. Never `.resume`: that would approve it.
    var confirmDefault: AgentLoop.HelpChoice = .skip
    /// Times an unattended run may go back to the Home Screen and try the task again.
    var maxRestarts = 0
    /// Nudge the pointer during long idle waits. Whether that resets auto-lock has to be checked on a device.
    var keepAwake = false
    /// Open Control Center and re-select the board when mirroring drops. No effect until taps have been learned.
    var selfHealMirroring = false
    /// 429 per minute, 5xx and timeouts. 30 seconds, doubling, capped at 10 minutes.
    var backoffBase: Double = 30
    var backoffCap: Double = 600

    static let attended = RunPolicy()

    static let unattendedRecovery: Double = 2 * 60 * 60
    static let unattendedHelp: Double = 120

    static func unattended(repairMirroring: Bool) -> RunPolicy {
        RunPolicy(unattended: true, recoveryLimit: unattendedRecovery, helpTimeout: unattendedHelp,
                  confirmDefault: .skip, maxRestarts: 3, keepAwake: true, selfHealMirroring: repairMirroring)
    }

    /// A help or confirm prompt that ran out of time. A confirm never comes back `.resume`.
    func fallback(reason: String, confirm: Bool, restarts: Int) -> AgentLoop.HelpChoice {
        if confirm { return confirmDefault == .resume ? .skip : confirmDefault }
        let retry = reason.contains(AgentLoop.stallReason) || reason.contains(AgentLoop.stepLimitReason)
            || reason.contains("errors in a row") || reason.contains(StuckGuard.reason)
        if retry && restarts < maxRestarts { return .restart }
        return .stop
    }

    func backoff(attempt: Int) -> Double {
        min(backoffBase * pow(2, Double(max(0, attempt))), backoffCap)
    }

    /// Minute limits, server errors and timeouts. A used-up daily quota or an ended free-line run stays fatal.
    static func backsOff(_ error: Error) -> Bool {
        if ModelRequestFailure.isTimeout(error) { return true }
        guard let e = error as? LLMError else { return false }
        if e.kind == "rate_limit_day" || e.kind == "trial_run_ended" { return false }
        if e.kind == "rate_limit_minute" || e.status == 429 { return true }
        if (500...599).contains(e.status) { return true }
        return false
    }

    var trace: JObject {
        ["unattended": .bool(unattended), "recovery_s": .num(recoveryLimit),
         "help_timeout_s": helpTimeout.map { .num($0) } ?? .str("none"),
         "confirm": .str(confirmDefault == .stop ? "stop" : "skip"),
         "max_restarts": .int(maxRestarts), "keep_awake": .bool(keepAwake),
         "heal_mirroring": .bool(selfHealMirroring)]
    }
}

/// First caller wins. Used so a help timeout and a tap can't both resume the same wait.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

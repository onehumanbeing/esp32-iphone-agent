import Foundation

enum ModelRequestFailure {
    static func isTimeout(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut || (error as? LLMError)?.kind == "timeout"  // free line: shown as busy
    }

    /// No answer in time, or one cut off before its end: a timeout, a reply stream that broke off, or a gateway
    /// timeout (504; 524 is Cloudflare's). A shorter answer, or the same one a moment later, usually works.
    static func cutOff(_ error: Error) -> Bool {
        if isTimeout(error) { return true }
        guard let e = error as? LLMError else { return false }
        return e.reason == "stream_cut" || [504, 524].contains(e.status)
    }

    /// A hiccup that was a cut-off answer, for the run's steps (not "busy": the service answered, too slowly).
    static var cutOffHiccup: String {
        String(localized: "The AI service's answer was cut off or took too long; trying again.")
    }

    /// The help text after `count` failed model rounds in a row: what happened, that nothing is lost, what to do.
    /// The step's reason stays "N errors in a row" (AgentLoop.errorsReason) for the record and its matching.
    static func streakMessage(_ count: Int, cutOff: Bool) -> String {
        cutOff
            ? String(localized: "The AI service's answer was cut off or took too long \(count) times in a row. Your progress and notes are saved. Tap Continue to try again, or Stop to end the run here.")
            : String(localized: "The AI service didn't give a usable answer \(count) times in a row. Your progress and notes are saved. Tap Continue to try again, or Stop to end the run here.")
    }

    /// For usage stats: what kind of failure, never its text.
    static func kind(_ error: Error) -> String {
        if isTimeout(error), !(error is LLMError) { return "timeout" }
        if let e = error as? LLMError {
            if let kind = e.kind { return kind }
            switch e.status {
            case 0: return "provider"
            case 429: return "http_429"
            case 500...: return "http_5xx"
            default: return "http_4xx"
            }
        }
        return error is URLError ? "network" : "other"
    }

    static func message(_ error: Error) -> String {
        if isTimeout(error), !(error is LLMError) {
            return String(localized: "The model request timed out before it finished. Try again or choose a specific vision model instead of automatic routing.")
        }
        return error.localizedDescription
    }
}

import Foundation

enum ModelRequestFailure {
    static func isTimeout(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }

    /// For usage stats: what kind of failure, never its text.
    static func kind(_ error: Error) -> String {
        if isTimeout(error) { return "timeout" }
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
        if isTimeout(error) {
            return String(localized: "The model request timed out before it finished. Try again or choose a specific vision model instead of automatic routing.")
        }
        return error.localizedDescription
    }
}

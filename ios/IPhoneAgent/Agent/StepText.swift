import Foundation

/// Human words for a recorded step, for the replay player, the Live Activity and Home.
enum StepText {
    static func title(_ s: JObject) -> String {
        let n = { (k: String) in s[k]?.int ?? Int(s[k]?.double ?? 0) }
        switch s["action"]?.str {
        case "plan": return String(localized: "Made a plan")
        case "replan (stuck)", "replan": return String(localized: "Made a new plan")
        case "tap": return String(localized: "Tap at \(n("x")), \(n("y"))")
        case "swipe": return String(localized: "Swipe")
        case "path": return String(localized: "Draw a path")
        case "circle": return String(localized: "Draw a circle")
        case "type": return String(localized: "Type “\(s["text"]?.str ?? "")”")
        case "key": return String(localized: "Press \(s["combo"]?.str ?? "")")
        case "home": return String(localized: "Go to the Home Screen")
        case "back": return String(localized: "Go back")
        case "wait": return String(localized: "Wait")
        case "done": return String(localized: "Done")
        case "fail": return String(localized: "Gave up")
        case "stopped": return String(localized: "Stopped")
        case "hiccup": return String(localized: "Hiccup, retrying")
        case "reconnected": return String(localized: "Reconnected")
        case "error": return String(localized: "Error")
        case "help": return String(localized: "Asked for your help")
        case "takeover": return String(localized: "You took over")
        case "skipped": return String(localized: "Skipped")
        case "confirm": return String(localized: "Asked you first")
        case "confirmed": return String(localized: "You said yes")
        case "note": return String(localized: "Note")
        default: return s["action"]?.str ?? ""
        }
    }

    /// The model's own words if it gave any, else the action.
    static func line(_ s: JObject) -> String {
        if let t = s["thought"]?.str, !t.isEmpty { return t }
        if let a = s["answer"]?.str ?? s["reason"]?.str, !a.isEmpty { return "\(title(s)): \(a)" }
        return title(s)
    }

    static func symbol(_ name: String?) -> String {
        switch name {
        case "plan", "replan (stuck)": return "list.bullet.clipboard"
        case "tap": return "hand.tap"
        case "swipe", "path", "circle": return "hand.draw"
        case "type": return "keyboard"
        case "key": return "command"
        case "home": return "house"
        case "back": return "chevron.backward"
        case "wait": return "hourglass"
        case "done": return "checkmark.circle.fill"
        case "stopped": return "stop.circle"
        case "help", "takeover", "confirm": return "hand.raised"
        case "confirmed": return "checkmark.shield"
        case "skipped": return "forward"
        case "note": return "text.bubble"
        case "reconnected": return "arrow.triangle.2.circlepath"
        default: return "exclamationmark.triangle"
        }
    }

    static let notMoves: Set<String> = ["plan", "replan (stuck)", "hiccup", "stopped", "error", "fail", "done", "help",
                                        "takeover", "skipped", "note", "reconnected", "confirm", "confirmed"]
}

/// How a run ended.
enum Outcome {
    case running, done, failed, stopped

    init(last: String?, running: Bool) {
        if running { self = .running; return }
        switch last {
        case "done": self = .done
        case "stopped": self = .stopped
        default: self = .failed
        }
    }

    var mood: Mood {
        switch self {
        case .running: return .thinking
        case .done: return .success
        case .failed: return .failure
        case .stopped: return .idle
        }
    }
}

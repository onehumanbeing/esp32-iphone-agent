import Foundation

/// What the character says in the Dynamic Island, first person: "Thinking…", "Tapping Clock", "Typing 0800",
/// "Done!". `short` fits the compact island (≤ ~16 characters), `full` is for the expanded island and the
/// Lock Screen. `look` is where the eyes go (-1...1 from the center, e.g. toward a tap); nil while it waits,
/// when the eyes dart around on their own.
struct IslandStatus: Equatable {
    var short: String
    var full: String
    var look: CGPoint?
    var minimal: String? = nil

    var waits: Bool { look == nil }

    static let compactLimit = 16

    static var leavingApp: Self {
        Self(short: String(localized: "See you later!"), full: String(localized: "See you later!"),
             look: CGPoint(x: 0, y: -0.6), minimal: String(localized: "Start"))
    }

    static var waitingForBoard: Self {
        Self(short: String(localized: "Reconnecting…"),
             full: String(localized: "Board disconnected. Move it closer; I’ll continue when it reconnects."),
             look: nil, minimal: String(localized: "Board"))
    }

    static var boardSlow: Self {
        Self(short: String(localized: "Board slow"),
             full: String(localized: "Board not responding. Move it closer or reconnect."),
             look: nil, minimal: String(localized: "Board"))
    }

    static var pausedInApp: Self {
        Self(short: String(localized: "Paused"),
             full: String(localized: "Paused while you're here. Go to the Home Screen and I'll go on."),
             look: nil, minimal: String(localized: "Wait"))
    }

    static var switchBack: Self {
        Self(short: String(localized: "Switch back"),
             full: String(localized: "Switch back to the app you were in. I'll go on from there."),
             look: nil, minimal: String(localized: "Back"))
    }

    static var paused: Self {
        Self(short: String(localized: "Paused"), full: String(localized: "Paused. Tap Continue and I'll go on from here."),
             look: nil, minimal: String(localized: "Pause"))
    }

    static var looking: Self {
        Self(short: String(localized: "Looking…"), full: String(localized: "Looking at the screen…"), look: nil, minimal: String(localized: "Look"))
    }

    static var getReady: Self {
        Self(short: String(localized: "Get ready"), full: String(localized: "Get ready to do the task"),
             look: CGPoint(x: 0, y: 0.6), minimal: String(localized: "Ready"))
    }

    static var watching: Self {
        Self(short: String(localized: "Watching you"), full: String(localized: "Watching you"), look: CGPoint(x: 0, y: 0.6))
    }

    static var thinking: Self {
        Self(short: String(localized: "Thinking…"), full: String(localized: "Thinking about my next move…"), look: nil, minimal: String(localized: "Think"))
    }

    static var waiting: Self {
        Self(short: String(localized: "Waiting…"), full: String(localized: "Waiting for the model to respond…"),
             look: nil, minimal: String(localized: "Wait"))
    }

    static var planning: Self {
        Self(short: String(localized: "Planning…"), full: String(localized: "Thinking through my plan…"),
             look: nil, minimal: String(localized: "Plan"))
    }

    static var retrying: Self {
        Self(short: String(localized: "Retrying…"), full: String(localized: "The model timed out. Trying once more…"), look: nil, minimal: String(localized: "Retry"))
    }

    static var help: Self {
        Self(short: String(localized: "Need help"), full: String(localized: "Need your help"), look: .zero, minimal: String(localized: "Help"))
    }

    static var confirm: Self {
        Self(short: String(localized: "OK to go on?"), full: String(localized: "Waiting for your OK"), look: .zero, minimal: String(localized: "OK?"))
    }

    static var yourTurn: Self {
        Self(short: String(localized: "Your turn"), full: String(localized: "Your turn"), look: CGPoint(x: 0, y: 0.6), minimal: String(localized: "You"))
    }

    /// The end of a run, from its outcome's mood.
    static func ended(_ mood: Mood) -> Self {
        switch mood {
        case .success: return Self(short: String(localized: "Done!"), full: String(localized: "Done!"), look: .zero, minimal: String(localized: "Done"))
        case .failure: return Self(short: String(localized: "Didn't finish"), full: String(localized: "Didn't finish"), look: .zero, minimal: String(localized: "Error"))
        default: return Self(short: String(localized: "Stopped"), full: String(localized: "Stopped"), look: .zero, minimal: String(localized: "Stop"))
        }
    }

    /// About to do `act` (its thought, if any, names the target: "… so I tap the Clock app").
    static func acting(_ act: JObject) -> Self {
        let look = gaze(act)
        let minimal: String
        switch act["action"]?.str {
        case "tap": minimal = String(localized: "Tap")
        case "type", "clear": minimal = String(localized: "Type")
        case "key": minimal = String(localized: "Key")
        case "swipe": minimal = String(localized: "Swipe")
        case "path", "circle": minimal = String(localized: "Draw")
        case "home": minimal = String(localized: "Home")
        case "back": minimal = String(localized: "Back")
        case "tool": minimal = String(localized: "Search")
        default: minimal = String(localized: "Wait")
        }
        func say(_ verb: (String) -> String, _ bare: String, _ what: String?) -> Self {
            guard let what, !what.isEmpty else { return Self(short: bare, full: bare, look: look, minimal: minimal) }
            let room = compactLimit - verb("").count
            return Self(short: verb(clip(what, room)), full: verb(clip(what, 28)), look: look, minimal: minimal)
        }
        switch act["action"]?.str {
        case "tap":
            return say({ String(localized: "Tapping \($0)") }, String(localized: "Tapping…"), target(act["thought"]?.str ?? ""))
        case "type":
            return say({ String(localized: "Typing \($0)") }, String(localized: "Typing…"), act["text"]?.str)
        case "key":
            return say({ String(localized: "Pressing \($0)") }, String(localized: "Pressing a key…"), act["combo"]?.str)
        case "swipe":
            let label: String
            if abs(look.x) > abs(look.y) {
                label = look.x > 0 ? String(localized: "Swiping right") : String(localized: "Swiping left")
            } else {
                label = look.y > 0 ? String(localized: "Swiping down") : String(localized: "Swiping up")
            }
            return Self(short: label, full: label, look: look, minimal: minimal)
        case "path", "circle":
            return Self(short: String(localized: "Drawing…"), full: String(localized: "Drawing…"), look: look, minimal: minimal)
        case "home":
            return Self(short: String(localized: "Going home"), full: String(localized: "Going to the Home Screen"), look: look, minimal: minimal)
        case "back":
            return Self(short: String(localized: "Going back"), full: String(localized: "Going back"), look: look, minimal: minimal)
        case "tool":  // `search "清闲智能椅"`: the query, without the tool's name
            let line = act["text"]?.str ?? ""
            let query = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return say({ String(localized: "Searching \($0)") }, String(localized: "Searching…"), query)
        default:
            return Self(short: String(localized: "Waiting…"), full: String(localized: "Waiting for the screen…"), look: nil, minimal: minimal)
        }
    }

    /// Where the pointer is going, relative to the screen center; typing looks down at the keyboard.
    static func gaze(_ act: JObject) -> CGPoint {
        if ["type", "clear", "key"].contains(act["action"]?.str ?? "") { return CGPoint(x: 0, y: 0.7) }
        if act["action"]?.str == "swipe" {
            let dx = (act["x2"]?.double ?? 0) - (act["x1"]?.double ?? 0)
            let dy = (act["y2"]?.double ?? 0) - (act["y1"]?.double ?? 0)
            let magnitude = max(abs(dx), abs(dy), 1)
            return CGPoint(x: dx / magnitude, y: dy / magnitude)
        }
        guard let p = pointerPath(act).last else { return .zero }
        func clamp(_ v: Double) -> Double { min(1, max(-1, (v - 0.5) * 2)) }
        return CGPoint(x: clamp(p.x), y: clamp(p.y))
    }

    /// The thing a thought says it taps: a quoted name ("Save", “Repeat”), else the words after the last
    /// "tap / open / press / select …" ("so I tap the Clock app" → "Clock"). Nil for "it", "here" and the like.
    static func target(_ thought: String) -> String? {
        if let quoted = lastMatch(#"[“"‘]([^“”"‘’]{1,24})[”"’]"#, in: thought) { return quoted }
        let verb = #"\b(?:tap|tapping|open|opening|press|select|choose|hit)\s+(?:on\s+)?(?:the\s+)?"#
        let stop = #"(?=\s+(?:app|icon|button|tab|field|row|toggle|option|pill|key|link|result|to|so|and|in|at|on|again)\b|[.,;:!]|$)"#
        guard let name = lastMatch(verb + #"([^.,;:!]{1,24}?)"# + stop, in: thought, options: .caseInsensitive) else { return nil }
        let pronouns: Set<String> = ["it", "this", "that", "them", "here", "there", "one", "a", "an"]
        return pronouns.contains(name.lowercased()) ? nil : name
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count <= n ? s : String(s.prefix(max(1, n - 1))) + "…"
    }

    private static func lastMatch(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = s as NSString
        guard let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let found = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return found.isEmpty ? nil : found
    }
}

import Foundation

/// Parsing of the model's replies; a line-for-line port of agent.py (parse_command, parse_actions, parse_plan).
enum Actions {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bookkeeping keys that are not part of the action itself.
    static let meta: Set<String> = ["t", "thought", "thought_zh", "think_s", "act_s", "shot", "_shot", "changed", "replay", "jev",
                                     "landed", "again", "demo", "sure", "label", "detour", "slot", "keyOnly"]

    /// action name -> argument names; numeric arguments are 0-1000 screen coordinates
    static let actions: [String: [String]] = [
        "tap": ["x", "y"], "swipe": ["x1", "y1", "x2", "y2"], "circle": ["x", "y", "r"], "path": ["points"],
        "type": ["text"], "clear": [], "key": ["combo"], "done": ["answer"], "fail": ["reason"], "confirm": ["reason"],
        "home": [], "back": [], "wait": [], "open": ["app"],
        "read": ["what"], "note": ["text"], "progress": ["text"], "remember": ["text"], "learn": ["text"], "write": [],
        "tool": ["text"],  // tool <name> "query" (Tools.swift)
        "say": ["text"],  // say "TEXT": Live Speech says it into a call (Calls.swift)
    ]
    static let textArgs: Set<String> = ["text", "combo", "answer", "reason", "what", "app"]
    /// Actions that touch the screen.
    static let gestures: Set<String> = ["tap", "swipe", "circle", "path", "type", "clear", "key", "home", "back", "open", "say"]
    /// Actions that touch the notebook or memory, not the screen (AgentLoop+Memory).
    static let notebookActions: Set<String> = ["read", "note", "progress", "remember", "learn", "write", "tool"]

    /// One DO line, e.g. "tap 152 362" -> {"action": "tap", "x": 152, "y": 362}.
    static func parseCommand(_ line: String) throws -> JObject {
        let (head, rest) = partition(line.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = head.lowercased()
        guard let keys = actions[name] else { throw ParseError(message: "unknown action: \(line.prefix(100))") }
        if let first = keys.first, textArgs.contains(first) {
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return ["action": .str(name), first: .str(text)]
        }
        let numbers = matches(#"-?\d+(?:\.\d+)?"#, in: rest).compactMap { Double($0) }.map { Int($0) }
        if keys == ["points"] {
            guard numbers.count >= 4, numbers.count % 2 == 0 else {
                throw ParseError(message: "path needs 2+ x y pairs: \(line.prefix(100))")
            }
            let points = stride(from: 0, to: numbers.count, by: 2).prefix(20)
                .map { JValue.arr([.int(numbers[$0]), .int(numbers[$0 + 1])]) }
            return ["action": .str(name), "points": .arr(Array(points))]
        }
        guard numbers.count == keys.count else {
            throw ParseError(message: "\(name) needs \(keys.count) numbers: \(line.prefix(100))")
        }
        var action: JObject = ["action": .str(name)]
        for (k, n) in zip(keys, numbers) { action[k] = .int(n) }
        if name == "tap" && rest.lowercased().contains("precise") { action["precise"] = .bool(true) }
        return action
    }

    /// Parse a THINK / DO… reply (an optional ZH line is kept); the thought goes on the first action.
    static func parseActions(_ text: String) throws -> [JObject] {
        let thought = firstGroup(#"^\s*THINK\s*[:：]\s*(.*?)\s*$"#, in: text, multiline: true)
        let zh = firstGroup(#"^\s*ZH\s*[:：]\s*(.*?)\s*$"#, in: text, multiline: true)
        var acts = try allGroups(#"^\s*DO\s*[:：]\s*(.*?)\s*$"#, in: text).map(parseCommand).prefix(6).map { $0 }
        guard !acts.isEmpty else { throw ParseError(message: "no DO line in reply: \(text.prefix(200))") }
        acts = blindSafe(acts)
        acts[0] = JObject([("thought", .str(thought ?? "")), ("thought_zh", .str(zh ?? ""))]).merging(acts[0])
        return acts
    }

    /// The part of a batch that can run without a new look. `done` only counts on its own: after other actions the
    /// model hasn't seen their result. After `type` only keys follow: typing can open a keyboard or panel that moves
    /// what the next tap aims at. (A chat run's blind "tap field, type, tap send" missed the field, the "send" tap
    /// opened another panel, and a trailing "done" ended the run unsent.) Switching the keyboard (ctrl+space) ends
    /// the batch: the model must see which layout it got before typing (2026-11-03: "key ctrl+space, type …" twice
    /// in a row toggled back to pinyin and left the English text as an unconfirmed pinyin string).
    static func blindSafe(_ acts: [JObject]) -> [JObject] {
        let ending: Set<String?> = ["done", "fail", "confirm", "write", "say"]  // after say: listen
        var out: [JObject] = []
        var typed = false
        for a in acts {
            let name = a["action"]?.str
            // `read` copies the screen the model looked at: only before any gesture
            if !out.isEmpty && (ending.contains(name) || name == "read" || typed && name != "key") { break }
            out.append(a)
            if ending.contains(name) || name == "open" || isKeyboardSwitch(a) { break }
            typed = typed || name == "type"
        }
        return out
    }

    static func isKeyboardSwitch(_ a: JObject) -> Bool {
        guard a["action"]?.str == "key", let combo = a["combo"]?.str?.lowercased() else { return false }
        return combo.replacingOccurrences(of: " ", with: "") == "ctrl+space"
    }

    /// Split an optional EN: / ZH: plan reply; a plain reply is used for both.
    static func parsePlan(_ text: String) -> (String, String) {
        let re = try! NSRegularExpression(pattern: #"EN\s*[:：](.*?)ZH\s*[:：](.*)"#,
                                          options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return (trim(ns.substring(with: m.range(at: 1))), trim(ns.substring(with: m.range(at: 2))))
        }
        return (trim(text), trim(text))
    }

    /// The reply's PLAN: block (a numbered list, up to the DO lines), or nil when the model kept its plan.
    static func planBlock(_ text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"^\s*PLAN\s*[:：][ \t]*(.*?)(?=^\s*(?:DO|THINK)\s*[:：]|\z)"#,
                                          options: [.anchorsMatchLines, .dotMatchesLineSeparators, .caseInsensitive])
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let plan = trim(ns.substring(with: m.range(at: 1)))
        return plan.isEmpty ? nil : plan
    }

    /// The action itself, without thoughts, timings and other bookkeeping.
    static func key(_ step: JObject) -> JObject { step.without(meta) }

    // MARK: - helpers

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func partition(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private static func regex(_ p: String, multiline: Bool) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: multiline ? [.anchorsMatchLines, .caseInsensitive] : [])
    }

    private static func matches(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: false).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func firstGroup(_ p: String, in s: String, multiline: Bool) -> String? {
        let ns = s as NSString
        guard let m = regex(p, multiline: multiline).firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allGroups(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: true).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

/// Screen points (fractions) the pointer passes through for one action.
func pointerPath(_ act: JObject) -> [CGPoint] {
    func n(_ k: String) -> Double { act[k]?.double ?? 0 }
    func f(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 1000, y: y / 1000) }
    switch act["action"]?.str {
    case "tap": return [f(n("x"), n("y"))]
    case "swipe": return [f(n("x1"), n("y1")), f(n("x2"), n("y2"))]
    case "path": return points(act).map { f($0.x, $0.y) }
    case "circle": return [f(n("x") + n("r"), n("y"))]
    case "home": return [CGPoint(x: 0.5, y: 0.995), CGPoint(x: 0.5, y: 0.6)]
    case "back": return [CGPoint(x: 0.005, y: 0.45), CGPoint(x: 0.6, y: 0.45)]
    default: return []
    }
}

/// The [[x, y], …] points of a path action, in 0-1000 units.
func points(_ act: JObject) -> [CGPoint] {
    guard case .arr(let items)? = act["points"] else { return [] }
    return items.compactMap {
        guard case .arr(let p) = $0, p.count == 2, let x = p[0].double, let y = p[1].double else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Points around a circle; r is a fraction of the width, aspect = width / height.
func circle(_ x: Double, _ y: Double, _ r: Double, aspect: Double, n: Int = 24) -> [CGPoint] {
    (0...n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return CGPoint(x: x + r * cos(a), y: y + r * aspect * sin(a))
    }
}

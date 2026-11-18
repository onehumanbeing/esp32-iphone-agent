import Foundation

/// A reply in another shape, turned into THINK / DO lines. 2026-11-17: 29 of 74 replies in one run were a JSON
/// action (`{"action": "tap", "x": 692, "y": 503}`), a tool call (`<tool_call><function=computer><parameter=…>`) or
/// XML tags instead of DO lines; each was asked again (~5 s). The gateway repairs them too; this is the second net.
/// Only actions the reply really holds: a reply that only describes the screen stays unparseable (asked again).
enum ReplyRepair {
    /// The reply as THINK / DO lines; nil when it holds no action.
    static func repair(_ text: String) -> String? {
        var found: [(at: Int, fields: [String: String])] = []
        let ns = text as NSString
        for m in regex(#"<function=[^>]*>(.*?)</function>|<tool_call>(.*?)(?:</tool_call>|\z)"#).matches(in: text, range: whole(text)) {
            let body = [1, 2].compactMap { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }.first ?? ""
            var fields: [String: String] = [:]
            for p in regex(#"<parameter=([A-Za-z_0-9]+)>\s*(.*?)\s*</parameter>"#).matches(in: body, range: whole(body)) {
                fields[(body as NSString).substring(with: p.range(at: 1)).lowercased()] = (body as NSString).substring(with: p.range(at: 2))
            }
            if !fields.isEmpty { found.append((m.range.location, fields)) }
        }
        if found.isEmpty, let m = regex(#"<action>\s*([A-Za-z_]+)\s*</action>"#).firstMatch(in: text, range: whole(text)) {
            var fields: [String: String] = ["action": ns.substring(with: m.range(at: 1))]
            for t in regex(#"<([a-z_0-9]+)>\s*(.*?)\s*</\1>"#).matches(in: text, range: whole(text)) {
                fields[ns.substring(with: t.range(at: 1)).lowercased()] = ns.substring(with: t.range(at: 2))
            }
            found.append((m.range.location, fields))
        }
        for (at, object) in jsonObjects(text) {
            var fields: [String: String] = [:]
            for (k, v) in object { fields[k.lowercased()] = string(v) }
            if fields["action"] != nil { found.append((at, fields)) }
        }
        var lines: [String] = []
        for f in found.sorted(by: { $0.at < $1.at }) {
            guard let line = doLine(f.fields), (try? Actions.parseCommand(line)) != nil, !lines.contains(line) else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return "THINK: \(thought(text))\n" + lines.prefix(6).map { "DO: " + $0 }.joined(separator: "\n")
    }

    /// One DO line from an action's fields, in the names a model uses for them.
    static func doLine(_ f: [String: String]) -> String? {
        guard var name = f["action"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        name = aliases[name] ?? name
        var f = f
        if let c = f["coordinate"] ?? f["coordinates"] ?? f["point"] {  // "[854, 267]"
            if let n = numbers(c), n.count >= 2 { (f["x"], f["y"]) = (n[0], n[1]) }
        }
        if name == "scroll" {  // content moves the way the finger does: scroll down = finger up
            let down = (f["direction"] ?? "down").lowercased() != "up"
            return down ? "swipe 500 650 500 400" : "swipe 500 400 500 650"
        }
        guard let keys = Actions.actions[name] else { return nil }
        guard let first = keys.first else { return name }
        if Actions.textArgs.contains(first) {
            let text = [first, "text", "keys", "key", "app", "answer", "reason", "value"].lazy.compactMap { f[$0] }.first ?? ""
            return text.isEmpty ? nil : "\(name) \(text)"
        }
        if keys == ["points"] { return nil }
        let values = keys.compactMap { f[$0].flatMap(numbers).flatMap(\.first) }
        guard values.count == keys.count else { return nil }
        return ([name] + values).joined(separator: " ") + (f["precise"].map { $0 == "true" ? " precise" : "" } ?? "")
    }

    /// Tool-use names for the same actions.
    static let aliases = ["left_click": "tap", "click": "tap", "touch": "tap", "press": "tap", "input": "type",
                          "type_text": "type", "key_press": "key", "hotkey": "key", "go_back": "back", "press_back": "back",
                          "go_home": "home", "press_home": "home", "open_app": "open", "launch": "open", "finish": "done",
                          "terminate": "done", "answer": "done", "drag": "swipe"]

    /// The reply's prose without the action blocks, as one short thought.
    private static func thought(_ text: String) -> String {
        var t = text
        for p in [#"<tool_call>.*?(?:</tool_call>|\z)"#, #"<function=.*?</function>"#, #"<[a-z_0-9]+>.*?</[a-z_0-9]+>"#,
                  #"```[a-z]*"#, #"\{[^{}]*\}"#] {
            t = regex(p).stringByReplacingMatches(in: t, range: whole(t), withTemplate: " ")
        }
        let one = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.isEmpty ? "(reply repaired)" : String(one.prefix(400))
    }

    /// Top-level {…} blocks that read as JSON objects, with where they start.
    private static func jsonObjects(_ text: String) -> [(Int, [String: Any])] {
        var out: [(Int, [String: Any])] = []
        let chars = Array(text.utf16)
        var depth = 0, start = -1, inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { inString = false }
                continue
            }
            if c == 34 { inString = depth > 0 } else if c == 123 { if depth == 0 { start = i }; depth += 1 } else if c == 125, depth > 0 {
                depth -= 1
                if depth == 0, let s = String(utf16CodeUnits: Array(chars[start...i]), count: i - start + 1).data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: s) as? [String: Any] {
                    out.append((start, object))
                }
            }
        }
        return out
    }

    private static func string(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any] { return "[" + a.map(string).joined(separator: ", ") + "]" }
        return "\(v)"
    }

    private static func numbers(_ s: String) -> [String]? {
        let r = regex(#"-?\d+(?:\.\d+)?"#)
        let out = r.matches(in: s, range: whole(s)).map { String(Int(Double((s as NSString).substring(with: $0.range)) ?? 0)) }
        return out.isEmpty ? nil : out
    }

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    private static func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
}

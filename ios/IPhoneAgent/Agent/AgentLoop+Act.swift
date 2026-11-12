import CoreGraphics
import Foundation

/// Carrying out one action, and its effect as the model reads it next round.
extension AgentLoop {
    /// The last action sent: not a plan row, not the repeat guard's "blocked" row (that one sent nothing).
    var lastSent: JObject? { steps.last { $0["action"]?.str != "plan" && $0["action"]?.str != RepeatGuard.action } }

    /// The previous round changed nothing on screen, so a tap may have landed off target.
    var missed: Bool { lastSent?["changed"] == .bool(false) }

    /// A tap where the last one went: that one didn't do what was meant even if the screen moved (Duolingo's
    /// animated mascot read three misses just above the "water" tile as changed, 2026-11-06).
    func retaps(_ a: JObject) -> Bool {
        guard let last = lastSent, last["action"]?.str == "tap",
              let x = last["x"]?.double, let y = last["y"]?.double, let ax = a["x"]?.double, let ay = a["y"]?.double
        else { return false }
        return abs(ax - x) <= 30 && abs(ay - y) <= 30
    }

    /// What an action did, the way a terminal shows a command's result.
    static func effect(_ s: JObject) -> String {
        guard let changed = s["changed"]?.bool else { return "" }
        var out = changed ? " -> screen changed" : " -> screen did NOT change"
        let app = s["app"]?.str ?? ""
        switch s["opened"]?.str.flatMap(OpenResult.init(rawValue:)) {
        case .opened?: out += "; \(app) is open"
        case .notFound?: out += "; Spotlight lists no app named \(app)"
            + AppNames.alternatives(app).map { " nor \($0)" }.joined() + " (the search is still on screen)"
        case .notOpened?: out += "; \(app) did not open"
        default: break
        }
        if let typed = s["typed"]?.str { out += "; typing stopped: \(typed)" }
        if let cleared = s["cleared"]?.str { out += "; clear: \(cleared)" }
        if case .arr(let p)? = s["landed"], p.count == 2, let lx = p[0].double, let ly = p[1].double,
           let x = s["x"]?.double, let y = s["y"]?.double {
            let dx = Int(lx - x), dy = Int(ly - y)
            var off: [String] = []
            if dx != 0 { off.append("\(abs(dx)) \(dx > 0 ? "right of" : "left of")") }
            if dy != 0 { off.append("\(abs(dy)) \(dy > 0 ? "below" : "above")") }
            out += "; the pointer is at \(Int(lx)) \(Int(ly))" + (off.isEmpty ? "" : " (" + off.joined(separator: ", ") + " the target)")
        }
        return out
    }

    /// Wait for the result of the last gesture. `busy`: what moved by itself while the model looked (`motion`);
    /// changes there alone don't keep the wait going (2026-11-11: a map or a video kept every settle to its cap).
    func settle(ignoring spots: [CGPoint] = [], busy: [CGRect] = []) async -> Double {
        let started = now()
        onDoing?(.looking)
        await screen?.afterAction(since: lastActed, ignoring: spots, busy: busy)
        return (now() - started) * 1000
    }

    /// What changed on its own between the frame the model saw and the one just before the first gesture, and how
    /// long finding it took. Started as the gesture goes out, not awaited before it (2026-11-11): it decodes two full
    /// frames, and only the waits and the verdict after the gesture use it.
    static func motion(_ seen: Data?, _ ahead: Data?) -> Task<(rects: [CGRect], s: Double), Never> {
        Task.detached(priority: .userInitiated) {
            let started = now()
            let rects = Vision.motion(seen, ahead)
            return (rects, now() - started)
        }
    }

    /// What `open` found, or what `type` could not type: a field for the step (nil for every other action).
    @discardableResult
    func perform(_ a: JObject, aim: Bool = false) async throws -> (field: String, value: String)? {
        guard let phone else { throw DeviceError(message: "no phone") }
        func p(_ k: String) -> Double { (a[k]?.double ?? 0) / 1000 }
        switch a["action"]?.str {
        case "tap": try await phone.tap(p("x"), p("y"), aim: aim || a["precise"]?.bool ?? false || missed || retaps(a))
        case "swipe": try await phone.swipe(p("x1"), p("y1"), p("x2"), p("y2"), hold: true)
        case "path": try await phone.drag(points(a).map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }, hold: true)
        case "circle": try await phone.drag(circle(p("x"), p("y"), p("r"), aspect: screen?.aspect ?? 9 / 19.5), hold: true)
        case "type":
            let text = a["text"]?.str ?? ""
            if Scripts.needsPaste(text) { return ("typed", try await pasteInstead(text)) }  // the board can't type it
            return try await phone.type(text).map { ("typed", $0) }
        case "say":  // the Live Speech field: typed, then return speaks it (never the clipboard: it asks first)
            // part of it not typed: not spoken either, half a sentence would go into the call
            if let missed = try await phone.type(a["text"]?.str ?? "") { return ("typed", missed + "; not said: clear the field and say it again") }
            try await phone.key("enter")
            return nil
        case "clear": return try await phone.clearField().map { ("cleared", $0) }
        case "key":
            // `type` picks the keyboard itself: the model's own ctrl+space flipped it back to English right before a
            // type, and the pinyin it then typed went in as letters (2026-11-13)
            if Actions.isKeyboardSwitch(a) { return ("result", "not sent: type switches the keyboard itself; type the text as is, Chinese as characters") }
            try await phone.key(a["combo"]?.str ?? "")
        case "home": try await phone.goHome(again: homeAgain)
        case "open": return ("opened", try await phone.openApp(a["app"]?.str ?? "").rawValue)
        case "back": try await phone.goBack()
        case "wait": break
        case let other: throw Actions.ParseError(message: "unknown action \(other ?? "nil")")
        }
        return nil
    }
}

/// Swipes have no momentum, and a long one skips what was between (scrolled past unseen); the prompt asks for
/// 100-250, the code holds it to that. A swipe from a screen edge (Control Center, Notification Center, Back)
/// keeps its length.
enum SwipeClamp {
    static let limit = 300.0, edge = 80.0  // Control Center swipes start ~50 from the top

    /// The model's swipe, cut to the limit (its end moved, a note for the next round). Replayed swipes are not.
    static func apply(_ a: inout JObject) {
        let (x, y, cut) = end(a)
        guard cut else { return }
        (a["x2"], a["y2"]) = (.int(Int(x.rounded())), .int(Int(y.rounded())))
        a["result"] = .str("swipe shortened to \(Int(limit)) units; swipe again to go further")
    }

    /// The swipe's end in 0-1000 units, and whether it was cut short.
    static func end(_ a: JObject) -> (x: Double, y: Double, cut: Bool) {
        let x1 = a["x1"]?.double ?? 0, y1 = a["y1"]?.double ?? 0, x2 = a["x2"]?.double ?? 0, y2 = a["y2"]?.double ?? 0
        let length = hypot(x2 - x1, y2 - y1)
        let fromEdge = x1 < edge || x1 > 1000 - edge || y1 < edge || y1 > 1000 - edge
        guard length > limit, !fromEdge else { return (x2, y2, false) }
        let k = limit / length
        return (x1 + (x2 - x1) * k, y1 + (y2 - y1) * k, true)
    }
}

/// A tap outside the 0-1000 screen is never sent: clamped, it lands on the screen's edge (the home bar, Control
/// Center), where a press sets off system gestures the model never asked for.
enum OffScreen {
    static func reason(_ a: JObject) -> String? {
        guard let x = a["x"]?.double, let y = a["y"]?.double, !(0...1000).contains(x) || !(0...1000).contains(y) else { return nil }
        return "not tapped: \(Int(x)), \(Int(y)) is off the screen; x and y run 0-1000"
    }
}

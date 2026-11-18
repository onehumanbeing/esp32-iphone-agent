import Foundation

/// Before a tap is sent: its spot from its words, then the checks that hold it back, in order. The first that holds
/// it wins; `.ask` goes to the user as a confirm (PayGuard).
extension AgentLoop {
    /// The text lines of `shot` (centres in 0-1000) for the checks before a tap. The look's frame: its tree's OCR;
    /// another frame: read once and kept for the next check (2026-11-19: three full reads of one frame before
    /// every tap, 4 s with the app in the background).
    func lookLines(for shot: Data) async -> [DemoAnalysis.Line] {
        if shot == limitFrame, !limitLines.isEmpty { return limitLines }
        if shot == lookFrame, let tree = lookTree { return DemoAnalysis.texts(of: tree, limit: 200) }
        if let kept = shotLines, kept.shot == shot { return kept.lines }
        let lines = await Self.screenLines(shot)
        shotLines = (shot, lines)
        return lines
    }

    enum TapCheck: Equatable {
        case send
        case held(String)
        case ask(String)
    }

    func checkTap(_ act: inout JObject, shot: Data?, earlierTap: Bool) async -> TapCheck {
        if let unplaced = await placeTextTap(&act, settleFirst: earlierTap) { return .held(unplaced) }
        if let off = OffScreen.reason(act, image: OffScreen.modelSize(shot)) {  // y 1108 tapped the home bar's edge (2026-11-13)
            DebugLog.write("step: tap not sent, \(off)")
            return .held(off)
        }
        if let ask = await payGuardReason(act, on: shot) { return .ask(ask) }
        if let held = await inventoryHold(act, on: shot) { return .held(held) }
        if let x = act["x"]?.double, let y = act["y"]?.double, let held = AssistiveTouchGuard.held(x, y, hits: assistiveHits) {
            DebugLog.write("step: tap not sent, on the AssistiveTouch button")
            return .held(held)
        }
        if let tree = lookTree, let held = TabBarGuard.held(act, lines: tree.lines, w: tree.w, h: tree.h) {
            DebugLog.write("step: tap not sent, \(held)")
            return .held(held)
        }
        if let off = IslandGuard.apply(&act, zone: island()) {
            DebugLog.write("step: tap not sent, \(off)")
            return .held(off)
        }
        return .send
    }
}

/// A tap by coordinates on a tab bar label its THINK never names: what the model meant (a list card at the screen's
/// bottom) is under the tab bar. 2026-11-19, 美团: order cards aimed at y 943 and 972 opened 神券 and 我的.
enum TabBarGuard {
    nonisolated static func held(_ act: JObject, lines: [(text: String, box: [Int])], w: Int, h: Int) -> String? {
        guard act["text"] == nil, let x = act["x"]?.double, let y = act["y"]?.double, y >= TapText.tabBar * 1000,
              w > 0, h > 0, let thought = act["thought"]?.str, !thought.isEmpty else { return nil }
        let (px, py, W, H) = (x / 1000 * Double(w), y / 1000 * Double(h), Double(w), Double(h))
        let label = lines.first { l in
            let t = l.text.trimmingCharacters(in: .whitespaces), b = l.box.map(Double.init)
            guard !t.isEmpty, t.count <= 4, b.count == 4, b[1] >= TapText.tabBar * H - 0.02 * H else { return false }
            // the label and its icon above it, about one tab wide
            return px >= b[0] - 0.06 * W && px <= b[2] + 0.06 * W && py >= b[1] - 0.06 * H && py <= b[3] + 0.02 * H
        }?.text.trimmingCharacters(in: .whitespaces)
        guard let label, !thought.contains(label) else { return nil }
        return "not tapped: \(Int(x)), \(Int(y)) is the tab bar's \"\(label)\", which your THINK does not name; what you "
            + "meant is under the tab bar: scroll the list up a little first, then tap it"
    }
}

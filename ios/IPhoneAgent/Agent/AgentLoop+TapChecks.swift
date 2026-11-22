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

    /// A tap on a send button goes through SendGuard like Enter: the label under the tap, or a text tap's words.
    func sendTapHold(_ act: JObject, on shot: Data?) async -> String? {
        guard act["action"]?.str == "tap" else { return nil }
        var under: String?
        if let x = act["x"]?.int, let y = act["y"]?.int, let shot {
            under = IntentLearner.label(at: x, y, in: await lookLines(for: shot))
        }
        guard SendGuard.isSend(under) || SendGuard.isSend(act["text"]?.str) else { return nil }
        return sendGuard.enter(step: steps.count + 1, again: "tap it again")
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
        if let held = await sendTapHold(act, on: shot) {
            DebugLog.write("step: tap not sent, a send button after a type that needs a look")
            return .held(held)
        }
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
/// A tab bar is a row: three or more short labels side by side along the bottom, over half the width, and the tap
/// is nearest that label of the row (2026-11-21: any short word low on the screen counted, and Notes' compose, the
/// Phone search button and a dock icon were held 12 times in 17 user runs).
enum TabBarGuard {
    nonisolated static func held(_ act: JObject, lines: [(text: String, box: [Int])], w: Int, h: Int) -> String? {
        guard act["text"] == nil, let x = act["x"]?.double, let y = act["y"]?.double, y >= TapText.tabBar * 1000,
              w > 0, h > 0, let thought = act["thought"]?.str, !thought.isEmpty else { return nil }
        let (px, py, W, H) = (x / 1000 * Double(w), y / 1000 * Double(h), Double(w), Double(h))
        let short = lines.compactMap { l -> (text: String, b: [Double])? in
            let t = l.text.trimmingCharacters(in: .whitespaces), b = l.box.map(Double.init)
            guard !t.isEmpty, t.count <= 4, b.count == 4, b[1] >= TapText.tabBar * H - 0.02 * H else { return nil }
            // one sign that is not a CJK character is an icon read as text (the Phone search button's magnifier,
            // 2026-11-21); a one-character tab such as 我 stays
            if t.count == 1, !t.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) { return nil }
            return (t, b)
        }
        let hit = short.first { l in  // the label and its icon above it, about one tab wide
            px >= l.b[0] - 0.06 * W && px <= l.b[2] + 0.06 * W && py >= l.b[1] - 0.06 * H && py <= l.b[3] + 0.02 * H
        }
        guard let hit, !thought.contains(hit.text) else { return nil }
        let mid = { (b: [Double]) in ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2) }
        let row = short.filter { abs(mid($0.b).1 - mid(hit.b).1) <= 0.015 * H }
        guard row.count >= 3, let left = row.map({ $0.b[0] }).min(), let right = row.map({ $0.b[2] }).max(),
              right - left >= 0.5 * W,
              let nearest = row.min(by: { abs(mid($0.b).0 - px) < abs(mid($1.b).0 - px) }), nearest.text == hit.text
        else { return nil }
        let label = hit.text
        return "not tapped: \(Int(x)), \(Int(y)) is the tab bar's \"\(label)\", which your THINK does not name; what you "
            + "meant is under the tab bar: scroll the list up a little first, then tap it"
    }
}

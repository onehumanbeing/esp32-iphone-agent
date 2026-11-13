import Foundation

/// Henry 2026-11-13: a demonstration is saved as what was meant, not where the finger went. After the model names
/// each change (DemoAnalysis), these local passes (no model call) tidy the steps:
/// - a tap's label is the text at its spot (OCR); the model's name only when the screen shows it;
/// - Home (+ paging, + a folder) + a tap on an app, or Spotlight + the app's name, become `open <app>`;
/// - taps on the on-screen keyboard are typing, which the `type` step already holds (a run types with no keyboard
///   on screen): left out, and the return key ("发送", "Send") becomes `key enter`;
/// - a detour (in and back out to the same screen) is marked left out: the review shows it as wrong, and marking
///   it correct keeps it.
enum DemoSteps {
    typealias Line = DemoAnalysis.Line

    struct Reader {
        var lines: (Data) async -> [Line]
        var same: (Data, Data) -> Bool
        static let phone = Reader(lines: { await DemoAnalysis.texts($0, limit: 80) }, same: { Vision.similar($0, $1) })
    }

    /// The return key's names on the keyboards people use: a tap on it sends what was typed.
    static let returnKeys: Set<String> = ["发送", "send", "搜索", "search", "go", "前往", "完成", "done", "return", "换行",
                                          "确定", "next", "下一项", "join", "加入"]
    /// A back control's names, for detours.
    static let backLabels: Set<String> = ["返回", "back", "<", "‹", "取消", "cancel", "关闭", "close"]
    static let searchLabels: Set<String> = ["搜索", "search", "q search"]

    /// `after`: the screen after the last step (the last captured frame).
    static func refine(_ steps: [DraftStep], prompt: String, after: Data?, reader: Reader = .phone) async -> [DraftStep] {
        var lines: [[Line]] = [], screens: [Data?] = []
        for step in steps {
            let data = step.frame.flatMap { try? Data(contentsOf: $0) }
            screens.append(data)
            lines.append(data == nil ? [] : await reader.lines(data!))
        }
        var tidy: [DraftStep] = [], typedNear = Set<Int>()
        for (i, step) in steps.enumerated() where step.name == "type" { typedNear.formUnion((i - 3)...(i + 3)) }
        var lostTyping = false
        for (i, var step) in steps.enumerated() {
            if step.name == "tap", let x = step.action["x"]?.int, let y = step.action["y"]?.int, !lines[i].isEmpty {
                if let top = keyboardTop(lines[i]), y >= top {
                    let key = IntentLearner.label(at: x, y, in: lines[i])?.lowercased()
                    if let key, returnKeys.contains(key) {
                        step.action = ["action": .str("key"), "combo": .str("enter")]
                        step.uncertain = false
                        tidy.append(step)
                    } else if !typedNear.contains(i) && !lostTyping {
                        lostTyping = true  // letters with no type step: the AI types what the task says
                        tidy.append(DraftStep(action: ["action": .str("note"), "text": .str("Type the text the task asks for")],
                                              frame: step.frame, uncertain: true))
                    }
                    continue
                }
                name(&step, x, y, lines[i])
            }
            tidy.append(step)
        }
        let opened = collapseOpens(tidy, prompt: prompt)
        return markDetours(opened, after: after, reader: reader)
    }

    /// The tap named by what reads at its spot; the model's name is kept when it reads there, and moved to where
    /// it reads when the model's spot was off. Unsure when the screen does not show the model's name.
    static func name(_ step: inout DraftStep, _ x: Int, _ y: Int, _ lines: [Line]) {
        let seen = IntentLearner.label(at: x, y, in: lines)
        guard let said = step.action["label"]?.str, !said.isEmpty else {
            if let seen { step.action["label"] = .str(seen) }
            return
        }
        if let hit = Replay.locate(said, near: x, y, in: lines) {
            if hypot(Double(hit.x - x), Double(hit.y - y)) > 2 * IntentLearner.reach {
                step.action["x"] = .int(hit.x); step.action["y"] = .int(hit.y)
            }
            return
        }
        if let seen { step.action["label"] = .str(seen) }
        step.uncertain = true
    }

    /// The top of the on-screen keyboard (0-1000), from its letter keys read low on the screen; nil = no keyboard.
    static func keyboardTop(_ lines: [Line]) -> Int? {
        let keys = lines.filter { $0.y > 500 && $0.text.count == 1 && "qwertyuiopasdfghjklzxcvbnm".contains($0.text.lowercased()) }
        guard keys.count >= 8, let top = keys.map(\.y).min() else { return nil }
        return top - 45
    }

    // MARK: - open APP

    static func isApp(_ label: String, prompt: String) -> Bool {
        let name = Scripts.fold(label)
        guard name.count >= 2 else { return false }
        return !AppNames.labels(label).isEmpty || Scripts.fold(prompt).contains(name)
    }

    private static func label(_ s: DraftStep) -> String? { s.name == "tap" ? s.action["label"]?.str : nil }
    private static func plain(_ s: String?) -> String { (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) }

    static func collapseOpens(_ steps: [DraftStep], prompt: String) -> [DraftStep] {
        var out: [DraftStep] = [], i = 0
        while i < steps.count {
            if let (app, end) = openAt(i, steps, prompt: prompt) {
                out.append(DraftStep(action: ["action": .str("open"), "app": .str(app)], frame: steps[i].frame, t: steps[i].t))
                i = end + 1
            } else {
                out.append(steps[i]); i += 1
            }
        }
        return out
    }

    /// (app, index of the last step it replaces) when an `open` starts at step i.
    static func openAt(_ i: Int, _ s: [DraftStep], prompt: String) -> (String, Int)? {
        var j = i
        let home = s[i].name == "home"
        if home { j += 1 }
        guard home || i == 0 else { return spotlight(i, s, prompt: prompt) }
        while j < s.count, s[j].name == "swipe", !isSpotlightSwipe(s[j]) { j += 1 }  // paging the Home Screen
        guard j < s.count else { return nil }
        if let app = label(s[j]), isApp(app, prompt: prompt) { return (app, j) }
        if home, j + 1 < s.count, label(s[j]) != nil, let app = label(s[j + 1]), isApp(app, prompt: prompt) {
            return (app, j + 1)  // a folder, then the app in it
        }
        return spotlight(j, s, prompt: prompt)
    }

    private static func isSpotlightSwipe(_ s: DraftStep) -> Bool {
        let n = { (k: String) in s.action[k]?.double ?? 0 }
        return n("y2") - n("y1") > 80 && abs(n("x2") - n("x1")) < 150
    }

    /// Spotlight (a swipe down, or the Search pill), the name typed, then the result tapped or Return.
    private static func spotlight(_ i: Int, _ s: [DraftStep], prompt: String) -> (String, Int)? {
        guard i + 2 < s.count, isSpotlightSwipe(s[i]) || searchLabels.contains(plain(label(s[i]))),
              s[i + 1].name == "type", let typed = s[i + 1].action["text"]?.str else { return nil }
        let next = s[i + 2]
        if next.name == "key", next.action["combo"]?.str == "enter" { return (typed, i + 2) }
        guard let app = label(next) else { return nil }
        let (a, t) = (Scripts.fold(app), Scripts.fold(typed))
        return a.contains(t) || t.contains(a) || isApp(app, prompt: prompt) ? (app, i + 2) : nil
    }

    // MARK: - detours

    static func isBack(_ s: DraftStep) -> Bool {
        if s.name == "back" { return true }
        guard s.name == "tap" else { return false }
        if backLabels.contains(plain(label(s))) { return true }
        let (x, y) = (s.action["x"]?.int ?? 500, s.action["y"]?.int ?? 500)
        return x < 150 && y < 130 && label(s) == nil  // the back arrow at the top left
    }

    /// Steps i...j, ending in a back, that left the screen as it was before step i. Typing and opens are never
    /// a detour.
    static func markDetours(_ steps: [DraftStep], after: Data?, reader: Reader) -> [DraftStep] {
        var out = steps
        let data = steps.map { $0.frame.flatMap { try? Data(contentsOf: $0) } }
        for j in steps.indices where isBack(steps[j]) {
            guard let then = j + 1 < steps.count ? data[j + 1] : after else { continue }
            for i in max(0, j - 4)...j {
                guard let before = data[i], reader.same(before, then),
                      !steps[i...j].contains(where: { ["type", "open", "key"].contains($0.name) }) else { continue }
                for k in i...j {
                    out[k].action["detour"] = .bool(true)
                    out[k].verdict = false
                    out[k].uncertain = false
                }
                break
            }
        }
        return out
    }
}

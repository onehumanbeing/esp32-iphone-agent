import CoreGraphics
import ImageIO
import Foundation

/// Carrying out one action, and its effect as the model reads it next round.
extension AgentLoop {
    /// The last action sent: not a plan row, not the repeat guard's "blocked" row (that one sent nothing).
    var lastSent: JObject? { steps.last { $0["action"]?.str != "plan" && $0["action"]?.str != RepeatGuard.action } }

    /// The first frame is the Home Screen: not when the scheme opened the task's app before it (a replay skips
    /// autoOpen, whose "opened" row would otherwise say so).
    var homeAtStart: Bool { startsOnHome && openedAtStart == nil }

    /// The previous round changed nothing on screen, so a tap may have landed off target.
    var missed: Bool { lastSent?["changed"] == .bool(false) }

    /// Twice in a row a tap that changed the screen was undone at once (back): the taps open the wrong thing, so the
    /// next one finds the pointer before it presses (aim, ~2 s; it also feeds Recalibration). 2026-11-24: a phone
    /// whose taps landed ~500 units low opened a wrong page every time; the screen changed, so no landing was ever
    /// checked and nothing was recalibrated for 133 steps.
    var backedOut: Bool {
        let sent = steps.filter { $0["action"]?.str != "plan" && $0["action"]?.str != RepeatGuard.action }.suffix(4)
        guard sent.count == 4 else { return false }
        let a = Array(sent)
        return stride(from: 0, to: 4, by: 2).allSatisfy { a[$0]["action"]?.str == "tap" && a[$0]["changed"] == .bool(true)
            && a[$0 + 1]["action"]?.str == "back" }
    }

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
        guard let changed = s["changed"]?.bool else { return s["stale"] == .bool(true) ? staleEffect : "" }  // stale: iPad
        // no frame came after it (confirmStill): unknown, not "did NOT change", which sent models into a repeat
        var out = changed ? " -> screen changed" : s["noframe"] == .bool(true) ? staleEffect : " -> screen did NOT change"
        let app = s["app"]?.str ?? ""
        switch s["opened"]?.str.flatMap(OpenResult.init(rawValue:)) {
        case .opened?: out += "; \(app) is open"
        case .notFound?: out += "; Spotlight lists no app named \(app)"
            + " (the search is still on screen): open it by the name this \(DeviceKind.name) shows, in its language"
        case .notOpened?: out += "; \(app) did not open (Spotlight stayed up after tapping its row and Return):"
            + " if Spotlight still lists it, tap its icon there"
        case .already?: out += "; \(app) is already open (this screen is one of its pages), so nothing was sent:"
            + " tap back (top left) or its tabs to reach the page you need"
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

    static let typedWhole = "typed and read back: the field holds all of it (a long text shows only its end there, the start scrolled out of view); go on (do not clear it or type it again)"

    /// The last gesture typed a text and read it back whole, and this `type` is part of it: the model saw only the end
    /// of a long text in its field and typed that end again, on top (2026-11-23, three runs in a row: "订好了，七点之前
    /// 到就行。", "七点之前到就行。"). Not typed; the model is told the field already holds it.
    static func typedAlready(_ text: String, after steps: [JObject]) -> String? {
        guard let last = steps.last(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              last["action"]?.str == "type", last["result"]?.str == typedWhole, let whole = last["text"]?.str else { return nil }
        let part = HanTyper.core(text)
        guard !part.isEmpty, HanTyper.core(whole).contains(part) else { return nil }
        return "not typed: the field already holds \"\(text)\" (the last type put all of \"\(whole.suffix(40))\" in and read "
            + "it back; a long text shows only its end in the field). Go on to the next step of the goal, e.g. send"
    }

    /// What `open` found, or what `type` could not type: a field for the step (nil for every other action).
    @discardableResult
    func perform(_ action: JObject, aim: Bool = false) async throws -> (field: String, value: String)? {
        guard let phone else { throw DeviceError(message: "no phone") }
        // iPad: frame to screen coordinates (PadGeometry); an iPhone has no geometry and sends the model's as they are
        let geometry = screen?.geometry
        let a = try geometry.map { try PadGeometry.toScreen(action, $0) } ?? action
        func p(_ k: String) -> Double { (a[k]?.double ?? 0) / 1000 }
        switch a["action"]?.str {
        case "tap": try await phone.tap(p("x"), p("y"), aim: aim || a["precise"]?.bool ?? false || missed || retaps(a) || backedOut)
        case "swipe": try await phone.swipe(p("x1"), p("y1"), p("x2"), p("y2"), hold: true)
        case "path": try await phone.drag(points(a).map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }, hold: true)
        case "circle": try await phone.drag(circle(p("x"), p("y"), p("r"), aspect: geometry?.screenAspect ?? screen?.aspect ?? 9 / 19.5), hold: true)
        case "type":
            let text = a["text"]?.str ?? ""
            if let note = Self.typedAlready(text, after: steps) {
                DebugLog.write("type: \"\(text)\" is part of the text the last type put in the field whole; not typed again")
                return ("result", note)
            }
            if Scripts.needsPaste(text) {  // the board can't type it
                let note = try await pasteInstead(text)
                typeStats.pasted(note, pinyin: false)
                sendGuard.typed(text, missing: note == nil ? nil : text, at: steps.count + 1)
                return note.map { ("typed", $0) } ?? ("result", "pasted (the board cannot type this script)")
            }
            // the text carried on the clipboard since the start (ClipboardCarry): pasted first, pinyin only when the
            // paste is not read back
            if carriedWhyNot(text) == nil, try await pasteCarriedFirst(text) {
                return ("result", "typed: pasted from the clipboard, which held this text; read back: the field holds all of it")
            }
            let stop = try await phone.typeStop(text)
            // the pinyin keyboard did not offer a word (2026-11-20: 西 not read among xi's candidates, 上海 typed and
            // 西岸艺术中心 not): the text carried on the clipboard since the start is pasted when it is this text
            // (ClipboardCarry); never a hop back to this app. Otherwise the model types the rest itself.
            if let stop, let rest = stop.rest, !rest.isEmpty {
                DebugLog.write("type: the pinyin keyboard stopped part way (\(rest.count) chars left)")
                // tried once more after a paste-first not seen: the read may have missed it, the field holds pinyin now
                if let pasted = try await pasteCarried(text, stop: stop) {
                    typeStats.pasted(pasted.field == "result" ? nil : "text is not seen", pinyin: true)
                    return pasted
                }
                typeStats.pasted("not pasted", pinyin: true)
                sendGuard.typed(text, missing: rest, at: steps.count + 1)
                return ("typed", SendGuard.listedHint + stop.note + "; type the rest yourself, in shorter pieces")
            }
            sendGuard.typed(text, missing: stop.flatMap { SendGuard.missing($0.note) }, at: steps.count + 1)
            // read back whole: the model is told so, or it cleared and retyped a right field for minutes (2026-11-23)
            return stop.map { ("typed", SendGuard.listedHint + $0.note) }
                ?? (HanTyper.isHan(text) ? ("result", Self.typedWhole) : nil)
        case "say":  // the Live Speech field: typed, then return speaks it (never the clipboard: it asks first)
            // part of it not typed: not spoken either, half a sentence would go into the call
            if let missed = try await phone.type(a["text"]?.str ?? "") { return ("typed", missed + "; not said: \(SendGuard.clearHint) and say it again") }
            try await phone.key("enter")
            return nil
        case "clear":
            sendGuard.cleared()
            return try await phone.clearField().map { ("cleared", $0) }
        case "key":
            // `type` picks the keyboard itself: the model's own ctrl+space flipped it back to English right before a
            // type, and the pinyin it then typed went in as letters (2026-11-13)
            if Actions.isKeyboardSwitch(a) { return ("result", "not sent: type switches the keyboard itself; type the text as is, Chinese as characters") }
            if Actions.isEnter(a), let held = sendGuard.enter(step: steps.count + 1) { return ("result", held) }
            try await phone.key(a["combo"]?.str ?? "")
        case "home":
            // keyOnly: the Home key once, no flick after it (a call's Control Center: the Live Captions panel stays
            // on screen in every app, so "the app's words are still there" always held, and the two flicks that
            // followed collapsed the panel mid-call, 2026-11-14)
            if a["keyOnly"]?.bool == true { try await phone.homeKey() } else { try await phone.goHome(again: homeAgain) }
        case "open":
            let app = a["app"]?.str ?? ""
            if AlreadyOpen.holds(app, steps) { return ("opened", OpenResult.already.rawValue) }
            if HomeSwipeGuard.onHome(steps, startsOnHome: homeAtStart), try await tapHomeIcon(app) {
                return ("opened", OpenResult.opened.rawValue)
            }
            return ("opened", try await phone.openApp(app).rawValue)
        case "back": return try await backChecked()
        case "wait": return try await waitFor(a).map { ("result", $0) }
        case let other: throw Actions.ParseError(message: "unknown action \(other ?? "nil")")
        }
        return nil
    }
}

extension AgentLoop {
    /// The top-left back arrow of a pushed page, 0-1000 (where the model tapped it when the edge swipe did nothing).
    static let backArrow = (x: 56, y: 69)
    static let backWords: Set<String> = ["<", "‹", "〈", "く", "返回", "Back", "back"]

    /// `back` as the edge swipe, then the top-left arrow when the screen did not move. Henry 2026-11-18: in one run
    /// back often did nothing and the model spent a step each time tapping the arrow itself.
    func backChecked() async throws -> (String, String)? {
        guard let phone else { return nil }
        let before = screen?.frame
        try await phone.goBack()
        lastActed = now()
        _ = await settle()
        let (after, pointer) = (screen?.frame, pointerAt)
        guard let before, !(await Vision.off { Vision.changed(before, after, ignore: [pointer]) }) else { return nil }
        // the AssistiveTouch button parked there: tapping it opens its menu, not the page's back (2026-11-18)
        let arrow = (x: Double(Self.backArrow.x) / 1000, y: Double(Self.backArrow.y) / 1000)
        if (AssistiveTouchSpots.all + assistiveHits.map { (x: Double($0.x) / 1000, y: Double($0.y) / 1000) })
            .contains(where: { abs($0.x - arrow.x) < 0.08 && abs($0.y - arrow.y) < 0.08 }) {
            DebugLog.write("back: the swipe changed nothing; the AssistiveTouch button sits on the arrow, not tapped")
            return ("result", "the back swipe changed nothing, and the AssistiveTouch button covers the top-left arrow: "
                    + "tap the page's own back button just right of it, or the back arrow's text")
        }
        // a page with no back arrow (an app's home: a city or a title up there) is left alone
        if let after, let image = Vision.image(after) {
            let size = CGSize(width: image.width, height: image.height)
            let words = await UITreeOCR.lines(image).filter { line in
                line.box.count == 4 && Double(line.box[0]) < 0.15 * size.width  // below the status bar's clock, above 12%
                    && Double(line.box[1] + line.box[3]) / 2 > 0.055 * size.height && Double(line.box[1] + line.box[3]) / 2 < 0.12 * size.height
            }.map(\.text)
            let arrow = { (t: String) in Self.backWords.contains(t) || ["<", "‹", "〈", "く"].contains { t.hasPrefix($0) } }
            if let word = words.first(where: { !arrow($0.trimmingCharacters(in: .whitespaces)) }) {
                DebugLog.write("back: the swipe changed nothing; top-left shows \"\(word.prefix(12))\", no arrow tapped")
                return ("result", "the back swipe changed nothing, and this page has no back arrow at the top left")
            }
        }
        DebugLog.write("back: the swipe changed nothing; tapping the top-left arrow")
        _ = try await perform(["action": .str("tap"), "x": .int(Self.backArrow.x), "y": .int(Self.backArrow.y)])
        return ("result", "the back swipe did nothing, so the top-left arrow was tapped")
    }

    /// `open` on the Home Screen with the app's icon on it: tap the icon (above its label) instead of Spotlight.
    /// 2026-11-17: 3 of 5 failed opens had the icon on screen while Spotlight did not find the app. True only when
    /// the screen then left the Home Screen; else Spotlight runs as before (a miss costs one OCR, ~0.3 s).
    func tapHomeIcon(_ app: String) async throws -> Bool {
        guard let phone, !app.isEmpty, let screen, screen.live, let before = screen.frame, let image = Vision.image(before) else { return false }
        let lines = await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: app), whole: true)
        let size = CGSize(width: image.width, height: image.height)
        guard let spot = Self.homeIconSpot(lines, labels: [app] + AppNames.labels(app), size: size) else { return false }
        DebugLog.write("open \(app): its icon is on the Home Screen, tapping it")
        try await phone.tap(spot.x, spot.y, aim: true)
        lastActed = now()
        _ = await settle()
        let after = screen.frame
        let left = await Vision.off { Vision.bigChange(before, after) }
        DebugLog.write("open \(app): icon tap \(left ? "opened it" : "did nothing, Spotlight next")")
        return left
    }

    /// Where to tap the icon whose label is one of `labels`: above the label by `iconLift` of the label's own
    /// height (measured, so any screen size and text size), on the icon. Only one such label: two (a widget, a
    /// folder name) leave it to Spotlight.
    static let iconLift = 1.5
    static func homeIconSpot(_ lines: [(text: String, box: [Int])], labels: [String], size: CGSize) -> CGPoint? {
        let spots = AppOpener.resultSpots(lines, labels: labels, size: size)
        guard spots.count == 1, let label = lines.first(where: { line in
            line.box.count == 4 && AppOpener.resultSpots([line], labels: labels, size: size) == spots
        }) else { return nil }
        let top = Double(label.box[1]), height = Double(label.box[3] - label.box[1])
        let y = (top - iconLift * height) / size.height
        return y > 0 ? CGPoint(x: spots[0].x, y: y) : nil
    }
}

/// `open APP` while the run is inside that app (it opened it and has not gone Home or opened another since): the
/// Home key, Spotlight and the typing cost 20-57 s and came back to the same app (2026-11-17: `open 美团外卖` from
/// one of its shop pages, 57 s, not_opened). Nothing is sent; the model is told to go back instead. Asked a second
/// time in a row, it really opens (the run may have left the app in a way the steps do not show).
enum AlreadyOpen {
    static func holds(_ app: String, _ steps: [JObject]) -> Bool {
        let sent = steps.filter { $0["action"]?.str != "plan" && $0["action"]?.str != RepeatGuard.action }
        if let last = sent.last, last["action"]?.str == "open", last["opened"]?.str == OpenResult.already.rawValue { return false }
        for s in sent.reversed() {
            switch s["action"]?.str {
            case "home": return false
            case "open":
                guard same(s["app"]?.str ?? "", app) else { return false }
                if s["opened"]?.str == OpenResult.opened.rawValue { return true }
            default: continue
            }
        }
        return false
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let n = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        return n(a) == n(b) || !AppNames.labels(a).isEmpty && AppNames.labels(a).contains { n($0) == n(b) }
    }
}

/// Swipes have no momentum, and a long one skips what was between (scrolled past unseen); the prompt asks for
/// 100-250, the code holds it to that. A swipe from a screen edge (Control Center, Notification Center, Back)
/// keeps its length.
enum SwipeClamp {
    static let limit = 300.0, edge = 80.0  // Control Center swipes start ~50 from the top

    /// The model's swipe, cut to the limit (its end moved, a note for the next round). Replayed swipes are not.
    static func apply(_ a: inout JObject, limit: Double = limit) {
        let (x, y, cut) = end(a, limit: limit)
        guard cut else { return }
        (a["x2"], a["y2"]) = (.int(Int(x.rounded())), .int(Int(y.rounded())))
        a["result"] = .str("swipe shortened to \(Int(limit)) units; swipe again to go further")
    }

    /// The swipe's end in 0-1000 units, and whether it was cut short; `limit` is shorter on a phone whose lists
    /// glide on (ScrollMeter.gain).
    static func end(_ a: JObject, limit: Double = limit) -> (x: Double, y: Double, cut: Bool) {
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
    /// `image`: the size of the screenshot the model saw. A y past 1000 that fits inside it is most likely in that
    /// image's pixels (2026-11-17: y 1083-1108 in 540 x 1170 images, 14% of runs): still not tapped (a guessed
    /// conversion could press Send), but the note gives the 0-1000 point that pixel would be.
    static func reason(_ a: JObject, image: @autoclosure () -> CGSize? = nil) -> String? {
        guard let x = a["x"]?.double, let y = a["y"]?.double, !(0...1000).contains(x) || !(0...1000).contains(y) else { return nil }
        var out = "not tapped: \(Int(x)), \(Int(y)) is off the screen; x and y run 0-1000"
        if let image = image(), image.width > 0, image.height > 1000, (0...image.width).contains(x), (0...image.height).contains(y) {
            out += " (not pixels of the screenshot; if you meant its pixel \(Int(x)), \(Int(y)), that is x \(Int(x * 1000 / image.width)), "
                + "y \(Int(y * 1000 / image.height)))"
        }
        return out
    }

    /// The size of the copy the model gets (ModelImage), from the JPEG the step looked at.
    static func modelSize(_ jpeg: Data?) -> CGSize? {
        guard let jpeg, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0
        else { return nil }
        let w = Double(pw), h = Double(ph)
        let sent = ModelImage.on ? min(Double(ModelImage.maxWidth), w) : w
        return CGSize(width: sent, height: (h * sent / w).rounded())
    }
}

/// The Dynamic Island at the top center: with a Live Activity in it (this agent's own, during a run) a tap there opens
/// that activity's app and leaves the one the task is in. A search field right under the island drew such taps.
/// A tap in the island's lowest `band` goes just below it (`below`), where a field under the island still is; one
/// higher up is not sent and the model is told where to tap instead.
enum IslandGuard {
    static let band = 30.0, below = 8.0
    /// Half the width of the island with a Live Activity's compact views beside it, of the screen's width.
    static let halfWidth = 0.32

    /// The island's touch area in 0-1000 screen units, from the window's top safe area in points (59-68 with an
    /// island; 44-50 under a notch, 20 with a Home button) and the screen's size in points. nil: no island, or
    /// not portrait.
    static func zone(top: Double, size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > size.width, top >= 54 else { return nil }
        let bottom = (top + 4) / Double(size.height) * 1000
        return CGRect(x: 500 - halfWidth * 1000, y: 0, width: 2 * halfWidth * 1000, height: bottom)
    }

    /// nil = send the tap (moved below the island if it was in its lowest band, with a note); else why it is not sent.
    static func apply(_ a: inout JObject, zone: CGRect?) -> String? {
        guard let zone, let x = a["x"]?.double, let y = a["y"]?.double,
              (zone.minX...zone.maxX).contains(x), y < zone.maxY else { return nil }
        let to = Int((zone.maxY + below).rounded(.up))
        guard y < zone.maxY - band else {
            a["y"] = .int(to)
            a["result"] = .str("moved down to y \(to): y \(Int(y)) is on the Dynamic Island, which a tap would open")
            return nil
        }
        return "not tapped: \(Int(x)), \(Int(y)) is on the Dynamic Island (top center), where a tap leaves the app;"
            + " tap the element left of x \(Int(zone.minX)), right of x \(Int(zone.maxX)) or below y \(to)"
    }
}

/// Enter after a `type`, held back once when it would do harm, for any app (Wiki #1007, 2026-11-16):
/// - N2: the typing stopped part way ("not typed: ..."), and Enter sent half a message (WeChat, Messages);
/// - N7: the goal was reached, and the same text was typed and sent again (QQ, ~4 times in one run).
/// Held once each, with the reason for the model; the same Enter again goes through (a search run twice is
/// legitimate). A `clear` or a complete `type` starts over.
/// A tap on a send button (发送 / Send, label under the tap) is held the same way (2026-11-22: a DM went out garbled
/// through the Send button, which no check saw).
/// A real send (that button, or Enter while a 发送 / Send key or button shows low on the screen) is a hard gate
/// (`send`, 2026-11-23, Wiki #1007: half-typed and garbled messages kept going out after the one hold): held once,
/// then the user is asked, only on hard evidence: the typer said part is missing and the screen does not show it,
/// or Chinese text whose characters are mostly not on the screen (pinyin letters went in). Built not to stop a
/// normal run: the screen overrules the typer when it shows the text; an OCR slip (emoji, punctuation, one wrong
/// character) is not evidence; text typed over `recentType` steps ago (a search never entered) and the same text
/// sent again (one reply to several chats) only get the old single hold. Enter in a search field stays soft.
struct SendGuard {
    private(set) var missing: String?  // what the last `type` did not get into the field
    private(set) var pending: String?  // the last complete `type`, not yet entered
    private(set) var sent: [String: Int] = [:]  // text -> the step that entered it
    private var heldIncomplete = false, heldRepeat: String?, heldUnseen = false
    private(set) var typedAt: Int?  // the step of the last `type`
    static let recentType = 6  // steps: a send this long after the type is not about that text any more

    enum Verdict: Equatable {
        case go
        case hold(String)  // the model's note: not sent, why, what to do
        case ask(String)   // the user decides (a confirm reason, "send: ...")
        var isHold: Bool { if case .hold = self { return true } else { return false } }
    }
    /// How to empty a field the agent typed into: its own `clear` action (keyboard deletes). A 清空 / Clear button on
    /// screen stops the run at the pay guard (2026-11-20: tapped to undo half a typed name, the user had to stop it).
    static let clearHint = "empty the field with the clear action (never a 清空 / Clear button on screen)"
    /// First thing a part-way `type` tells the model: the app's suggestions often list the target already (2026-11-20:
    /// 西岸艺术中心 sat under the field while the run went on typing). Starts a note, ends with a space.
    static let listedHint = "If the screen already lists what the goal needs (a suggestion or result under the field),"
        + " tap it instead of typing more. "

    /// The part a `type` note says is missing (`not typed: "..."`). Every note is a problem (a word cleared, symbols
    /// wrong, nothing typed): "" when it does not say what is missing (the whole text is then taken as unsure).
    static func missing(_ note: String) -> String? {
        guard let r = note.range(of: "not typed: \"", options: .backwards) else { return "" }
        let rest = String(note[r.upperBound...].prefix { $0 != "\"" })
        return rest
    }

    mutating func typed(_ text: String, missing: String?, at step: Int? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        typedAt = step
        if let missing {
            self.missing = missing.isEmpty ? text : missing
            pending = nil
        } else {
            self.missing = nil
            pending = text.isEmpty ? nil : text
            heldIncomplete = false
        }
    }

    mutating func cleared() {
        (missing, pending, heldIncomplete, heldUnseen) = (nil, nil, false, false)
    }

    /// Labels of a button that sends what was typed: the whole label, as PayGuard reads it.
    static let sendWords: Set<String> = ["发送", "发布", "回复", "send", "post", "reply"]

    static func isSend(_ label: String?) -> Bool {
        guard let label = label?.trimmingCharacters(in: .whitespaces).lowercased(), !label.isEmpty else { return false }
        return sendWords.contains(label)
    }

    /// Before Enter (or a tap on a send button: `again` names it) at `step`: a reason to hold it back, or nil to send it.
    mutating func enter(step: Int, again: String = "key enter again") -> String? {
        if let missing, !heldIncomplete {
            heldIncomplete = true
            return "not sent: the field holds only part of the text (not typed: \"\(missing)\"). " + Self.listedHint
                + "Else type the rest first, or \(Self.clearHint) and type it all again; \(again) to send it as it is"
        }
        if let text = pending, let at = sent[text], heldRepeat != text {
            heldRepeat = text
            return "not sent: \"\(text)\" was already entered at step \(at). If it is on screen, the goal may be done;"
                + " \(again) only to enter it a second time"
        }
        went(step: step)
        return nil
    }

    /// Before a real send at `step`. `lines`: the screen the model saw, when it shows the field as typed (nil: typed
    /// in this same round, after that screen was taken, or not read).
    mutating func send(step: Int, lines: [DemoAnalysis.Line]?, again: String) -> Verdict {
        if let at = typedAt, step - at > Self.recentType {  // an old type: the soft hold, never asked
            return enter(step: step, again: again).map { .hold($0) } ?? .go
        }
        if let missing {
            if let lines, Self.seen(missing, in: lines) >= 0.8 {  // the field shows it: the typer's note was wrong
                went(step: step)
                return .go
            }
            if !heldIncomplete {
                heldIncomplete = true
                return .hold("not sent: the field holds only part of the text (not typed: \"\(missing)\"). "
                    + Self.listedHint + "Else type the rest first, or \(Self.clearHint) and type it all again")
            }
            return .ask("send: the field holds only part of the message (not typed: \"\(missing)\")")
        }
        if let text = pending, let lines, HanTyper.isHan(text), Self.seen(text, in: lines) < 0.5 {
            if !heldUnseen {
                heldUnseen = true
                return .hold("not sent: \"\(text)\" is not seen in the field (the keyboard may have typed letters or"
                    + " other words). Look at the field: \(Self.clearHint) and type it again if it is wrong; \(again) if it is right")
            }
            return .ask("send: the typed message \"\(text)\" is not seen in the field")
        }
        // the same text again: held once (a reply sent twice), then sent (one reply to several chats)
        return enter(step: step, again: again).map { .hold($0) } ?? .go
    }

    /// How much of `text` the screen shows, 0-1: Chinese by its characters (any order: an OCR slip on one character,
    /// a wrapped line), other text whole; emoji, punctuation and spaces are left out (OCR drops them).
    static func seen(_ text: String, in lines: [DemoAnalysis.Line]) -> Double {
        func core(_ s: String) -> [Character] {
            Scripts.fold(s).filter { $0.isLetter || $0.isNumber }
        }
        let want = core(text), screen = core(lines.map(\.text).joined())
        guard !want.isEmpty else { return 1 }
        let han = want.filter { HanTyper.isHan(String($0)) }
        if han.isEmpty { return String(screen).contains(String(want)) ? 1 : 0 }
        let there = Set(screen)
        return Double(han.filter { there.contains($0) }.count) / Double(han.count)
    }

    /// The send went out (or the user said yes to it): what was typed counts as sent, the holds start over.
    mutating func went(step: Int) {
        if let text = pending { sent[text] = step }
        (pending, missing, heldIncomplete, heldRepeat, heldUnseen) = (nil, nil, false, nil, false)
    }

    /// Whether Enter sends: a 发送 / Send key or button reads in the lower half of the screen (the keyboard's return
    /// key, or the app's button next to the field). A search field's key reads 搜索 / Search / 前往; 回复 / Reply
    /// do not count here (a comment list shows one under every comment).
    static let enterSendWords: Set<String> = ["发送", "发布", "send", "post"]
    static func sendShown(_ lines: [DemoAnalysis.Line]) -> Bool {
        lines.contains { $0.y >= 500 && enterSendWords.contains($0.text.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

}

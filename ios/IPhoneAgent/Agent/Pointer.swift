import UIKit

/// Touch-like gestures on the phone, built from relative mouse moves. Port of phone.py.
///
/// The pointer is relative, so the app tracks where it is (in mouse units) and moves from there; every few
/// gestures it slams it into the top-left corner (`home`) again to cancel drift. Coordinates are fractions of
/// the screen (0..1, origin top-left), so they work for any frame size.
@MainActor final class Pointer: ObservableObject {
    static let calibrationMove = 200        // mouse units moved diagonally for a manual (one point) calibration
    static let calibrationStops = [150, 350]  // automatic calibration finds the pointer at these distances
    static let rehomeEvery = 10             // gestures between re-homing
    static let hold = 0.25                  // s to rest before lifting, so iOS adds no momentum
    static let tapGap = 0.15                // s to stay still after a click, so iOS sees a finished tap
    static let nudge = 12                   // mouse units the pointer is wiggled by to find it on screen
    static let aimTolerance = 0.008         // screen fraction; a bigger miss is corrected before pressing
    static let maxMiss = 0.06               // bigger misses are still corrected, but not learned from

    struct Span: Codable, Equatable { var w: Int, h: Int }
    private struct Saved: Codable { var w: Int, h: Int, seen: [String: [[Double]]]?, quality: Double?, aspect: Double? }

    let device: HIDDevice
    weak var screen: ScreenSource?
    private let file: URL
    @Published private(set) var span: Span?  // mouse units needed to cross the full screen width / height
    private var pos: (Int, Int)?  // pointer position in mouse units; nil = unknown
    private var moves = 0
    private var link = 0  // device.links when the pointer was last homed
    /// where the pointer really landed (seen on screen) for the fraction we aimed at, per axis; a line fit
    /// through them corrects every later move, so taps get better as the agent works
    private(set) var seen: [String: [(Double, Double)]] = ["x": [], "y": []]
    @Published private(set) var quality: Double?  // pointer error at the last check, fraction of the screen
    private(set) var aspect: Double?  // frame width / height when calibrated
    var log: (String) -> Void = { print($0) }
    /// The device screen's width / height (iPhone or iPad), stored with a calibration.
    var screenAspect: () -> Double = { 9 / 19.5 }
    /// Last-resort pointer finder on a frame (the vision model), when the pixel diff finds nothing.
    var locate: ((Data) async -> CGPoint?)?

    init(device: HIDDevice, calibrationFile: URL, screen: ScreenSource? = nil) {
        self.device = device
        self.file = calibrationFile
        self.screen = screen
        if let data = try? Data(contentsOf: calibrationFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            span = Span(w: saved.w, h: saved.h)
            (quality, aspect) = (saved.quality, saved.aspect)
            for axis in ["x", "y"] {
                seen[axis] = (saved.seen?[axis] ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }.suffix(12)
            }
        }
    }

    var calibrated: Bool { span != nil }

    private func remember(_ axis: String, _ sample: (Double, Double)) {
        seen[axis] = Array((seen[axis, default: []] + [sample]).suffix(12))  // deque(maxlen=12)
    }

    /// Find the pointer on screen at two known distances from the corner and fit the mapping from both.
    /// Returns true when it calibrated itself; otherwise the user taps the pointer (finishCalibration).
    /// `progress` gets 0 (homing), then 1, 2 (each probe).
    func startCalibration(progress: ((Int) -> Void)? = nil) async throws -> Bool {
        pos = nil
        progress?(0)
        try await device.send("home")
        var found: [(Int, Double, Double)] = []
        for (i, units) in Self.calibrationStops.enumerated() {
            progress?(i + 1)
            let step = units - (found.last?.0 ?? 0)
            try await device.send("move \(step) \(step)")
            guard let screen, screen.live, let p = try await findPointer() else { break }
            found.append((units, p.x, p.y))
        }
        if found.count < 2 {
            log("calibration: pointer not found on screen, waiting for a tap")
            if found.isEmpty {
                try await device.send("home")
                try await device.send("move \(Self.calibrationMove) \(Self.calibrationMove)")
            }
            return false
        }
        let (u1, x1, y1) = found[0], (u2, x2, y2) = found[1]
        let s = Span(w: Int((Double(u2 - u1) / (x2 - x1)).rounded(.toNearestOrEven)), h: Int((Double(u2 - u1) / (y2 - y1)).rounded(.toNearestOrEven)))
        span = s
        (quality, aspect) = (nil, screenAspect())
        seen = ["x": [], "y": []]
        for (units, x, y) in found {  // where each stop landed, so moves are corrected for the offset too
            remember("x", (Double(units) / Double(s.w), x))
            remember("y", (Double(units) / Double(s.h), y))
        }
        save()
        log("calibration: span \(s.w) x \(s.h)")
        return true
    }

    /// Wiggle the pointer and find it anywhere on screen (the span may still be unknown).
    private func findPointer() async throws -> CGPoint? {
        guard let screen else { return nil }
        await screen.settled(quiet: 0.2, least: 0.3, most: 1.5)
        let before = screen.frame, sent = now()
        try await device.send("move \(Self.nudge) 0")
        var after = await screen.fresh(since: sent, timeout: 1.0)
        if after != nil {
            await screen.settled(quiet: 0.15, least: 0.1, most: 0.6)
            after = screen.frame
        }
        try await device.send("move -\(Self.nudge) 0")
        guard let before, let after else { return nil }
        let pixel = Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: 0.025, reach: CGPoint(x: 0.5, y: 0.5))
        var found = pixel
        if found == nil { found = await locate?(after) }
        guard let p = found else { return nil }
        if pixel == nil { log(String(format: "calibration: vision model found the pointer at (%.3f, %.3f)", p.x, p.y)) }
        return 0.03 < p.x && p.x < 0.97 && 0.03 < p.y && p.y < 0.97 ? p : nil
    }

    /// x, y: where the pointer ended up after startCalibration() (one point, picked by the user).
    func finishCalibration(x: Double, y: Double) {
        (quality, aspect) = (nil, screenAspect())
        span = Span(w: Int((Double(Self.calibrationMove) / x).rounded(.toNearestOrEven)), h: Int((Double(Self.calibrationMove) / y).rounded(.toNearestOrEven)))
        seen = ["x": [], "y": []]
        save()
    }

    /// Touch-probe result: per-axis lines landed = a * units + b fitted from taps the app caught itself.
    /// The span is 1/a; every probe becomes a landing sample, so `fix` also corrects the offset b.
    func applyProbe(x: ProbeFit.Line, y: ProbeFit.Line, samples: [(ux: Double, uy: Double, fx: Double, fy: Double)]) {
        let s = Span(w: Int((1 / x.a).rounded()), h: Int((1 / y.a).rounded()))
        span = s
        (quality, aspect) = (max(x.rms, y.rms), screenAspect())
        seen = ["x": [], "y": []]
        for p in samples {
            remember("x", (p.ux / Double(s.w), p.fx))
            remember("y", (p.uy / Double(s.h), p.fy))
        }
        pos = nil
        save()
        log(String(format: "calibration: touch probe span %d x %d, offset %.3f / %.3f, residual %.2f%%",
                   s.w, s.h, x.b, y.b, max(x.rms, y.rms) * 100))
    }

    /// A measured check (e.g. a probe tap) as the current accuracy.
    func setQuality(_ q: Double) {
        quality = q
        save()
    }

    /// Calibration plus the observed landings, so the correction survives a restart.
    private func save() {
        guard let span else { return }
        let saved = Saved(w: span.w, h: span.h, seen: seen.mapValues { $0.map { [$0.0, $0.1] } }, quality: quality,
                          aspect: aspect)
        try? JSONEncoder().encode(saved).write(to: file)
    }

    func point(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        guard calibrated else { throw DeviceError(message: "pointer not calibrated") }
        try await moveTo(dx(x), dy(y))
        if aim && screen != nil { try await self.aim(x, y) }
    }

    /// Closed loop: find the real pointer on screen, fix a miss, and learn the error for later moves.
    private func aim(_ x: Double, _ y: Double) async throws {
        guard let span, let found = try await measure(x, y, model: false) else {
            log(String(format: "aim (%.3f, %.3f): pointer not found", x, y))
            return
        }
        let fx = Double(found.x), fy = Double(found.y)
        if max(abs(fx - x), abs(fy - y)) <= Self.maxMiss {  // learn from normal drift only, never a stray reading
            remember("x", (fix(x, "x"), fx))
            remember("y", (fix(y, "y"), fy))
            save()
        }
        if abs(fx - x) <= Self.aimTolerance && abs(fy - y) <= Self.aimTolerance { return }
        let mx = Int(((x - fx) * Double(span.w)).rounded(.toNearestOrEven)), my = Int(((y - fy) * Double(span.h)).rounded(.toNearestOrEven))
        try await device.send("move \(mx) \(my)")  // fix this miss right away
        if let p = pos { pos = (p.0 + mx, p.1 + my) }
    }

    /// Wiggle the pointer and find it on screen, near the target first, then anywhere. model: ask the vision
    /// model when the pixels don't show it (~20 s, rarely right); a tap's aim never waits for that.
    private func measure(_ x: Double, _ y: Double, model: Bool = true) async throws -> CGPoint? {
        guard let screen, let span else { return nil }
        let nudge = x < 0.9 ? Self.nudge : -Self.nudge  // stay clear of the screen edge
        await screen.settled(quiet: 0.15, least: 0.1, most: 0.6)  // pointer at rest
        let before = screen.frame, sent = now()
        try await device.send("move \(nudge) 0")
        var after = await screen.fresh(since: sent, timeout: 1.2)
        if after != nil {
            await screen.settled(quiet: 0.1, least: 0.05, most: 0.4)
            after = screen.frame
        }
        try await device.send("move \(-nudge) 0")
        let shift = Double(nudge) / Double(span.w)
        guard let before, let after else { return nil }
        if let p = Vision.pointer(before, after, near: CGPoint(x: x, y: y), shift: shift)
            ?? Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: shift, reach: CGPoint(x: 0.5, y: 0.5)) {
            return p
        }
        return model ? await locate?(after) : nil
    }

    /// Calibration check without tapping: move to a known point and measure the miss (fraction of the screen).
    /// nil when the pointer could not be found.
    func verify(x: Double = 0.5, y: Double = 0.62) async throws -> Double? {
        try await point(x, y)
        guard let found = try await measure(x, y) else { return nil }
        let error = max(abs(Double(found.x) - x), abs(Double(found.y) - y))
        quality = error
        save()
        return error
    }

    /// How far the learned correction has moved targets away from the plain calibration (fraction of the screen).
    var drift: Double {
        [0.2, 0.8].flatMap { t in ["x", "y"].map { abs(fix(t, $0) - t) } }.max() ?? 0
    }

    /// Demo data: pretend a calibration with this quality.
    func mockCalibrated(quality: Double) {
        span = span ?? Span(w: 400, h: 860)
        self.quality = quality
    }

    /// The fraction to aim at so the pointer lands on t, from the line through the observed landings.
    func fix(_ t: Double, _ axis: String) -> Double {
        let pts = seen[axis] ?? []
        guard pts.count >= 2 else { return t }
        let n = Double(pts.count)
        let mc = pts.map(\.0).reduce(0, +) / n, mf = pts.map(\.1).reduce(0, +) / n
        let variance = pts.map { pow($0.0 - mc, 2) }.reduce(0, +)
        var a = variance > 1e-4 ? pts.map { ($0.0 - mc) * ($0.1 - mf) }.reduce(0, +) / variance : 1.0  // landed = a*aimed + b
        a = 0.85 < a && a < 1.15 ? a : 1.0
        let b = mf - a * mc
        return abs(b) < 0.1 ? (t - b) / a : t
    }

    private func moveTo(_ tx: Int, _ ty: Int, rehome: Bool = true) async throws {
        if link != device.links {  // new link: a dropped gesture may have left the button down
            try await device.send("release")
            (pos, link) = (nil, device.links)
        }
        if pos == nil || (rehome && moves >= Self.rehomeEvery) {
            try await device.send("home")
            (pos, moves) = ((0, 0), 0)
        }
        let (x, y) = pos!
        pos = nil  // unknown until the move succeeds
        try await device.send("move \(tx - x) \(ty - y)")
        (pos, moves) = ((tx, ty), moves + 1)
    }

    /// Let go of the button and re-home the pointer, whatever state a gesture left.
    func reset() async throws {
        pos = nil
        try await device.send("release")
        try await device.send("home")
        (pos, moves) = ((0, 0), 0)
    }

    /// aim: find the pointer on screen first (slower); worth it when a tap just missed.
    func tap(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        try await point(x, y, aim: aim)
        try await device.send("click")
        try await Task.sleep(nanoseconds: UInt64(Self.tapGap * 1e9))
    }

    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool = true) async throws {
        try await drag([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], hold: hold)
    }

    /// Press at the first point, move through the rest, release: one continuous stroke. hold rests at the end
    /// first, so lists and pickers stop exactly there; system gestures (home, back) need the flick.
    func drag(_ points: [CGPoint], hold: Bool = true) async throws {
        try await point(Double(points[0].x), Double(points[0].y))
        try await device.send("press")
        do {
            for p in points.dropFirst() {
                try await moveTo(dx(Double(p.x)), dy(Double(p.y)), rehome: false)  // never home mid-drag
            }
            if hold { try await Task.sleep(nanoseconds: UInt64(Self.hold * 1e9)) }
        } catch {
            _ = try? await device.send("release")
            throw error
        }
        try await device.send("release")
    }

    func scroll(_ x: Double, _ y: Double, lines: Int) async throws {
        try await point(x, y)
        try await device.send("scroll \(lines) 0")
    }

    /// The board types printable ASCII only (one key per character). Chinese goes in as toneless pinyin, which
    /// most Chinese apps' search boxes accept; other non-ASCII (emoji, accents) is folded or dropped. The clipboard
    /// is no route: iOS refuses a background app's write (a Mac's Universal Clipboard text got pasted instead,
    /// 2026-10-20) and other apps ask "Allow Paste" every time.
    func type(_ text: String) async throws {
        let ascii = Self.typeable(text)
        if ascii != text { DebugLog.write("type: \(text.count) chars as ASCII \"\(ascii)\"") }
        guard !ascii.isEmpty else { throw DeviceError(message: "nothing typeable in that text (the board types ASCII only)") }
        try await matchKeyboard(pinyin: ascii != text && text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) })
        _ = try await device.send("type \(ascii)")
    }

    /// English text on a pinyin keyboard comes out as unconfirmed pinyin, and Chinese on an English one as plain
    /// letters; models rarely notice (2026-11-03 runs). Read the keyboard off the screen and switch (ctrl+space).
    private func matchKeyboard(pinyin: Bool) async throws {
        guard let screen, screen.live else { return }
        for _ in 0..<2 {
            guard let frame = screen.frame else { return }
            let layout = await KeyboardLayout.read(frame)
            if layout == .none || (layout == .pinyin) == pinyin { return }
            log("type: the keyboard is \(layout == .pinyin ? "pinyin" : "English"); switching")
            let sent = now()
            try await key("ctrl+space")
            _ = await screen.fresh(since: sent, timeout: 1.5)
            await screen.settled(quiet: 0.2, least: 0.4, most: 1.5)
        }
    }

    /// "卫生纸 3卷" → "weishengzhi 3juan": Han characters to joined pinyin, accents folded, the rest dropped.
    static func typeable(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else { return text }
        var out = ""
        for ch in text {
            let s = String(ch)
            let isHan = s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
            let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s)
                .applyingTransform(.stripDiacritics, reverse: false) ?? s
            let kept = String(String.UnicodeScalarView(latin.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }))
            if isHan { out += kept.replacingOccurrences(of: " ", with: "") } else { out += kept }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
    /// Models write "delete" for the Mac's backspace key; the board knows it as "backspace" (2026-11-02 log).
    func key(_ combo: String) async throws {
        let keys = combo.split(separator: "+").map { $0 == "delete" ? "backspace" : String($0) }
        try await device.send("key \(keys.joined(separator: "+"))")
    }
    /// The board's consumer-control Home key ("AC Home"), which iOS treats like a keyboard's home key. Boards
    /// without it (older firmware) answer an error: then Cmd+H and the flick up from the home bar (a flick, not
    /// a rest: resting opens the app switcher). An acknowledged key that left the screen as it was gets the flick
    /// too: a contacts-sharing sheet and Calendar stayed through a dozen "homescreen → ok" (2026-11-03).
    func goHome() async throws {
        let before = screen?.live == true ? screen?.frame : nil
        if (try? await device.send("homescreen")) != nil {
            guard let screen, let before else { return }
            await screen.settled(quiet: 0.3, least: 0.6, most: 2.0)
            if Vision.changed(before, screen.frame) { return }
            log("home: the Home key left the screen unchanged; flicking up from the home bar")
        } else {
            try await key("cmd+h")
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        try await homeSwipe()
    }

    /// Spotlight (cmd+space), the app's name, return: tapping Home's Search pill with the pointer mostly did
    /// nothing (2026-11-03: 20+ taps in one run), and an app off the first page is only found by searching.
    func openApp(_ name: String) async throws {
        guard !name.isEmpty else { throw DeviceError(message: "open needs an app name") }
        try await goHome()
        try await key("cmd+space")
        try await Task.sleep(nanoseconds: 700_000_000)
        try await type(name)
        try await Task.sleep(nanoseconds: 900_000_000)
        try await key("enter")
    }

    /// Park the pointer on the home bar ahead of a departure, so the flick starts the moment it is asked for.
    func aimHomeBar() async throws { try await point(0.5, 0.995) }

    /// A real home-bar flick, independent of consumer-key and keyboard acknowledgements.
    func homeSwipe() async throws {
        defer { pos = nil }  // edge clamping or a cancelled stroke invalidates the tracked position
        try Task.checkCancellation()
        try await point(0.5, 0.995)
        // Push past the bottom edge, where the pointer stops: the calibration fit is weakest at the edges and
        // left it above the home bar on an iPhone 17 Pro Max (2026-11-02).
        guard let span else { return }
        try await device.send("move 0 \(span.h / 10)")
        try await device.send("press")
        do {
            try await device.send("move 0 \(-Int(Double(span.h) * 0.85))")  // to the middle only (0.45) left the app card half-way (2026-10-19)
        } catch {
            _ = try? await device.send("release")
            throw error
        }
        try await device.send("release")
    }

    func goBack() async throws {
        try await swipe(0.005, 0.45, 0.6, 0.45, hold: false)
        pos = nil
    }

    private func dx(_ x: Double) -> Int { Int((min(max(fix(x, "x"), 0), 1) * Double(span!.w)).rounded(.toNearestOrEven)) }
    private func dy(_ y: Double) -> Int { Int((min(max(fix(y, "y"), 0), 1) * Double(span!.h)).rounded(.toNearestOrEven)) }
}

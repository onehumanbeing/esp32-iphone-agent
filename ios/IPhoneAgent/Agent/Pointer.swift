import UIKit

/// Touch-like gestures on the phone, built from relative mouse moves. Port of phone.py.
///
/// The pointer is relative, so the app tracks where it is (in mouse units) and moves from there; every few
/// gestures it slams it into the top-left corner (`home`) again to cancel drift. Coordinates are fractions of
/// the screen (0..1, origin top-left), so they work for any frame size.
@MainActor final class Pointer: ObservableObject {
    static let calibrationMove = 200        // mouse units moved diagonally for a manual (one point) calibration
    static let calibrationStops = [150, 350]  // automatic calibration finds the pointer at these distances
    /// Gestures between re-homing. Not every one: each home pushes the pointer into the top corner, and doing it
    /// before every tap opened Control Center and the Screen Mirroring panel 4 times in one run (2026-11-06).
    /// A landing that missed by more than maxMiss re-homes at once instead (see `landing`).
    static let rehomeEvery = 10
    static let samplesVersion = 4  // 2: landings before a big miss re-homed; 3: firmware pace 2 moves differently; 4: video recalibration samples lacked the origin
    static let hold = 0.25                  // s to rest before lifting, so iOS adds no momentum
    static let tapGap = 0.15                // s to stay still after a click, so iOS sees a finished tap
    static let nudge = 12                   // mouse units the pointer is wiggled by to find it on screen
    static let aimTolerance = 0.008         // screen fraction; a bigger miss is corrected before pressing
    static let maxMiss = 0.06               // bigger misses are still corrected, but not learned from
    static let agree = 0.02                 // a far reading is taken again; both must agree this closely
    static let sameSpot = 0.03              // a far reading this close to the last far one, for targets
    static let apart = 0.1                  // this far apart, is something moving by itself, not the pointer
    static let watch = 0.3                  // s the screen is watched before a nudge, for what moves by itself
    static let flickSpeed = 40              // the home flick's speed per report: the firmware's top (`move dx dy speed`)
    static let gentleFlickSpeed = 20        // Settings > Gentle Home swipe (default): half that, still a flick
    static let gentleHomeKey = "gentleHomeSwipe"
    static var gentleHome: Bool { UserDefaults.standard.object(forKey: gentleHomeKey) as? Bool ?? true }

    struct Span: Codable, Equatable {
        var w: Int, h: Int
        init(w: Int, h: Int) { (self.w, self.h) = (w, h) }
        /// nil unless both sides are a usable size: when the pointer did not move between two probes the fit
        /// divides by zero, and converting that to Int crashed calibration (TestFlight 1.0.1 (9), C2).
        init?(w: Double, h: Double) {
            guard w.isFinite, h.isFinite, 1...1e6 ~= w, 1...1e6 ~= h else { return nil }
            self.init(w: Int(w.rounded(.toNearestOrEven)), h: Int(h.rounded(.toNearestOrEven)))
        }
    }
    private struct Saved: Codable {
        var w: Int, h: Int, seen: [String: [[Double]]]?, quality: Double?, aspect: Double?, v: Int?, pace: Int?, ox: Double?, oy: Double?,
            gain: [[Double]]?
    }
    static let speed = 10.0  // the board's speed per report (STEP), the probes' and every long move's

    let device: HIDDevice
    weak var screen: ScreenSource?
    private let file: URL
    @Published private(set) var span: Span?  // mouse units needed to cross the full screen width / height
    /// Where home really leaves the pointer (screen fraction). Going left, then up the left edge, the rounded corner
    /// pushes it in to about x 0.14 (2026-11-06): steady, so it is part of the calibration, not learned drift.
    private(set) var origin = CGPoint.zero
    /// How far a move goes at a slower speed per report, relative to `speed`: (speed, ratio), measured at calibration.
    /// iOS accelerates the pointer by speed, so a short move or a correction (under one full report) falls short.
    private(set) var gain: [(Double, Double)] = []
    var recalibration = Recalibration()  // a landing far off target calibrates again before the next tap
    private var pos: (Int, Int)?  // pointer position in mouse units; nil = unknown
    private var moves = 0
    private var lastFar: (target: CGPoint, found: CGPoint)?  // the last reading far off its target (measureSure)
    /// The last measure's wiggle, for a second reading from its move back (`reread`).
    private var wiggle: (after: Data, back: Double, shift: Double, quiet: [CGRect])?
    private var link = 0  // device.links when the pointer was last homed
    /// where the pointer really landed (seen on screen) for the fraction we aimed at, per axis; a line fit
    /// through them corrects every later move, so taps get better as the agent works
    private(set) var seen: [String: [(Double, Double)]] = ["x": [], "y": []]
    @Published private(set) var quality: Double?  // pointer error at the last check, fraction of the screen
    private(set) var aspect: Double?  // frame width / height when calibrated
    private(set) var pace = 1  // the board's move pacing ("pace") when calibrated; 1 = firmware before it answered
    /// The connected board's pacing; a calibration made under another one no longer fits (iOS accelerates by speed).
    @Published var boardPace: Int?
    /// The board takes `flick` (firmware 0.2.5); nil until tried, reset by a new board connection.
    var flickInOne: Bool?
    var log: (String) -> Void = { print($0) }
    /// This app is in front (it must not be: open checks the app it opened is not this one).
    var ownAppInFront: (() -> Bool)?
    /// Puts text on the clipboard (ClipboardHop), for app names the board cannot type (AppOpener.paste).
    var clipboard: ((String) async throws -> Bool)?
    /// The device screen's width / height (iPhone or iPad), stored with a calibration.
    var screenAspect: () -> Double = { 9 / 19.5 }
    /// Last-resort pointer finder on a frame (the vision model), when the pixel diff finds nothing.
    var locate: ((Data) async -> CGPoint?)?

    init(device: HIDDevice, calibrationFile: URL, screen: ScreenSource? = nil) {
        self.device = device
        self.file = calibrationFile
        self.screen = screen
        if let data = try? Data(contentsOf: calibrationFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            load(saved)
        }
    }

    private func load(_ saved: Saved) {
        span = Span(w: saved.w, h: saved.h)
        (quality, aspect, pace) = (saved.quality, saved.aspect, saved.pace ?? 1)
        origin = CGPoint(x: saved.ox ?? 0, y: saved.oy ?? 0)
        gain = (saved.gain ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }
        for axis in ["x", "y"] where saved.v == Self.samplesVersion {
            seen[axis] = (saved.seen?[axis] ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }.suffix(12)
        }
    }

    /// The calibration as saved (nil when there is none), so a rejected calibration can put it back (`restore`).
    func snapshot() -> Data? { try? Data(contentsOf: file) }

    /// Back to a `snapshot`: the previous calibration, or none (issue #96: a ±49.8% check was kept and used).
    func restore(_ snapshot: Data?) {
        (span, quality, aspect, pace, origin, gain) = (nil, nil, nil, 1, .zero, [])
        (seen, pos) = (["x": [], "y": []], nil)
        if let snapshot, let saved = try? JSONDecoder().decode(Saved.self, from: snapshot) {
            load(saved)
            try? snapshot.write(to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    var calibrated: Bool { span != nil && (boardPace ?? pace) == pace }

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
        var fit: Span?
        if found.count == 2 {
            let (u1, x1, y1) = found[0], (u2, x2, y2) = found[1]
            fit = Span(w: Double(u2 - u1) / (x2 - x1), h: Double(u2 - u1) / (y2 - y1))
        }
        guard let s = fit else {
            log(found.count < 2 ? "calibration: pointer not found on screen, waiting for a tap"
                                : "calibration: the pointer did not move between the probes, waiting for a tap")
            if found.count != 1 {  // the tap expects the pointer at calibrationMove
                try await device.send("home")
                try await device.send("move \(Self.calibrationMove) \(Self.calibrationMove)")
            }
            return false
        }
        span = s
        // the corner the board homes to is not exactly (0, 0): fit that offset from the same two stops. Keeping an
        // older one (a touch probe's 0.142) while the samples left it out made `fix` learn a -7% x shift: every tap
        // landed left of its target after a mid-run recalibration (2026-11-11 Maps run).
        let (u1, x1, y1) = found[0]
        origin = CGPoint(x: x1 - Double(u1) / Double(s.w), y: y1 - Double(u1) / Double(s.h))
        if abs(origin.x) > 0.2 || abs(origin.y) > 0.2 { origin = .zero }  // not a corner: fall back to none
        (quality, aspect) = (nil, screenAspect())  // the speed gain (applySpeeds) still holds
        seen = ["x": [], "y": []]
        for (units, x, y) in found {  // where each stop landed, in the same terms as dx/dy aim
            remember("x", (Double(units) / Double(s.w) + origin.x, x))
            remember("y", (Double(units) / Double(s.h) + origin.y, y))
        }
        save()
        log(String(format: "calibration: span %d x %d, offset %.3f / %.3f", s.w, s.h, origin.x, origin.y))
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
        let pixel = await Vision.off { Vision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: 0.025, reach: CGPoint(x: 0.5, y: 0.5)) }
        var found = pixel
        // 与像素差分一致，模型测量微移前的位置。
        if found == nil { found = await locate?(before) }
        guard let p = found else { return nil }
        if pixel == nil { log(String(format: "calibration: vision model found the pointer at (%.3f, %.3f)", p.x, p.y)) }
        return 0.03 < p.x && p.x < 0.97 && 0.03 < p.y && p.y < 0.97 ? p : nil
    }

    /// x, y: where the pointer ended up after startCalibration() (one point, picked by the user).
    func finishCalibration(x: Double, y: Double) {
        (quality, aspect, pace, origin, gain) = (nil, screenAspect(), boardPace ?? pace, .zero, [])
        guard let s = Span(w: Double(Self.calibrationMove) / x, h: Double(Self.calibrationMove) / y) else {
            log(String(format: "calibration: tap at (%.3f, %.3f) gives no usable span", x, y))
            return
        }
        span = s
        seen = ["x": [], "y": []]
        save()
    }

    /// Touch-probe result: per-axis lines landed = a * units + b fitted from taps the app caught itself.
    /// The span is 1/a and the origin b; every probe becomes a landing sample, so `fix` corrects what is left.
    func applyProbe(x: ProbeFit.Line, y: ProbeFit.Line, samples: [(ux: Double, uy: Double, fx: Double, fy: Double)]) {
        guard let s = Span(w: 1 / x.a, h: 1 / y.a) else {
            log(String(format: "calibration: touch probe slopes %.5f / %.5f give no usable span", x.a, y.a))
            return
        }
        span = s
        (quality, aspect, pace) = (max(x.rms, y.rms), screenAspect(), boardPace ?? pace)
        (origin, gain) = (CGPoint(x: x.b, y: y.b), [])
        seen = ["x": [], "y": []]
        for p in samples {
            remember("x", (p.ux / Double(s.w) + x.b, p.fx))
            remember("y", (p.uy / Double(s.h) + y.b, p.fy))
        }
        pos = nil
        save()
        log(String(format: "calibration: touch probe span %d x %d, offset %.3f / %.3f, residual %.2f%%",
                   s.w, s.h, x.b, y.b, max(x.rms, y.rms) * 100))
    }

    /// The speed calibration: ratios of a move's distance at a slower speed to the same move at `speed`.
    func applySpeeds(_ measured: [(Double, Double)]) {
        gain = measured.filter { $0.0 < Self.speed && $0.1 > 0.2 && $0.1 < 3 }.sorted { $0.0 < $1.0 }
        save()
        log("calibration: speed gain " + gain.map { String(format: "%.0f→%.2f", $0.0, $0.1) }.joined(separator: " "))
    }

    /// The distance ratio at a speed per report, interpolated between the measured speeds (1 at `speed`).
    func ratio(atSpeed v: Double) -> Double {
        let pts = (gain + [(Self.speed, 1.0)]).sorted { $0.0 < $1.0 }
        if v <= pts[0].0 { return pts[0].1 }
        for (a, b) in zip(pts, pts.dropFirst()) where v <= b.0 { return a.1 + (b.1 - a.1) * (v - a.0) / (b.0 - a.0) }
        return 1
    }

    /// The units to send for a move meant to go (mx, my) at full speed: the board paces a move of length L at
    /// L / ceil(L / speed) per report, so a short one is slower and goes ratio(v) as far.
    func paced(_ mx: Int, _ my: Int) -> (Int, Int) {
        let d = hypot(Double(mx), Double(my))
        guard d > 0, !gain.isEmpty else { return (mx, my) }
        var l = d
        for _ in 0..<4 { l = d / ratio(atSpeed: l / max(ceil(l / Self.speed), 1)) }
        let k = l / d
        return (Int((Double(mx) * k).rounded()), Int((Double(my) * k).rounded()))
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
                          aspect: aspect, v: Self.samplesVersion, pace: pace, ox: origin.x, oy: origin.y,
                          gain: gain.map { [$0.0, $0.1] })
        try? JSONEncoder().encode(saved).write(to: file)
    }

    func point(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        guard calibrated else { throw DeviceError(message: "pointer not calibrated") }
        try await moveTo(dx(x), dy(y))
        if aim && screen != nil { try await self.aim(x, y) }
    }

    /// Closed loop: find the real pointer on screen, fix a miss, and learn the error for later moves.
    private func aim(_ x: Double, _ y: Double) async throws {
        guard let span, let found = try await measureSure(x, y) else {
            log(String(format: "aim (%.3f, %.3f): pointer not found", x, y))
            return
        }
        let fx = Double(found.x), fy = Double(found.y)
        learn(x, y, found)
        if abs(fx - x) <= Self.aimTolerance && abs(fy - y) <= Self.aimTolerance { return }
        // A far reading is either the tracked position gone wrong or a wrong reading (two agreeing readings of a
        // map's own marker): moving by the difference then threw the pointer to the screen's edge (2026-11-11, a
        // +254 move from a reading at 0.46 x). From the corner again is right in both cases.
        if max(abs(fx - x), abs(fy - y)) > Self.maxMiss {
            pos = nil
            try await moveTo(dx(x), dy(y))
            return
        }
        let mx = Int(((x - fx) * Double(span.w)).rounded(.toNearestOrEven)), my = Int(((y - fy) * Double(span.h)).rounded(.toNearestOrEven))
        let (sx, sy) = paced(mx, my)
        let previousPosition = pos
        pos = nil
        try await device.send("move \(sx) \(sy)")  // fix this miss right away
        if let p = previousPosition { pos = (p.0 + mx, p.1 + my) }
    }

    /// Learn from where a move to (x, y) really landed: normal drift only, never a stray reading.
    /// True = re-home before the next gesture instead of calibrating again (Recalibration).
    @discardableResult
    private func learn(_ x: Double, _ y: Double, _ found: CGPoint) -> Bool {
        // a reading past maxMiss comes back from measureSure only when a second reading agreed with it
        let far = max(abs(Double(found.x) - x), abs(Double(found.y) - y)) > Self.maxMiss
        let rehome = recalibration.measured(CGPoint(x: x, y: y), found, pixels: Recalibration.pixels, confirmed: far)
        if rehome { log("pointer: far landing seen twice; re-homing, calibrating again only if the next one is far too") }
        guard !far else { return rehome }
        remember("x", (fix(x, "x"), Double(found.x)))
        remember("y", (fix(y, "y"), Double(found.y)))
        save()
        return rehome
    }

    /// After a tap at (x, y) that changed nothing: where the pointer really is (pixels only, no model), learned
    /// like an aim so the next taps are corrected. nil = not found.
    func landing(_ x: Double, _ y: Double) async -> CGPoint? {
        guard let found = try? await measureSure(x, y) else { return nil }
        learn(x, y, found)
        // A big miss: the tracked position drifted (relative moves between taps: a +256 x move went 75% of the
        // way, 2026-11-06), so the next gesture starts from the corner again.
        if max(abs(Double(found.x) - x), abs(Double(found.y) - y)) > Self.maxMiss { pos = nil }
        log(String(format: "landing (%.3f, %.3f): pointer at (%.3f, %.3f)", x, y, found.x, found.y))
        return found
    }

    /// Whether the pointer shows on screen at all: wiggled twice and looked for near `p`, then anywhere (TouchCheck).
    /// nil = no live screen or calibration, or the board did not answer.
    func pointerSeen(near p: CGPoint) async -> Bool? {
        guard let screen, screen.live, span != nil else { return nil }
        do {
            for _ in 0..<2 { if try await measure(p.x, p.y, model: false) != nil { return true } }
        } catch { return nil }
        return false
    }

    /// measure (pixels only), with a reading far from the target taken again: a word tile flying into Duolingo's
    /// answer row once read as the pointer 60% away (2026-11-06). nil when not found; when the two readings
    /// disagree the position is unknown too, so the next gesture starts from the corner.
    private func measureSure(_ x: Double, _ y: Double) async throws -> CGPoint? {
        func off(_ p: CGPoint, _ x: Double, _ y: Double) -> Double { max(abs(Double(p.x) - x), abs(Double(p.y) - y)) }
        guard let first = try await measure(x, y, model: false) else { return nil }
        guard off(first, x, y) > Self.maxMiss else { lastFar = nil; return first }
        // the second reading from the same wiggle's move back first, a whole new wiggle only if that shows nothing
        // (2026-11-11: two wiggles took 2.5 s; the move back gives a reading from two other frames for ~0.4 s)
        var reading = await reread(x, y)
        if reading == nil { reading = try await measure(x, y, model: false) }
        guard let again = reading, off(again, Double(first.x), Double(first.y)) <= Self.agree else {
            log(String(format: "pointer: far reading (%.3f, %.3f) not seen again; position unknown", first.x, first.y))
            pos = nil
            return nil
        }
        defer { lastFar = (CGPoint(x: x, y: y), again) }
        if let last = lastFar, Self.stuckReading(again, target: CGPoint(x: x, y: y), last: last) {
            log(String(format: "pointer: far reading (%.3f, %.3f) stays put while targets move; not the pointer", again.x, again.y))
            pos = nil
            return nil
        }
        return again
    }

    /// A far reading at the spot of the last far reading although the targets are far apart: the pointer went
    /// elsewhere, so it is something that moves on screen by itself (e.g. a clock), not the pointer.
    static func stuckReading(_ found: CGPoint, target: CGPoint, last: (target: CGPoint, found: CGPoint)) -> Bool {
        func off(_ a: CGPoint, _ b: CGPoint) -> Double { max(abs(Double(a.x - b.x)), abs(Double(a.y - b.y))) }
        return off(found, last.found) <= sameSpot && off(target, last.target) > apart
    }

    /// Wiggle the pointer and find it on screen, near the target first, then anywhere. model: ask the vision
    /// model when the pixels don't show it (~20 s, rarely right); a tap's aim never waits for that.
    private func measure(_ x: Double, _ y: Double, model: Bool = true) async throws -> CGPoint? {
        guard let screen, let span else { return nil }
        let nudge = x < 0.9 ? Self.nudge : -Self.nudge  // stay clear of the screen edge
        let started = now()
        wiggle = nil
        await screen.settled(quiet: 0.15, least: 0.1, most: 0.6)  // pointer at rest
        // what moves by itself (a clock, a spinner) in a short look before the nudge can't be the pointer. The time
        // the settled screen has already shown no change counts toward that look (2026-11-11: the full 0.3 s on top
        // of every settle; the frame is the same one throughout, so the look sees the same)
        let base = screen.frame
        let stillFor = now() - screen.changed
        if stillFor < Self.watch { try? await Task.sleep(nanoseconds: UInt64((Self.watch - stillFor) * 1e9)) }
        let before = screen.frame, sent = now()
        // 任一微移可能已执行但丢失回执，往返均确认后才能恢复位置缓存。
        let previousPosition = pos
        pos = nil
        try await device.send("move \(nudge) 0")
        var after = await screen.fresh(since: sent, timeout: 1.2)
        if after != nil {
            await screen.settled(quiet: 0.1, least: 0.05, most: 0.4)
            after = screen.frame
        }
        let back = now()
        try await device.send("move \(-nudge) 0")
        pos = previousPosition
        let shift = Double(nudge) / Double(span.w)
        guard let before, let after else {
            log(after == nil ? "pointer: no new frame after the nudge" : "pointer: no frame before the nudge")
            return nil
        }
        let looked = now()
        let (p, quiet) = await Vision.off {
            let quiet = Vision.motion(base, before)
            return (Self.find(before, after, near: CGPoint(x: x, y: y), shift: shift, quiet: quiet), quiet)
        }
        wiggle = (after, back, shift, quiet)
        // where a slow search spends its time (2026-11-07: taps took 9-26 s with seconds between commands)
        log(String(format: "pointer: measure %.1f s (settle %.1f, frames %.1f, search %.1f)%@", now() - started,
                   sent - started, looked - sent, now() - looked, p == nil ? ", not found" : ""))
        if let p { return p }
        return model ? await locate?(before) : nil
    }

    /// The pointer in `a`, moved by `shift` (fraction of width) in `b`: near the target, else anywhere.
    nonisolated private static func find(_ a: Data, _ b: Data, near: CGPoint, shift: Double, quiet: [CGRect]) -> CGPoint? {
        Vision.pointer(a, b, near: near, shift: shift, quiet: quiet)
            ?? Vision.pointer(a, b, near: CGPoint(x: 0.5, y: 0.5), shift: shift, reach: CGPoint(x: 0.5, y: 0.5), quiet: quiet)
    }

    /// A second reading of where the last measure found the pointer, from its move back (the frame after the nudge
    /// against one after the move back: two other frames, the pointer going the other way). Something that moved by
    /// itself in the first pair rarely moves back the same way; the readings must still agree (measureSure).
    private func reread(_ x: Double, _ y: Double) async -> CGPoint? {
        guard let screen, let w = wiggle else { return nil }
        wiggle = nil
        guard await screen.fresh(since: w.back, timeout: 1.2) != nil else { return nil }
        await screen.settled(quiet: 0.1, least: 0.05, most: 0.4)
        guard let back = screen.frame else { return nil }
        let p = await Vision.off { Self.find(w.after, back, near: CGPoint(x: x, y: y), shift: -w.shift, quiet: w.quiet) }
        // found where it was after the nudge: where it was before it is one shift to the left
        return p.map { CGPoint(x: $0.x - w.shift, y: $0.y) }
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
        let (mx, my) = paced(tx - x, ty - y)
        try await device.send("move \(mx) \(my)")
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
        if recalibration.tap() { try await recalibrate() }
        let from = pos  // where the tracked pointer was, for a tap that set off something else (another app in front)
        try await point(x, y, aim: aim)
        log(String(format: "tap (%.3f, %.3f): pointer from %@ to %@", x, y, from.map { "\($0.0) \($0.1)" } ?? "unknown",
                   pos.map { "\($0.0) \($0.1)" } ?? "unknown"))
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
        do {
            try await device.send("press")
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

    /// Spotlight (cmd+space) with the app's name typed, opened and read back by AppOpener: tapping Home's Search
    /// pill with the pointer mostly did nothing (2026-11-03: 20+ taps in one run), and a tap on the results
    /// that misses closes Spotlight.
    /// Only the Home key first, never goHome's flick: on the Home Screen the key changes nothing, and the flick
    /// then opened the App Switcher (2026-11-06). Spotlight opens from any app anyway.
    /// The results show up a moment after the name: wait for them (2026-11-06, Brain task #885).
    func openApp(_ name: String) async throws -> OpenResult {
        guard !name.isEmpty else { throw DeviceError(message: "open needs an app name") }
        let opener = AppOpener(home: { [self] in
            if (try? await device.send("homescreen")) == nil { try await key("cmd+h") }
        }, key: { [self] in try await key($0) }, type: { [self] in _ = try await type($0) }, look: { [weak self] in
            guard let screen = self?.screen, screen.live else { return nil }
            await screen.settled(quiet: 0.5, least: 1.0, most: 3.0)
            return screen.frame
        }, read: { jpeg in
            guard let image = Vision.image(jpeg) else { return [] }
            // Chinese names need zh-Hans named (the automatic pick drops small ones), the device's language too
            let languages = UITreeOCR.languages(for: name)
            return await UITreeOCR.lines(image, languages: languages, whole: true).map(\.text)  // "App Store" stays one
        }, ownAppInFront: { [weak self] in self?.ownAppInFront?() ?? false }, paste: nil,
           searchButton: { [weak self] in try await self?.tapSearchButton() ?? false })  // no clipboard: pasting into Spotlight asks for permission, a box the board can rarely reach (Henry 2026-11-12)
        let result = try await opener.open(name)
        log("open \(name): \(result.rawValue)")
        return result
    }

    /// Park the pointer on the home bar ahead of a departure, so the flick starts the moment it is asked for.
    func aimHomeBar() async throws { try await point(0.5, 0.995) }

    /// A real home-bar flick, independent of consumer-key and keyboard acknowledgements.
    /// `full`: the board's top speed even with the gentle setting (a second try after a flick that did not take).
    func homeSwipe(full: Bool = false) async throws {
        defer { pos = nil }  // edge clamping or a cancelled stroke invalidates the tracked position
        try Task.checkCancellation()
        try await point(0.5, 0.995)
        // Push past the bottom edge, where the pointer stops: the calibration fit is weakest at the edges and
        // left it above the home bar on an iPhone 17 Pro Max (2026-11-02).
        guard let span else { return }
        try await device.send("move 0 \(span.h / 10)")
        let speed = (boardPace ?? pace) >= 3 ? " \(Self.gentleHome && !full ? Self.gentleFlickSpeed : Self.flickSpeed)" : ""
        // Firmware 0.2.5: press, move and release in one command. Three commands left a pause before the release,
        // and iOS took the lingering stroke for "show the app switcher" (iddzz 2026-11-12).
        if flickInOne != false {
            do {
                try await device.send("flick 0 \(-Int(Double(span.h) * 0.85))" + speed)
                flickInOne = true
                return
            } catch let error as DeviceError where error.message.contains("unknown command") {
                flickInOne = false  // older firmware: the three-command stroke below
            }
        }
        do {
            try await device.send("press")
            // to the middle only (0.45) left the app card half-way (2026-10-19). At the board's top speed per report
            // (40, firmware pace 3): at the default 10 the stroke took 1.2 s (2026-11-11); a flick is fast anyway
            // 2026-11-11 Henry: the top-speed flick at a run's start is too abrupt; gentle by default
            try await device.send("move 0 \(-Int(Double(span.h) * 0.85))" + speed)
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

    private func dx(_ x: Double) -> Int { Int(((min(max(fix(x, "x"), 0), 1) - origin.x) * Double(span!.w)).rounded(.toNearestOrEven)) }
    private func dy(_ y: Double) -> Int { Int(((min(max(fix(y, "y"), 0), 1) - origin.y) * Double(span!.h)).rounded(.toNearestOrEven)) }
}

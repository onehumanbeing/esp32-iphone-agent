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
    static let longPress = 1.0             // s held for a long press (iOS opens the menu at ~0.5 s)
    static let hold = 0.35                  // s to rest before lifting, so iOS adds no momentum
    static let tapGap = 0.15                // s to stay still after a click, so iOS sees a finished tap
    static let nudge = 12                   // mouse units the pointer is wiggled by to find it on screen
    static let aimTolerance = 0.008         // screen fraction; a bigger miss is corrected before pressing
    static let maxMiss = 0.06               // bigger misses are still corrected, but not learned from
    static let rehomeOff = 0.03             // a tap that changed nothing and landed this far off re-homes first
    static let agree = 0.02                 // a far reading is taken again; both must agree this closely
    static let sameSpot = 0.03              // a far reading this close to the last far one, for targets
    static let apart = 0.1                  // this far apart, is something moving by itself, not the pointer
    static let watch = 0.3                  // s the screen is watched before a nudge, for what moves by itself
    static let flickSpeed = 40              // the home flick's speed per report: the firmware's top (`move dx dy speed`)
    static let gentleFlickSpeed = 20        // Settings > Gentle Home swipe (default): half that, still a flick
    static let gentleHomeKey = "gentleHomeSwipe"
    static var gentleHome: Bool { UserDefaults.standard.object(forKey: gentleHomeKey) as? Bool ?? true }
    static let offTopEdge = 150             // mouse units the pointer steps down before homing on an iPad
    /// The iPadOS pointer, unlike AssistiveTouch on iPhone: a pointer resting at the top edge that keeps pushing
    /// up opens Notification Center (it looks like the Lock Screen), while a home flick arriving from lower down
    /// does not; and it accelerates by overall speed, so a diagonal step goes ~27% further per unit on each axis
    /// than a straight one (probe fits missed by 2-3%). So on iPad: step off the top edge before homing, and move
    /// one axis at a time (drags keep their path). iPad Air M3, 2026-10-27: probe fit residual 2.4% -> 0.03%.
    static var iPadPointer: Bool { DeviceKind.isPad }

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
        var geometry: ScreenGeometry?  // iPad: orientation and shape it was made in
    }
    static let speed = 10.0  // the board's speed per report (STEP), the probes' and every long move's

    let device: HIDDevice
    weak var screen: ScreenSource?
    /// Where the calibration is kept. iPad: one file per orientation (`adopt`), named after `baseFile`.
    private var file: URL
    private let baseFile: URL
    @Published private(set) var calibratedSpan: Span?  // mouse units needed to cross the full screen width / height
    /// `calibratedSpan` for the screen as it is now. iPhone: an app in landscape (a game) turns the pointer's axes
    /// with it, so the long side is the width: the calibration's sides swap. Calibrated in portrait, a target at x 0.87
    /// of Kingdom Rush landed at x 0.35, on a locked mode button (2026-11-26). iPad keeps one per orientation (`adopt`).
    var span: Span? {
        guard let s = calibratedSpan else { return nil }
        guard !Self.iPadPointer, let aspect = screen?.aspect, aspect.isFinite, aspect > 0 else { return s }
        return Self.turned(s, landscape: aspect > 1)
    }

    /// The screen is turned from the calibration (iPhone, a landscape app): its corner offset is for the other
    /// orientation, so it is left out, and landings go to their own table (`key`).
    var turnedNow: Bool { calibratedSpan != nil && span != calibratedSpan }

    /// The sides of `s` for a landscape or portrait screen (the long side across a landscape one).
    nonisolated static func turned(_ s: Span, landscape: Bool) -> Span {
        (s.w > s.h) == landscape || s.w == s.h ? s : Span(w: s.h, h: s.w)
    }
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
    private var wiggle: (after: Data, back: Double, shift: Double, quiet: [CGRect], reach: CGPoint)?
    private var link = 0  // device.links when the pointer was last homed
    /// where the pointer really landed (seen on screen) for the fraction we aimed at, per axis; a line fit
    /// through them corrects every later move, so taps get better as the agent works
    private(set) var seen: [String: [(Double, Double)]] = ["x": [], "y": []]
    @Published private(set) var quality: Double?  // pointer error at the last check, fraction of the screen
    private(set) var aspect: Double?  // frame width / height when calibrated
    /// iPad: the screen's orientation and the mirrored shape when calibrated (nil on iPhone). Rotated, the mouse
    /// axes meet other screen edges: the calibration no longer holds.
    private(set) var geometry: ScreenGeometry?
    var currentGeometry: () -> ScreenGeometry? = { nil }
    private(set) var pace = 1  // the board's move pacing ("pace") when calibrated; 1 = firmware before it answered
    /// The connected board's pacing; a calibration made under another one no longer fits (iOS accelerates by speed).
    @Published var boardPace: Int?
    /// The board takes `flick` (firmware 0.2.5); nil until tried, reset by a new board connection.
    var flickInOne: Bool?
    var log: (String) -> Void = { print($0) }
    /// This app is in front (it must not be: open checks the app it opened is not this one).
    var ownAppInFront: (() -> Bool)?
    /// Opens an app by its URL scheme while this app is in front (AppModel.openByScheme); false = the old way.
    var openByScheme: ((String) async -> Bool)?
    /// A call run: Live Captions and Live Speech stay on screen in every app, so "the app's words are still there"
    /// says nothing about Home. goHome then flicks only when the key changed nothing, and once (2026-11-14: the
    /// extra flicks collapsed the captions panel and opened the App Switcher mid-call).
    var overlayStays = false
    /// Puts text on the clipboard (ClipboardHop), for app names the board cannot type (AppOpener.paste).
    var clipboard: ((String) async throws -> Bool)?
    /// The device screen's width / height (iPhone or iPad), stored with a calibration.
    var screenAspect: () -> Double = { 9 / 19.5 }
    /// Last-resort pointer finder on a frame (the vision model), when the pixel diff finds nothing.
    var locate: ((Data) async -> CGPoint?)?

    init(device: HIDDevice, calibrationFile: URL, screen: ScreenSource? = nil) {
        self.device = device
        self.file = calibrationFile
        self.baseFile = calibrationFile
        self.screen = screen
        if let data = try? Data(contentsOf: calibrationFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            load(saved)
        }
    }

    private func load(_ saved: Saved) {
        calibratedSpan = Span(w: saved.w, h: saved.h)
        (quality, aspect, pace, geometry) = (saved.quality, saved.aspect, saved.pace ?? 1, saved.geometry)
        origin = CGPoint(x: saved.ox ?? 0, y: saved.oy ?? 0)
        gain = (saved.gain ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }
        for axis in ["x", "y", "lx", "ly"] where saved.v == Self.samplesVersion {
            seen[axis] = (saved.seen?[axis] ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }.suffix(12)
        }
    }

    /// The calibration as saved (nil when there is none), so a rejected calibration can put it back (`restore`).
    func snapshot() -> Data? { try? Data(contentsOf: file) }

    /// Back to a `snapshot`: the previous calibration, or none (issue #96: a ±49.8% check was kept and used).
    func restore(_ snapshot: Data?) {
        (calibratedSpan, quality, aspect, pace, origin, gain, geometry) = (nil, nil, nil, 1, .zero, [], nil)
        (seen, pos) = (["x": [], "y": []], nil)
        if let snapshot, let saved = try? JSONDecoder().decode(Saved.self, from: snapshot) {
            load(saved)
            try? snapshot.write(to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The board is an absolute mouse (flash.sh --abs): X/Y are screen fractions, so no homing, calibration or aiming.
    @Published var absolute = false
    /// A Bluetooth HID board: iOS ignores its Home key, so Home is the swipe up from the home bar.
    var swipeHome = false
    /// iPad with a Bluetooth HID board: how many reports `home` pushes up (HomeTuning), nil for the board's own.
    var homeUp: (() -> Int?)?
    /// Above the tracked position when going up the measured way (homeFromKnown): covers drift, a short push only.
    static let topMarginShare = 0.04
    static let absoluteSpan = Span(w: Int(32767), h: Int(32767))
    /// Per report for a flick (home, back): ~0.1 s for the whole stroke. The board's default glide is for lists.
    static let flickStep = 2000
    /// A list drag (`hold`): the finger starts slowly, then glides a little slower than the firmware's own pace (245),
    /// and rests before lifting. 2026-11-17: fast drags jerked the page (a header pulled down a lot) and stopped at
    /// a different place each time. `easeShare` of the first segment goes at `easeStep`.
    static let dragStep = 160, easeStep = 90, easeShare = 0.2
    /// Relative mouse: where the drag's moves end (shares of the stroke), each shorter than the last, so it slows to a
    /// stop; then `stillReports` pairs of one-unit moves over `hold`.
    static let relativeEase = [0.7, 0.9, 1.0], stillReports = 4

    var calibrated: Bool { absolute || span != nil && (boardPace ?? pace) == pace }

    /// iPad: the screen turned. Each orientation keeps its own calibration (calibration-portrait.json,
    /// calibration-landscape.json): load the one for `current` if there is one, so turning back and forth calibrates
    /// once per orientation, not after every turn. Nothing to do on iPhone, or while the calibration matches.
    func adopt(_ current: ScreenGeometry?) {
        guard Self.iPadPointer, let current, !matches(geometry: current) else { return }
        let target = Self.file(for: current, base: baseFile)
        guard target != file || calibrated else { return }  // this orientation has none: nothing to load again
        file = target
        (calibratedSpan, quality, aspect, pace, origin, gain, geometry) = (nil, nil, nil, 1, .zero, [], nil)
        (seen, pos) = (["x": [], "y": []], nil)
        if let data = try? Data(contentsOf: target), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            load(saved)
            log("calibration: \(current.landscape ? "landscape" : "portrait") calibration loaded"
                + (matches(geometry: current) ? "" : ", but for another mirrored shape"))
        } else {
            log("calibration: none yet for \(current.landscape ? "landscape" : "portrait")")
        }
    }

    /// iPad: the orientation's own file beside `base`.
    static func file(for geometry: ScreenGeometry, base: URL) -> URL {
        let name = base.deletingPathExtension().lastPathComponent + (geometry.landscape ? "-landscape" : "-portrait")
        return base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(base.pathExtension)
    }

    /// iPad: the calibration was made in this orientation and shape. False without a current geometry.
    func matches(geometry current: ScreenGeometry?) -> Bool {
        guard let current else { return false }
        return geometry?.matches(current) == true
    }

    /// The landings of a turned screen (a landscape app on an iPhone calibrated in portrait) have their own table,
    /// "lx"/"ly": its axes and corner differ, so mixing them in would bend portrait taps, and leaving them out kept a
    /// steady 3-4% x miss in Kingdom Rush uncorrected (2026-11-26).
    private func key(_ axis: String) -> String { turnedNow ? "l" + axis : axis }

    private func remember(_ axis: String, _ sample: (Double, Double)) {
        seen[axis] = Array((seen[axis, default: []] + [sample]).suffix(12))  // deque(maxlen=12)
    }

    /// Find the pointer on screen at two known distances from the corner and fit the mapping from both.
    /// Returns true when it calibrated itself; otherwise the user taps the pointer (finishCalibration).
    /// `progress` gets 0 (homing), then 1, 2 (each probe).
    func startCalibration(progress: ((Int) -> Void)? = nil) async throws -> Bool {
        let started = currentGeometry()
        if Self.iPadPointer && started == nil { throw DeviceError(message: "No mirrored screen yet. Try again in a moment.") }
        pos = nil
        progress?(0)
        try await home(from: nil)
        var found: [(Int, Double, Double)] = []
        for (i, units) in Self.calibrationStops.enumerated() {
            try checkRotation(since: started)
            progress?(i + 1)
            let step = units - (found.last?.0 ?? 0)
            try await travel(step, step, paced: false)
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
                try await home(from: nil)
                try await travel(Self.calibrationMove, Self.calibrationMove, paced: false)
            }
            return false
        }
        try checkRotation(since: started)
        calibratedSpan = s
        // the corner the board homes to is not exactly (0, 0): fit that offset from the same two stops. Keeping an
        // older one (a touch probe's 0.142) while the samples left it out made `fix` learn a -7% x shift: every tap
        // landed left of its target after a mid-run recalibration (2026-11-11 Maps run).
        let (u1, x1, y1) = found[0]
        origin = CGPoint(x: x1 - Double(u1) / Double(s.w), y: y1 - Double(u1) / Double(s.h))
        if abs(origin.x) > 0.2 || abs(origin.y) > 0.2 { origin = .zero }  // not a corner: fall back to none
        (quality, aspect, geometry) = (nil, screenAspect(), started)  // the speed gain (applySpeeds) still holds
        seen = ["x": [], "y": []]
        for (units, x, y) in found {  // where each stop landed, in the same terms as dx/dy aim
            remember("x", (Double(units) / Double(s.w) + origin.x, x))
            remember("y", (Double(units) / Double(s.h) + origin.y, y))
        }
        save()
        log(String(format: "calibration: span %d x %d, offset %.3f / %.3f", s.w, s.h, origin.x, origin.y))
        return true
    }

    /// iPad: the screen rotated since `started` (a calibration in progress would mix two orientations).
    private func checkRotation(since started: ScreenGeometry?) throws {
        guard let started, !started.matches(currentGeometry()) else { return }
        throw DeviceError(message: String(localized: "The screen rotated during calibration. Try again."))
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
        guard 0.03 < p.x && p.x < 0.97 && 0.03 < p.y && p.y < 0.97 else { return nil }
        guard let geometry = currentGeometry() else { return p }  // iPhone: the frame is the screen
        return geometry.contains(framePoint: p) ? geometry.screenPoint(fromFrame: p) : nil
    }

    /// x, y: where the pointer ended up `move` units from home (one point, picked by the user). Assumes home is at
    /// (0, 0); the manual calibration fits the offset too when the board's own check click arrives.
    func finishCalibration(x: Double, y: Double, move: Int = Pointer.calibrationMove) {
        (quality, aspect, pace, origin, gain) = (nil, screenAspect(), boardPace ?? pace, .zero, [])
        geometry = currentGeometry()
        guard let s = Span(w: Double(move) / x, h: Double(move) / y) else {
            log(String(format: "calibration: tap at (%.3f, %.3f) gives no usable span", x, y))
            return
        }
        calibratedSpan = s
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
        calibratedSpan = s
        (quality, aspect, pace) = (max(x.rms, y.rms), screenAspect(), boardPace ?? pace)
        (origin, gain, geometry) = (CGPoint(x: x.b, y: y.b), [], currentGeometry())
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
        if Self.iPadPointer, let geometry { file = Self.file(for: geometry, base: baseFile) }
        let saved = Saved(w: span.w, h: span.h, seen: seen.mapValues { $0.map { [$0.0, $0.1] } }, quality: quality,
                          aspect: aspect, v: Self.samplesVersion, pace: pace, ox: origin.x, oy: origin.y,
                          gain: gain.map { [$0.0, $0.1] }, geometry: geometry)
        try? JSONEncoder().encode(saved).write(to: file)
    }

    func point(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        guard calibrated else { throw DeviceError(message: "pointer not calibrated") }
        if geometry != nil, !matches(geometry: currentGeometry()) {  // iPad, rotated since the calibration
            throw DeviceError(message: String(localized: "The screen rotated since the pointer was calibrated. Calibrate it again."))
        }
        try await moveTo(dx(x), dy(y))
        if aim && screen != nil && !absolute { try await self.aim(x, y) }
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
            // Looked at again before the click: far again from the corner is the calibration, not the tracked
            // position (2026-11-16: a steady +65 x on one phone, three taps in a row between icons). The second far
            // landing asks Recalibration for a new calibration (within its limits); then the move once more.
            guard let again = try await measureSure(x, y) else { return }
            learn(x, y, again)
            let farAgain = max(abs(Double(again.x) - x), abs(Double(again.y) - y)) > Self.maxMiss
            if recalibration.take() || (farAgain && recalibration.farFromCorner()) {
                try await recalibrate()
                try await moveTo(dx(x), dy(y))
            } else if max(abs(Double(again.x) - x), abs(Double(again.y) - y)) <= Self.maxMiss {
                try await correct(x, y, again, span)  // near from the corner: the usual small fix, once
            }
            return
        }
        try await correct(x, y, found, span)
    }

    /// Moves the pointer by the small miss between where it was found and (x, y).
    private func correct(_ x: Double, _ y: Double, _ found: CGPoint, _ span: Span) async throws {
        let fx = Double(found.x), fy = Double(found.y)
        if abs(fx - x) <= Self.aimTolerance && abs(fy - y) <= Self.aimTolerance { return }
        let mx = Int(((x - fx) * Double(span.w)).rounded(.toNearestOrEven)), my = Int(((y - fy) * Double(span.h)).rounded(.toNearestOrEven))
        let previousPosition = pos
        pos = nil
        try await travel(mx, my)  // fix this miss right away (paced; on iPad one axis at a time)
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
        if far { StepReport.shared.farLanding() }
        guard !far else { return rehome }
        remember(key("x"), (fix(x, "x"), Double(found.x)))
        remember(key("y"), (fix(y, "y"), Double(found.y)))
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
        // Off by more than `rehomeOff` too (Wiki #1007 N4): the retry starts from the corner, the cheap fix for a
        // tracked position that drifted; a calibration that is off shows up as the next far landing (Recalibration).
        if max(abs(Double(found.x) - x), abs(Double(found.y) - y)) > Self.rehomeOff { pos = nil }
        // with the span it moved by: an offset in proportion to the target is a scale (tracking speed), a constant one
        // a lost position
        log(String(format: "landing (%.3f, %.3f): pointer at (%.3f, %.3f), span %d x %d", x, y, found.x, found.y,
                   span?.w ?? 0, span?.h ?? 0))
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
        // iPad: the target is on the screen, the search on the frame (letterboxed, maybe); nil geometry on iPhone
        let geometry = currentGeometry(), rect = geometry?.contentRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let near = geometry?.framePoint(fromScreen: CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y)
        // iPad: about 1.4% of the screen and paced (its calibrated width is ~1700 units, and a short move goes only
        // half as far): 12 units moved the pointer ~2 px of a 720 px search and it was not found (2026-11-10)
        let units = Self.iPadPointer ? max(Self.nudge, Int((Double(span.w) * 0.014).rounded())) : Self.nudge
        let nudge = x < 0.9 ? units : -units  // stay clear of the screen edge
        let sentNudge = Self.iPadPointer ? paced(nudge, 0).0 : nudge
        let started = now()
        wiggle = nil
        // pointer at rest; a screen that never stands still (a game) gives no quiet gap, so the wait is short there:
        // 0.6 s per look on every measure, 23 measures in one run (2026-11-26, Kingdom Rush)
        await screen.settled(quiet: 0.15, least: 0.1, most: StepWaits.moving || StepWaits.alwaysMoving ? 0.2 : 0.6)
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
        try await device.send("move \(sentNudge) 0")
        var after = await screen.fresh(since: sent, timeout: 1.2)
        if after != nil {
            await screen.settled(quiet: 0.1, least: 0.05, most: 0.4)
            after = screen.frame
        }
        let back = now()
        try await device.send("move \(-sentNudge) 0")
        pos = previousPosition
        let shift = Double(nudge) / Double(span.w) * rect.width
        guard let before, let after else {
            log(after == nil ? "pointer: no new frame after the nudge" : "pointer: no frame before the nudge")
            return nil
        }
        let looked = now()
        let reach = CGPoint(x: 0.12 * rect.width, y: 0.08 * rect.height)  // Vision.pointer's default on iPhone
        let (p, quiet) = await Vision.off {
            let quiet = Vision.motion(base, before)
            return (Self.find(before, after, near: near, shift: shift, reach: reach, quiet: quiet), quiet)
        }
        wiggle = (after, back, shift, quiet, reach)
        // where a slow search spends its time (2026-11-07: taps took 9-26 s with seconds between commands)
        log(String(format: "pointer: measure %.1f s (settle %.1f, frames %.1f, search %.1f)%@", now() - started,
                   sent - started, looked - sent, now() - looked, p == nil ? ", not found" : ""))
        guard let found = p != nil ? p : model ? await locate?(before) : nil else { return nil }
        guard let geometry else { return found }
        return geometry.contains(framePoint: found) ? geometry.screenPoint(fromFrame: found) : nil
    }

    /// The pointer in `a`, moved by `shift` (fraction of width) in `b`: near the target, else anywhere.
    /// `reach`: Vision.pointer's default (iPhone), or that much of the content on a letterboxed iPad frame.
    nonisolated private static func find(_ a: Data, _ b: Data, near: CGPoint, shift: Double,
                                         reach: CGPoint = CGPoint(x: 0.12, y: 0.08), quiet: [CGRect]) -> CGPoint? {
        guard let (ga, gb) = Vision.pointerFrames(a, b) else { return nil }
        return Vision.pointer(ga, gb, near: near, shift: shift, reach: reach, quiet: quiet)
            ?? Vision.pointer(ga, gb, near: CGPoint(x: 0.5, y: 0.5), shift: shift, reach: CGPoint(x: 0.5, y: 0.5), quiet: quiet)
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
        // iPad: searched on the frame (maybe letterboxed), answered on the screen, as in measure; iPhone: the same
        let geometry = currentGeometry()
        let near = geometry?.framePoint(fromScreen: CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y)
        let p = await Vision.off { Self.find(w.after, back, near: near, shift: -w.shift, reach: w.reach, quiet: w.quiet) }
        // found where it was after the nudge: where it was before it is one shift to the left
        guard let found = p.map({ CGPoint(x: $0.x - w.shift, y: $0.y) }) else { return nil }
        guard let geometry else { return found }
        return geometry.contains(framePoint: found) ? geometry.screenPoint(fromFrame: found) : nil
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
        calibratedSpan = calibratedSpan ?? Span(w: 400, h: 860)
        geometry = currentGeometry()
        self.quality = quality
    }

    /// The fraction to aim at so the pointer lands on t, from the line through the observed landings.
    func fix(_ t: Double, _ axis: String) -> Double {
        if absolute { return t }
        let pts = seen[key(axis)] ?? []
        guard pts.count >= 2 else { return t }
        let n = Double(pts.count)
        let mc = pts.map(\.0).reduce(0, +) / n, mf = pts.map(\.1).reduce(0, +) / n
        let variance = pts.map { pow($0.0 - mc, 2) }.reduce(0, +)
        var a = variance > 1e-4 ? pts.map { ($0.0 - mc) * ($0.1 - mf) }.reduce(0, +) / variance : 1.0  // landed = a*aimed + b
        a = 0.85 < a && a < 1.15 ? a : 1.0
        let b = mf - a * mc
        return abs(b) < 0.1 ? (t - b) / a : t
    }

    private func moveTo(_ tx: Int, _ ty: Int, rehome: Bool = true, flick: Bool = false, step: Int? = nil,
                        held: Bool = false) async throws {
        if link != device.links {  // new link: a dropped gesture may have left the button down
            try await device.send("release")
            (pos, link) = (nil, device.links)
        }
        if absolute {
            do {
                let pace = flick ? Self.flickStep : step
                try await device.send(pace.map { "abs \(tx) \(ty) \($0)" } ?? "abs \(tx) \(ty)")
            } catch let error as DeviceError where error.message.hasPrefix("err unknown") {
                absolute = false  // flashed back to the relative mouse: calibrate as before
                log("pointer: the board has no absolute mouse any more")
                throw error
            }
            pos = (tx, ty)
            return
        }
        if pos == nil || (rehome && moves >= Self.rehomeEvery) {
            let at = pos
            pos = nil
            try await home(from: at)
            (pos, moves) = ((0, 0), 0)
        }
        let (x, y) = pos!
        pos = nil  // unknown until the move succeeds
        try await travel(tx - x, ty - y, held: held)
        (pos, moves) = ((tx, ty), moves + 1)
    }

    /// The tracked position is not trusted any more: the next move starts from the corner. A run's start does this
    /// (Wiki #1007 N4: the position left by the last run or by the user's own touches is a guess).
    func forgetPosition() { pos = nil }

    /// Slam the pointer into the top-left corner from `at` (nil: unknown). iPad: step off the top edge first when it
    /// may rest there, or iPadOS opens Notification Center. Callers track `pos`. `measured`: with a known position, a
    /// Bluetooth iPad may go up the measured way instead (calibration probes need the real corner: false).
    private func home(from at: (Int, Int)?, measured: Bool = true) async throws {
        if Self.iPadPointer, let up = homeUp?() {
            // Bluetooth on iPad: a long push up at the top edge opens Notification Center (HomeTuning). Known
            // position: left edge only, then up the measured way plus a margin, which pushes only briefly.
            if measured, let at, let span, at.1 >= 0 {
                try await device.send("home \(HomeTuning.gap) 0")
                try await travel(0, -(at.1 + max(12, Int(Double(span.h) * Self.topMarginShare))))
                return
            }
            if (at?.1 ?? 0) < Self.offTopEdge { try await device.send("move 0 \(Self.offTopEdge)") }
            try await device.send("home \(HomeTuning.gap) \(up)")
            return
        }
        if Self.iPadPointer && (at?.1 ?? 0) < Self.offTopEdge {
            try await device.send("move 0 \(Self.offTopEdge)")
        }
        try await device.send("home")
    }

    /// Move by (dx, dy) mouse units, paced (see `paced`). iPad: one axis at a time, vertical first (off the top
    /// edge), each paced on its own, unless the button is held, where the path is the gesture.
    private func travel(_ dx: Int, _ dy: Int, held: Bool = false, paced pace: Bool = true) async throws {
        if Self.iPadPointer && !held && dx != 0 && dy != 0 {
            let (_, py) = pace ? paced(0, dy) : (0, dy), (px, _) = pace ? paced(dx, 0) : (dx, 0)
            try await device.send("move 0 \(py)")
            try await device.send("move \(px) 0")
        } else {
            let (mx, my) = pace ? paced(dx, dy) : (dx, dy)
            try await device.send("move \(mx) \(my)")
        }
    }

    /// A calibration probe's move from home (TouchCalibration): the pointer is homed and moved by (ux, uy) mouse
    /// units, unpaced, then `then` (another raw move) if given. iPhone: exactly `home`, `move ux uy`. iPad: the
    /// agent's own way (off the top edge, one axis at a time), so the fit is for the moves the agent makes.
    func probe(_ ux: Int, _ uy: Int, then: (dx: Int, dy: Int, speed: Int?)? = nil) async throws {
        guard Self.iPadPointer else {
            try await device.send("home")
            try await device.send("move \(ux) \(uy)")
            if let then { try await device.send("move \(then.dx) \(then.dy)" + (then.speed.map { " \($0)" } ?? "")) }
            return
        }
        let at = pos
        pos = nil
        try await home(from: at, measured: false)
        try await travel(ux, uy, paced: false)
        if let then {
            // one axis per move here too (the speed probes go along x on iPad: AutoCalibrator.calibrateSpeeds)
            let speed = then.speed.map { " \($0)" } ?? ""
            if then.dy != 0 { try await device.send("move 0 \(then.dy)" + speed) }
            if then.dx != 0 || then.dy == 0 { try await device.send("move \(then.dx) 0" + speed) }
        }
    }

    /// Let go of the button and re-home the pointer, whatever state a gesture left.
    func reset() async throws {
        let at = pos
        pos = nil
        try await device.send("release")
        if absolute { return }
        try await home(from: at)
        (pos, moves) = ((0, 0), 0)
    }

    /// Manual calibration: from home to (move, move), where the user then taps the pointer.
    func parkForManualCalibration(move: Int = Pointer.calibrationMove) async throws {
        try await reset()
        guard Self.iPadPointer else { return _ = try await device.send("move \(move) \(move)") }
        pos = nil
        try await travel(move, move, paced: false)
    }

    /// aim: find the pointer on screen first (slower); worth it when a tap just missed.
    /// Where the last tap went (fractions): the text field a type goes into, for its quick read back.
    var lastTapAt: CGPoint?

    func tap(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        lastTapAt = CGPoint(x: x, y: y)
        if recalibration.tap() { try await recalibrate() }
        let from = pos  // where the tracked pointer was, for a tap that set off something else (another app in front)
        try await point(x, y, aim: aim)
        log(String(format: "tap (%.3f, %.3f): pointer from %@ to %@", x, y, from.map { "\($0.0) \($0.1)" } ?? "unknown",
                   pos.map { "\($0.0) \($0.1)" } ?? "unknown"))
        try await device.send("click")
        try await Task.sleep(nanoseconds: UInt64(Self.tapGap * 1e9))
    }

    func clickAgain() async throws {
        log("tap again: one more click where the pointer is")
        try await device.send("click")
        try await Task.sleep(nanoseconds: UInt64(Self.tapGap * 1e9))
    }

    func longPress(_ x: Double, _ y: Double) async throws {
        lastTapAt = CGPoint(x: x, y: y)
        try await point(x, y)
        log(String(format: "long press (%.3f, %.3f)", x, y))
        try await device.send("press")
        do { try await Task.sleep(nanoseconds: UInt64(Self.longPress * 1e9)) } catch {
            _ = try? await device.send("release")
            throw error
        }
        try await device.send("release")
        try await Task.sleep(nanoseconds: UInt64(Self.tapGap * 1e9))
    }

    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool = true) async throws {
        try await drag([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], hold: hold)
    }

    func pressDrag(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) async throws {
        log(String(format: "press and drag (%.3f, %.3f) to (%.3f, %.3f)", x1, y1, x2, y2))
        try await drag([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], hold: true, still: Self.longPress * 0.8)
    }

    func switchApp() async throws { try await switchToPreviousApp() }

    /// Press at the first point, move through the rest, release: one continuous stroke. hold rests at the end
    /// first, so lists and pickers stop exactly there; system gestures (home, back) need the flick.
    func drag(_ points: [CGPoint], hold: Bool = true) async throws { try await drag(points, hold: hold, still: 0) }

    /// still: seconds to stand still after the press, before moving (a press and drag).
    func drag(_ points: [CGPoint], hold: Bool, still: Double) async throws {
        try await point(Double(points[0].x), Double(points[0].y))
        do {
            try await device.send("press")
            if still > 0 { try await Task.sleep(nanoseconds: UInt64(still * 1e9)) }
            var from = points[0]
            for (i, p) in points.dropFirst().enumerated() {
                if hold && absolute && i == 0 {  // ease in: the first part slowly, so the page follows without a jerk
                    let e = CGPoint(x: from.x + (p.x - from.x) * Self.easeShare, y: from.y + (p.y - from.y) * Self.easeShare)
                    try await moveTo(dx(Double(e.x)), dy(Double(e.y)), rehome: false, step: Self.easeStep, held: true)
                }
                if hold && absolute && points.count == 2 {  // ease out too: the last part slowly, so the list stops
                    // where the finger stops (Henry 2026-11-18: scrolls ran on past their end)
                    let e = CGPoint(x: from.x + (p.x - from.x) * (1 - Self.easeShare), y: from.y + (p.y - from.y) * (1 - Self.easeShare))
                    try await moveTo(dx(Double(e.x)), dy(Double(e.y)), rehome: false, step: Self.dragStep, held: true)
                    try await moveTo(dx(Double(p.x)), dy(Double(p.y)), rehome: false, step: Self.easeStep, held: true)
                    from = p
                    continue
                }
                if hold && !absolute && points.count == 2 {  // relative mouse: slow down over the last part, in steps
                    for share in Self.relativeEase {
                        let e = CGPoint(x: from.x + (p.x - from.x) * share, y: from.y + (p.y - from.y) * share)
                        try await moveTo(dx(Double(e.x)), dy(Double(e.y)), rehome: false, held: true)
                    }
                    from = p
                    continue
                }
                try await moveTo(dx(Double(p.x)), dy(Double(p.y)), rehome: false, flick: !hold,  // never home mid-drag
                                 step: hold && points.count == 2 ? Self.dragStep : nil, held: true)
                from = p
            }
            if hold && !absolute { try await restStill() } else if hold { try await Task.sleep(nanoseconds: UInt64(Self.hold * 1e9)) }
        } catch {
            _ = try? await device.send("release")
            throw error
        }
        try await device.send("release")
    }

    /// The rest before lifting, for the relative mouse: a mouse at rest sends no reports, so iOS keeps the drag's last
    /// speed and the list glides on after the lift (2026-11-18: 11 of 20 swipes moved the page 2-4.8 times their
    /// length). One-unit moves there and back tell it the finger stands still.
    /// Bounded by time, at least one pair: each move waits for the board's answer, and 4 pairs took 1.8 s instead of
    /// `hold` (2026-11-19, 14 swipes of one run).
    private func restStill() async throws {
        let gap = Self.hold / Double(Self.stillReports * 2)
        let deadline = Date().addingTimeInterval(Self.hold * 2)
        for pair in 0..<Self.stillReports {
            if pair > 0, Date() >= deadline { break }
            try await device.send("move 0 1")
            try await Task.sleep(nanoseconds: UInt64(gap * 1e9))
            try await device.send("move 0 -1")
            try await Task.sleep(nanoseconds: UInt64(gap * 1e9))
        }
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
        // this app in front: its scheme goes straight there; in the background iOS opens no URL, so Spotlight
        if ownAppInFront?() == true, let openByScheme, await openByScheme(name) {
            log("open \(name): opened by scheme")
            return .opened
        }
        var opener = AppOpener(home: { [self] in
            let before = screen?.live == true ? screen?.frame : nil
            // USB: the board's Home key works; over Bluetooth it answers an error, and cmd+h with an app in front did
            // nothing six times out of six (Settings, Weather; 2026-11-26), each a 3 s wait before the flick anyway.
            // So over Bluetooth: on the Home Screen nothing to do, else the flick at once.
            let keyWorks = (try? await device.send("homescreen")) != nil
            guard let screen, let before else {
                if !keyWorks { try await key("cmd+h") }
                return
            }
            if keyWorks {
                await screen.settled(quiet: 0.2, least: 0.4, most: 1.0)
                let after = screen.frame
                guard await !Vision.off({ Vision.bigChange(before, after) }), await Self.keyMissed(before, after) else { return }
                log("open: the Home key left the app in front; flicking up from the home bar")
            } else {
                if await Self.onHomeScreen(before) { return }
                log("open: an app in front; flicking up from the home bar")
            }
            var sent = now()
            try await homeSwipe()
            // a big change in the first frames: left (no text read). The first flick often only woke the pointer
            // (2026-11-26: Settings stayed): once more at full speed while the same app is in front
            if let first = await screen.fresh(since: sent, timeout: 1.0), await Vision.off({ Vision.bigChange(before, first) }) { return }
            await screen.settled(quiet: 0.2, least: 0.4, most: 1.0)
            guard await Self.sameApp(before, screen.frame) else { return }
            log("open: the flick left the app in front; once more at full speed")
            sent = now()
            try await homeSwipe(full: true)
            _ = await screen.fresh(since: sent, timeout: 1.0)
        }, key: { [self] in try await key($0) }, type: { [self] query in
            // letters straight to the board: the keyboard check before them read the screen twice, 5.3 s for
            // "rednote" (2026-11-26), and the opener handles letters left composing on the pinyin keyboard itself
            if query.allSatisfy(\.isASCII) { _ = try await device.send("type \(query)") } else { _ = try await type(query) }
        }, look: { [weak self] in
            guard let screen = self?.screen, screen.live else { return nil }
            await screen.settled(quiet: 0.5, least: 1.0, most: 3.0)
            return screen.frame
        }, read: { jpeg in
            guard let image = Vision.image(jpeg) else { return [] }
            // Chinese names need zh-Hans named (the automatic pick drops small ones), the device's language too
            let languages = UITreeOCR.languages(for: name)
            return await UITreeOCR.lines(image, languages: languages, whole: true).map(\.text)  // "App Store" stays one
        }, ownAppInFront: { [weak self] in self?.ownAppInFront?() ?? false }, paste: nil,
           searchButton: { [weak self] in try await self?.tapSearchButton() ?? false },  // no clipboard: pasting into Spotlight asks for permission, a box the board can rarely reach (Henry 2026-11-12)
           readBoxes: { jpeg in
            guard let image = Vision.image(jpeg) else { return ([], .zero) }
            let lines = await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: name), whole: true)
            return (lines, CGSize(width: image.width, height: image.height))
        }, tapAt: { [self] p in try await tap(p.x, p.y, aim: true) })
        opener.glance = { [weak self] in self?.screen?.live == true ? self?.screen?.frame : nil }
        opener.freshAfter = { [weak self] delay in
            guard let self, let screen, screen.live else { return nil }
            return await screen.fresh(since: now() + delay, timeout: delay + 1.5)
        }
        let result = try await opener.open(name)
        log("open \(name): \(result.rawValue)")
        return result
    }

    /// Henry 2026-11-13: back to the app the user left for this one (a task from the quick sheet works there):
    /// a flick to the right along the home bar, iOS's switch to the previous app. Needs firmware 0.2.5's `flick`.
    func switchToPreviousApp() async throws {
        defer { pos = nil }
        if absolute {
            try await point(0.2, 0.999)
            do {
                try await device.send("press")
                try await moveTo(dx(0.8), dy(0.999), rehome: false, flick: true)
            } catch {
                _ = try? await device.send("release")
                throw error
            }
            try await device.send("release")
            return
        }
        try await point(0.2, 0.995)
        guard let span else { return }
        try await device.send("move 0 \(span.h / 10)")
        try await device.send("flick \(Int(Double(span.w) * 0.6)) 0 \(Self.flickSpeed)")
    }

    /// Park the pointer on the home bar ahead of a departure, so the flick starts the moment it is asked for.
    func aimHomeBar() async throws { try await point(0.5, 0.995) }

    /// A real home-bar flick, independent of consumer-key and keyboard acknowledgements.
    /// `full`: the board's top speed even with the gentle setting (a second try after a flick that did not take).
    func homeSwipe(full: Bool = false) async throws {
        defer { pos = nil }  // edge clamping or a cancelled stroke invalidates the tracked position
        try Task.checkCancellation()
        try await point(0.5, absolute ? 0.999 : 0.995)
        if absolute {
            do {
                try await device.send("press")
                try await moveTo(dx(0.5), dy(0.15), rehome: false, flick: true)
            } catch {
                _ = try? await device.send("release")
                throw error
            }
            try await device.send("release")
            return
        }
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

    private func dx(_ x: Double) -> Int {
        if absolute { return Int((min(max(x, 0), 1) * Double(Self.absoluteSpan.w)).rounded(.toNearestOrEven)) }
        return Int(((min(max(fix(x, "x"), 0), 1) - (turnedNow ? 0 : origin.x)) * Double(span!.w)).rounded(.toNearestOrEven))
    }
    private func dy(_ y: Double) -> Int {
        if absolute { return Int((min(max(y, 0), 1) * Double(Self.absoluteSpan.h)).rounded(.toNearestOrEven)) }
        return Int(((min(max(fix(y, "y"), 0), 1) - (turnedNow ? 0 : origin.y)) * Double(span!.h)).rounded(.toNearestOrEven))
    }
}

/// iPad with a Bluetooth HID board: how many reports `home` pushes up, learned per model and orientation.
/// BLE takes a report about every 14 ms, so the pushes add up: too many and the pointer keeps pushing at the top
/// edge until iPadOS opens Notification Center (with an app in front); too few and it stops short of the top, and
/// every move measured from home is off. iPad Air M3, landscape, 2026-11-20: 5 reach the top from the bottom edge,
/// 18 did not open it, 25 did. Other models, orientations and pointer speeds move both limits, so calibration
/// adjusts it (AutoCalibrator): fewer after the panel came down, more when the probe fit puts home below the top.
enum HomeTuning {
    static let gap = 4                    // ms between reports; the link sets the real pace
    static let start = 10, least = 4, most = 30, step = 3
    static let shortOffset = 0.015        // the fit's y at 0 units: home this far below the top fell short

    enum Miss: Error, Equatable {
        case panel                        // the app left the front during homing: a system panel came down
        case short(Double)                // the probe fit's home point, this far below the top
    }

    static func key(landscape: Bool, model: String = DeviceInfo.model) -> String {
        "homeUp.\(model).\(landscape ? "landscape" : "portrait")"
    }

    static func value(landscape: Bool, defaults: UserDefaults = .standard) -> Int {
        let n = defaults.integer(forKey: key(landscape: landscape))
        return n == 0 ? start : min(max(n, least), most)
    }

    /// The count to try after a miss; nil when it is already at its bound that way.
    static func next(after miss: Miss, from n: Int) -> Int? {
        switch miss {
        case .panel: return n > least ? max(least, n - max(step, n / 3)) : nil  // 25 -> 17 -> 12: quickly into the safe range
        case .short: return n < most ? min(most, n + max(step, n / 3)) : nil
        }
    }

    static func store(_ n: Int, landscape: Bool, defaults: UserDefaults = .standard) {
        defaults.set(n, forKey: key(landscape: landscape))
    }
}

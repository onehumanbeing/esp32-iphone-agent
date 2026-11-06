import UIKit

/// Touch-probe calibration, like levelling a 3D printer bed: home the pointer, click at known mouse
/// distances and catch where each click lands on this app's own screen. Stage 1 clicks twice on the
/// diagonal for a rough fit; stage 2 clicks near the four corners (25% / 75%) and the centre, all from home,
/// and fits mouse units → screen fraction per axis by least squares; then the same short move at several speeds
/// (iOS accelerates by speed: a correction is slower than the probes and falls short); stage 3 taps a check point.
extension AutoCalibrator {
    enum TouchResult { case done(Double), noTaps, failed(String) }

    static let roughStops = [150, 350]
    static let targets: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75)]
    static let check = (x: 0.5, y: 0.62)
    static let tapTimeout = 3.0
    static let speeds = [2, 4, 6]  // per report; the board's full speed (10) is the reference
    static let speedMove = 80      // units, diagonally, from a point near the centre

    func touchCalibrate(full: Bool) async throws -> TouchResult {
        let probe = app.probe, device = app.board.commands, pointer = app.pointer
        var total = full ? Self.roughStops.count + Self.targets.count + 1 : 1
        var clicks = 0, hits = 0
        phase = .homing
        try await pointer.reset()

        /// Home, move by (ux, uy), click and wait for the tap. Every probe starts from home, like the agent's moves.
        /// then: one more move first (the speed probes).
        func click(_ ux: Int, _ uy: Int, then: String? = nil) async throws -> CGPoint? {
            try await device.send("home")
            try await device.send("move \(ux) \(uy)")
            if let then { try await device.send(then) }
            let sent = now()
            try await device.send("click")
            let p = await probe.tap(since: sent, timeout: Self.tapTimeout)
            clicks += 1
            progress = Progress(done: clicks, total: total)
            if let p {
                hits += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                app.say(String(format: "probe %d: move %d %d → (%.3f, %.3f) = %.0f, %.0f px", clicks, ux, uy, p.x, p.y,
                               p.x * DeviceScreen.size.width * DeviceScreen.scale,
                               p.y * DeviceScreen.size.height * DeviceScreen.scale))
            } else {
                app.say("probe \(clicks): move \(ux) \(uy) → no tap within \(Int(Self.tapTimeout)) s")
            }
            return p
        }

        /// A click that never reached the app probably hit the AssistiveTouch button and opened its menu:
        /// remember the spot and close the menu (esc, then a click on an empty area, which the probe swallows).
        func missed(at fx: Double, _ fy: Double, empty: (Int, Int)?) async {
            AssistiveTouchSpots.remember(x: fx, y: fy)
            _ = try? await device.send("key esc")
            if let (ex, ey) = empty {
                _ = try? await device.send("home")
                _ = try? await device.send("move \(ex) \(ey)")
                _ = try? await device.send("click")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if !full {  // quick check after a reconnect: one tap at the check point
            phase = .verifying
            guard pointer.calibrated else { return .failed("not calibrated") }
            try await pointer.point(Self.check.x, Self.check.y)
            let sent = now()
            try await device.send("click")
            guard let p = await probe.tap(since: sent, timeout: Self.tapTimeout) else { return .noTaps }
            let error = max(abs(p.x - Self.check.x), abs(p.y - Self.check.y))
            app.say(String(format: "probe check: ±%.1f%%", error * 100))
            if error <= Self.tolerance {
                pointer.setQuality(error)
                return .done(error)
            }
            return try await touchCalibrate(full: true)
        }

        var samples: [(ux: Double, uy: Double, fx: Double, fy: Double)] = []
        func record(_ ux: Int, _ uy: Int, _ p: CGPoint?) {
            if let p { samples.append((Double(ux), Double(uy), p.x, p.y)) }
        }
        func lines() -> (ProbeFit.Line, ProbeFit.Line)? {
            let xs = samples.filter { ProbeFit.usable($0.fx) }.map { ($0.ux, $0.fx) }
            let ys = samples.filter { ProbeFit.usable($0.fy) }.map { ($0.uy, $0.fy) }
            guard let x = ProbeFit.line(xs) ?? xs.first.flatMap(ProbeFit.throughHome),
                  let y = ProbeFit.line(ys) ?? ys.first.flatMap(ProbeFit.throughHome) else { return nil }
            return (x, y)
        }

        // stage 1: rough, on the diagonal
        phase = .probeA
        for u in Self.roughStops {
            let p = try await click(u, u)
            if p == nil && hits == 0 { return .noTaps }
            if p == nil { _ = try? await device.send("key esc") }  // no fit yet to place the spot or an empty click
            record(u, u, p)
        }
        guard let rough = lines() else { return .failed("probe taps stuck at the screen edge") }

        // stage 2: corners and centre
        phase = .probeB
        let empty = (rough.0.units(for: 0.5), rough.1.units(for: 0.12))
        for (fx, fy) in Self.targets {
            let ux = rough.0.units(for: fx), uy = rough.1.units(for: fy)
            guard ux > 0, uy > 0 else { continue }
            if let p = try await click(ux, uy) { record(ux, uy, p); continue }
            await missed(at: fx, fy, empty: empty)
            // replace the probe with one a little closer to the centre
            let rx = fx + (0.5 - fx) * 0.4, ry = fy + (0.5 - fy) * 0.4
            guard rx != fx || ry != fy else { continue }
            let vx = rough.0.units(for: rx), vy = rough.1.units(for: ry)
            total += 1
            app.say(String(format: "probe replaced: (%.2f, %.2f) → (%.2f, %.2f)", fx, fy, rx, ry))
            if let p = try await click(vx, vy) { record(vx, vy, p) } else { await missed(at: rx, ry, empty: empty) }
        }
        guard samples.count >= 4, let (lx, ly) = lines() else {
            return .failed("only \(samples.count) of \(clicks) probe clicks arrived")
        }
        app.say(String(format: "probe fit: x = %.5f·u %+.3f, y = %.5f·u %+.3f, residual %.2f%% / %.2f%% (%@)",
                       lx.a, lx.b, ly.a, ly.b, lx.rms * 100, ly.rms * 100,
                       "\(Int(DeviceScreen.size.width))×\(Int(DeviceScreen.size.height)) pt @\(Int(DeviceScreen.scale))x"))
        pointer.applyProbe(x: lx, y: ly, samples: samples)
        if (pointer.boardPace ?? 1) >= 3 {
            total += Self.speeds.count + 2
            try await calibrateSpeeds(lx.units(for: 0.35), ly.units(for: 0.4)) { try await click($0, $1, then: $2) }
        }

        // stage 3: check with the agent's own move
        phase = .verifying
        try await pointer.point(Self.check.x, Self.check.y)
        let sent = now()
        try await device.send("click")
        clicks += 1
        progress = Progress(done: clicks, total: total)
        guard let p = await probe.tap(since: sent, timeout: Self.tapTimeout) else { return .done(max(lx.rms, ly.rms)) }
        let error = max(abs(p.x - Self.check.x), abs(p.y - Self.check.y))
        pointer.setQuality(error)
        app.say(String(format: "probe check at (%.2f, %.2f): landed (%.3f, %.3f), ±%.1f%%", Self.check.x, Self.check.y,
                       p.x, p.y, error * 100))
        return .done(error)
    }
}

extension AutoCalibrator {
    /// The same diagonal move at each speed from (bx, by), against the full speed: the distance ratios.
    func calibrateSpeeds(_ bx: Int, _ by: Int, click: (Int, Int, String?) async throws -> CGPoint?) async throws {
        let d = Self.speedMove
        guard let base = try await click(bx, by, nil), let full = try await click(bx, by, "move \(d) \(d)") else { return }
        let fx = full.x - base.x, fy = full.y - base.y
        guard fx > 0.02, fy > 0.01 else { return app.say("speed probes: the full-speed move went nowhere") }
        var measured: [(Double, Double)] = []
        for v in Self.speeds {
            guard let p = try await click(bx, by, "move \(d) \(d) \(v)") else { continue }
            measured.append((Double(v), ((p.x - base.x) / fx + (p.y - base.y) / fy) / 2))
        }
        app.pointer.applySpeeds(measured)
    }
}

extension AppModel {
    /// Ask the vision model where the pointer is on a mirrored frame (fallback for calibration).
    func locatePointer(_ jpeg: Data) async -> CGPoint? {
        guard !MockMode.on, settings.isConfigured, let client = try? await settings.client("actor") else { return nil }
        let system = "You find the mouse pointer on iPhone/iPad screenshots. The AssistiveTouch pointer is a small "
            + "round dark grey translucent dot. During calibration the screen is white with a grid: thin lines every "
            + "10% labelled 100-900 along the top and left edges, and coloured squares in the corners. Reply with JSON only: {\"x\": <0-1000>, \"y\": <0-1000>} for its centre, "
            + "relative to the screenshot (x left->right, y top->bottom), or {\"x\": null, \"y\": null} if there is none."
        guard let r = try? await client.chat(system: system, text: "Where is the pointer?", image: jpeg, maxTokens: 200,
                                             temperature: 0),
              let start = r.text.firstIndex(of: "{"), let end = r.text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(r.text[start...end].utf8)) as? [String: Any],
              let x = (json["x"] as? NSNumber)?.doubleValue, let y = (json["y"] as? NSNumber)?.doubleValue,
              (0...1000).contains(x), (0...1000).contains(y) else {
            say("calibration: vision model did not find the pointer")
            return nil
        }
        return CGPoint(x: x / 1000, y: y / 1000)
    }
}

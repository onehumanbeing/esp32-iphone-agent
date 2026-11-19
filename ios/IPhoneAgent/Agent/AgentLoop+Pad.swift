import CoreGraphics
import Foundation

/// What only an iPad needs in the loop. `screen?.geometry` is nil on iPhone, so none of this runs there.
///
/// The model sees the screen as decoded (black bars are cropped off when there are any, H264Decoder), so its
/// 0-1000 coordinates are screen fractions. Should a frame still be letterboxed (bars that were not black), the
/// geometry maps them onto the screen, and a point on a bar is refused rather than clamped onto the screen's edge.
extension AgentLoop {
    /// iPad: no frame from after the last action arrived. Its effect is unknown, not "unchanged": a stale frame read as
    /// "did NOT change" sent the model into repeating a tap that had worked (2026-10-26).
    func unseen() {
        steps[steps.count - 1]["stale"] = .bool(true)
        trace?.write(kind: "verdict", ["stale": .bool(true)])
    }

    static let staleNote = "\n\nNote: no new screen image arrived after your last action (the video from the device "
        + "stalled), so this screenshot may be from before it and not show its effect yet. If the screen looks "
        + "unchanged, prefer `wait` over repeating the action."

    static let staleEffect = " -> no new screen image yet (effect unknown)"

    /// A reply for a screen that rotated meanwhile is dropped and the model looks again (ask), at most this often per
    /// look: an iPad that keeps turning ends the run instead of paying for looks forever.
    static let turnRetries = 2
    static let turningReason = "the iPad kept rotating while the model looked: hold it still and start again"
    /// The screen's shape must hold this long before the model looks again, waiting at most `steadyMost`.
    static let steadyFor = 1.0, steadyMost = 6.0

    /// Wait until the mirrored shape stops changing (a rotation streams a few frames of each size), so the next look
    /// is of the turned screen and not of one in between.
    func steadyGeometry() async {
        let started = now()
        var last = screen?.geometry, since = now()
        while !Task.isCancelled && now() - started < Self.steadyMost {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let current = screen?.geometry
            if current != last { (last, since) = (current, now()) }
            if now() - since >= Self.steadyFor { return }
        }
    }
}

/// iPad: an action's frame coordinates (0-1000) as screen coordinates (0-1000). Actions without coordinates pass.
enum PadGeometry {
    static func toScreen(_ a: JObject, _ geometry: ScreenGeometry) throws -> JObject {
        var out = a
        func map(_ x: Double, _ y: Double) throws -> CGPoint {
            let point = CGPoint(x: x / 1000, y: y / 1000)
            guard geometry.contains(framePoint: point) else {
                throw Actions.ParseError(message: "that point is on a black bar around the mirrored screen, not on it")
            }
            let p = geometry.screenPoint(fromFrame: point)
            return CGPoint(x: min(max(p.x, 0), 1) * 1000, y: min(max(p.y, 0), 1) * 1000)
        }
        func move(_ kx: String, _ ky: String) throws {
            guard let x = a[kx]?.double, let y = a[ky]?.double else { return }
            let p = try map(x, y)
            (out[kx], out[ky]) = (.num(p.x), .num(p.y))
        }
        switch a["action"]?.str {
        case "tap": try move("x", "y")
        case "swipe": try move("x1", "y1"); try move("x2", "y2")
        case "path":
            out["points"] = .arr(try points(a).map { p in
                let s = try map(Double(p.x), Double(p.y))
                return .arr([.num(s.x), .num(s.y)])
            })
        case "circle":
            try move("x", "y")
            if let r = a["r"]?.double { out["r"] = .num(r / max(geometry.contentRect.width, 0.01)) }  // r is in x units
        default: break
        }
        return out
    }
}

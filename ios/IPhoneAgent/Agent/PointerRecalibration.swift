import UIKit

/// A pointer that lands far off its target (more than `miss` device pixels) has a calibration that no longer fits:
/// the learned correction only takes small, steady misses (Pointer.maxMiss) and fixes one landing at a time. Then
/// the pointer is calibrated again from the video before the next tap (homed, found at two known distances, the
/// check point measured), pixels only, no clicks. At most once every `every` taps, so a screen where the pointer
/// can't be read well never loops on it. Pure: the pointer feeds it its misses and taps.
///
/// One far landing that two readings agreed on (`confirmed`, Pointer.measureSure) is the tracked position gone
/// wrong more often than the calibration: the pointer is re-homed (the next gesture starts from the corner) and
/// only a second far landing in a row calibrates again. 2026-11-11: one far reading cost a 5.3 s recalibration
/// that came out at ±1.2%, i.e. the old calibration had been fine.
struct Recalibration {
    /// Device pixels between a target and where the pointer was found that call for a new calibration.
    static let miss = 100.0
    /// The same as a share of the screen on either side (Pointer.maxMiss): a landing past it is not learned from,
    /// so it must count here too. 2026-11-16: a steady +65 x (0.065 of the width, ~86 px) was past maxMiss but under
    /// `miss`, neither learned nor calibrated, and every tap on that phone missed alike.
    static let fraction = 0.06
    /// Taps after one recalibration before the next may run.
    static let every = 15
    /// A recalibration that failed (pointer not found: a busy screen) is tried again this many taps later, the wait
    /// doubling after each failure in a row (3, 6, 12 ... taps), never given up: the old calibration had already missed
    /// far (Henry 2026-11-11: lost = calibrate again). 2026-11-24: after 3 failures it stopped for good, and a phone
    /// whose taps landed ~500 units low tapped wrong for 133 steps.
    static let retryAfter = 3
    private(set) var failures = 0

    private(set) var pending = false
    private(set) var taps = 0
    private(set) var last: Int?  // `taps` at the last recalibration
    private(set) var rehomed = false  // the last landing was far but confirmed: re-homed instead
    private var farSide: (right: Bool, below: Bool)?  // which way the last far landing was off its target
    private(set) var early = false  // the last recalibration came before `every` taps: the next one waits for them

    /// The pointer was found at `found` for a move to `target` (screen fractions) on a screen of `pixels`. A miss
    /// within `every` taps of the last recalibration is left to the usual correction, unless it is the second far
    /// one in a row off the same way: then the scale is wrong (the tracking speed changed since the calibration),
    /// every tap until the 15th would miss alike, and `retryAfter` taps are enough. Once: if that one did not help
    /// (a screen where the pointer can't be read well), the next waits the full `every` taps again.
    /// Returns true when the caller should re-home the pointer instead (a first confirmed far landing).
    @discardableResult
    mutating func measured(_ target: CGPoint, _ found: CGPoint, pixels: CGSize, confirmed: Bool = false) -> Bool {
        let off = hypot((found.x - target.x) * pixels.width, (found.y - target.y) * pixels.height)
        let share = max(abs(found.x - target.x), abs(found.y - target.y))
        guard Double(off) > Self.miss || Double(share) > Self.fraction else { rehomed = false; farSide = nil; return false }
        let side = (right: found.x > target.x, below: found.y > target.y)
        let sameWay = farSide.map { $0 == side } ?? false
        farSide = side
        let soon = sameWay && !early
        guard last.map({ taps - $0 >= (soon ? Self.retryAfter : Self.every) }) ?? true else { return false }
        let isEarly = last.map { taps - $0 < Self.every } ?? false
        if confirmed && !rehomed {
            rehomed = true
            return true
        }
        pending = true
        early = isEarly
        return false
    }

    /// Before a tap: true = recalibrate first (the miss is then dealt with, whatever the result).
    mutating func tap() -> Bool {
        taps += 1
        if failures > 0 && !pending, let last, taps - last >= backoff { pending = true }
        return take()
    }

    /// Taps to wait before trying again after `failures` failed recalibrations in a row.
    var backoff: Int { Self.retryAfter << min(max(failures - 1, 0), 5) }

    /// Far from the target again right after a re-home (two far landings around it): the calibration is off, not the
    /// tracked position, so calibrate again now rather than press where the pointer is known to be wrong. Only the
    /// wait after failed tries holds it (`backoff`), not the `every` taps that guard against stray single readings.
    mutating func farFromCorner() -> Bool {
        if failures > 0, let last, taps - last < backoff { return false }
        pending = true
        return take()
    }

    /// A pending recalibration, taken now (mid-aim) rather than before the next tap.
    mutating func take() -> Bool {
        guard pending else { return false }
        (pending, last, rehomed) = (false, taps, false)
        return true
    }

    /// The recalibration's result: a failure asks for another try a few taps later.
    mutating func finished(ok: Bool) { failures = ok ? 0 : failures + 1 }

    /// The phone's screen in pixels (the app runs on the iPhone it controls).
    @MainActor static var pixels: CGSize {
        CGSize(width: DeviceScreen.size.width * DeviceScreen.scale, height: DeviceScreen.size.height * DeviceScreen.scale)
    }
}

extension Pointer {
    /// Calibrate again from the video, mid-run, as AutoCalibrator's fallback does but without its board (the run's
    /// app stays in front) and without the vision model (slow). A failed or poor result puts the old one back; the
    /// pointer is re-homed either way, so the next tap starts from the corner.
    func recalibrate() async throws {
        guard let before = snapshot(), screen?.live == true, FrameMode.current == .stream else { return }
        let model = locate
        locate = nil
        defer { locate = model }
        log("pointer: landed far from the target; calibrating again")
        StepReport.shared.recalibrated()
        do {
            guard try await startCalibration(), let error = try await verify(), error <= AutoCalibrator.rejectAbove else {
                recalibration.finished(ok: false)
                log("pointer: calibration again failed; the previous one stays, trying again in \(recalibration.backoff) taps")
                return restore(before)
            }
            recalibration.finished(ok: true)
            log(String(format: "pointer: calibrated again, ±%.1f%%", error * 100))
        } catch {
            restore(before)
            throw error
        }
    }
}

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
    /// Taps after one recalibration before the next may run.
    static let every = 15

    private(set) var pending = false
    private(set) var taps = 0
    private(set) var last: Int?  // `taps` at the last recalibration
    private(set) var rehomed = false  // the last landing was far but confirmed: re-homed instead

    /// The pointer was found at `found` for a move to `target` (screen fractions) on a screen of `pixels`. A miss
    /// within `every` taps of the last recalibration is left to the usual correction.
    /// Returns true when the caller should re-home the pointer instead (a first confirmed far landing).
    @discardableResult
    mutating func measured(_ target: CGPoint, _ found: CGPoint, pixels: CGSize, confirmed: Bool = false) -> Bool {
        let off = hypot((found.x - target.x) * pixels.width, (found.y - target.y) * pixels.height)
        guard Double(off) > Self.miss else { rehomed = false; return false }
        guard last.map({ taps - $0 >= Self.every }) ?? true else { return false }
        if confirmed && !rehomed {
            rehomed = true
            return true
        }
        pending = true
        return false
    }

    /// Before a tap: true = recalibrate first (the miss is then dealt with, whatever the result).
    mutating func tap() -> Bool {
        taps += 1
        guard pending else { return false }
        (pending, last, rehomed) = (false, taps, false)
        return true
    }

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
        do {
            guard try await startCalibration(), let error = try await verify(), error <= AutoCalibrator.rejectAbove else {
                log("pointer: calibration again failed; the previous one stays")
                return restore(before)
            }
            log(String(format: "pointer: calibrated again, ±%.1f%%", error * 100))
        } catch {
            restore(before)
            throw error
        }
    }
}

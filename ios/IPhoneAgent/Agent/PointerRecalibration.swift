import UIKit

/// A pointer that lands far off its target (more than `miss` device pixels) has a calibration that no longer fits:
/// the learned correction only takes small, steady misses (Pointer.maxMiss) and fixes one landing at a time. Then
/// the pointer is calibrated again from the video before the next tap (homed, found at two known distances, the
/// check point measured), pixels only, no clicks. At most once every `every` taps, so a screen where the pointer
/// can't be read well never loops on it. Pure: the pointer feeds it its misses and taps.
struct Recalibration {
    /// Device pixels between a target and where the pointer was found that call for a new calibration.
    static let miss = 100.0
    /// Taps after one recalibration before the next may run.
    static let every = 15

    private(set) var pending = false
    private(set) var taps = 0
    private(set) var last: Int?  // `taps` at the last recalibration

    /// The pointer was found at `found` for a move to `target` (screen fractions) on a screen of `pixels`. A miss
    /// within `every` taps of the last recalibration is left to the usual correction.
    mutating func measured(_ target: CGPoint, _ found: CGPoint, pixels: CGSize) {
        let off = hypot((found.x - target.x) * pixels.width, (found.y - target.y) * pixels.height)
        if Double(off) > Self.miss, last.map({ taps - $0 >= Self.every }) ?? true { pending = true }
    }

    /// Before a tap: true = recalibrate first (the miss is then dealt with, whatever the result).
    mutating func tap() -> Bool {
        taps += 1
        guard pending else { return false }
        (pending, last) = (false, taps)
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

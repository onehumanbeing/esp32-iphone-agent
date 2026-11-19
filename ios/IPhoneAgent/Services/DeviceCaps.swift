import CoreTelephony
import UIKit

/// Hardware facts that steer the network-mode choice (board hotspot vs home Wi-Fi).
enum DeviceCaps {
    /// Cellular data is possible on this device. Every iPhone qualifies; a Wi-Fi-only iPad has no telephony
    /// hardware and lists no subscriptions, so it can't use the board's hotspot with internet over cellular and
    /// goes straight to the LAN mode. A cellular iPad lists its SIM slots (with or without a SIM: iOS 16+ only
    /// reports placeholder carriers), so it keeps the choice.
    static var hasCellular: Bool {
        if UIDevice.current.userInterfaceIdiom == .phone { return true }
        return !(CTTelephonyNetworkInfo().serviceSubscriberCellularProviders ?? [:]).isEmpty
    }

    /// The board's default AirPlay display (`res`), what an iPhone always gets: it streams 718x1560 from it.
    static let phoneDisplay = (w: 480, h: 1040)

    /// The AirPlay display the board advertises for this device (`res W H`, stored on the board). An iPad fits its
    /// screen into the display (iPad Air M3, 2026-10-29: 960x2080 -> 960x668, 1040x720 -> 1036x720, 1440x1000 and
    /// 1920x1334 as is; 480x1040 and 720x720 -> 720x500). It gets a square one, 1200 px each way: landscape fits
    /// it as 1200x834 (as the landscape display of its own shape did), and portrait as 834x1200 instead of the
    /// ~580x834 that display left it, so both orientations have the same ~1M pixels: about what a model uses (DashScope's
    /// Qwen resizes beyond that) and near an iPhone stream's 1.12M, since bigger frames fill the board's 4 MB GOP
    /// buffer sooner. Whatever bars iOS adds around the screen are cropped off (Letterbox), and the display no longer
    /// changes with the orientation. The square at 720 (2026-10-28) only failed on an external-display scene taken
    /// for the app's own window (DeviceScreen.scene keeps to the app's role now) and on being too small.
    @MainActor static var mirrorDisplay: (w: Int, h: Int) {
        #if DEBUG
        if let size = mirrorDisplayOverride { return size }
        #endif
        guard DeviceKind.isPad else { return phoneDisplay }
        return padDisplay(nativeSize: DeviceScreen.scene?.screen.nativeBounds.size ?? CGSize(width: 1640, height: 2360))
    }

    /// The iPad's display: square (see mirrorDisplay), or with `square` off a landscape one of the screen's aspect,
    /// 1200 px long with an even height (H.264 macroblocks), for either orientation of `nativeSize`.
    static let padSide = 1200
    static func padDisplay(nativeSize size: CGSize, square: Bool = true) -> (w: Int, h: Int) {
        if square { return (padSide, padSide) }
        let aspect = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (padSide, Int((Double(padSide) / aspect / 2).rounded()) * 2)
    }

    /// An iPhone never wants a display that is not taller than wide: such a one was an iPad's, and the iPhone puts the
    /// board back to its default.
    static func iPadsDisplay(w: Int, h: Int) -> Bool { w >= h }

    #if DEBUG
    /// A size under test (iphoneagent://display) instead of the default; nil = the default.
    static var mirrorDisplayOverride: (w: Int, h: Int)? {
        get {
            let parts = (UserDefaults.standard.string(forKey: "mirrorDisplayOverride") ?? "").split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            return (w, h)
        }
        set { UserDefaults.standard.set(newValue.map { "\($0.w)x\($0.h)" }, forKey: "mirrorDisplayOverride") }
    }
    #endif
}

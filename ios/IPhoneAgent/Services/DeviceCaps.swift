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
    /// 1920x1334 as is; 480x1040 and 720x720 -> 720x500), so it gets a landscape display of its own shape, 1200 px
    /// long: about the 1M pixels a model can use (DashScope's Qwen resizes beyond that) and near an iPhone stream's
    /// 1.12M, since bigger frames fill the board's 4 MB GOP buffer sooner. Portrait fits its height (~580x834).
    @MainActor static var mirrorDisplay: (w: Int, h: Int) {
        #if DEBUG
        if let size = mirrorDisplayOverride { return size }
        #endif
        guard DeviceKind.isPad else { return phoneDisplay }
        return padDisplay(nativeSize: DeviceScreen.scene?.screen.nativeBounds.size ?? CGSize(width: 1640, height: 2360))
    }

    /// 1200 px long, the screen's aspect, an even height (H.264 macroblocks); either orientation of `nativeSize`.
    static func padDisplay(nativeSize size: CGSize) -> (w: Int, h: Int) {
        let aspect = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1200, Int((1200 / aspect / 2).rounded()) * 2)
    }

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

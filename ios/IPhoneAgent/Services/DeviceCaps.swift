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
}

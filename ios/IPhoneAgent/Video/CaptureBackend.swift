import Foundation

/// Where a run's screen comes from. AirPlay (the board mirrors the phone and forwards the frames) is the default and
/// the only choice before iOS 27; from iOS 27 the user can choose Screen Recording in Settings: the phone captures
/// its own screen (ScreenCaptureFeed) and the board only moves the pointer, so no Wi-Fi, hotspot or mirroring.
///
/// The board plays no part in the choice: every firmware moves the pointer the same way, and the one hint the app
/// gives it (the StopWatch's `o`, StopWatchUI.Payload) is a key older firmware skips.
enum CaptureBackend: String {
    case airPlay, onDevice
    static let key = "captureBackend"

    /// What decides whether Screen Recording can be offered on this phone, in this build.
    struct Support: Equatable {
        /// iOS 27 or later: ScreenCaptureKit exists on iPhone from then on.
        var os27: Bool
        /// The build was made with an SDK that has ScreenCaptureKit for iOS (Xcode 27+); older Xcodes compile it out.
        var sdk: Bool
        /// SCContentSharingPicker.isAvailable: screen recording is supported and allowed (Screen Time can forbid it).
        var allowed: Bool
        /// Info.plist declares the `screen-capture` background mode. Without it iOS stops the stream the moment the
        /// app leaves the front (SCStreamError.missingBackgroundMode), and the agent works in other apps.
        var background: Bool
        /// An iPhone. An iPad's pointer calibration is kept per orientation from the mirrored picture's shape
        /// (ScreenGeometry), which the phone's own capture does not give; iPads stay on AirPlay for now.
        var phone = true

        var onDevice: Bool { os27 && sdk && allowed && background && phone }
    }

    /// The source a run uses: the saved preference where the phone supports it, else AirPlay. A preference saved
    /// on a phone or build that lost the support (a TestFlight build without the background mode, Screen Time
    /// turned recording off) falls back to AirPlay and is kept for when the support is back.
    static func resolve(_ support: Support, saved: String?) -> CaptureBackend {
        guard support.onDevice else { return .airPlay }
        return saved.flatMap(CaptureBackend.init(rawValue:)) ?? .airPlay
    }

    /// The `screen-capture` background mode is in this build's Info.plist (CaptureBackend.Support.background).
    static func declaresBackgroundMode(_ info: [String: Any]?) -> Bool {
        (info?["UIBackgroundModes"] as? [String])?.contains("screen-capture") == true
    }

    @MainActor static var support: Support {
        var support = Support(os27: false, sdk: false, allowed: false,
                              background: declaresBackgroundMode(Bundle.main.infoDictionary), phone: !DeviceKind.isPad)
        if #available(iOS 27.0, *) {
            support.os27 = true
            support.sdk = ScreenCaptureFeed.compiled
            support.allowed = ScreenCaptureFeed.isAvailable
        }
        return support
    }

    @MainActor static var onDeviceAvailable: Bool { support.onDevice }

    @MainActor static var current: CaptureBackend {
        resolve(support, saved: UserDefaults.standard.string(forKey: key))
    }
}

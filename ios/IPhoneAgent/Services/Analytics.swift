import Foundation
import UIKit

/// Anonymous usage stats, sent only after the user turns them on (first-launch sheet or Settings › Privacy;
/// off by default). A fixed list of events goes to PostHog: setup steps, board, mirroring and calibration,
/// run start and end with step count and duration (a start that failed: the startup step and a fixed error kind,
/// StartupFailure), the model provider, the board's input (ble/usb), firmware and model, per run counts of typing
/// fallbacks and video trouble (TypeStats, VideoHealth), and per model request its timing,
/// token counts and error kind. Never the task, screenshots,
/// model replies, keys or addresses; no location, no person profiles. No SDK: events are batched and
/// POSTed to PostHog's capture API. Builds without IA_POSTHOG_KEY (e.g. built from source) send nothing.
@MainActor
enum Analytics {
    static let consentKey = "usageStatsConsent"
    private static let idKey = "usageStatsID"
    private static let key = Bundle.main.object(forInfoDictionaryKey: "IAPostHogKey") as? String ?? ""
    private static let host = (Bundle.main.object(forInfoDictionaryKey: "IAPostHogHost") as? String)
        .flatMap(URL.init(string:))
    private static var queue: [[String: Any]] = []
    private static var sent: Set<String> = []  // captureOnce events this launch
    private static var timer: Timer?
    private static var sending = false
    private static var flushRequested = false
    private static var delivery: Task<Void, Never>?
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static var deliveryRevision = 0
    private static var consentRevision = 0
    private static let stamp = ISO8601DateFormatter()

    /// This build can send stats (the switch is shown only then).
    static var available: Bool { !key.isEmpty && host != nil && !MockMode.on }
    static var enabled: Bool { available && UserDefaults.standard.bool(forKey: consentKey) }

    /// Call once at launch: flush every 30 s and when the app leaves the screen.
    static func start() {
        guard available, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in flush() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in Task { @MainActor in flush() } }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in Task { @MainActor in flush() } }
        capture("app_opened")
    }

    /// The switch changed. Off forgets the queue and the install id (the next opt-in starts a new one).
    static func consentChanged(_ on: Bool) {
        if on {
            capture("usage_stats_enabled")
        } else {
            consentRevision += 1
            queue = []
            delivery?.cancel()
            UserDefaults.standard.removeObject(forKey: idKey)
        }
    }

    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard enabled else { return }
        var p = common
        p.merge(props) { _, new in new }
        p["distinct_id"] = distinctID
        queue.append(["event": event, "properties": p, "timestamp": stamp.string(from: Date())])
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }  // offline for a long time
        if queue.count >= 20 { flush() }
    }

    /// At most once per launch, e.g. "board_connected" on every reconnect would be noise.
    static func captureOnce(_ event: String, _ props: [String: Any] = [:]) {
        guard enabled, sent.insert(event).inserted else { return }
        capture(event, props)
    }

    static func flush() {
        guard enabled, !queue.isEmpty, let host else { return }
        guard !sending else { flushRequested = true; return }
        // JSONSerialization raises an ObjC exception (not a Swift error) on a non-JSON value, which `try?` does not
        // catch: a struct in board_reboot's "fw" aborted 1.0.5 on every board reboot (2026-11-15). Drop such events.
        let bad = queue.filter { !JSONSerialization.isValidJSONObject($0) }
        if !bad.isEmpty {
            DebugLog.write("analytics: dropped \(bad.count) events with non-JSON props: "
                           + bad.compactMap { $0["event"] as? String }.joined(separator: ","))
            queue.removeAll { !JSONSerialization.isValidJSONObject($0) }
            guard !queue.isEmpty else { return }
        }
        let batch = queue
        queue = []
        sending = true
        flushRequested = false
        deliveryRevision += 1
        let revision = deliveryRevision
        let consent = consentRevision
        // A run normally finishes off screen. Allow this bounded request to finish before suspension;
        // expired or failed deliveries stay queued for the next foreground/timer flush.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "usage stats") {
            Task { @MainActor in
                guard revision == deliveryRevision else { return }
                delivery?.cancel()
                endBackgroundDelivery()
            }
        }
        var request = URLRequest(url: host.appendingPathComponent("batch/"))
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": key, "batch": batch])
        delivery = Task {
            let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
            let ok = status == 200
            sending = false
            delivery = nil
            endBackgroundDelivery()
            if !ok && enabled && consent == consentRevision {
                queue = Array((batch + queue).suffix(200))
            }
            DebugLog.write("analytics delivery: \(batch.count) events, \(ok ? "accepted" : "deferred")")
            // A terminal event can arrive while the preceding batch is outstanding.
            if ok && flushRequested { flush() }
        }
    }

    private static func endBackgroundDelivery() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Random per-install id, not tied to the device or a person.
    private static var distinctID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static let common: [String: Any] = {
        let info = Bundle.main.infoDictionary
        return [
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$lib": "esp32-agent-ios",
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info?["CFBundleVersion"] as? String ?? "",
            "os_version": UIDevice.current.systemVersion,
            "device_model": DeviceInfo.model,
            "language": Locale.current.language.languageCode?.identifier ?? "",
        ]
    }()
}

enum DeviceInfo {
    /// The hardware model, e.g. "iPhone17,2".
    static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}

/// A run's typing fallbacks for run_ended: counts and fixed reasons only, never the text.
struct TypeStats: Equatable {
    var pinyinStops = 0  // the pinyin keyboard stopped part way, the rest went to the paste path
    var pasteOK = 0
    var pasteFailed: [String: Int] = [:]  // reason → count

    /// One paste fallback; `note` is pasteInstead's result (nil: pasted and read back).
    mutating func pasted(_ note: String?, pinyin: Bool) {
        if pinyin { pinyinStops += 1 }
        guard let note else { pasteOK += 1; return }
        pasteFailed[Self.reason(note), default: 0] += 1
    }

    /// pasteInstead's sentence as a fixed kind.
    static func reason(_ note: String) -> String {
        if note.contains("clipboard is not available") { return "no_clipboard" }
        if note.contains("could not be put on the clipboard") { return "clipboard_write" }
        if note.contains("did not open again") { return "reopen" }
        if note.contains("open the target app again") { return "no_app" }
        if note.contains("text is not seen") { return "not_seen" }
        if note.contains("not pasted") { return "not_pasted" }  // no carried text, the clipboard changed or other text
        return "other"
    }

    var props: [String: Any] {
        var p: [String: Any] = ["pinyin_stops": pinyinStops, "paste_ok": pasteOK,
                                "paste_failed": pasteFailed.values.reduce(0, +)]
        for (reason, n) in pasteFailed { p["paste_failed_" + reason] = n }
        return p
    }
}

/// A run's video trouble for run_ended: the board's GOP filling up (fz), the user asked to (re)start mirroring,
/// and decode errors (a lost decoder session among them) since the run started.
struct VideoHealth: Equatable {
    var frozen = 0
    var mirrorAsked = 0
    var decodeErrorsBefore = 0, backgroundDecodeErrorsBefore = 0

    init() {}
    @MainActor init(_ metrics: Metrics) {
        (decodeErrorsBefore, backgroundDecodeErrorsBefore) = (metrics.decodeErrors, metrics.backgroundDecodeErrors)
    }

    func props(decodeErrors: Int, backgroundDecodeErrors: Int) -> [String: Any] {
        ["video_frozen": frozen, "mirror_reconnect_asked": mirrorAsked,
         "decode_errors": max(0, decodeErrors - decodeErrorsBefore),
         "decode_errors_bg": max(0, backgroundDecodeErrors - backgroundDecodeErrorsBefore)]
    }
}

extension BoardStatus {
    /// The board on run events: input transport, firmware and model; no addresses or names.
    static func analytics(_ s: BoardStatus?) -> [String: Any] {
        guard let s else { return ["hid": "none"] }
        return ["hid": s.bleInput ? "ble" : "usb", "dual_hid": s.hidm != nil,
                "fw": s.fw?.plain ?? "unknown", "board": s.board ?? "stock"]
    }
}

extension AppModel {
    /// Board, typing and video counts merged into both run_ended events.
    var runHealthProps: [String: Any] {
        BoardStatus.analytics(board.status)
            .merging(agent.typeStats.props) { $1 }
            .merging(videoHealth.props(decodeErrors: metrics.decodeErrors,
                                       backgroundDecodeErrors: metrics.backgroundDecodeErrors)) { $1 }
            .merging(["mirror_hint_shown": mirrorHintShown]) { $1 }
    }
}

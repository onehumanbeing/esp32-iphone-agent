import Foundation
import GameController
import UIKit

/// Settings › Developer › Input probe (docs/input-probe.md): what any app on this iPhone can read about a tap
/// (UITouch, UIEvent, pointer hover) and about the phone (screen capture, accessibility, GameController). Measurement
/// only: nothing here changes how the board taps.
enum InputProbe {
    static let fileName = "input-probe.json"

    /// One reading of a touch at one phase.
    struct Phase: Codable, Equatable {
        var phase: String
        var dtMs: Double  // since the touch began
        var majorRadius: Double
        var majorRadiusTolerance: Double
        var force: Double
        var maximumPossibleForce: Double
        var altitudeAngle: Double
        var azimuth: Double
        var x: Double
        var y: Double
    }

    /// Phone-wide state, read live and copied into every sample (a protocol run switches mirroring on and off).
    struct Signals: Codable, Equatable {
        var screenCaptured: Bool  // UIScreen.isCaptured: AirPlay mirroring, recording
        var sceneCaptureState: String?  // iOS 17+: UITraitCollection.sceneCaptureState
        var screens: Int  // UIScreen.screens.count
        var assistiveTouch: Bool
        var guidedAccess: Bool
        var voiceOver: Bool
        var switchControl: Bool
        var mouseCurrent: Bool  // GCMouse.current != nil
        var mice: Int  // GCMouse.mice().count
        var keyboard: Bool  // GCKeyboard.coalesced != nil
        var ios: String
        var indirectInputEvents: String  // this app's UIApplicationSupportsIndirectInputEvents: "absent", "true", "false"
    }

    /// One finished touch (began → ended or cancelled).
    struct Sample: Codable, Equatable {
        var index: Int
        var label: String
        var at: Date
        var type: String  // UITouch.type
        var tapCount: Int
        var durationMs: Double  // began → ended
        var moved: Int  // .moved readings between began and ended (a finger usually jitters; a click may not)
        var pathPt: Double  // distance travelled while down, points
        var hoverBefore: Bool  // a UIHoverGestureRecognizer saw the pointer since the previous touch
        var hoverEvents: Int
        var eventType: String  // UIEvent.type
        var eventSubtype: String
        var buttonMask: Int  // UIEvent.buttonMask (pointer buttons, 0 for a finger)
        var modifierFlags: Int
        var phases: [Phase]
        var signals: Signals
    }

    struct Event: Codable, Equatable {
        var at: Date
        var name: String
        var detail: String
    }

    /// Per label: what to compare between protocol runs at a glance.
    struct Summary: Codable, Equatable {
        var label: String
        var count: Int
        var types: [String: Int]
        var majorRadiusMin: Double
        var majorRadiusMax: Double
        var forceMax: Double
        var medianDurationMs: Double
        var hoverBefore: Int
        var moved: Int  // samples with at least one .moved reading
        var captured: Int  // samples taken while the screen was captured
    }

    struct Report: Codable, Equatable {
        var schema = 1
        var generated: Date
        var app: String
        var signals: Signals
        var summary: [Summary]
        var samples: [Sample]
        var events: [Event]
    }

    // MARK: JSON shaping (pure, tested)

    static func summaries(_ samples: [Sample]) -> [Summary] {
        var order: [String] = []
        var groups: [String: [Sample]] = [:]
        for s in samples {
            if groups[s.label] == nil { order.append(s.label) }
            groups[s.label, default: []].append(s)
        }
        return order.map { label in
            let g = groups[label]!
            let radii = g.flatMap { $0.phases.map(\.majorRadius) }
            let durations = g.map(\.durationMs).sorted()
            let mid = durations.count / 2
            let median = durations.count % 2 == 1 ? durations[mid] : (durations[mid - 1] + durations[mid]) / 2
            return Summary(label: label, count: g.count, types: Dictionary(g.map { ($0.type, 1) }, uniquingKeysWith: +),
                           majorRadiusMin: radii.min() ?? 0, majorRadiusMax: radii.max() ?? 0,
                           forceMax: g.flatMap { $0.phases.map(\.force) }.max() ?? 0,
                           medianDurationMs: round3(median), hoverBefore: g.filter(\.hoverBefore).count,
                           moved: g.filter { $0.moved > 0 }.count, captured: g.filter(\.signals.screenCaptured).count)
        }
    }

    static func report(samples: [Sample], signals: Signals, events: [Event], app: String, now: Date = Date()) -> Report {
        Report(generated: now, app: app, signals: signals, summary: summaries(samples), samples: samples, events: events)
    }

    static func json(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func round3(_ v: Double) -> Double { v.isFinite ? (v * 1000).rounded() / 1000 : 0 }

    static func plistFlag(_ value: Any?) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.boolValue ? "true" : "false"
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased()) ? "true" : "false"
        default: return "absent"
        }
    }

    static func name(_ t: UITouch.TouchType) -> String {
        switch t {
        case .direct: return "direct"
        case .indirect: return "indirect"
        case .pencil: return "pencil"
        case .indirectPointer: return "indirectPointer"
        @unknown default: return "raw(\(t.rawValue))"
        }
    }

    static func name(_ p: UITouch.Phase) -> String {
        switch p {
        case .began: return "began"
        case .moved: return "moved"
        case .stationary: return "stationary"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .regionEntered: return "regionEntered"
        case .regionMoved: return "regionMoved"
        case .regionExited: return "regionExited"
        @unknown default: return "raw(\(p.rawValue))"
        }
    }

    static func name(_ t: UIEvent.EventType) -> String {
        switch t {
        case .touches: return "touches"
        case .motion: return "motion"
        case .remoteControl: return "remoteControl"
        case .presses: return "presses"
        case .scroll: return "scroll"
        case .hover: return "hover"
        case .transform: return "transform"
        @unknown default: return "raw(\(t.rawValue))"
        }
    }

    static func name(_ s: UIEvent.EventSubtype) -> String {
        s == .none ? "none" : s == .motionShake ? "motionShake" : "raw(\(s.rawValue))"
    }

    /// One line per sample for debug.log (`app log` from the harness).
    static func line(_ s: Sample) -> String {
        let r = s.phases.map(\.majorRadius), f = s.phases.map(\.force)
        return String(format: "probe: #%d [%@] %@ tap%d %.0fms moved %d r %.2f-%.2f f %.2f hover %@ captured %@ %@",
                      s.index, s.label, s.type, s.tapCount, s.durationMs, s.moved, r.min() ?? 0, r.max() ?? 0, f.max() ?? 0,
                      s.hoverBefore ? "yes" : "no", s.signals.screenCaptured ? "yes" : "no",
                      s.signals.assistiveTouch ? "AT on" : "AT off")
    }
}

/// The probe's live state: the label, finished samples, phone-wide signals and their changes.
@MainActor final class InputProbeLog: ObservableObject {
    static let shared = InputProbeLog()

    @Published var label = "finger"
    @Published private(set) var samples: [InputProbe.Sample] = []
    @Published private(set) var signals = InputProbeLog.readSignals()
    @Published private(set) var events: [InputProbe.Event] = []
    private var observers: [NSObjectProtocol] = []
    private var hoverCount = 0
    private struct Open { var began: TimeInterval; var phases: [InputProbe.Phase]; var last: CGPoint; var path: Double
        var moved: Int; var type: UITouch.TouchType; var hover: Int
        var eventType: String; var eventSubtype: String; var buttonMask: Int; var modifierFlags: Int }
    private var open: [ObjectIdentifier: Open] = [:]

    var fileURL: URL { AgentFiles.root.appendingPathComponent(InputProbe.fileName) }

    /// Starts watching the phone-wide signals while the probe page is open; `stop()` on close keeps normal runs quiet.
    func start() {
        signals = Self.readSignals()
        guard observers.isEmpty else { return }
        _ = GCMouse.mice()  // begins GameController discovery
        let names: [(Notification.Name, String)] = [
            (UIScreen.capturedDidChangeNotification, "screenCaptured"),
            (UIScreen.didConnectNotification, "screenConnected"),
            (UIScreen.didDisconnectNotification, "screenDisconnected"),
            (UIAccessibility.assistiveTouchStatusDidChangeNotification, "assistiveTouch"),
            (UIAccessibility.guidedAccessStatusDidChangeNotification, "guidedAccess"),
            (UIAccessibility.voiceOverStatusDidChangeNotification, "voiceOver"),
            (UIAccessibility.switchControlStatusDidChangeNotification, "switchControl"),
            (.GCMouseDidConnect, "mouseConnected"), (.GCMouseDidDisconnect, "mouseDisconnected"),
            (.GCKeyboardDidConnect, "keyboardConnected"), (.GCKeyboardDidDisconnect, "keyboardDisconnected"),
        ]
        observers = names.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(label) }
            }
        }
        changed("probeOpened")
    }

    func stop() {
        guard !observers.isEmpty else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        changed("probeClosed")
    }

    private func changed(_ name: String) {
        signals = Self.readSignals()
        let s = signals
        let detail = "captured \(s.screenCaptured) screens \(s.screens) AT \(s.assistiveTouch) mice \(s.mice) "
            + "mouseCurrent \(s.mouseCurrent) keyboard \(s.keyboard)"
        events.append(.init(at: Date(), name: name, detail: detail))
        DebugLog.write("probe: \(name): \(detail)")
    }

    func hovered() { hoverCount += 1 }

    func touch(_ t: UITouch, _ event: UIEvent?, in view: UIView) {
        let id = ObjectIdentifier(t)
        let p = t.location(in: view)
        if t.phase == .began {
            open[id] = Open(began: t.timestamp, phases: [], last: p, path: 0, moved: 0, type: t.type, hover: hoverCount,
                            eventType: event.map { InputProbe.name($0.type) } ?? "none",
                            eventSubtype: event.map { InputProbe.name($0.subtype) } ?? "none",
                            buttonMask: event?.buttonMask.rawValue ?? 0, modifierFlags: event?.modifierFlags.rawValue ?? 0)
            hoverCount = 0
        }
        guard var o = open[id] else { return }
        o.phases.append(.init(phase: InputProbe.name(t.phase), dtMs: InputProbe.round3((t.timestamp - o.began) * 1000),
                              majorRadius: InputProbe.round3(Double(t.majorRadius)),
                              majorRadiusTolerance: InputProbe.round3(Double(t.majorRadiusTolerance)),
                              force: InputProbe.round3(Double(t.force)),
                              maximumPossibleForce: InputProbe.round3(Double(t.maximumPossibleForce)),
                              altitudeAngle: InputProbe.round3(Double(t.altitudeAngle)),
                              azimuth: InputProbe.round3(Double(t.azimuthAngle(in: view))),
                              x: InputProbe.round3(Double(p.x)), y: InputProbe.round3(Double(p.y))))
        if t.phase == .moved { o.moved += 1 }
        o.path += hypot(p.x - o.last.x, p.y - o.last.y)
        o.last = p
        open[id] = o
        guard t.phase == .ended || t.phase == .cancelled else { return }
        open[id] = nil
        let sample = InputProbe.Sample(
            index: samples.count + 1, label: label.trimmingCharacters(in: .whitespaces), at: Date(),
            type: InputProbe.name(o.type), tapCount: t.tapCount,
            durationMs: InputProbe.round3((t.timestamp - o.began) * 1000), moved: o.moved,
            pathPt: InputProbe.round3(o.path), hoverBefore: o.hover > 0, hoverEvents: o.hover,
            eventType: o.eventType, eventSubtype: o.eventSubtype, buttonMask: o.buttonMask, modifierFlags: o.modifierFlags,
            phases: o.phases, signals: Self.readSignals())
        samples.append(sample)
        DebugLog.write(InputProbe.line(sample))
    }

    func clear() {
        samples = []
        events = []
        open = [:]
        hoverCount = 0
    }

    func json() throws -> Data {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return try InputProbe.json(InputProbe.report(samples: samples, signals: Self.readSignals(), events: events, app: app))
    }

    @discardableResult func save() throws -> URL {
        try json().write(to: fileURL, options: .atomic)
        DebugLog.write("probe: wrote \(samples.count) samples to Documents/\(InputProbe.fileName)")
        return fileURL
    }

    static func readSignals() -> InputProbe.Signals {
        let scene = DeviceScreen.scene
        var capture: String?
        if #available(iOS 17.0, *), let state = scene?.traitCollection.sceneCaptureState {
            switch state {
            case .active: capture = "active"
            case .inactive: capture = "inactive"
            case .unspecified: capture = "unspecified"
            @unknown default: capture = "raw(\(state.rawValue))"
            }
        }
        return .init(screenCaptured: (scene?.screen ?? UIScreen.main).isCaptured, sceneCaptureState: capture,
                     screens: UIScreen.screens.count,
                     assistiveTouch: UIAccessibility.isAssistiveTouchRunning, guidedAccess: UIAccessibility.isGuidedAccessEnabled,
                     voiceOver: UIAccessibility.isVoiceOverRunning, switchControl: UIAccessibility.isSwitchControlRunning,
                     mouseCurrent: GCMouse.current != nil, mice: GCMouse.mice().count, keyboard: GCKeyboard.coalesced != nil,
                     ios: UIDevice.current.systemVersion,
                     indirectInputEvents: InputProbe.plistFlag(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSupportsIndirectInputEvents")))
    }
}

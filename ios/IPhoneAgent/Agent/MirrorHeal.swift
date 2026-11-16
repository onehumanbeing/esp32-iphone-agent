import CoreGraphics
import Foundation
import UIKit

/// Where Screen Mirroring and the board's row sit in Control Center, learned while mirroring is healthy.
/// Coordinates are 0...1000, the same space as a model's tap. Layouts differ, so a guess is never stored.
struct MirrorSpots: Codable, Equatable {
    struct Point: Codable, Equatable { var x: Int; var y: Int }
    var tile: Point
    var row: Point
    var width: Int
    var height: Int
    var ios: String
    var learnedAt: Double

    static let key = "mirrorHealSpots"
    /// Words on the Screen Mirroring control. Matched case-insensitively, as a substring.
    static let tileWords = ["screen mirroring", "屏幕镜像", "螢幕鏡像", "屏幕鏡像"]
    /// Never learn or tap a control that would stop an active session.
    static let stopWords = ["stop mirroring", "停止镜像", "停止鏡像"]

    var validNow: Bool { valid(width: Self.screenSize.width, height: Self.screenSize.height, ios: Self.systemVersion) }

    func valid(width: Int, height: Int, ios: String) -> Bool {
        width > 0 && height > 0 && self.width == width && self.height == height && self.ios == ios
    }

    static var screenSize: (width: Int, height: Int) {
        let b = UIScreen.main.bounds
        let s = UIScreen.main.scale
        return (Int((b.width * s).rounded()), Int((b.height * s).rounded()))
    }

    static var systemVersion: String { UIDevice.current.systemVersion }

    static func load(_ defaults: UserDefaults = .standard) -> MirrorSpots? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MirrorSpots.self, from: data)
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// The center of an OCR box (`[x1, y1, x2, y2]` pixels, origin top-left) in 0...1000.
    static func center(_ box: [Int], size: CGSize) -> Point? {
        guard box.count == 4, size.width > 0, size.height > 0 else { return nil }
        let x = Int((Double(box[0] + box[2]) / 2 / size.width * 1000).rounded())
        let y = Int((Double(box[1] + box[3]) / 2 / size.height * 1000).rounded())
        guard (0...1000).contains(x), (0...1000).contains(y) else { return nil }
        return Point(x: x, y: y)
    }

    /// The first line that contains one of `words` and none of `avoiding`.
    static func find(_ lines: [(text: String, box: [Int])], words: [String], size: CGSize,
                     avoiding: [String] = stopWords) -> Point? {
        for line in lines {
            let text = line.text.lowercased()
            if avoiding.contains(where: { text.contains($0) }) { continue }
            guard words.contains(where: { text.contains($0) }) else { continue }
            if let point = center(line.box, size: size) { return point }
        }
        return nil
    }
}

/// When to try putting Screen Mirroring back, and how long to wait after a miss.
/// Pure: the loop polls it. Initial estimates for the quiet time, the backoff and the attempt cap.
enum MirrorHeal {
    struct Clock: Equatable {
        var part: Recovery.Part = .mirroring
        var inPart: Double = 0
        var connected = false
        var sta: Int? = nil
        var usb: String? = nil
        var spotsValid = false
        var attempts = 0
        var now = 0.0
        var backoffUntil = 0.0
        var userInFront = false
        /// Three misses in a row: stop tapping until the spots are learned again.
        var suspicious = false
    }

    enum Decision: Equatable { case idle, attempt(Int) }

    static let maxAttempts = 8
    /// How long to watch for `ap == streaming` and a new frame after the taps.
    static let verifySeconds = 8.0
    /// After opening Control Center, and after tapping the tile. Initial estimates.
    static let openDelay = 0.8
    static let rowDelay = 1.0

    static func backoff(after attempt: Int) -> Double {
        let steps = [30.0, 60, 120, 240, 600]
        return steps[min(max(attempt - 1, 0), steps.count - 1)]
    }

    static func decide(_ c: Clock) -> Decision {
        guard c.part == .mirroring, c.spotsValid, !c.suspicious, c.connected, (c.sta ?? 0) > 0,
              c.usb != "asleep" && c.usb != "off", !c.userInFront, c.attempts < maxAttempts else { return .idle }
        guard c.inPart >= (Recovery.quiet[.mirroring] ?? 20) else { return .idle }
        guard c.now >= c.backoffUntil else { return .idle }
        return .attempt(c.attempts + 1)
    }
}

extension AgentLoop {
    /// One try at Control Center → Screen Mirroring → the board, when the pure clock says so.
    func healMirroring(_ stage: Recovery.Stage) async {
        guard policy.selfHealMirroring, policy.unattended, let phone else { return }
        let spots = MirrorSpots.load()
        let state = link?()
        let clock = MirrorHeal.Clock(part: stage.part, inPart: max(0, now() - mirrorPartSince),
                                      connected: phone.device.connected, sta: state?.sta, usb: state?.usb,
                                      spotsValid: spots?.validNow == true, attempts: mirrorAttempts, now: now(),
                                      backoffUntil: mirrorBackoffUntil, userInFront: userInFront(),
                                      suspicious: mirrorSuspicious)
        guard case .attempt(let n) = MirrorHeal.decide(clock), let spots else { return }
        let held = JevGate.hold
        JevGate.hold = true
        defer { JevGate.hold = held }
        let ok = await performMirrorHeal(n, spots)
        mirrorAttempts = n
        mirrorBackoffUntil = now() + MirrorHeal.backoff(after: n)
        if !ok, n >= 3 {
            mirrorSuspicious = true
            MirrorSpots.clear()
            DebugLog.write("mirror heal: three misses; forgot the taps. Learn them again in Settings.")
        }
    }

    /// Opens Control Center and taps the learned spots. Never types, and closes the panel with the Home key.
    private func performMirrorHeal(_ n: Int, _ spots: MirrorSpots) async -> Bool {
        guard let phone else { return false }
        let started = now()
        do {
            if userInFront() || connectionChanged(since: acceptedLookLinks) { return false }
            try await phone.reset()
            if n >= 2 { try await phone.homeKey() }
            try await phone.swipe(0.93, 0.005, 0.93, 0.45, hold: true)
            try await Task.sleep(nanoseconds: UInt64(MirrorHeal.openDelay * 1_000_000_000))
            try await phone.tap(Double(spots.tile.x) / 1000, Double(spots.tile.y) / 1000, aim: false)
            try await Task.sleep(nanoseconds: UInt64(MirrorHeal.rowDelay * 1_000_000_000))
            try await phone.tap(Double(spots.row.x) / 1000, Double(spots.row.y) / 1000, aim: false)
            let until = now() + MirrorHeal.verifySeconds
            while now() < until {
                try Task.checkCancellation()
                let streaming = link?()?.ap == "streaming"
                let fresh = (screen?.capturedAt ?? 0) > started
                if streaming && fresh {
                    try await phone.homeKey()
                    record(nil, ["action": .str("healed"), "part": .str("mirroring"), "attempt": .int(n),
                                 "s": .num((now() - started).rounded())])
                    DebugLog.write("mirror heal: streaming again on attempt \(n)")
                    return true
                }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            try await phone.homeKey()
        } catch {
            try? await phone.homeKey()
            DebugLog.write("mirror heal: \(error.localizedDescription)")
        }
        return false
    }
}

extension AppModel {
    /// While mirroring is healthy: open Control Center, remember the Screen Mirroring button and the board's
    /// row, and close the panel. The row is not tapped — that can be Stop Mirroring.
    func learnMirrorSpots() async {
        guard feed.live, let jpeg = feed.frame, Vision.image(jpeg) != nil else {
            toast = Toast(text: String(localized: "Start Screen Mirroring first, then try again."))
            return
        }
        do {
            try await pointer.reset()
            try await pointer.swipe(0.93, 0.005, 0.93, 0.45, hold: true)
            await feed.settled(quiet: 0.4, least: 0.4, most: 2)
            guard let opened = feed.frame.flatMap(Vision.image) else { throw DeviceError(message: "no frame") }
            let lines = await UITreeOCR.lines(opened)
            let openedSize = CGSize(width: opened.width, height: opened.height)
            guard let tile = MirrorSpots.find(lines, words: MirrorSpots.tileWords, size: openedSize) else {
                try? await pointer.homeKey()
                toast = Toast(text: String(localized: "Couldn't find Screen Mirroring. Add it in Control Center, large enough to show its name, and try again."))
                return
            }
            try await pointer.tap(Double(tile.x) / 1000, Double(tile.y) / 1000, aim: false)
            await feed.settled(quiet: 0.4, least: 0.5, most: 2)
            guard let listed = feed.frame.flatMap(Vision.image) else { throw DeviceError(message: "no frame") }
            let rows = await UITreeOCR.lines(listed)
            let listSize = CGSize(width: listed.width, height: listed.height)
            let family = BoardName.family(BoardName.current)?.lowercased()
            let words = [BoardName.current.lowercased(), family].compactMap { $0 }.filter { !$0.isEmpty }
            guard let row = MirrorSpots.find(rows, words: words, size: listSize) else {
                try? await pointer.homeKey()
                toast = Toast(text: String(localized: "Couldn't find \(BoardName.current) in Screen Mirroring. Leave mirroring on and try again."))
                return
            }
            let pixels = MirrorSpots.screenSize
            MirrorSpots(tile: tile, row: row, width: pixels.width, height: pixels.height,
                        ios: MirrorSpots.systemVersion, learnedAt: now()).save()
            try await pointer.homeKey()
            toast = Toast(text: String(localized: "Learned Screen Mirroring taps. The iPhone is on the Home Screen."))
            DebugLog.write("mirror learn: tile \(tile.x) \(tile.y), row \(row.x) \(row.y)")
        } catch {
            try? await pointer.homeKey()
            toast = Toast(text: String(localized: "Couldn't learn Screen Mirroring taps."))
            DebugLog.write("mirror learn: \(error.localizedDescription)")
        }
    }
}

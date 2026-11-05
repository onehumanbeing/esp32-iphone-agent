import Foundation
import UIKit

/// What the agent and the pointer need from the screen (VideoFeed, or a fake in tests). Port of screen.py.
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    var updated: Double { get }
    /// When the shown image last differed from the one before (AirPlay repeats a still screen at full fps).
    var changed: Double { get }
    var capturedAt: Double { get }
    var aspect: Double { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result (and fetch it, in snap mode).
    func afterAction(since: Double) async
}

/// How a run gets its frames: the live stream (`stream on`, the default: a frame in under a second), or one
/// snap after each action (`stream off`; waits for the board's whole GOP, often 20-30 s).
enum FrameMode: String {
    case stream, snap
    static let key = "frameModeV2"  // V2: drops the old saved "snap" left by earlier automatic fallbacks
    /// A command timeout switches the current run to snap; not saved, so the next run streams again.
    static var fallback: FrameMode?
    static var current: FrameMode {
        get { fallback ?? FrameMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stream }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); fallback = nil }
    }
}

extension ScreenSource {
    var changed: Double { updated }
    func afterAction(since: Double) async { await settled() }

    /// Wait until the screen stops changing. AirPlay keeps sending frames of a still screen (5 fps of tiny
    /// P-frames), so this watches when the image last changed, not when a frame last arrived: waiting on
    /// arrivals hit the `most` cap on every step (frame 4.0 s per step, 2026-10-19). Mid-animation frames are
    /// big and can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's lag.
    func settled(quiet: Double = 0.5, least: Double = 0.3, most: Double = 4) async {
        let started = now()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while !Task.isCancelled && now() - changed < quiet + lag && now() - started < most {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How late the shown frame arrived after the board got it (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since` (received, when capture times are unknown), or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = now() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if Task.isCancelled || now() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Task.isCancelled ? nil : frame
    }
}

/// The phone's screen, mirrored over AirPlay to the board and forwarded over BLE, as JPEG frames.
@MainActor final class VideoFeed: ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var note = ""  // last decoder problem, shown in Diagnostics
    private(set) var updated = 0.0
    private(set) var changed = 0.0
    /// When the board received the shown frame, in local time (≈; see `boardClock`).
    private(set) var capturedAt = 0.0
    /// A decode error or a lost chunk since the last good frame: the shown frame is stale until the next IDR.
    private(set) var broken = false
    private var noteLogged = 0.0
    private var clockOffset: Double?  // local s − board s, the smallest seen (≈ the link latency)
    var mirroring = false  // board status says ap == streaming
    /// Board status fz: its GOP filled up and no stream goes on from it, so nothing newer than the shown frame
    /// arrives until mirroring sends a keyframe (#25). The shown frame is stale, not "the screen didn't change".
    var frozen = false
    var metrics: Metrics?
    weak var device: HIDDevice?
    /// The board streams every access unit over Wi-Fi while the app's session is up (see video_link.cpp), so
    /// the feed is always in step and a snap would only resend the GOP and stall that stream and BLE.
    var continuous: () -> Bool = { false }

    private var assembler = VideoAssembler()
    static let repeatBytes = 120  // a still 480x1040 screen streams ~75-byte P-frames (3 kbps at 5 fps)
    private var generation = 0
    private let decoder: H264Decoder
    @MainActor private final class DecodeDrain { var completed = false }

    init(decoder: H264Decoder = H264Decoder()) {
        self.decoder = decoder
        decoder.onFrame = { [weak self] f in DispatchQueue.main.async { self?.publish(f) } }
        decoder.onError = { [weak self] msg in
            DispatchQueue.main.async {
                let bg = UIApplication.shared.applicationState == .background
                let note = bg ? "\(msg) [in background]" : msg
                if note != self?.note || now() - (self?.noteLogged ?? 0) > 5 {  // was only in Diagnostics
                    DebugLog.write("decoder: " + note)
                    self?.noteLogged = now()
                }
                self?.note = note
                self?.metrics?.decodeError(background: bg)
                self?.broken = true
                self?.resumeMs = nil  // the decoder needs the IDR again
            }
        }
    }

    var live: Bool { mirroring && !frozen && frame != nil && (device?.connected ?? false) }

    /// Frame width / height (portrait iPhone as a fallback).
    var aspect: Double { size.width > 0 && size.height > 0 ? size.width / size.height : 9 / 19.5 }

    /// One `video` notify from BoardLink.
    func receive(_ chunk: Data) {
        metrics?.videoBytes(chunk.count)
        let dropsBefore = assembler.drops
        let unit = assembler.add(chunk)
        if assembler.drops > dropsBefore { metrics?.videoDrops(assembler.drops - dropsBefore); broken = true }
        guard var unit else { return }
        unit.generation = generation
        if !unit.snap { boardClock(ms: Int(unit.boardMs)) }  // snap units are resent late: their ages say nothing
        if unit.idr { metrics?.idrSeen() }
        if !unit.config { resumeMs = unit.boardMs }
        decoder.queue.async { [decoder] in decoder.decode(unit) }
    }

    /// Board timestamp of the last unit handed to the decoder: a reconnecting Wi-Fi stream asks the board to go on
    /// right after it (`hello <token> at <ms>`) instead of resending the GOP. nil once the decoder lost its place.
    private(set) var resumeMs: UInt32?
    func forgetResume() { resumeMs = nil }

    /// The link (re)connected: chunk numbering starts over.
    func resetStream() { assembler.reset(); clockOffset = nil }  // the board may have rebooted: its clock too

    /// A board timestamp (status `up`, or a streamed unit) just arrived: keep the smallest offset.
    func boardClock(ms: Int) {
        let offset = now() - Double(ms) / 1000
        clockOffset = min(clockOffset ?? offset, offset)
    }

    /// Show a still frame (demo data).
    func show(_ jpeg: Data, width: Int, height: Int) {
        publish(H264Decoder.Frame(jpeg: jpeg, width: width, height: height, decodeMs: 4.2,
                                  unit: AccessUnit(data: Data(), idr: false, config: false, snap: false, boardMs: 0, generation: generation)))
    }

    private func publish(_ f: H264Decoder.Frame) {
        guard f.unit.generation == generation else { return }
        // A repeat of a still screen: a tiny P-frame (skipped blocks only) or the very same image.
        let tiny = !f.unit.data.isEmpty && !f.unit.idr && !f.unit.config && f.unit.data.count < Self.repeatBytes
        let repeated = tiny || f.jpeg == frame
        frame = f.jpeg
        updated = now()
        if !repeated { changed = updated }
        capturedAt = clockOffset.map { Double(f.unit.boardMs) / 1000 + $0 } ?? updated
        broken = false
        if size.width != CGFloat(f.width) || size.height != CGFloat(f.height) {
            size = CGSize(width: f.width, height: f.height)
        }
        metrics?.frameDecoded(ms: f.decodeMs)
    }

    /// The app asked the board to forward the stream (`stream on`).
    private(set) var streamOn = false

    /// Seconds a snap may take: the buffered GOP over the measured BLE rate, doubled, at least 8 s.
    var snapTimeout: Double {
        let gopBytes = Double(metrics?.board?.gop ?? 0)
        let kbps = max(metrics?.bleKbps ?? 0, metrics?.board?.ble?.kbps ?? 0, metrics?.board?.udp?.kbps ?? 0, 40)
        return max(8, gopBytes * 8 / 1000 / kbps * 2 + 3)
    }

    /// A current frame for the model. While the board streams, the live stream has it (an IDR comes every
    /// ~2 s): use a frame younger than `maxAge`, or wait for the next one. Snap only as a fallback, retried
    /// once with a longer timeout. Returns where the frame came from, for the log.
    @discardableResult
    func currentFrame(maxAge: Double = 1, wait: Double = 3) async throws -> String {
        if streamOn && mirroring {
            try Task.checkCancellation()
            if !broken && !frozen && frame != nil && now() - updated < maxAge { return "live" }
            if await fresh(since: now() - maxAge, timeout: wait) != nil && !broken { return "live (waited)" }
        }
        do {
            try await snap()
        } catch is BoardTimeout {
            DebugLog.write("snap timed out; retrying once with a longer timeout")
            try await snap(timeout: snapTimeout * 1.5)
        }
        return "snap"
    }

    /// Ask the board for the current GOP and wait until it is decoded. Returns the latency in ms.
    @discardableResult
    func snap(timeout: Double? = nil, decodeWait: Double = 1) async throws -> Double {
        try Task.checkCancellation()
        guard let device, device.connected else { throw DeviceError(message: "board not connected") }
        let started = now(), previousFrame = updated
        if continuous() && mirroring && !broken && !frozen && frame != nil {
            // Already in step: take a newer frame if the screen moves within a second, else the current one is it
            // (2026-10-20: a 14 s snap stalled calibration, a 24 s one the run start).
            _ = await fresh(since: started, timeout: 1)
            DebugLog.write(String(format: "snap: skipped, Wi-Fi stream in step (frame %.1f s old)", now() - updated))
            return (now() - started) * 1000
        }
        if let channel = device as? CommandChannel {
            try await channel.send("snap", timeout: timeout ?? snapTimeout)
        } else {
            try await device.send("snap")
        }
        try Task.checkCancellation()
        // A snap delivers the whole GOP at once; decoding it can take seconds (≈45 fps in the 2026-10-17 log),
        // so `decodeWait` only starts once the decoder has caught up with it.
        let drain = DecodeDrain()
        let drainLimit = now() + max(decodeWait, 15)
        let acked = now()
        var caughtUp: Double?
        decoder.queue.async { DispatchQueue.main.async { drain.completed = true } }
        while !drain.completed || frame == nil || updated <= previousFrame || broken {
            try Task.checkCancellation()
            if drain.completed, caughtUp == nil { caughtUp = now() }
            guard now() < caughtUp.map({ $0 + max(0, decodeWait) }) ?? drainLimit else {
                broken = true
                DebugLog.write("snap: no new image (decoder \(drain.completed ? "caught up" : "still busy"), frame \(frame == nil ? "none" : String(format: "%.1f s old", now() - updated)))")
                throw DeviceError(message: String(localized: "The board answered, but no new screen image arrived. Keep Screen Mirroring connected and try again."))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        let ms = (now() - started) * 1000
        DebugLog.write(String(format: "snap: ack after %.0f ms, decoded +%.0f ms", (acked - started) * 1000, (now() - acked) * 1000))
        metrics?.snapLatency(ms)
        return ms
    }

    func stream(_ on: Bool) async throws {
        try await device?.send("stream \(on ? "on" : "off")")
        streamOn = on
    }

    /// The model must never see a frame from before the action that ended at `since`. Stream: let the screen
    /// settle, then wait (bounded) for a frame captured after the action; none while the stream is healthy means
    /// the screen did not change, but a broken stream (waiting for an IDR) needs a snap. Snap: give the UI a moment,
    /// snap, and snap once more if the GOP still ends before the action.
    func afterAction(since: Double) async {
        do {
            if FrameMode.current == .snap {
                try await Task.sleep(nanoseconds: 700_000_000)
                try await currentFrame()
                guard capturedAt < since else { return }
                DebugLog.write(String(format: "frame: snap ends %.1f s before the action; snapping again", since - capturedAt))
                try await Task.sleep(nanoseconds: 500_000_000)
                try await currentFrame()
            } else {
                await settled()
                if await newer(than: since, timeout: 1.5) { return }
                if frozen { return DebugLog.write("frame: none after the action; the board's video is frozen (no keyframe)") }
                guard broken || !streamOn else { return DebugLog.write("frame: none after the action; screen unchanged") }
                DebugLog.write("frame: stream stale (waiting for an IDR); snapping")
                try await snap()
            }
        } catch {
            DebugLog.write("frame after action failed: \(error.localizedDescription)")
        }
        if capturedAt < since { DebugLog.write(String(format: "frame: still %.1f s older than the action", since - capturedAt)) }
    }

    /// Waits until the shown frame was captured after `t`; false on timeout.
    private func newer(than t: Double, timeout: Double) async -> Bool {
        let deadline = now() + timeout
        while capturedAt < t {
            if Task.isCancelled || now() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// The link dropped: the board forgets `stream on`.
    func linkLost() {
        streamOn = false
        broken = true
        generation += 1  // a late decode from the old link must not make its stale image healthy again
    }
}

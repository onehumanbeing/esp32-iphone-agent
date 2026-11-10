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
    /// The shown frame is older than the last action and nothing newer came: fetch one before the model looks.
    var stale: Bool { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result (and fetch it, in snap mode).
    /// `ignoring`: where the pointer was and went (fractions); changes there alone are not a result.
    func afterAction(since: Double, ignoring: [CGPoint]) async
    /// A frame captured from now on, not the shown one (LinkCheck): false when none arrives; nil = can't tell.
    func freshFrame() async -> Bool?
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

/// What one agent step spent waiting for the screen. A screen that never stops moving (a video playing, a live
/// feed) makes every `settled` run to its `most`, several times per step; after one such long wait the rest of
/// the step only waits a short cap. `AgentLoop.step` resets this per step.
@MainActor enum StepWaits {
    /// A wait allowed at least this long that still ended without a quiet gap marks the screen as moving.
    static let longWait = 3.0
    /// The most any later `settled` in the same step waits.
    static let movingCap = 0.8
    static var moving = false
    static var settle = 0.0  // s spent in `settled`
    static var snaps = 0  // snaps asked for
    static var replied = 0.0  // when the actor's last reply arrived (AgentLoop.ask), for Metrics.Step.leadMs
    static var record = 0.0  // s the steps list took to update (AgentLoop.record)
    static func reset() { moving = false; settle = 0; snaps = 0; replied = 0; record = 0 }
}

extension ScreenSource {
    var changed: Double { updated }
    var stale: Bool { false }
    func afterAction(since: Double, ignoring spots: [CGPoint]) async { await settled(ignoring: spots) }
    func freshFrame() async -> Bool? { nil }

    /// Wait until the screen stops changing. AirPlay keeps sending frames of a still screen (5 fps of tiny
    /// P-frames), so this watches when the image last changed, not when a frame last arrived: waiting on
    /// arrivals hit the `most` cap on every step (frame 4.0 s per step, 2026-10-19). Mid-animation frames are
    /// big and can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's lag.
    ///
    /// With `ignoring` (where the pointer was and went), frames that differ only there or in the status bar are
    /// still: after a tap the pointer fades for seconds, and a tap that changed nothing waited ~2.2 s (2026-11-06).
    ///
    /// Once a long wait in the step found no quiet gap, waits are capped at `StepWaits.movingCap` (see there).
    func settled(quiet: Double = 0.5, least: Double = 0.3, most: Double = 4, ignoring spots: [CGPoint] = []) async {
        let started = now(), cap = StepWaits.moving ? StepWaits.movingCap : most
        let (least, most) = (min(least, cap), min(most, cap))
        defer { StepWaits.settle += now() - started }
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        var still = frame, moved = changed, checked = changed  // moved: the last change that counts
        while !Task.isCancelled && now() - (spots.isEmpty ? changed : moved) < quiet + lag && now() - started < most {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !spots.isEmpty, changed > checked else { continue }
            checked = changed
            let (a, b) = (still, frame)
            if await Task.detached(priority: .userInitiated, operation: { Vision.changed(a, b, ignore: spots) }).value {
                still = b
                moved = checked
            }
        }
        if !Task.isCancelled, !StepWaits.moving, most >= StepWaits.longWait, now() - started >= most {
            StepWaits.moving = true
            DebugLog.write(String(format: "settle: no still moment in %.1f s; the screen keeps moving, later waits this step are capped at %.1f s", most, StepWaits.movingCap))
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

    /// After an action whose frame never came (the stream broke and the snap failed or was older too): the shown
    /// frame is stale, so the screen is not live until one captured after the action decodes. 2026-11-06: frames
    /// 5–14 minutes old went to the model, which then answered a listening exercise with the old matching pairs.
    private var staleBefore = 0.0
    private var lastVia = "", seqJumpsLogged = 0
    /// A seq gap: ask the board to go on from `resumeMs` (at most once a second). Set by the app.
    var onGap: (() -> Void)?
    private var lastGapAsk = 0.0

    /// A seq gap breaks the stream until the next IDR. 2026-11-06 (fw 0.2.3): gaps of ~65535 with no Wi-Fi loss,
    /// i.e. a chunk older than the last one: say which link each came over (BLE and Wi-Fi feed one assembler).
    private func noteSeqJump(from: UInt16?, to: UInt16?, via: String) {
        guard seqJumpsLogged < 200, let from, let to else { return }
        seqJumpsLogged += 1
        let back = to &- from >= 0x8000
        DebugLog.write("video: seq \(from) -> \(to) (\(back ? "back \(from &- to)" : "gap \(to &- from &- 1)")) via \(via), last via \(lastVia)")
    }
    var stale: Bool { capturedAt < staleBefore }
    var live: Bool { mirroring && !frozen && frame != nil && !stale && (device?.connected ?? false) }

    /// Frame width / height (portrait iPhone as a fallback).
    var aspect: Double { size.width > 0 && size.height > 0 ? size.width / size.height : 9 / 19.5 }

    /// Totals for the background summary: access units assembled, and frames shown after decoding.
    private(set) var unitsReceived = 0, framesShown = 0

    /// One video chunk, from BLE (BoardLink) or Wi-Fi (VideoStream): both feed the one assembler.
    func receive(_ chunk: Data, via: String = "ble") {
        metrics?.videoBytes(chunk.count)
        let dropsBefore = assembler.drops, lastSeq = assembler.lastSeq
        let unit = assembler.add(chunk)
        if assembler.drops > dropsBefore {
            metrics?.videoDrops(assembler.drops - dropsBefore)
            broken = true
            noteSeqJump(from: lastSeq, to: assembler.lastSeq, via: via)
            if now() - lastGapAsk > 1 { lastGapAsk = now(); onGap?() }
        }
        lastVia = via
        guard var unit else { return }
        unitsReceived += 1
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
    func resetStream() { assembler.reset(); clockOffset = nil; shownMs = nil }  // the board may have rebooted: its clock too

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

    /// Board time of the shown frame. A replay (the board resending its GOP from the IDR after a link switch, or
    /// the decoder's own after a lost session) is decoded to catch up but never shown: 2026-11-06 the model was
    /// handed the Screen Mirroring panel, Spotlight and a Home folder from minutes before, mid-lesson, and tapped
    /// Stop Mirroring. Snaps are exempt: the model only looks once the whole snap is decoded.
    private var shownMs: UInt32?
    /// When a replayed (hidden) frame last decoded: the board is resending its GOP and the stream is catching up.
    private var replayingAt = 0.0

    private func publish(_ f: H264Decoder.Frame) {
        guard f.unit.generation == generation else { return }
        if let shownMs, f.unit.boardMs > 0, !f.unit.snap, f.unit.boardMs < shownMs { replayingAt = now(); return }
        if f.unit.boardMs > 0 { shownMs = f.unit.boardMs }
        // A repeat of a still screen: a tiny P-frame (skipped blocks only) or the very same image.
        let tiny = !f.unit.data.isEmpty && !f.unit.idr && !f.unit.config && f.unit.data.count < Self.repeatBytes
        let repeated = tiny || f.jpeg == frame
        frame = f.jpeg
        framesShown += 1
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

    private var inStep: Bool { continuous() && mirroring && !broken && !frozen && frame != nil }

    /// The stream's next frame (a still screen still sends an IDR every ~2 s), else one real snap, even in step.
    func freshFrame() async -> Bool? {
        if streamOn && mirroring, await fresh(since: now(), timeout: 4) != nil, !broken { return true }
        do { try await snap(force: true) } catch { return false }
        return !frozen
    }

    /// Ask the board for the current GOP and wait until it is decoded. Returns the latency in ms. `force`: even when
    /// the stream is in step (where a snap is normally skipped).
    @discardableResult
    func snap(timeout: Double? = nil, decodeWait: Double = 1, force: Bool = false) async throws -> Double {
        try Task.checkCancellation()
        guard let device, device.connected else { throw DeviceError(message: "board not connected") }
        let started = now(), previousFrame = updated
        StepWaits.snaps += 1
        if inStep && !force {
            // Already in step: take a newer frame if the screen moves within a second, else the current one is it
            // (2026-10-20: a 14 s snap stalled calibration, a 24 s one the run start).
            _ = await fresh(since: started, timeout: 1)
            staleBefore = 0  // in step: the shown frame is the screen now, however long ago it last changed
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
    func afterAction(since: Double, ignoring spots: [CGPoint]) async {
        var snapped = false
        do {
            if FrameMode.current == .snap {
                try await Task.sleep(nanoseconds: 700_000_000)
                try await currentFrame()
                guard capturedAt < since else { return }
                DebugLog.write(String(format: "frame: snap ends %.1f s before the action; snapping again", since - capturedAt))
                try await Task.sleep(nanoseconds: 500_000_000)
                try await currentFrame()
            } else {
                await settled(ignoring: spots)
                if await newer(than: since, timeout: 1.5) { return }
                if frozen { return DebugLog.write("frame: none after the action; the board's video is frozen (no keyframe)") }
                guard broken || !streamOn else { return DebugLog.write("frame: none after the action; screen unchanged") }
                // the next IDR (~2 s) mends the stream; a snap meanwhile took 12–30 s and gave the board's old GOP
                if streamOn, await newer(than: since, timeout: 4) { return DebugLog.write("frame: stream mended by the next keyframe") }
                // a resend already under way: a snap would send the same GOP again, behind it (run 8, 2026-11-06:
                // snaps of 12-42 s while the stream replayed the GOP at 1.3 Mbps)
                if await caughtUp(since) { return DebugLog.write("frame: the board's resend caught up; no snap") }
                DebugLog.write("frame: stream stale (waiting for an IDR); snapping")
                snapped = !inStep  // a stream in step skips the snap: a still screen sends no new frame (2026-11-06:
                try await snap()   // marked stale anyway, recovery re-homed the pointer every 0.7 s for 4 minutes)
            }
        } catch {
            DebugLog.write("frame after action failed: \(error.localizedDescription)")
        }
        guard capturedAt < since else { return }
        DebugLog.write(String(format: "frame: still %.1f s older than the action", since - capturedAt))
        // a healthy stream sends nothing for a still screen: only a broken one (or a snap) proves the frame stale.
        // The snap clears `broken` but can still hand back the board's old GOP: 196 s old, a Screen Mirroring menu
        // long closed, was sent and tapped on (2026-11-06)
        if FrameMode.current == .snap || snapped || broken || frozen { staleBefore = since }
    }

    /// While the board's resend goes on (hidden frames still decoding): true once a frame from after `t` shows.
    private func caughtUp(_ t: Double) async -> Bool {
        while now() - replayingAt < 2 && !Task.isCancelled {
            if await newer(than: t, timeout: 1) { return true }
        }
        return false
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
        shownMs = nil  // a new link may be a rebooted board, its clock started over
        generation += 1  // a late decode from the old link must not make its stale image healthy again
    }
}

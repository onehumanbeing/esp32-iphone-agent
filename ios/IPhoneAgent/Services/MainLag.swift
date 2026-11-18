import Foundation

/// How long work handed to the main thread waits. Board replies arrive on the main queue (CoreBluetooth), so a
/// busy main thread shows up as slow commands: 2026-11-18, commands took 0.6-2.2 s for 20 s at a run's start and
/// the log could not tell the board from the phone. A wait over `limit` is logged (at most once a second).
final class MainLag: @unchecked Sendable {  // state confined to `queue`
    static let shared = MainLag()
    static let limit = 0.25
    private let queue = DispatchQueue(label: "main.lag", qos: .utility)
    private var timer: DispatchSourceTimer?, sampler: DispatchSourceTimer?
    private var waiting = false, lastLog = 0.0
    private let phaseLock = NSLock()
    private var phaseValue = "idle"
    /// What the run is doing now (AgentLoop sets it at each part of a step): a stall's line says during what.
    var phase: String {
        get { phaseLock.withLock { phaseValue } }
        set { phaseLock.withLock { phaseValue = newValue } }
    }

    private var stall: MainStall?
    private var sentAt = 0.0

    /// Call on the main thread (the sampler takes its thread from here).
    func start() {
        let stall = Thread.isMainThread ? MainStall() : nil
        queue.async { [self] in
            if self.stall == nil { self.stall = stall }
            if let stall, sampler == nil {
                let s = DispatchSource.makeTimerSource(queue: queue)
                s.schedule(deadline: .now() + 1, repeating: 0.02, leeway: .milliseconds(5))
                s.setEventHandler { [weak self] in
                    guard let self, self.waiting, CFAbsoluteTimeGetCurrent() - self.sentAt > Self.limit else { return }
                    stall.sample()
                }
                s.resume()
                sampler = s
            }
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 0.2, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.probe() }
            t.resume()
            timer = t
        }
    }

    private func probe() {
        guard !waiting else { return }  // one probe in flight: a stalled main thread is measured once, not piled on
        waiting = true
        let sent = CFAbsoluteTimeGetCurrent()
        sentAt = sent
        let during = phase
        DispatchQueue.main.async { [self] in
            let lag = CFAbsoluteTimeGetCurrent() - sent
            queue.async { [self] in
                waiting = false
                if let line = stall?.report(lag: lag), lag > 0.4 { DebugLog.write(line) }
                guard lag > Self.limit, sent - lastLog > 1 else { return }
                lastLog = sent
                DispatchQueue.main.async { DebugLog.write(String(format: "main thread: work waited %.0f ms (during %@, now %@)", lag * 1000, during, self.phase)) }
            }
        }
    }
}

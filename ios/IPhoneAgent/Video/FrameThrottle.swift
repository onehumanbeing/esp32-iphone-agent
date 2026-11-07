import Foundation

/// Upstream's leading + latest-frame policy, shared by both JPEG producers.
/// All methods and the output callback run on the supplied serial queue.
final class FrameThrottle<Frame>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interval: Double
    private let emit: (Frame) -> Void
    private var lastEmit = -Double.infinity
    private var held: Frame?
    private var flush: DispatchWorkItem?

    init(queue: DispatchQueue, interval: Double, emit: @escaping (Frame) -> Void) {
        self.queue = queue
        self.interval = interval
        self.emit = emit
    }

    func submit(_ frame: Frame) {
        held = frame
        let wait = lastEmit + interval - ProcessInfo.processInfo.systemUptime
        if wait <= 0 {
            flush?.cancel()
            emitLatest()
        } else if flush == nil {
            let work = DispatchWorkItem { [weak self] in self?.emitLatest() }
            flush = work
            queue.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// A stopped/unavailable source must not publish its pending image later.
    func reset() {
        flush?.cancel()
        flush = nil
        held = nil
        lastEmit = -Double.infinity
    }

    private func emitLatest() {
        flush = nil
        guard let frame = held else { return }
        held = nil
        lastEmit = ProcessInfo.processInfo.systemUptime
        emit(frame)
    }
}

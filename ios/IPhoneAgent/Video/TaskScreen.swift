import Combine
import Foundation

/// A stable screen for the pointer, agent and run recording. AppModel chooses its source.
@MainActor final class TaskScreen: ObservableObject, ScreenSource {
    private var source: ScreenSource
    private var frameSink: AnyCancellable?
    private let isConnected: () -> Bool
    @Published private(set) var frame: Data?
    // AgentLoop treats live as readiness to act, so losing the control link must still pause the run.
    var live: Bool { source.live && isConnected() }
    var updated: Double { source.updated }
    var changed: Double { source.changed }
    var capturedAt: Double { source.capturedAt }
    var aspect: Double { source.aspect }

    init(source: ScreenSource, frames: Published<Data?>.Publisher, isConnected: @escaping () -> Bool) {
        self.source = source
        self.isConnected = isConnected
        select(source, frames: frames)
    }

    /// Replace the source and subscription together. Published immediately supplies its current frame.
    func select(_ source: ScreenSource, frames: Published<Data?>.Publisher) {
        frameSink = nil
        self.source = source
        frameSink = frames.sink { [weak self] in self?.frame = $0 }
    }

    func afterAction(since: Double) async { await source.afterAction(since: since) }
    func checkAvailability() throws { try source.checkAvailability() }
}

import Combine
import Foundation

/// A stable screen for the pointer, agent and run recording. AppModel chooses its source: the AirPlay feed from the
/// board (VideoFeed), or on iOS 27+ the phone's own capture (ScreenCaptureFeed, ScreenSourceChoice).
@MainActor final class TaskScreen: ObservableObject, ScreenSource {
    private(set) var source: ScreenSource
    private var frameSink: AnyCancellable?
    @Published private(set) var frame: Data?
    var live: Bool { source.live }
    var stale: Bool { source.stale }
    var updated: Double { source.updated }
    var changed: Double { source.changed }
    var capturedAt: Double { source.capturedAt }
    var aspect: Double { source.aspect }
    var geometry: ScreenGeometry? { source.geometry }
    var behind: Bool { source.behind }

    init(source: ScreenSource, frames: Published<Data?>.Publisher) {
        self.source = source
        select(source, frames: frames)
    }

    /// Replace the source and subscription together. Published immediately supplies its current frame.
    func select(_ source: ScreenSource, frames: Published<Data?>.Publisher) {
        frameSink = nil
        self.source = source
        frameSink = frames.sink { [weak self] in self?.frame = $0 }
    }

    func afterAction(since: Double, ignoring spots: [CGPoint], busy: [CGRect]) async {
        await source.afterAction(since: since, ignoring: spots, busy: busy)
    }
    func freshFrame() async -> Bool? { await source.freshFrame() }
    func checkAvailability() throws { try source.checkAvailability() }
}

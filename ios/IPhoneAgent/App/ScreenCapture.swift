import Foundation

/// Screen Recording (iOS 27+, CaptureBackend.onDevice): the phone captures its own screen and the board only moves
/// the pointer. One sharing session per run, task demonstration or calibration: the system asks at its start, while
/// the app is in front, and it stops when that ends, so nothing is captured between runs.
extension AppModel {
    @available(iOS 27.0, *)
    var ownCapture: ScreenCaptureFeed? { ownCaptureSource as? ScreenCaptureFeed }

    /// Settings › Screen source. Only between runs; a phone or build without the support stays on AirPlay.
    func setCaptureBackend(_ backend: CaptureBackend) {
        guard !startingAgent, !agent.running, !recorder.busy, !calibrator.busy else { return }
        let chosen: CaptureBackend = CaptureBackend.onDeviceAvailable ? backend : .airPlay
        guard chosen != captureBackend else { return }
        captureBackend = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: CaptureBackend.key)
        DebugLog.write("capture: switched to \(chosen.rawValue)")
        if #available(iOS 27.0, *), onDeviceCapture, let ownCapture {
            screen.select(ownCapture, frames: ownCapture.$frame)
        } else {
            screen.select(feed, frames: feed.$frame)
        }
        board.commands.ownScreen = onDeviceCapture  // the StopWatch stops asking for Screen Mirroring
        prewarmJob?.cancel()
        let previous = screenCleanup
        screenCleanup = Task {
            await previous?.value
            await prewarmJob?.value
            await stopLocalCapture()
            if onDeviceCapture {
                wifiVideo.stop()
                if feed.streamOn { try? await feed.stream(false) }
            } else {
                updateWifiVideo()
                prewarmStream()
            }
        }
    }

    /// Start sharing for a run, a demonstration or a calibration: AirPlay's stream is let go first, then the system
    /// asks. Throws when the user cancels, the app is not in front, or no frame comes.
    func prepareLocalCapture() async throws {
        await screenCleanup?.value
        prewarmJob?.cancel()
        await prewarmJob?.value
        if feed.streamOn { try? await feed.stream(false) }  // any firmware; a board that is away does not block sharing
        if #available(iOS 27.0, *), onDeviceCapture, let ownCapture { try await ownCapture.start() }
    }

    func stopLocalCapture() async {
        if #available(iOS 27.0, *), let ownCapture { await ownCapture.stop() }
    }

    /// Stop the sharing after a run, queued so an old run's stop cannot end the next run's new session.
    func finishScreen() {
        let previous = screenCleanup
        screenCleanup = Task {
            await previous?.value
            await stopLocalCapture()
        }
    }

    /// The run no longer looks at the screen (it finished, or handed the phone back): AirPlay's stream goes off,
    /// Screen Recording's sharing stops.
    func releaseScreen() async {
        if onDeviceCapture { finishScreen() } else { try? await feed.stream(false) }
    }

    /// A current frame for a check outside the agent's steps (the keyboard handoff). The capture's latest frame is
    /// current once the screen is still (it sends only changes); AirPlay may need a fresh frame or a snap.
    func refreshScreen() async throws {
        if onDeviceCapture {
            await screen.settled(most: 1)
            try screen.checkAvailability()
        } else {
            _ = try await feed.currentFrame(maxAge: 0)
        }
    }
}

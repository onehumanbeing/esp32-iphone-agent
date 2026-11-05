import Foundation
import UIKit

/// Captures settled mirror frames, then creates an editable demonstration draft.
@MainActor final class DemoRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var inferring = false
    @Published private(set) var stopping = false
    @Published private(set) var keyframes = 0
    @Published private(set) var started = Date()
    @Published private(set) var countdownEnds: Date?  // leaving the app while the island counts down; nothing is captured yet
    @Published var error: String?
    private unowned let app: AppModel
    private var folder: URL?
    private var loop: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var bytes = 0
    private var startedAt = 0.0  // now() when capture began: frames captured before it are from the setup
    private var inference: Task<String, Error>?
    static let maxFrames = 12
    static let captureLimit = 120
    /// One countdown from the tap: long enough for the app to leave and the Home Screen to settle.
    static let countdown: TimeInterval = 5
    var busy: Bool { recording || inferring || stopping }
    var canRetry: Bool { !busy && folder != nil && keyframes > 0 }
    var hasDraft: Bool { folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("review.json").path) } ?? false }

    init(app: AppModel) {
        self.app = app
        // UI tests start from no unfinished demo recording (an earlier test may have left one)
        if MockMode.on && ProcessInfo.processInfo.arguments.contains("-freshRecordings") {
            try? FileManager.default.removeItem(at: Self.pendingURL)
        }
        if let name = try? String(contentsOf: Self.pendingURL, encoding: .utf8),
           !name.isEmpty, !name.contains("/"), !name.contains("..") {
            folder = Self.root.appendingPathComponent(name)
            keyframes = capturedFrames.count
            if keyframes > 0 { error = String(localized: "An unfinished recording is ready to retry.") }
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(MockMode.on ? "demo-recordings" : "recordings")
    }
    private static var pendingURL: URL { root.appendingPathComponent("pending.txt") }
    private var capturedFrames: [URL] {
        guard let folder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func start() -> Bool {
        guard !busy, !canRetry, !app.agent.running, !app.startingAgent else { return false }
        guard MockMode.on || (app.board.connected && (app.onDeviceCapture || app.board.status?.ap == "streaming") && app.modelReady) else {
            error = String(localized: "Connect the board, start Screen Mirroring, and set up a model first.")
            return false
        }
        let dir = Self.root.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try dir.lastPathComponent.write(to: Self.pendingURL, atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription; return false }
        folder = dir
        keyframes = 0
        bytes = 0
        error = nil
        started = Date()
        countdownEnds = started.addingTimeInterval(Self.countdown)
        recording = true
        background = UIApplication.shared.beginBackgroundTask(withName: "demonstration") { [weak self] in
            guard let self else { return }
            self.loop?.cancel()
            self.endBackground()
            Task { await self.interrupt(String(localized: "Recording paused because background time ended. Return to the app to create your draft.")) }
        }
        // A Live Activity can only be started in the foreground, so the countdown phase starts it here.
        app.live.start(task: String(localized: "Recording a demonstration"), runID: "rec-" + dir.lastPathComponent,
                       limit: Self.captureLimit, phase: .countdown, since: countdownEnds ?? started)
        app.runMood = .listening
        loop = Task { [weak self] in await self?.capture() }
        return true
    }

    private func capture() async {
        do {
            if !MockMode.on {
                await app.screenCleanup?.value
                if app.onDeviceCapture { try await app.prepareLocalCapture() }
                else { try await app.feed.stream(true) }
                try await leaveApp()
            }
            try await countDown()
            var last: Data?
            var staleSince = now()
            while recording && !Task.isCancelled {
                if !MockMode.on && (!app.board.connected || !app.onDeviceCapture && app.board.status?.ap != "streaming") {
                    throw DeviceError(message: String(localized: "Screen Mirroring disconnected. Captured screens are kept for retry."))
                }
                if !MockMode.on { try app.screen.checkAvailability() }
                if Date().timeIntervalSince(started) >= 600 || keyframes >= Self.captureLimit || bytes >= 30_000_000 {
                    Task { await self.stop() }
                    return
                }
                let frame = MockMode.on ? AppModel.mockFrame : freshFrame()
                if frame == nil, !MockMode.on, now() - staleSince > 2 {
                    await requestFrame()
                    staleSince = now()
                }
                if let frame, MockMode.on || Vision.changed(last, frame) {
                    if !MockMode.on { await app.screen.settled() }
                    try Task.checkCancellation()
                    guard recording else { return }
                    let settled = MockMode.on ? frame : (freshFrame() ?? frame)
                    try save(settled)
                    last = settled
                }
                if frame != nil { staleSince = now() }
                try await Task.sleep(nanoseconds: MockMode.on ? 1_500_000_000 : 400_000_000)
            }
        } catch is CancellationError {
            // Stop/cancel already owns cleanup. Dismissing the system picker does not cancel this task.
            if !Task.isCancelled { Task { await self.cancel() } }
            return
        } catch {
            // Let this capture task return before cleanup awaits it.
            let message = error.localizedDescription
            Task { await self.interrupt(message) }
        }
    }

    /// The user does the task on the Home Screen, so the app gets out of the way first, as for a run.
    private func leaveApp() async throws {
        guard !app.appIsBackgrounded else { return }
        #if !DEBUG
        try? await app.pointer.aimHomeBar()
        #endif
        var away = try await app.leaveApp()
        if !away { away = try await app.askUserToLeave() }
        try Task.checkCancellation()
        guard away else { throw DeviceError(message: String(localized: "Go to the Home Screen to start recording.")) }
    }

    /// The rest of the countdown that began at the tap (the system runs the island's timer), then the recording
    /// starts. Leaving the app takes part of it; one countdown, not a second 3-2-1 once away.
    private func countDown() async throws {
        let ends = countdownEnds ?? Date()
        let left = ends.timeIntervalSinceNow
        DebugLog.write(String(format: "recording: away, %.1f s of the countdown left", max(left, 0)))
        if left > 0 { try await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
        countdownEnds = nil
        started = Date()
        startedAt = now()
        app.live.update(mood: .listening, step: 0, line: String(localized: "Do the task yourself. I'm watching."),
                        phase: .recording, status: .watching, since: started)
        DebugLog.write("recording: started")
    }

    /// The shown frame, only if captured after the recording began: the feed still holds the last screen from the
    /// setup (Control Center, this app), and a broken stream keeps showing it until the next IDR.
    private func freshFrame() -> Data? {
        let feed = app.screen
        let at = feed.capturedAt > 0 ? feed.capturedAt : feed.updated
        return at >= startedAt ? feed.frame : nil
    }

    /// No frame since the recording began: the stream may be waiting for an IDR (a decode error, chunks lost),
    /// so ask the board for one, as a run does after an action.
    private func requestFrame() async {
        guard !app.onDeviceCapture else { return }
        let feed = app.feed
        let at = feed.capturedAt > 0 ? feed.capturedAt : feed.updated
        DebugLog.write(String(format: "recording: no new screen for 2 s (newest %.1f s before the start, broken %@); snapping",
                              startedAt - at, feed.broken ? "true" : "false"))
        do { _ = try await feed.snap() } catch { DebugLog.write("recording: snap failed: \(error.localizedDescription)") }
    }

    private func save(_ jpeg: Data) throws {
        guard let folder else { return }
        try jpeg.write(to: folder.appendingPathComponent(String(format: "k%03d.jpg", keyframes + 1)), options: .atomic)
        keyframes += 1
        bytes += jpeg.count
        app.live.update(mood: .listening, step: keyframes,
                        line: String(localized: "\(keyframes) screens captured. Stop when you're done."), phase: .recording)
    }

    private func endBackground() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    private func finishCapture() async {
        recording = false
        countdownEnds = nil
        loop?.cancel()
        await loop?.value
        loop = nil
        if !MockMode.on {
            await app.stopLocalCapture()
            do { if !app.onDeviceCapture { try await app.feed.stream(false) } }
            catch { self.error = error.localizedDescription }
        }
        app.live.end(nil)
        app.runMood = nil
        endBackground()
    }

    private func interrupt(_ message: String) async {
        guard recording, !stopping else { return }
        stopping = true
        await finishCapture()
        error = message
        stopping = false
    }

    func cancel() async {
        guard !stopping, !inferring else { return }
        stopping = true
        error = nil
        await finishCapture()
        guard error == nil else { stopping = false; return }
        // Keep captured files; only clear the recovery pointer when explicitly discarded.
        do { try "".write(to: Self.pendingURL, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription; stopping = false; return }
        folder = nil
        keyframes = 0
        error = nil
        stopping = false
    }

    func stop() async {
        guard recording, !stopping else { return }
        if countdownEnds != nil { return await cancel() }  // nothing captured yet
        stopping = true
        error = nil
        await finishCapture()
        stopping = false
        guard error == nil else { return }
        await retry()
    }

    func retry() async {
        guard !busy, !app.agent.running, !app.startingAgent, let folder else { return }
        if hasDraft {
            app.review = ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil,
                                     steps: [], name: "", prompt: "")
            return
        }
        inferring = true
        error = nil
        background = UIApplication.shared.beginBackgroundTask(withName: "infer-demonstration") { [weak self] in
            self?.inference?.cancel()
            self?.endBackground()
        }
        defer { inferring = false; app.runMood = nil; inference = nil; endBackground() }
        let picked = Self.sample(capturedFrames, Self.maxFrames)
        guard picked.count >= 2 else {
            error = String(localized: "Capture at least two screens before creating an intent.")
            return
        }
        do {
            let task = Task {
                let reply = MockMode.on ? try await Self.mockReply() : try await self.infer(picked)
                try Task.checkCancellation()
                return reply
            }
            inference = task
            let reply = try await task.value
            try Task.checkCancellation()
            let draft = Self.draft(reply, frames: picked, folder: folder)
            guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.steps.contains(where: { $0.name != "note" }) else {
                throw DeviceError(message: String(localized: "The model returned no usable steps. Retry with the captured screens."))
            }
            try draft.persistEdits()
            error = String(localized: "Your recording draft is ready to review.")
            app.notifier.post(.done, title: String(localized: "Intent draft ready"),
                              body: String(localized: "\(draft.steps.count) steps. Check the yellow ones."),
                              run: "rec-" + folder.lastPathComponent)
            app.review = draft
        } catch { self.error = error.localizedDescription }
    }

    func markSaved(_ draft: ReviewDraft) {
        guard let folder, folder == draft.folder else { return }
        do {
            try "".write(to: Self.pendingURL, atomically: true, encoding: .utf8)
            self.folder = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func infer(_ frames: [URL]) async throws -> String {
        let images = try frames.map { try Data(contentsOf: $0) }
        let r = try await app.settings.client("planner").chat(system: Self.inferPrompt, text:
            "These are \(images.count) keyframes in order (frame 1 first). Infer the steps.",
            images: images, maxTokens: 1200, temperature: 0)
        return r.text
    }

    static func sample(_ frames: [URL], _ n: Int) -> [URL] {
        guard n > 0 else { return [] }
        guard n > 1 else { return Array(frames.prefix(1)) }
        guard frames.count > n else { return frames }
        return (0..<n).map { frames[$0 * (frames.count - 1) / (n - 1)] }
    }

    static let inferPrompt = """
    You watch keyframes of a person using an iPhone, in order. Fingers are not visible: infer each action \
    from how the screen changed between two frames. Coordinates are 0-1000 of the screen width and height. \
    Reply in this format only:
    NAME: <short name for the task>
    PROMPT: <one instruction that would make an AI agent repeat this task>
    STEP <frame number the action was done on>: <command> | sure or unsure
    Commands: tap X Y, swipe X1 Y1 X2 Y2, type "text", home, back, wait, ai "what to achieve", read "what".
    Use tap / swipe / type for controls that stay in the same place every time. When a step depends on what     the screen shows this time (a search result, an item in a list that changes, a message), write     ai "what to achieve" instead, e.g. ai "open the newest video in the list". When the person was reading or     collecting information off the screen, write read "what", e.g. read "video titles".
    """

    /// Parses the model's reply into a draft (unparseable or "unsure" steps are marked uncertain).
    static func draft(_ reply: String, frames: [URL], folder: URL) -> ReviewDraft {
        var name = "", prompt = "", steps: [DraftStep] = []
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("NAME:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.uppercased().hasPrefix("PROMPT:") { prompt = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard line.uppercased().hasPrefix("STEP"), let colon = line.firstIndex(of: ":") else { continue }
            let n = Int(line[line.index(line.startIndex, offsetBy: 4)..<colon].trimmingCharacters(in: .whitespaces)) ?? 0
            let parts = line[line.index(after: colon)...].split(separator: "|", maxSplits: 1)
            let command = parts.first.map(String.init) ?? ""
            let sure = parts.count > 1 && parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "sure"
            let validFrame = n > 0 && n <= frames.count
            let action = Self.parseDemonstratedAction(command) ?? ["action": .str("note"), "text": .str(command)]
            steps.append(DraftStep(action: action, frame: validFrame ? frames[n - 1] : nil,
                                   uncertain: !sure || !validFrame || action["action"]?.str == "note"))
        }
        return ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil, steps: steps, name: name,
                           prompt: prompt, icon: "record.circle")
    }

    /// Only the documented demonstration commands are accepted; malformed actions stay editable notes.
    static func parseDemonstratedAction(_ command: String) -> JObject? {
        let tokens = command.split(whereSeparator: \.isWhitespace)
        guard let head = tokens.first?.lowercased() else { return nil }
        switch head {
        case "tap", "swipe":
            guard tokens.count == (head == "tap" ? 3 : 5), tokens.dropFirst().allSatisfy({
                guard let number = Double($0) else { return false }
                return number.isFinite && (0...1000).contains(number)
            }) else { return nil }
        case "type": guard tokens.count > 1 else { return nil }
        case "home", "back", "wait": guard tokens.count == 1 else { return nil }
        case "ai", "read":  // script steps (ScriptRunner): the rest of the line is the goal / what to read
            let rest = command.trimmingCharacters(in: .whitespaces).drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !rest.isEmpty else { return nil }
            return ["action": .str(head), (head == "ai" ? "goal" : "what"): .str(rest)]
        default: return nil
        }
        return try? Actions.parseCommand(command)
    }

    private static func mockReply() async throws -> String {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return """
        NAME: Daily 7 AM alarm
        PROMPT: Open Clock, add an alarm for 7:00 AM that repeats every day, then save it
        STEP 1: tap 500 814 | sure
        STEP 2: type "Clock" | sure
        STEP 3: tap 152 212 | sure
        STEP 4: tap 905 88 | unsure
        STEP 5: swipe 397 300 397 200 | unsure
        STEP 6: tap 150 395 | sure
        """
    }
}

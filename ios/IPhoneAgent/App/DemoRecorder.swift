import Combine
import Foundation
import UIKit

/// Captures settled mirror frames into a run folder (Documents/traces/<id>), names the action of every change
/// as it goes (DemoAnalysis), and writes the result as a run: listed in Runs, reviewed like one, saved as an
/// intent and continued from where the person stopped (Henry 2026-11-12: a recording must be a run).
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
    private var windows: [Int: Task<String, Error>] = [:]  // DemoAnalysis calls by first screen (0-based)
    private var nextWindow = 0, analysing = 0
    private var videoSink: AnyCancellable?
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
            let run = app.traces.root.appendingPathComponent(name)
            folder = FileManager.default.fileExists(atPath: run.path) ? run : Self.root.appendingPathComponent(name)
            keyframes = capturedFrames.count
            if keyframes > 0 { error = String(localized: "An unfinished recording is ready to retry.") }
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(MockMode.on ? "demo-recordings" : "recordings")
    }
    private static var pendingURL: URL {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("pending.txt")
    }
    private var capturedFrames: [URL] {
        guard let folder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func start() -> Bool {
        guard !busy, !canRetry, !app.agent.running, !app.startingAgent else { return false }
        guard MockMode.on || (app.board.connected && app.board.status?.ap == "streaming" && app.modelReady) else {
            error = String(localized: "Connect the board, start Screen Mirroring, and set up a model first.")
            return false
        }
        let dir = app.traces.root.appendingPathComponent(TraceStore.folderName())
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try dir.lastPathComponent.write(to: Self.pendingURL, atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription; return false }
        folder = dir
        keyframes = 0
        bytes = 0
        (windows, nextWindow, analysing) = ([:], 0, 0)
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
                try await app.feed.stream(true)
                try await leaveApp()
            }
            try await countDown()
            var last: Data?
            var staleSince = now()
            while recording && !Task.isCancelled {
                if !MockMode.on && (!app.board.connected || app.board.status?.ap != "streaming") {
                    throw DeviceError(message: String(localized: "Screen Mirroring disconnected. Captured screens are kept for retry."))
                }
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
                    if !MockMode.on { await app.feed.settled() }
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
        startVideo()
    }

    /// The shown frame, only if captured after the recording began: the feed still holds the last screen from the
    /// setup (Control Center, this app), and a broken stream keeps showing it until the next IDR.
    private func freshFrame() -> Data? {
        let feed = app.feed
        let at = feed.capturedAt > 0 ? feed.capturedAt : feed.updated
        return at >= startedAt ? feed.frame : nil
    }

    /// No frame since the recording began: the stream may be waiting for an IDR (a decode error, chunks lost),
    /// so ask the board for one, as a run does after an action.
    private func requestFrame() async {
        let feed = app.feed
        let at = feed.capturedAt > 0 ? feed.capturedAt : feed.updated
        DebugLog.write(String(format: "recording: no new screen for 2 s (newest %.1f s before the start, broken %@); snapping",
                              startedAt - at, feed.broken ? "true" : "false"))
        do { _ = try await feed.snap() } catch { DebugLog.write("recording: snap failed: \(error.localizedDescription)") }
    }

    /// The mirror at ~2 fps in video/, like a run's, so the review shows what happened between the screens.
    private func startVideo() {
        guard !MockMode.on, let dir = folder?.appendingPathComponent("video") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        videoSink = app.feed.$frame.compactMap { $0 }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { jpeg in try? jpeg.write(to: dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jpg")) }
    }

    private func save(_ jpeg: Data) throws {
        guard let folder else { return }
        let name = String(format: "k%03d.jpg", keyframes + 1)
        try jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)
        Self.append("\(name) \(now())\n", to: folder.appendingPathComponent("keyframes.txt"))
        keyframes += 1
        analyseWhileRecording()
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
        videoSink = nil
        countdownEnds = nil
        loop?.cancel()
        await loop?.value
        loop = nil
        if !MockMode.on {
            do { try await app.feed.stream(false) }
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
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("steps.jsonl").path) {
                app.openReview(run: folder.lastPathComponent)
            } else {  // a recording from before they were runs
                app.review = ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil,
                                         steps: [], name: "", prompt: "")
            }
            return
        }
        inferring = true
        error = nil
        background = UIApplication.shared.beginBackgroundTask(withName: "infer-demonstration") { [weak self] in
            self?.inference?.cancel()
            self?.endBackground()
        }
        defer { inferring = false; app.runMood = nil; inference = nil; endBackground() }
        let frames = capturedFrames
        guard frames.count >= 2 else {
            error = String(localized: "Capture at least two screens before creating an intent.")
            return
        }
        do {
            let task = Task {
                let reply = MockMode.on ? try await Self.mockReply() : try await self.analyse(frames)
                try Task.checkCancellation()
                return reply
            }
            inference = task
            let reply = try await task.value
            try Task.checkCancellation()
            let draft = Self.draft(reply, frames: frames, folder: folder)
            guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.steps.contains(where: { $0.name != "note" }) else {
                throw DeviceError(message: String(localized: "The model returned no usable steps. Retry with the captured screens."))
            }
            let review = try writeRun(draft, folder: folder)
            error = String(localized: "Your recording draft is ready to review.")
            app.notifier.post(.done, title: String(localized: "Intent draft ready"),
                              body: String(localized: "\(review.steps.count) steps. Check the yellow ones."),
                              run: folder.lastPathComponent)
            app.review = review
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

    // MARK: - analysis (DemoAnalysis) and the run it becomes

    /// While recording: each full window of screens is named in the background, at most two calls at a time.
    private func analyseWhileRecording() {
        guard !MockMode.on, analysing < 2, nextWindow + DemoAnalysis.window < keyframes else { return }
        let start = nextWindow
        nextWindow += DemoAnalysis.window
        windows[start] = window(start, Array(capturedFrames[start...(start + DemoAnalysis.window)]))
    }

    private func window(_ start: Int, _ screens: [URL]) -> Task<String, Error> {
        analysing += 1
        return Task { [weak self] in
            defer { Task { @MainActor in self?.analysing -= 1; self?.analyseWhileRecording() } }
            guard let self else { throw CancellationError() }
            let saved = screens[0].deletingLastPathComponent().appendingPathComponent("analysis-\(start).txt")
            if let text = try? String(contentsOf: saved, encoding: .utf8) { return text }  // a retry after a relaunch
            let model = try await self.app.settings.client("planner")
            let text = try await DemoAnalysis.ask(model, screens: try screens.map { try Data(contentsOf: $0) }, first: start + 1)
            try? text.write(to: saved, atomically: true, encoding: .utf8)
            DebugLog.write("recording: changes \(start + 1)-\(start + screens.count - 1) named")
            return text
        }
    }

    /// Every change named (the windows started while recording, the rest now), then the task's name and prompt.
    private func analyse(_ frames: [URL]) async throws -> String {
        var steps: [String] = []
        for start in stride(from: 0, to: frames.count - 1, by: DemoAnalysis.window) {
            let end = min(start + DemoAnalysis.window, frames.count - 1)
            let job = windows[start] ?? window(start, Array(frames[start...end]))
            windows[start] = job
            steps += try await job.value.split(separator: "\n").map(String.init)
                .filter { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("STEP") }
        }
        let summary = try await DemoAnalysis.summarize(try await app.settings.client("planner"), steps: steps)
        return summary + "\n" + steps.joined(separator: "\n")
    }

    /// The draft written as the run in its folder: a task row, one step per action on the screen it was done on
    /// (when it was captured), and `stopped`, so Runs lists it and Continue goes on from it.
    private func writeRun(_ draft: ReviewDraft, folder: URL) throws -> ReviewDraft {
        let times = Self.keyframeTimes(folder)
        let trace = TraceStore(root: folder.deletingLastPathComponent())
        trace.open(folder)
        trace.write(kind: "task", ["task": .str(draft.prompt), "demo": .bool(true)])
        var last = times.values.max() ?? now()
        for step in draft.steps {
            var row = step.action.merging(["changed": .bool(true), "demo": .bool(true), "sure": .bool(!step.uncertain)])
            if let frame = step.frame?.lastPathComponent {
                row["frame"] = .str(frame)
                if let t = times[frame] { row["t"] = .num(t); last = t }
            }
            trace.write(kind: "step", row)
        }
        trace.write(kind: "step", ["action": .str("stopped"), "demo": .bool(true), "t": .num(last)])
        app.runs.reload()
        guard let run = RunStore.load(folder) else { throw DeviceError(message: "the recording could not be read back") }
        let review = ReviewDraft(run: run)
        (review.name, review.prompt, review.icon) = (draft.name, draft.prompt, "record.circle")
        try review.persistEdits()
        return review
    }

    static func keyframeTimes(_ folder: URL) -> [String: Double] {
        let text = (try? String(contentsOf: folder.appendingPathComponent("keyframes.txt"), encoding: .utf8)) ?? ""
        return Dictionary(text.split(separator: "\n").compactMap { line -> (String, Double)? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let t = Double(parts[1]) else { return nil }
            return (String(parts[0]), t)
        }, uniquingKeysWith: { $1 })
    }

    private static func append(_ text: String, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

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

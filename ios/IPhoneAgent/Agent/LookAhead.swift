import Foundation

/// The shrunk model image (and, when the on-device tree is on, the tree) for a frame, built off the main thread
/// while the step is still deciding whether the screen changed. Reused only when the next look sends that frame.
/// 2026-11-18 (Meituan run): the tree took 5.1 s (p50) and held every look. A new frame never stopped the read of
/// the one before (up to four ran at once), and 14 of 21 looks sent a newer frame than the prepared one, so the
/// tree was built again while the look waited. Now: a new frame cancels the old work, a look sends the prepared
/// frame when the screen has not changed since (AgentLoop.ask), and waits for its tree at most `treeWait`.
@MainActor final class FramePrep {
    struct Ready {
        var token: Int
        var image: Data
        var tree: UITree?
        var imageMs: Double
        var treeMs: Double
        var treeLate = false  // not built within treeWait: the look went without it
    }

    /// The longest a look waits for the tree of its frame (initial estimate; tuned from the `tree late` log lines).
    static let treeWait = 1.2

    private var imageTask: Task<(Data, Double), Never>?
    private var treeTask: Task<(UITree?, Double), Never>?
    private var token: Int?
    /// The frame being prepared (or prepared): a look may send it instead of a newer copy of the same screen.
    private(set) var frame: Data?

    static func token(for jpeg: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(jpeg.count)
        hasher.combine(jpeg.prefix(64))
        hasher.combine(jpeg.suffix(64))
        return hasher.finalize()
    }

    /// Starts preparing `jpeg` unless it is the frame already in hand; a different frame cancels the earlier work.
    func start(_ jpeg: Data, wantTree: Bool) {
        let token = Self.token(for: jpeg)
        if token == self.token, treeTask != nil || !wantTree { return }
        imageTask?.cancel()
        treeTask?.cancel()
        (self.token, frame) = (token, jpeg)
        let image = Task.detached(priority: .userInitiated) { () -> (Data, Double) in
            let started = now()
            let data = ModelImage.forModel(jpeg)
            return (data, (now() - started) * 1000)
        }
        imageTask = image
        treeTask = wantTree ? Task.detached(priority: .userInitiated) { () -> (UITree?, Double) in
            let (data, _) = await image.value
            guard !Task.isCancelled else { return (nil, 0) }
            let started = now()
            let tree = await UITree.build(jpeg: data)
            return (Task.isCancelled ? nil : tree, (now() - started) * 1000)
        } : nil
    }

    /// The prepared copy when `jpeg` is the frame that was started, else nil. The tree is waited for `treeWait`
    /// at most; a late one keeps building (a retry on the same frame gets it) until a new frame cancels it.
    func take(_ jpeg: Data, wantTree: Bool, treeWait: Double = FramePrep.treeWait) async -> Ready? {
        let token = Self.token(for: jpeg)
        guard token == self.token, let imageTask else { return nil }
        let (image, imageMs) = await imageTask.value
        var ready = Ready(token: token, image: image, tree: nil, imageMs: imageMs, treeMs: 0)
        guard wantTree, let treeTask else { return ready }
        let waited = now()
        if let (tree, ms) = await Self.value(of: treeTask, within: treeWait) {
            (ready.tree, ready.treeMs) = (tree, ms)
        } else {
            ready.treeLate = true
            ready.treeMs = (now() - waited) * 1000
        }
        return ready
    }

    /// `task`'s value, or nil when it is not there within `seconds` (the task itself goes on).
    nonisolated static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let once = Vision.Once()
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            Task.detached { let value = await task.value; if once.take() { done.resume(returning: value) } }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                if once.take() { done.resume(returning: nil) }
            }
        }
    }
}

extension AgentLoop {
    struct PendingLook {
        var prompt: String
        var task: Task<(String, Double, Data?), Error>
    }

    /// The actor's user prompt, without taking queued steering. Speculative and the real look must match.
    func actorUserPrompt() -> String {
        let hidden: Set<String> = ["t", "plan", "plan_zh", "think_s", "act_s", "shot", "thought", "thought_zh", "changed",
                                   "replay", "jev", "planner", "landed", "opened", "typed", "again", "demo", "sure", "cached",
                                   "timing", "repaired", "stale", "recorded"]
        let history = steps.suffix(8).filter {
            $0["plan"] == nil && $0["action"]?.str != Self.steerAction && $0["action"]?.str != Self.checkpointAction
        }.map { s -> String in
            String(PyJSON.dumps(s.without(hidden)).prefix(300)) + Self.effect(s)
        }.joined(separator: "\n")
        let older = steps.dropLast(8).filter { $0["action"]?.str == "confirmed" }.suffix(3)  // the user's yes stays in view
        let pinned = older.isEmpty ? "" : "\n\nThe user confirmed earlier (still holds):\n"
            + older.map { "- " + ($0["reason"]?.str ?? "") }.joined(separator: "\n")
        let collected = (notebook.isEmpty ? "" : "\n\n" + notebook.summary())  // looked-up text and files show without notes too
            + (lookedUp.isEmpty ? "" : "\n\nLooked up:\n" + lookedUp.suffix(3).joined(separator: "\n\n"))
            + (fileView.map { "\n\nYour files:\n" + $0 } ?? "")
        let guide = guided.map { "\n\nGuide for \($0.names.joined(separator: " / ")):\n" + ($0.text ?? "") }.joined()
        let sound = heard?() ?? ""
        return "Goal: \(task)\(steeredSection)\(guide)\n\nPlan:\n\(plan.isEmpty ? "(none yet: write one)" : plan)\n\nRecent actions:\n"
            + (history.isEmpty ? "(none)" : history) + pinned + collected + (sound.isEmpty ? "" : "\n\n" + sound)
            + (steps.last?["stale"] == .bool(true) ? Self.staleNote : "")  // iPad only: no frame after the last action
            + (handedBack ? HandBack.note(saved: savedInRunFolder()) : "")
            + recordHint
            + "\n\n" + Self.replyFormat
    }

    /// RECORD is on and no each ran lately: say next to the reply that a list goes through each (2026-11-19: a resumed
    /// run opened orders one tap at a time; the rule alone, 14k characters up, was not followed).
    var recordHint: String {
        guard reader != nil, !recordFields.isEmpty else { return "" }
        if let old = recorder.beforeStart {
            return "\n\nThe reader saw \"\(old.prefix(80))\", older than the goal's dates" + NoteCheck.pastStart + "."
                + (steps.suffix(8).contains(where: { $0["action"]?.str == "each" }) ? "" : Self.eachLine)
        }
        guard !steps.suffix(8).contains(where: { $0["action"]?.str == "each" }) else { return "" }
        return Self.eachLine
    }

    static let eachLine = "\n\nRECORD is on: on a list of items, give each \"ANCHOR\" [open \"X\"] as the only DO line "
        + "(no read \"WHAT\"), not one tap per item; the reader copies the RECORD facts off every item it opens."

    /// The prompt's last line: the reply format, next to where the reply starts (the system prompt's is 14k characters
    /// away; 2026-11-17: 16% of replies were JSON, tool calls or a description of the screen).
    static let replyFormat = "Next action? Reply with THINK: (PLAN: only when it changes) and DO: lines, nothing else."

    /// Shorter quiet window before a speculative look. Initial estimates, under the normal settle.
    static let earlyQuiet = 0.25, earlyLeast = 0.15

    var canSpeculate: Bool {
        speculate && !inventory.needed && FrameMode.current != .snap && !StepWaits.moving && !roundDroppedByPause
            && !JevGate.hold && steering.isEmpty && !connectionChanged(since: acceptedLookLinks)
            && (checkpointModel == nil || checkpoints.reason(steps) == nil)
    }

    func prepareFrame(_ jpeg: Data?) {
        guard let jpeg else { return }
        framePrep.start(jpeg, wantTree: screenTree && !serverTree)
    }

    func startSpeculative() {
        guard let actor, pendingLook == nil else { return }
        let prompt = actorUserPrompt()
        let task = Task { @MainActor in try await self.ask("actor", actor, self.actorPrompt, prompt) }
        pendingLook = PendingLook(prompt: prompt, task: task)
    }

    func cancelSpeculative(_ reason: String) {
        guard let pending = pendingLook else { return }
        pending.task.cancel()
        pendingLook = nil
        specCancelled = true
        trace?.write(kind: "llm_cancelled", ["reason": .str(reason)])
        DebugLog.write("speculative look cancelled: \(reason)")
    }

    /// The in-flight look when the prompt is still the one it was built from and the screen has not moved.
    func takeSpeculative(_ prompt: String) async throws -> [Planned]? {
        guard let pending = pendingLook else { return nil }
        pendingLook = nil
        guard pending.prompt == prompt else {
            pending.task.cancel()
            specCancelled = true
            trace?.write(kind: "llm_cancelled", ["reason": .str("prompt changed")])
            return nil
        }
        var text: String, seconds: Double, frame: Data?
        do { (text, seconds, frame) = try await pending.task.value }
        catch {
            if !(error is CancellationError) { DebugLog.write("speculative look dropped: \(error.localizedDescription)") }
            return nil
        }
        let pointer = pointerAt
        if let frame, let nowFrame = screen?.frame,
           await Vision.off({ Vision.changed(frame, nowFrame, ignore: [pointer]) }) {
            specCancelled = true
            trace?.write(kind: "llm_cancelled", ["reason": .str("screen moved")])
            return nil
        }
        var acts: [JObject]
        do { acts = try Actions.parseActions(text) } catch { return nil }
        guard !acts.isEmpty else { return nil }
        if !inPart, let checked = try await confirmDone(acts, prompt),
           let theirs = try? Actions.parseActions(checked.0) {
            (text, seconds, frame, acts) = (checked.0, seconds + checked.1, checked.2 ?? frame, theirs)
            guard !acts.isEmpty else { return nil }
        }
        if let new = Actions.planBlock(text), new != plan {
            plan = new
            record(frame, ["action": .str("plan"), "plan": .str(new), "plan_zh": .str(new)])
        }
        acts[0]["think_s"] = .num(seconds)
        if lastServed == "handsy-jev" { acts[0]["jev"] = .bool(true) }
        specUsed = true
        DebugLog.write("speculative look used")
        return acts.map { Planned(act: $0, shot: frame, speculative: true) }
    }
}

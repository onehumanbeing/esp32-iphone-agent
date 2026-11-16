import Foundation

/// The shrunk model image (and, when the on-device tree is on, the tree) for a frame, built while the
/// step is still deciding whether the screen changed. Reused only when the next look sends that same frame.
@MainActor final class FramePrep {
    struct Ready {
        var token: Int
        var image: Data
        var tree: UITree?
        var imageMs: Double
        var treeMs: Double
    }

    private var task: Task<Ready, Never>?
    private var token: Int?

    static func token(for jpeg: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(jpeg.count)
        hasher.combine(jpeg.prefix(64))
        hasher.combine(jpeg.suffix(64))
        return hasher.finalize()
    }

    func start(_ jpeg: Data, wantTree: Bool) {
        let token = Self.token(for: jpeg)
        self.token = token
        let copy = jpeg
        task = Task {
            let started = now()
            let image = ModelImage.forModel(copy)
            let imageMs = (now() - started) * 1000
            var tree: UITree?
            var treeMs = 0.0
            if wantTree, !Task.isCancelled {
                let treeStarted = now()
                tree = await UITree.build(jpeg: image)
                treeMs = (now() - treeStarted) * 1000
            }
            return Ready(token: token, image: image, tree: tree, imageMs: imageMs, treeMs: treeMs)
        }
    }

    /// The prepared copy when `jpeg` is the frame that was started, else nil (and the in-flight work is left alone).
    func take(_ jpeg: Data) async -> Ready? {
        guard token == Self.token(for: jpeg), let task else { return nil }
        let ready = await task.value
        guard ready.token == token else { return nil }
        return ready
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
                                   "timing"]
        let history = steps.suffix(8).filter {
            $0["plan"] == nil && $0["action"]?.str != Self.steerAction && $0["action"]?.str != Self.checkpointAction
        }.map { s -> String in
            String(PyJSON.dumps(s.without(hidden)).prefix(300)) + Self.effect(s)
        }.joined(separator: "\n")
        let collected = notebook.isEmpty ? "" : "\n\n" + notebook.summary()
            + (lookedUp.isEmpty ? "" : "\n\nLooked up:\n" + lookedUp.suffix(3).joined(separator: "\n\n"))
        let sound = heard?() ?? ""
        return "Goal: \(task)\(steeredSection)\n\nPlan:\n\(plan.isEmpty ? "(none yet: write one)" : plan)\n\nRecent actions:\n"
            + (history.isEmpty ? "(none)" : history) + collected + (sound.isEmpty ? "" : "\n\n" + sound) + "\n\nNext action?"
    }

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

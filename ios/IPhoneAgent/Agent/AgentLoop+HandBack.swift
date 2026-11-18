import Foundation

/// Once the run has everything (the progress count is reached) and the model turns to writing, the phone goes back to
/// the user and the result is written without the screen: text-only model calls, no gestures. Henry 2026-11-18: the
/// last 100 s of a 345 s run only wrote and re-read files while the phone sat taken. If the write-up cannot finish
/// (the model fails, too many rounds, the run is stopped), the notes become the result (LiveNotes.finish(asResult:)).
enum HandBack {
    static let rounds = 12  // model rounds for the write-up before the notes stand as the result
    static let allowed: Set<String> = ["note", "progress", "remember", "learn", "write", "tool", "guide", "file", "done", "fail"]

    /// This round only writes (no gesture, no snap, no screen read) and the count is reached.
    static func starts(_ actions: [String], count: (done: Int, total: Int?)?) -> Bool {
        guard let count, let total = count.total, total > 0, count.done >= total, !actions.isEmpty else { return false }
        return actions.allSatisfy(allowed.contains)
    }

    static let refusal = "refused: the phone is the user's again (everything was collected); write the result from your notes"

    static func note(saved: [String]) -> String {
        "\n\nThe phone is handed back to the user: there is no screen now, and taps, swipes, open and snap are refused. "
            + "Write the result file the goal asks for from your notes and the images already saved, then done."
            + (saved.isEmpty ? "" : "\nSaved in the result folder: " + saved.joined(separator: ", "))
    }
}

extension AgentLoop {
    /// Before a round's actions: hand the phone back when this round only writes and the count is reached.
    func handBackIfCollected(_ acts: [Planned]) async {
        // the count as it stands after this round: its own `progress` line counts (note, progress, then the write-up)
        let said = acts.last { $0.act["action"]?.str == "progress" }?.act["text"]?.str
        let reached = said.flatMap(Notebook.count) ?? notebook.count
        guard !handedBack, !resultWritten,
              HandBack.starts(acts.map { $0.act["action"]?.str ?? "" }, count: reached) else { return }
        handedBack = true
        let count = reached.map { "\($0.done)/\($0.total ?? 0)" } ?? ""
        DebugLog.write("hand back: \(count) collected; the phone goes back to the user, the result is written without it")
        record(nil, ["action": .str("handback"), "reason": .str("collected \(count): the phone is the user's again; writing the result")])
        onDoing?(.wrapping)
        await onHandBack?()
    }

    /// The files in the run's result folder, for the write-up prompt (it has no screen to look at).
    func savedInRunFolder() -> [String] {
        guard let folder = liveNotes.folder ?? runFolder, let dir = MemoryFiles.open().box.resolve(folder) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != LiveNotes.file }.sorted()
    }

    /// A model call while the phone is handed back: text only, no screen wait, no gate (the user may be in this app).
    func askWithoutScreen(_ role: String, _ llm: ChatModel, _ system: String, _ prompt: String,
                          temperature: Double, budget: Int? = nil) async throws -> (String, Double, Data?) {
        let started = now()
        let maxTokens = budget ?? Self.maxTokens[role] ?? 8000
        DebugLog.write("model request starting (\(role), handed back): \(llm.model), maxTokens \(maxTokens), no image")
        let reply: ChatResult
        do {
            reply = try await llm.chat(system: system, text: prompt, image: nil, maxTokens: maxTokens, temperature: temperature)
        } catch {
            if !Task.isCancelled { onModelCall?(ModelCall(role: role, model: llm.model, reply: nil, error: error, imageKB: 0)) }
            throw error
        }
        onModelCall?(ModelCall(role: role, model: llm.model, reply: reply, error: nil, imageKB: 0))
        if reply.finishReason == "length", maxTokens < Self.cutRetryTokens, !Task.isCancelled {
            DebugLog.write("model reply cut at \(maxTokens) tokens (\(role), handed back); asking once more")
            return try await askWithoutScreen(role, llm, system, prompt, temperature: temperature, budget: Self.cutRetryTokens)
        }
        let seconds = ((now() - started) * 100).rounded() / 100
        lastServed = reply.servedModel
        trace?.write(kind: "llm", ["role": .str(role), "model": .str(llm.model), "prompt": .str(prompt),
                                   "reply": .str(reply.text), "seconds": .num(seconds), "handed_back": .bool(true)])
        return (reply.text, seconds, nil)
    }
}

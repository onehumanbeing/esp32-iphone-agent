import Foundation

/// The notebook and memory actions: read, note, progress, write, remember, learn. None of them moves the pointer.
extension AgentLoop {
    /// Recalled memory and the earlier turns of this chat, appended to the planner's and actor's system prompts.
    /// Fixed for the whole run, so the prompt prefix stays the same from step to step.
    var background: String {
        var out = ""
        let remembered = MemoryStore.promptSection(recalled)
        if !remembered.isEmpty { out += "\n\n" + remembered }
        if !chatContext.isEmpty { out += "\n\nEarlier in this chat:\n" + chatContext }
        return out
    }

    func notebookAction(_ act: inout JObject) async throws {
        switch act["action"]?.str {
        case "read":
            let what = act["what"]?.str ?? ""
            let prompt = "Copy from this screen: \(what.isEmpty ? "the items the goal asks for" : what)\nGoal: \(task)"
            guard let model = actor ?? planner else { throw LLMError(message: "no actor model") }
            let (reply, seconds, _) = try await ask("reader", model, Prompts.reader, prompt)
            let lines = Notebook.lines(reply)
            let added = notebook.add(lines)
            act["think_s"] = .num(seconds)
            act["reason"] = .str("read \(lines.count) line\(lines.count == 1 ? "" : "s"), \(added) new; \(notebook.items.count) in the notebook")
        case "note":
            notebook.note(act["text"]?.str ?? "")
        case "progress":
            notebook.setProgress(act["text"]?.str ?? "")
        case "remember":
            let text = act["text"]?.str ?? ""
            if Self.saidByUser(text, in: task + "\n" + chatContext), memory?.add(text, kind: .preference) != nil {
                act["reason"] = .str("remembered")
            } else {
                act["reason"] = .str("not remembered: only what the user said, nothing sensitive")
            }
        case "learn":
            let text = act["text"]?.str ?? ""
            if !text.isEmpty { learned.append(text) }
            act["reason"] = .str("kept if the task ends with done")
        case "write":
            act["reason"] = .str(try await writeOut())
        default:
            break
        }
    }

    /// Puts the notebook on the clipboard; the actor then pastes it (key cmd+v) where the goal wants it.
    private func writeOut() async throws -> String {
        guard !notebook.items.isEmpty else { return "nothing to write: the notebook is empty (read first)" }
        guard let onWrite else { return "the clipboard is not available here: type the items instead" }
        guard try await onWrite(notebook.text) else {
            return "could not put the notebook on the clipboard: type the items instead"
        }
        return "the clipboard holds all \(notebook.items.count) items: open the target app, tap the text field, "
            + "then key cmd+v and check the result"
    }

    /// `type` with text the board cannot type (Scripts.needsPaste: Japanese, Korean …): on the clipboard instead, the
    /// way `write` does it; the app hop leaves the target app, so the actor opens it again and pastes.
    func pasteInstead(_ text: String) async throws -> String {
        let not = "nothing typed: the board cannot type this script"
        guard let onWrite else { return "\(not), and the clipboard is not available here" }
        guard try await onWrite(text) else { return "\(not), and the text could not be put on the clipboard" }
        return "\(not), so the text is on the clipboard instead: open the target app again, tap the text field, "
            + "then key cmd+v and check the result"
    }

    /// `done` carries everything collected, so the answer (and the chat) keeps the full list.
    func attachNotebook(_ act: inout JObject) {
        guard !notebook.items.isEmpty else { return }
        act["notebook"] = .arr(notebook.items.map { .str($0) })
    }

    /// A run that ended with done keeps the lessons the actor offered on the way.
    func keepLessons() {
        defer { learned = [] }
        guard steps.last?["action"]?.str == "done", let memory else { return }
        for text in learned {
            let topic = text.split(separator: ":", maxSplits: 1).count == 2 ? String(text.split(separator: ":")[0]) : ""
            memory.add(text, kind: .app, topic: topic.count <= 30 ? topic : "")
        }
    }

    /// `remember` only keeps the user's own words: most of the text must appear in what they wrote.
    static func saidByUser(_ text: String, in words: String) -> Bool {
        let t = MemoryStore.bigrams(text), w = MemoryStore.bigrams(words)
        guard !t.isEmpty else { return false }
        return Double(t.intersection(w).count) / Double(t.count) >= 0.6
    }
}

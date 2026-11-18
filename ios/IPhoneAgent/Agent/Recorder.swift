import Foundation

/// Records read in the background (Henry 2026-11-18: "整理的时候一定是千问去整理…异步的去看图片"). When the plan's first
/// line is `RECORD: field, field, …`, every screen the actor looks at is also handed to the reader model, which copies
/// those fields when the screen is one item's own page. The line goes into the notebook and notes.md (with that
/// screen) the way a note does; a later screen of the same item completes it in place (Notebook.completes). The actor
/// only opens items and unfolds what is folded; it no longer copies numbers itself.
/// 2026-11-18: the actor noted an order before unfolding its time; the screen with the time was never read and the
/// order was opened again.
enum Record {
    static let maxFields = 8

    /// The fields of the latest `RECORD:` line in the plans so far (the current plan first), or [] for none.
    static func fields(plans: [String]) -> [String] {
        for plan in plans.reversed() {
            for line in plan.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }),
                      t[..<colon].trimmingCharacters(in: .whitespaces).uppercased() == "RECORD" else { continue }
                let list = t[t.index(after: colon)...].split(whereSeparator: { ",，、;；".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !list.isEmpty { return Array(list.prefix(maxFields)) }
            }
        }
        return []
    }

    static let system = """
        You copy one record from an iPhone screenshot. You do not operate the phone.
        If the screen is ONE item's own page (one order, one booking, one message) and shows at least two of the \
        fields asked for, reply with one line per field it shows, in the order asked: FIELD: value, the value copied \
        exactly as written (keep the original language). Leave out a field the screen does not show; never guess, \
        never take a value from an ad or a recommendation.
        If the screen is a list of several items, a recommendations feed, a shop, a search or a home page, reply NONE.
        """

    static let snapRefused = "not saved: the record reader keeps each item's screen with its record (RECORD); "
        + "snap only when the goal asks for pictures. Open the next item instead."

    /// The goal asks for screenshots or pictures itself (then snaps stay allowed beside RECORD).
    static func wantsPictures(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["截图", "截屏", "图片", "照片", "screenshot", "screen shot", "picture", "photo", "image"].contains { g.contains($0) }
    }

    static func prompt(_ fields: [String], goal: String) -> String {
        "Fields: " + fields.joined(separator: ", ") + "\nGoal: " + goal
    }

    /// The reply as one notebook line, values in the fields' order joined by " · "; nil for NONE, under two values,
    /// or without the first field.
    static func line(_ reply: String, fields: [String]) -> String? {
        var values: [String: String] = [:]
        for raw in reply.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let name = key(String(t[..<colon]))
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.uppercased() != "NONE",
                  let field = fields.first(where: { key($0) == name }) else { continue }
            values[field] = values[field] ?? value
        }
        // the first field names the item (the shop, the title): without it a line cannot be told from another
        // item's (2026-11-18: "¥31.2 · 20:46:17 · address" went in beside the order it belonged to)
        guard let first = fields.first, values[first] != nil else { return nil }
        let shown = fields.compactMap { values[$0] }
        return shown.count >= 2 ? shown.joined(separator: " · ") : nil
    }

    private static func key(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

/// One read at a time; a newer screen waiting replaces the one before it, so the reader never falls behind.
struct RecorderState {
    var task: Task<Void, Never>?
    var queued: (full: Data, sent: Data)?
    var last: Int?  // FramePrep.token of the last screen handed over
    var reads = 0, recorded = 0
    var beforeStart: String?  // a record older than the goal's first day: the list's end is near
}

extension AgentLoop {
    var recordFields: [String] {
        Record.fields(plans: steps.compactMap { $0["plan"]?.str } + [plan])
    }

    /// The screen the actor is shown this round (`full`: the trace's frame, kept as the note's picture).
    func offerToRecorder(full: Data, sent: Data) {
        guard reader != nil, !recordFields.isEmpty else { return }
        let token = FramePrep.token(for: sent)
        guard token != recorder.last else { return }
        recorder.last = token
        if recorder.task != nil { recorder.queued = (full, sent); return }
        recorder.task = Task { [weak self] in
            var next: (full: Data, sent: Data)? = (full, sent)
            while let frame = next, let self {
                self.recorder.queued = nil
                await self.record(frame.full, frame.sent)
                next = self.recorder.queued
            }
            self?.recorder.task = nil
        }
    }

    enum Recorded: Equatable { case none, already, kept }

    /// The screen now, read at once (each with RECORD): `.kept` a new record, `.already` this item was in the
    /// notebook (opened again), `.none` nothing to read here.
    func recordNow() async -> Recorded {
        guard let full = screen?.frame else { return .none }
        let sent = ModelImage.forModel(full)
        recorder.last = FramePrep.token(for: sent)  // the background reader skips this screen
        return await record(full, sent)
    }

    @discardableResult
    private func record(_ full: Data, _ sent: Data) async -> Recorded {
        let fields = recordFields
        guard let reader, !fields.isEmpty, !Task.isCancelled else { return .none }
        recorder.reads += 1
        let started = now()
        let reply: ChatResult
        do {
            reply = try await reader.chat(system: Record.system, text: Record.prompt(fields, goal: task),
                                          image: sent, maxTokens: 2000, temperature: 0)
        } catch {
            DebugLog.write(String(format: "record: the reader did not answer (%.1f s): %@", now() - started,
                                  String(error.localizedDescription.prefix(120))))
            return .none
        }
        let seconds = now() - started
        guard let line = Record.line(reply.text, fields: fields) else {
            DebugLog.write(String(format: "record: nothing on this screen (%.1f s)", seconds))
            return .none
        }
        if notebook.noted(line) || Notebook.place(line, in: notebook.notes) == .known {
            DebugLog.write(String(format: "record: already noted (%.1f s)", seconds))
            return .already
        }
        if let outside = NoteCheck.outside(line, goal: task) {
            if NoteCheck.beforeStart(line, goal: task) { recorder.beforeStart = line }  // shown to the model (recordHint)
            DebugLog.write("record: left out, \(outside)")
            return .none
        }
        notebook.note(line)
        recorder.recorded += 1
        liveNotes.add(line, task: task, name: resultName, since: filesSince, files: MemoryFiles.open(since: filesSince), shot: full)
        trace?.write(kind: "record", ["text": .str(line), "seconds": .num((seconds * 100).rounded() / 100)])
        DebugLog.write(String(format: "record: \"%@\" (%.1f s)", String(line.prefix(60)), seconds))
        return .kept
    }
}

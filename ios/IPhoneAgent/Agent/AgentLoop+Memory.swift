import Foundation

/// The notebook and memory actions: read, note, progress, write, remember, learn. None of them moves the pointer.
extension AgentLoop {
    /// Recalled memory and the earlier turns of this chat, appended to the planner's and actor's system prompts.
    /// Fixed for the whole run, so the prompt prefix stays the same from step to step.
    var background: String {
        var out = ""
        let remembered = MemoryStore.promptSection(recalled)
        if !remembered.isEmpty { out += "\n\n" + remembered }
        if !chatContext.isEmpty {  // what those runs did is not this run's progress
            out += "\n\nEarlier runs in this chat (finished before this run started; what they did or showed is not "
                + "progress of this run):\n" + chatContext
        }
        return out
    }

    /// Today's date and the result folders there were when the run started: the model decides whether this run
    /// adds to one of them or starts its own. Fixed for the run (same system prompt every step).
    var resultsSection: String {
        guard !resultsAtStart.isEmpty else { return "" }  // nothing to add to or to clash with
        return "\n\nToday is \(MemoryFiles.stamp(filesSince).prefix(10)). Result folders already in your files "
            + "(newest first; earlier runs', written into only when the goal names one):\n" + resultsAtStart
    }

    /// `guide APP`: the server's notes for an app the goal is done in, shown under "Guide" from the next round on.
    func loadGuide(_ name: String) async -> String {
        if let had = AppGuides.match(name, in: guided) { return "already loaded: the guide for \(had.names[0]) is below the goal" }
        guard AppGuides.match(name, in: guides) != nil else {
            return "no guide for \(name); guides: " + (guides.isEmpty ? "none" : guides.map { $0.names[0] }.joined(separator: ", "))
        }
        guard guided.count < AppGuides.perRun else { return "not loaded: this task already has \(AppGuides.perRun) guides" }
        guard let guide = await AppGuides.shared.load(name, from: guides), guide.text?.isEmpty == false else {
            return "the guide for \(name) could not be loaded; go on without it"
        }
        guided.append(guide)
        return "loaded: the guide for \(guide.names[0]) is below the goal from now on"
    }

    /// A task for one app gets that app's guide before the first step (Henry 2026-11-18: in a 18-minute run the
    /// model loaded it only at step 269, after tapping the shop name on order cards again and again).
    /// A resumed run also gets back the guides it had loaded before (`guide` steps that said "loaded").
    func guideAtStart() async {
        guard guided.isEmpty, !guides.isEmpty else { return }
        let before = steps.filter { $0["action"]?.str == "guide" && $0["reason"]?.str?.hasPrefix("loaded") == true }
            .compactMap { $0["text"]?.str }
        let first = (openedAtStart ?? AppNames.only(in: task)).map { [$0] } ?? []
        for app in first + before where AppGuides.match(app, in: guides) != nil {
            DebugLog.write("guide at start: " + (await loadGuide(app)))
        }
    }

    /// The note's amounts not on the page now nor on its screens since it opened (NoteCheck).
    /// Amounts and names in the note that neither this screen nor the page's earlier screens show.
    func amountsNotOnPage(_ text: String) async -> [String] {
        var amounts = NoteCheck.amounts(text), names = NoteCheck.names(text), days = NoteCheck.days(text)
        guard !amounts.isEmpty || !names.isEmpty || !days.isEmpty, let frame = screen?.frame else { return [] }
        for shot in [frame] + pageFrames.reversed().filter({ $0 != frame })
        where !amounts.isEmpty || !names.isEmpty || !days.isEmpty {
            guard let image = Vision.image(shot) else { continue }
            let lines = await UITreeOCR.lines(image).map(\.text)
            amounts = NoteCheck.missing(amounts, screen: lines)
            names = NoteCheck.unseenNames(names, screen: lines)
            days = NoteCheck.unseenDays(days, screen: lines)
        }
        return amounts + names + days.map(\.text)
    }

    /// The reader copies `what` off the screen now into the notebook: lines read, how many were new, seconds.
    func readScreen(_ what: String) async throws -> (Int, Int, Double) {
        let prompt = "Copy from this screen: \(what.isEmpty ? "the items the goal asks for" : what)\nGoal: \(task)"
        guard let model = actor ?? planner else { throw LLMError(message: "no actor model") }
        let (reply, seconds, _) = try await ask("reader", model, Prompts.reader, prompt)
        let read = Notebook.lines(reply)
        // items outside the goal's dates are not kept; a screen whose dated items are all before its start ends a
        // collect (2026-11-19: a ride list going back years would be paged through to the page limit)
        let dated = read.filter { !NoteCheck.days($0).isEmpty }
        // a card cut off at the screen's edge comes without its date while the others have one: not an item
        let partial = dated.count >= 2 && dated.count * 2 > read.count
        let lines = read.filter { NoteCheck.outside($0, goal: task) == nil && (!partial || !NoteCheck.days($0).isEmpty) }
        if lines.count < read.count { DebugLog.write("read: \(read.count - lines.count) outside the goal's dates or cut off, left out") }
        let added = notebook.add(lines)
        // older items showed and nothing new in range did: the list is past the goal's dates (2026-11-19, Gaode:
        // the screens with 11-08 rides still showed 11-09 ones already read, so "all of them older" never came)
        readPastStart = added == 0 && dated.contains { NoteCheck.beforeStart($0, goal: task) }
        if readPastStart { listRead = true }
        // what was read is on disk too, with its screen (2026-11-17: an order only read, never noted, was missing
        // from notes.md when the run stopped)
        // one entry per screen read: line by line, the file filled with bare prices and counts (2026-11-18)
        let kept = notebook.items.suffix(added).joined(separator: " · ")
        if !kept.isEmpty {
            liveNotes.add(kept, task: task, name: resultName, since: filesSince, files: MemoryFiles.open(since: filesSince), shot: screen?.frame)
        }
        return (lines.count, added, seconds)
    }

    func notebookAction(_ act: inout JObject) async throws {
        switch act["action"]?.str {
        case "read":
            let (lines, added, seconds) = try await readScreen(act["what"]?.str ?? "")
            act["think_s"] = .num(seconds)
            act["reason"] = .str("read \(lines) line\(lines == 1 ? "" : "s"), \(added) new; \(notebook.items.count) in the notebook"
                                 + (readPastStart ? "; this screen's items are all before the goal's dates. " + listDone() : ""))
        case "note":
            let text = act["text"]?.str ?? ""
            if notebook.noted(text) {  // the same note again (2026-11-18: an order noted twice in notes.md)
                act["reason"] = .str("already noted: the notebook has this line; go on with the next item")
                break
            }
            notebook.note(text)
            let missing = await amountsNotOnPage(text)
            // a note the page does not back gets no picture: this screen is not its proof (2026-11-18: hotels noted
            // off the list showed a car order's page in the result)
            liveNotes.add(text, task: task, name: resultName, since: filesSince, files: MemoryFiles.open(since: filesSince),
                          shot: missing.isEmpty ? screen?.frame : nil)
            var said = liveNotes.folder.map { "noted; also in \($0)/\(LiveNotes.file)" } ?? "noted"
            if !missing.isEmpty {
                DebugLog.write("note: \(missing) not seen on the page")
                said += NoteCheck.warning(missing)
            }
            if let out = NoteCheck.outside(text, goal: task) {  // 2026-11-18: October hotels in an "11-09 to today" result
                DebugLog.write("note: outside the goal's dates")
                said += out
            }
            act["reason"] = .str(said)
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
        case "tool":
            let line = act["text"]?.str ?? ""
            guard lookedUp.count < ToolStore.perRun else {
                act["reason"] = .str("not looked up: this task already used its \(ToolStore.perRun) tool calls; go on with what is on screen")
                break
            }
            let answer = await ToolRunner.run(line, run: Trial.shared.runID)
            lookedUp.append("\(line)\n\(answer)")
            act["reason"] = .str("looked up: " + String(answer.prefix(160)))
        case "guide":
            act["reason"] = .str(await loadGuide(act["text"]?.str ?? ""))
        case "write":
            act["reason"] = .str(try await writeOut())
        case "file":
            let files = MemoryFiles.open(since: filesSince)
            if let runFolder { act["text"] = .str(RunFolder.file(act["text"]?.str ?? "", in: runFolder, goal: task, earlier: foldersAtStart)) }
            let line = act["text"]?.str ?? ""
            let result = files.run(line)
            if let viewed = FileViews.viewed(line), result.hasPrefix("ok") {
                // 2026-11-18: after its README the run viewed the folder and the README five times each (70 s)
                let again = !viewedSinceWrite.insert(viewed).inserted
                act["reason"] = .str(again ? FileViews.again : String(result.prefix(160)))
                fileView = result.count > 160 ? result : nil
            } else {
                act["reason"] = .str(String(result.prefix(160)))
                if result.count > 160 { fileView = result }
            }
            if let path = RunOutputs.written(result.hasPrefix("ok: ") ? String(result.dropFirst(4)) : "") {
                liveNotes.wrote(path, files: files)
                viewedSinceWrite = []; resultWritten = true
                if path == autoResult?.path { autoResult = nil }  // the actor changed the app's result: it is the actor's now
            }
        case "snap":
            // with RECORD the reader keeps each item's screen beside its note: a snap only repeats it (2026-11-18:
            // 28 snaps in one run, two to three per order, while the reader had saved every one)
            if !recordFields.isEmpty, !Record.wantsPictures(task) {
                act["reason"] = .str(Record.snapRefused)
                break
            }
            let files = MemoryFiles.open(since: filesSince)
            if let runFolder { act["text"] = .str(RunFolder.snap(act["text"]?.str ?? "", in: runFolder, goal: task, earlier: foldersAtStart)) }
            let result = files.snap(screen?.frame, act["text"]?.str ?? "")
            act["reason"] = .str(result)
            if let path = RunOutputs.written(result.hasPrefix("ok: ") ? String(result.dropFirst(4)) : "") { liveNotes.wrote(path, files: files) }
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
    /// way `write` does it. The hop leaves the target app; when this run knows which app that is, it opens it again,
    /// keys cmd+v and reads the text back (nil: pasted and seen). Otherwise, or when the text is not seen, the actor
    /// is told to paste it itself, as before (2026-11-17: 5 runs stopped at a Japanese or Korean `type`).
    func pasteInstead(_ text: String) async throws -> String? {
        let not = "nothing typed: the board cannot type this script"
        guard let onWrite else { return "\(not), and the clipboard is not available here" }
        guard try await onWrite(text) else { return "\(not), and the text could not be put on the clipboard" }
        let held = "\(not), so the text is on the clipboard instead: "
        let paste = "tap the text field, then key cmd+v and check the result"
        guard let app = currentApp, let phone else { return held + "open the target app again, " + paste }
        guard try await phone.openApp(app) == .opened else { return held + "\(app) did not open again: open it, " + paste }
        _ = await settle()
        try await phone.key("cmd+v")
        lastActed = now()
        _ = await settle()
        if let frame = screen?.frame, let image = Vision.image(frame),
           Self.shows(text, await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: text)).map(\.text)) {
            DebugLog.write("type: pasted into \(app) and read back")
            return nil
        }
        return held + "\(app) is open again and cmd+v was pressed, but the text is not seen: " + paste
    }

    /// The app the task is in: the last one `open` opened (or the run opened before its first step), unless Home was
    /// pressed after it.
    var currentApp: String? {
        for s in steps.reversed() {
            switch s["action"]?.str {
            case "home": return nil
            case "open" where s["opened"]?.str == OpenResult.opened.rawValue: return s["app"]?.str
            default: continue
            }
        }
        return openedAtStart
    }

    /// Whether the read lines hold `text`: all of it for short text, its start and end for long text (a field shows
    /// only part of a long one, wrapped).
    static let wholeUpTo = 12, ends = 6  // characters: short text whole, long text by its two ends
    static func shows(_ text: String, _ lines: [String]) -> Bool {
        let want = Scripts.fold(text), seen = Scripts.fold(lines.joined())
        guard !want.isEmpty else { return false }
        if want.count <= wholeUpTo { return seen.contains(want) }
        return seen.contains(String(want.prefix(ends))) && seen.contains(String(want.suffix(ends)))
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

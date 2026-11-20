import Foundation

/// `collect WHAT`: the list is paged through by code. Read the screen into the notebook, scroll a little less than
/// half a screen, read again, until two screens in a row bring nothing new, the list stops moving (its end) or the
/// page limit. One model call per screen (the reader) instead of a look, a decision and a swipe per screen
/// (2026-11-17: a 4-order list took 19 minutes, most of it deciding to scroll).
enum Collect {
    static let pages = 25
    static let dry = 2  // screens in a row with nothing new
    static let from = (x: 0.5, y: 0.70), to = (x: 0.5, y: 0.40)  // mid content: clear of nav and tab bars

    enum End: String {
        case dry = "2 screens in a row brought nothing new"
        case still = "the list stopped moving (its end)"
        case limit = "the page limit"
        case feed = "a recommendations feed starts (the list's own end)"
        case past = "the list reached items before the goal's dates"
    }

    /// What to do after the stop: the list's end may only load more on a tap; past the goal's dates it is done.
    /// `done`: what the actor is told once the list is done (AgentLoop.listDone()).
    static func next(_ end: End, done: String) -> String {
        switch end {
        case .past: return ". " + done
        case .still: return ". If the list's last row offers more (a row to tap to load more items), tap it and collect again; else " + done.prefix(1).lowercased() + done.dropFirst()
        default: return ""
        }
    }

    /// 2026-11-19: Gaode and Meituan runs read their lists to the end and then never finished.
    static let listDone = "The list is done: write the result from the notebook now (every item in it that the goal counts), then finish with done"

    /// The list is done and the app saved its result from the notebook (AgentLoop.saveListResult).
    static func saved(_ path: String, items: Int) -> String {
        "The list is done and its result is saved: \(path) holds all \(items) item\(items == 1 ? "" : "s") of the notebook "
            + "(the app wrote it). Do not write it again. If the goal asks for more than the list (a total, a summary), "
            + "add only that with one short str_replace or insert; then finish with done"
    }

    /// The result file from the notebook: the title, one line per item, then the actor's notes.
    static func result(title: String, items: [String], notes: [String], chinese: Bool) -> String {
        let list = { (lines: [String]) in lines.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        var text = "# \(title)\n\n"
        if !items.isEmpty { text += list(items) }
        if !notes.isEmpty { text += (items.isEmpty ? "" : "\n" + (chinese ? "## 备注" : "## Notes") + "\n\n") + list(notes) }
        return text
    }

    /// After one more screen: whether to stop, and why. `added`: new items on it; `moved`: the scroll before it moved.
    static func end(page: Int, dryRun: Int, moved: Bool) -> End? {
        if !moved { return .still }
        if dryRun >= dry { return .dry }
        return page >= pages ? .limit : nil
    }
}

extension AgentLoop {
    func collect(_ act: inout JObject) async throws {
        guard let phone else { throw LLMError(message: "no phone") }
        let what = act["what"]?.str ?? ""
        var (page, dryRun, added, seconds) = (0, 0, 0, 0.0)
        var end = Collect.End.limit
        var moved = true
        while true {
            let (_, new, s) = try await readScreen(what)
            (page, added, seconds) = (page + 1, added + new, seconds + s)
            dryRun = new == 0 ? dryRun + 1 : 0
            if readPastStart { end = .past; listRead = true; break }
            if let stop = Collect.end(page: page, dryRun: dryRun, moved: moved) { end = stop; break }
            if await feedShown() != nil { end = .feed; break }
            try await gate?()  // a pause or stop between screens
            let before = screen?.frame
            try await phone.swipe(Collect.from.x, Collect.from.y, Collect.to.x, Collect.to.y, hold: true)
            lastActed = now()
            _ = await settle()
            let after = screen?.frame, pointer = pointerAt
            moved = await Vision.off { Vision.changed(before, after, ignore: [pointer]) }
            if !moved, let stop = Collect.end(page: page, dryRun: dryRun, moved: false) { end = stop; break }
        }
        DebugLog.write("collect: \(page) screens, \(added) new, stopped: \(end.rawValue)")
        act["think_s"] = .num((seconds * 100).rounded() / 100)
        let done = end == .past || end == .still ? listDone() : ""
        act["reason"] = .str("collected over \(page) screen\(page == 1 ? "" : "s"): \(added) new; \(notebook.items.count) in the notebook; "
                             + "stopped: \(end.rawValue)" + Collect.next(end, done: done))
    }

    /// The list is read to its end: the app saves the result from the notebook and the actor is told where it is.
    /// 2026-11-20: a collect read 25 rides, then the whole README had to come in one model reply; the reply was cut
    /// three times and the run ended in help with no result. The result no longer hangs on one long reply.
    func listDone() -> String {
        guard let path = saveListResult() else { return Collect.listDone }
        return Collect.saved(path, items: notebook.items.count)
    }

    /// README.md in the run's folder, from the notebook. nil: nothing to write, or the run wrote its own result there
    /// (left alone). Written again when the notebook grew, as long as the actor has not changed the file since.
    @discardableResult
    func saveListResult() -> String? {
        guard !notebook.items.isEmpty || !notebook.notes.isEmpty, let folder = liveNotes.folder ?? runFolder else { return nil }
        let path = folder + "/README.md"
        let text = Collect.result(title: resultName ?? task, items: notebook.items, notes: notebook.notes, chinese: HanTyper.isHan(task))
        if let own = autoResult {
            guard own.path == path else { return nil }
            if own.text == text { return path }
        } else if resultWritten {
            return nil  // the actor's own result
        }
        let files = MemoryFiles.open(since: filesSince)
        let args = (try? JSONSerialization.data(withJSONObject: ["command": "create", "path": path, "file_text": text])) ?? Data()
        let said = files.run(String(decoding: args, as: UTF8.self))
        guard said.hasPrefix("ok: ") else {
            DebugLog.write("list done: the result was not saved (\(said))")
            return nil
        }
        DebugLog.write("list done: \(said)")
        record(nil, ["action": .str("file"), "path": .str(path), "by": .str("app"),
                     "reason": .str(said + "; written by the app from the notebook")])
        liveNotes.wrote(path, files: files)
        (autoResult, resultWritten, viewedSinceWrite) = ((path, text), true, [])
        return path
    }

    /// The run's work is complete: the list was read to its end, or the progress count reached, and the result is
    /// saved (the actor's, else the app's from the notebook).
    func workComplete() -> Bool {
        guard listRead || notebook.reached else { return false }
        return saveListResult() != nil || resultWritten
    }
}

/// `find "满减"`: scroll down until the words show, then stop there; the result says where they are, so the next
/// reply taps them (tap "满减") without a look per scroll. Stops at the list's end or after `pages` screens, then
/// the model looks again: Henry 2026-11-18, a find scrolled 9 screens (108 s) into a feed with no model call.
enum Find {
    static let pages = 3
}

extension AgentLoop {
    func find(_ act: inout JObject) async throws {
        guard let phone else { throw LLMError(message: "no phone") }
        let target = act["text"]?.str ?? ""
        var scrolls = 0
        var up = false  // the feed showed: what this page has is above it, so look there
        while true {
            if let frame = screen?.frame, let image = Vision.image(frame) {
                let lines = await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: target), whole: true)
                let found = TapText.find(target, in: lines, size: CGSize(width: image.width, height: image.height))
                if found != .none {
                    let at: String
                    switch found {
                    case .at(let x, let y): at = "at \(x) \(y)"
                    case .several(let spots): at = "in \(spots.count) places (\(spots.joined(separator: ", ")))"
                    case .none: at = ""
                    }
                    act["reason"] = .str("found \"\(target)\" \(at) after \(scrolls) scroll\(scrolls == 1 ? "" : "s")\(up ? " up" : "")")
                    return
                }
            }
            guard scrolls < Find.pages else { break }
            if !up, let feed = await feedShown() {
                // 2026-11-18: the feed header was still on screen after a scroll back up, so find stopped at once
                // although "查看更多" sat just above; now it turns and looks up
                guard scrolls == 0 else {
                    act["reason"] = .str("\"\(target)\" not found above \"\(feed.prefix(16))\" (a recommendations feed) after \(scrolls) scroll\(scrolls == 1 ? "" : "s")")
                    return
                }
                DebugLog.write("find: \"\(feed)\" on screen, looking up")
                up = true
            }
            try await gate?()
            let before = screen?.frame
            let (from, to) = up ? (Collect.to, Collect.from) : (Collect.from, Collect.to)
            try await phone.swipe(from.x, from.y, to.x, to.y, hold: true)
            lastActed = now()
            scrolls += 1
            _ = await settle()
            let after = screen?.frame, pointer = pointerAt
            guard await Vision.off({ Vision.changed(before, after, ignore: [pointer]) }) else {
                act["reason"] = .str("\"\(target)\" not found: the \(up ? "page's top came" : "list ended") after \(scrolls) scroll\(scrolls == 1 ? "" : "s")"
                                     + (up ? " up (the feed was on screen)" : ""))
                return
            }
        }
        act["reason"] = .str("\"\(target)\" not found in \(scrolls) scrolls\(up ? " up from the feed" : ""). Look at this screen first: if it is past this "
                             + "page's own content (a feed, another page), scroll back up or go back; else find again")
    }
}

extension AgentLoop {
    /// Once the list was read past the goal's dates, the first scroll back up is refused with the reason: the model
    /// went back "to verify nothing was missed" in several runs (2026-11-19 Ctrip: twice, then six rounds of snaps)
    /// although the list runs newest first. A second scroll back goes through: the model may know better.
    func scrollBackRefusal(_ act: JObject) -> String? {
        guard listRead, !backChecked, let y1 = act["y1"]?.double, let y2 = act["y2"]?.double, y2 - y1 > 100 else { return nil }
        backChecked = true
        return "refused once: the list was already read past the goal's dates (newest first, so nothing newer was "
            + "skipped). " + listDone() + ". Scroll back up again only if something the goal needs is really missing."
    }
}

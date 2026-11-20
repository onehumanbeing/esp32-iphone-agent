import Foundation

/// Chinese text the run will likely type, put on the clipboard once at the start while this app is still in front
/// (iOS ignores clipboard writes from the background, 2026-10-20). When pinyin then stops part way through that
/// text, the field is cleared and cmd+v pastes it, with no hop back to this app (Henry 2026-11-20: the Spotlight hop
/// looked bizarre and missed with many apps open). The write is local only; logs carry counts, never the text.
struct ClipboardCarry: Equatable {
    var text: String
    var changeCount: Int  // UIPasteboard.changeCount right after the write: any later write changes it
    var source: String  // "plan" or "prompt"

    /// What to carry, in this order:
    /// 1. plan: the first Han `type` text of the intent's recorded steps, else of the cached plan
    ///    (a quoted text right after type / 输入 / 搜索 / search, e.g. `type "上海西岸艺术中心"`);
    /// 2. prompt: the search term of the task, the Han text after a search verb (搜索, 搜, 查找, 查询, 输入) up to the
    ///    end of its clause, with app names (AppNames.table) removed; else the one quoted Han text. Taken only when
    ///    exactly one term is found: two or more is unsure, so nothing is carried.
    /// nil: nothing to carry (the clipboard is then left as it is).
    static func pick(task: String, plan: String?, typed: [String]) -> (text: String, source: String)? {
        if let text = (typed + quotedAfterVerb(plan ?? "")).map(trim).first(where: carries) { return (text, "plan") }
        return fromPrompt(task).map { ($0, "prompt") }
    }

    static func fromPrompt(_ task: String) -> String? {
        let clauses = split(task)
        let terms = unique(clauses.compactMap(afterVerb).map(withoutAppNames).filter(carries))
        if !terms.isEmpty { return terms.count == 1 ? terms[0] : nil }
        let quoted = unique(quoted(task).map(withoutAppNames).filter(carries))
        return quoted.count == 1 ? quoted[0] : nil
    }

    /// Worth carrying: Chinese the pinyin keyboard may not give (other scripts paste their own way, needsPaste).
    static func carries(_ text: String) -> Bool { text.count >= 2 && HanTyper.isHan(text) && !Scripts.needsPaste(text) }

    /// The rule for pasting it: the `type` text is the carried text, after trimming.
    func matches(_ text: String) -> Bool { Self.trim(text) == Self.trim(self.text) }

    static let verbs = ["搜一搜", "搜一下", "查一下", "搜索", "查找", "查询", "输入", "搜"]  // longer first
    private static let ends = ["，", ",", "。", "；", ";", "！", "!", "？", "?", "\n", " then ", "然后", "之后", "接着", "并且"]

    private static func split(_ task: String) -> [String] {
        var parts = [task]
        for end in ends { parts = parts.flatMap { $0.components(separatedBy: end) } }
        return parts
    }

    /// The text after the clause's first search verb (a longer verb wins at the same place).
    private static func afterVerb(_ clause: String) -> String? {
        var best: Range<String.Index>?
        for verb in verbs {
            if let r = clause.range(of: verb), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        return best.map { trim(String(clause[$0.upperBound...])) }
    }

    private static let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』"), ("'", "'")]

    private static func quoted(_ text: String) -> [String] {
        var found: [String] = [], open: Character?, close: Character = "\"", current = ""
        for ch in text {
            if open != nil {
                if ch == close { found.append(current); open = nil; current = "" } else { current.append(ch) }
            } else if let pair = quotes.first(where: { $0.0 == ch }) { open = pair.0; close = pair.1 }
        }
        return found
    }

    /// In a plan: the quoted texts right after a type verb.
    private static func quotedAfterVerb(_ plan: String) -> [String] {
        let pattern = "(?i)(?:type|search(?: for)?|输入|搜索)\\s*[:：]?\\s*[\"“「『']([^\"”」』'\\n]+)[\"”」』']"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: plan, range: NSRange(plan.startIndex..., in: plan)).compactMap {
            Range($0.range(at: 1), in: plan).map { String(plan[$0]) }
        }
    }

    private static let appNames: [String] = AppNames.table.flatMap { $0 }.filter { $0.count >= 2 && HanTyper.isHan($0) }
        .sorted { $0.count > $1.count }

    static func withoutAppNames(_ text: String) -> String {
        var text = text
        for name in appNames { text = text.replacingOccurrences(of: name, with: "") }
        return trim(text)
    }

    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：\"“”「」『』'")))
    }

    private static func unique(_ texts: [String]) -> [String] {
        texts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

extension AgentLoop {
    /// A Chinese `type` that pinyin stopped part way: paste the carried text when the clipboard still holds it and it
    /// is this text (ClipboardCarry.matches): clear the field, cmd+v, read it back. Never leaves the app. nil: not
    /// pasted, the model is told to type the rest itself.
    func pasteCarried(_ text: String, stop: HanTyper.Stop) async throws -> (field: String, value: String)? {
        let why: String? = if let carried {
            clipboardCount?() != carried.changeCount ? "clipboard changed" : carried.matches(text) ? nil : "different text"
        } else { "no carried text" }
        if let why { DebugLog.write("clipboard: not pasting: \(why)"); return nil }
        guard let phone else { return nil }
        _ = try await phone.clearField()
        try await phone.key("cmd+v")
        lastActed = now()
        _ = await settle()
        var seen = false
        if let frame = screen?.frame, let image = Vision.image(frame) {
            seen = Self.shows(ClipboardCarry.trim(text), await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: text)).map(\.text))
        }
        DebugLog.write("clipboard: paste carried text (\(text.count) chars): read back \(seen ? "ok" : "not seen")")
        if seen {
            sendGuard.typed(text, missing: nil)
            return ("result", "the pinyin keyboard stopped part way, so the field was cleared and the whole text pasted from the clipboard; read back: the field holds all of it")
        }
        sendGuard.typed(text, missing: text)
        return ("typed", SendGuard.listedHint + stop.note + "; the field was then cleared and the text pasted with cmd+v,"
            + " but it is not seen: check the field; if it is wrong, \(SendGuard.clearHint) and type it in shorter pieces")
    }
}

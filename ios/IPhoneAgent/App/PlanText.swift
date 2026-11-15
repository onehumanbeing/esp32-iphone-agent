import Foundation

/// One line of a recorded plan: a command the runner already understands, and the screenshot it was done on.
struct PlanStep: Equatable {
    var command: String
    var frame: String?
}

/// The plan file (`plan.txt`) the editor rewrites. `until` is ScriptRunner's "repeat until".
struct PlanDocument: Equatable {
    var name: String
    var prompt: String
    var until: String?
    var maxLoops: Int?
    var steps: [PlanStep]
}

/// Read and write that file, and turn it back into the review's steps. No model name lives here.
enum PlanText {
    static func render(_ plan: PlanDocument) -> String {
        var lines: [String] = []
        if !plan.name.isEmpty { lines.append("NAME: \(plan.name)") }
        if !plan.prompt.isEmpty { lines.append("PROMPT: \(plan.prompt)") }
        if let until = plan.until?.trimmingCharacters(in: .whitespacesAndNewlines), !until.isEmpty {
            lines.append("UNTIL: \(until)")
            lines.append("MAX_LOOPS: \(plan.maxLoops ?? 5)")
        }
        for (i, step) in plan.steps.enumerated() {
            var line = "\(i + 1). \(step.command)"
            if let frame = step.frame, looksLikeFile(frame) { line += " | \(frame)" }
            lines.append(line)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Nil when there is no numbered step.
    static func parse(_ text: String) -> PlanDocument? {
        var name = "", prompt = "", until: String?
        var loops: Int?
        var steps: [PlanStep] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("NAME:") { name = value(line, dropping: 5); continue }
            if upper.hasPrefix("PROMPT:") { prompt = value(line, dropping: 7); continue }
            if upper.hasPrefix("UNTIL:") {
                let v = value(line, dropping: 6)
                until = v.isEmpty ? nil : v
                continue
            }
            if upper.hasPrefix("MAX_LOOPS:") {
                loops = Int(value(line, dropping: 10))
                continue
            }
            if let step = parseStep(line) { steps.append(step) }
        }
        guard !steps.isEmpty else { return nil }
        if until == nil { loops = nil }
        if let n = loops { loops = min(20, max(1, n)) }
        return PlanDocument(name: name, prompt: prompt, until: until, maxLoops: loops, steps: steps)
    }

    @MainActor
    static func document(from draft: ReviewDraft) -> PlanDocument {
        let folder = draft.folder?.standardizedFileURL.path
        let steps = draft.steps.compactMap { step -> PlanStep? in
            let name = step.name
            guard Replay.replayable.contains(name) || Replay.scriptKinds.contains(name)
                    || name == "note" || name == "waittext" else { return nil }
            let command = command(step.action)
            guard !command.isEmpty else { return nil }
            var frame: String?
            if let url = step.frame, url.deletingLastPathComponent().standardizedFileURL.path == folder {
                frame = url.lastPathComponent
            }
            return PlanStep(command: command, frame: frame)
        }
        return PlanDocument(name: draft.name, prompt: draft.prompt, until: draft.until,
                            maxLoops: draft.maxLoops, steps: steps)
    }

    static func command(_ action: JObject) -> String {
        let n = { (k: String) in action[k]?.int ?? Int(action[k]?.double ?? 0) }
        func quoted(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        switch action["action"]?.str ?? "" {
        case "tap":
            let base = "tap \(n("x")) \(n("y"))"
            if let label = action["label"]?.str, !label.isEmpty { return base + " \"\(quoted(label))\"" }
            return base
        case "swipe":
            return "swipe \(n("x1")) \(n("y1")) \(n("x2")) \(n("y2"))"
        case "type": return "type \"\(quoted(action["text"]?.str ?? ""))\""
        case "open": return "open \"\(quoted(action["app"]?.str ?? ""))\""
        case "key": return "key \(action["combo"]?.str ?? "")"
        case "ai": return "ai \"\(quoted(action["goal"]?.str ?? ""))\""
        case "read": return "read \"\(quoted(action["what"]?.str ?? ""))\""
        case "manual": return "manual \"\(quoted(action["reason"]?.str ?? ""))\""
        case "note": return "note \"\(quoted(action["text"]?.str ?? ""))\""
        case "waittext": return "waittext \"\(quoted(action["pattern"]?.str ?? ""))\""
        case "home", "back", "wait", "clear", "write": return action["action"]?.str ?? ""
        default: return action["action"]?.str ?? ""
        }
    }

    /// A command the runner knows. Anything else stays a note, so a bad line is visible and not replayed as a tap.
    @MainActor
    static func action(_ command: String) -> JObject {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let (bare, label) = DemoRecorder.splitLabel(trimmed)
        if var parsed = DemoRecorder.parseDemonstratedAction(bare) {
            if let label, parsed["action"]?.str == "tap" { parsed["label"] = .str(label) }
            return parsed
        }
        let head = trimmed.prefix { !$0.isWhitespace }.lowercased()
        let rest = trimmed.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch head {
        case "manual" where !rest.isEmpty: return ["action": .str("manual"), "reason": .str(rest)]
        case "note" where !rest.isEmpty: return ["action": .str("note"), "text": .str(rest)]
        case "waittext" where !rest.isEmpty: return ["action": .str("waittext"), "pattern": .str(rest)]
        case "key" where !rest.isEmpty: return ["action": .str("key"), "combo": .str(rest)]
        case "clear", "write": return ["action": .str(String(head))]
        default: return ["action": .str("note"), "text": .str(trimmed)]
        }
    }

    static func parseStep(_ line: String) -> PlanStep? {
        guard let dot = line.firstIndex(of: "."),
              let n = Int(line[..<dot].trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        var rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var frame: String?
        if let bar = rest.range(of: " | ", options: .backwards) {
            let candidate = rest[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            if looksLikeFile(candidate) {
                frame = candidate
                rest = rest[..<bar.lowerBound].trimmingCharacters(in: CharacterSet.whitespaces)
            }
        }
        guard !rest.isEmpty else { return nil }
        return PlanStep(command: String(rest), frame: frame)
    }

    static func looksLikeFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png"].contains(ext) && !name.contains("/") && !name.contains("..") && name.count < 80
    }

    static func verdict(_ text: String) -> (ok: Bool?, notes: [String]) {
        var ok: Bool?
        var notes: [String] = []
        var inNotes = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("VERDICT:") {
                let value = line.dropFirst(8).trimmingCharacters(in: .whitespaces).lowercased()
                ok = value.hasPrefix("ok")
                inNotes = false
            } else if upper.hasPrefix("NOTES:") {
                inNotes = true
            } else if inNotes, line.hasPrefix("-") || line.hasPrefix("•") {
                let note = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !note.isEmpty { notes.append(String(note)) }
            }
        }
        return (ok, notes)
    }

    /// What can be saved without leaving the folder or storing a step the runner cannot read.
    @MainActor
    static func localCheck(before: String, after: String, sandbox: FileSandbox) -> (plan: PlanDocument?, notes: [String], blocking: Bool) {
        guard let plan = parse(after) else {
            return (nil, [String(localized: "The plan file is not a plan the app can run.")], true)
        }
        var notes: [String] = []
        var blocking = false
        for (i, step) in plan.steps.enumerated() {
            let action = self.action(step.command)
            let name = action["action"]?.str ?? ""
            if name == "note", !step.command.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("note") {
                notes.append(String(localized: "Step \(i + 1) is not a step the runner knows."))
                blocking = true
            }
            if let frame = step.frame {
                if let url = sandbox.resolve(frame), FileManager.default.fileExists(atPath: url.path) {
                    continue
                }
                if sandbox.resolve(frame) == nil {
                    notes.append(String(localized: "Step \(i + 1) names a file outside the plan folder."))
                } else {
                    notes.append(String(localized: "Step \(i + 1) names a screenshot that is not in the folder."))
                }
                blocking = true
            }
        }
        if plan.until != nil, plan.steps.isEmpty {
            notes.append(String(localized: "A loop needs at least one step."))
            blocking = true
        }
        if let until = plan.until, until.count < 3 {
            notes.append(String(localized: "Repeat until needs a condition that can be seen on screen."))
            blocking = true
        }
        let known = Set((parse(before)?.steps ?? []).map(\.command))
        let invented = plan.steps.filter { step in
            let name = self.action(step.command)["action"]?.str ?? ""
            return !known.contains(step.command) && Replay.replayable.contains(name)
        }
        if !invented.isEmpty {
            notes.append(String(localized: "\(invented.count) step(s) are moves the recording did not have."))
        }
        if notes.isEmpty {
            notes.append(String(localized: "The steps parse, and every named screenshot is in the folder."))
        }
        return (plan, notes, blocking)
    }

    private static func value(_ line: String, dropping count: Int) -> String {
        String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    }
}

enum TextDiff {
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable { case same, added, removed }
        var id: Int
        var kind: Kind
        var text: String
    }

    static func lines(_ before: String, _ after: String) -> [Row] {
        let a = rows(before), b = rows(after)
        let table = lcs(a, b)
        var i = a.count, j = b.count
        var reversed: [(Row.Kind, String)] = []
        var guardrail = 0
        while i > 0 || j > 0 {
            guardrail += 1
            if guardrail > 8000 { break }
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                reversed.append((.same, a[i - 1])); i -= 1; j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                reversed.append((.added, b[j - 1])); j -= 1
            } else if i > 0 {
                reversed.append((.removed, a[i - 1])); i -= 1
            } else {
                break
            }
        }
        return reversed.reversed().enumerated().map { Row(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
            .filter { !$0.text.isEmpty || $0.kind != .same }
    }

    private static func rows(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        guard !a.isEmpty, !b.isEmpty else { return table }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] { table[i][j] = table[i - 1][j - 1] + 1 }
                else { table[i][j] = max(table[i - 1][j], table[i][j - 1]) }
            }
        }
        return table
    }
}

extension ReviewDraft {
    /// Replace the steps with a plan the editor already wrote. The recording's `steps.jsonl` is left as it was.
    func applyPlan(_ plan: PlanDocument) {
        if !plan.name.isEmpty { name = plan.name }
        if !plan.prompt.isEmpty { prompt = plan.prompt }
        until = plan.until
        maxLoops = plan.maxLoops
        let previous = steps
        let box = folder.map { FileSandbox(root: $0) }
        steps = plan.steps.map { step in
            let action = PlanText.action(step.command)
            let known = action["action"]?.str != "note"
                || step.command.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("note")
            var frame = previous.first { PlanText.command($0.action) == step.command }?.frame
            if let name = step.frame, let box, let url = box.resolve(name),
               FileManager.default.fileExists(atPath: url.path) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    frame = url
                }
            }
            return DraftStep(action: action, frame: frame, uncertain: !known)
        }
        saveEdits()
    }
}

@MainActor
enum PlanFolder {
    static func looksLike(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains(where: { ["plan.txt", "review.json", "steps.jsonl", "keyframes.txt"].contains($0) }) {
            return true
        }
        return names.contains { $0.range(of: #"^k\d+\.jpg$"#, options: .regularExpression) != nil }
    }

    static func makeDraft(_ folder: URL) -> ReviewDraft {
        if let run = RunStore.load(folder) { return ReviewDraft(run: run) }
        return ReviewDraft(source: .recording, folder: folder, runID: nil, outcome: nil, steps: [],
                           name: "", prompt: "")
    }

    /// Write `plan.txt` from the review when the folder does not already have a plan the runner can read.
    static func ensure(_ sandbox: FileSandbox, _ draft: ReviewDraft) {
        if let existing = sandbox.textFile("plan.txt"), PlanText.parse(existing) != nil { return }
        let text = PlanText.render(PlanText.document(from: draft))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = sandbox.perform(FileCall(name: "write", args: ["plan.txt"], body: text), allow: FileTool.edit)
    }
}

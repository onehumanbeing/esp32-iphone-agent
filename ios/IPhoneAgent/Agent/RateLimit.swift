import Foundation

/// The app on the phone says the run goes too fast or too far: "操作频繁", "已达上限", "too many requests". Going on
/// risks the account (a blocked bulk delete, a frozen login), so the run stops and asks the user. Read after a
/// round, while the model thinks about the next one; checked before the next gesture, so no action is sent past it.
/// Only words that were not on the screen at the check before count: a page that always shows "上限" in its terms
/// does not stop anything.
enum RateLimit {
    static let phrases = [
        "操作频繁", "操作太频繁", "操作过于频繁", "请求过于频繁", "访问过于频繁", "频繁操作", "已达上限", "达到上限",
        "次数上限", "超出限制", "超过限制", "too many requests", "rate limit",
        "limit reached", "reached the limit",
    ]

    /// The first line of `lines` holding a phrase, unless `before` already held it.
    static func shown(_ lines: [String], before: [String]) -> String? {
        let old = Set(before.flatMap(hits))
        return lines.first { !hits($0).filter { !old.contains($0) }.isEmpty }
    }

    static func hits(_ line: String) -> [String] {
        let l = line.lowercased().filter { !$0.isWhitespace || $0 == " " }
        return phrases.filter { l.contains($0) }
    }

    static func reason(_ line: String) -> String {
        "the app says \"\(line.prefix(60))\": it limits how fast or how often this can be done. Stopped so the account is not blocked; wait before going on"
    }
}

extension AgentLoop {
    /// After a round with gestures: read the screen in the background (RateLimit; its lines also serve PayGuard).
    func startLimitCheck() {
        guard let frame = screen?.frame else { return }
        let before = limitLines.map(\.text)
        limitCheck = Task.detached(priority: .utility) {
            let lines = await Self.screenLines(frame)
            return (frame, lines, RateLimit.shown(lines.map(\.text), before: before))
        }
    }

    /// Whole OCR lines of a frame, centres in 0-1000 (phrases with spaces stay one line).
    nonisolated static func screenLines(_ frame: Data) async -> [DemoAnalysis.Line] {
        guard let image = Vision.image(frame) else { return [] }
        let w = Double(image.width), h = Double(image.height)
        return await UITreeOCR.lines(image, whole: true).filter { $0.box.count == 4 }.map { line in
            let b = line.box.map(Double.init)
            return DemoAnalysis.Line(text: line.text, x: Int((b[0] + b[2]) / 2 / w * 1000), y: Int((b[1] + b[3]) / 2 / h * 1000))
        }
    }

    /// Before the next round's first gesture: the line that stops the run, if the last check found one.
    func takeLimitCheck() async -> String? {
        guard let task = limitCheck else { return nil }
        limitCheck = nil
        let (frame, lines, hit) = await task.value
        (limitFrame, limitLines) = (frame, lines)
        if let hit { DebugLog.write("step: the app limits the run: \(hit)") }
        return hit
    }
}

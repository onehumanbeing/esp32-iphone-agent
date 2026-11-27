import Foundation

/// `wait "支付成功"` / `wait gone "加载中"` [SECONDS]: wait until the words show (or are gone), read by OCR about
/// once a second, up to SECONDS (default 5, at most `most`). Lets one reply hold "tap 提交, wait "成功", tap 完成"
/// instead of a look per step, and a slow page is waited for instead of tapped through.
///
/// Plain `wait` (or `wait 0`) watches the screen until something changes (what moves by itself, a spinner, is left
/// out), up to `plainMost`, then lets it settle; `wait 10` waits up to that long and ends as soon as the screen changes
/// the same way (what moved in its first 1.2 s left out, so an ad's once-a-second countdown or a video playing
/// doesn't end it, their end does). 2026-11-25: plain `wait` only settled and asked
/// the model again, so a loading page took a model step (about 13 s) per look. 2026-11-27: `wait N` was still cut to
/// 1-20 s, so `wait 0` waited 1 s and `wait 60` 20 s, each followed by another ~33k-token look: wait-only replies
/// were 15% of the free line's calls (32% on one phone), and one reply wrote `wait 0` 1327 times. Waiting costs
/// nothing; a look does. The waits of one reply are one wait (`fold`).
enum WaitFor {
    static let seconds = 5.0, most = 120.0, every = 0.8
    /// Plain `wait`: how long to watch for a change before asking the model again (a ceiling, 2 minutes: the user
    /// can stop or steer meanwhile), and how often to check.
    nonisolated(unsafe) static var plainMost = most  // tests with a still fake screen shorten it
    static let plainEvery = 0.25

    /// The words and whether they are to go, from what follows `wait`.
    static func parse(_ rest: String) -> (text: String, gone: Bool, seconds: Double)? {
        var r = rest.trimmingCharacters(in: .whitespaces)
        let gone = r.lowercased().hasPrefix("gone")
        if gone { r = String(r.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        guard let open = r.first, open == "\"" || open == "“" else { return nil }
        let body = r.dropFirst()
        guard let close = body.firstIndex(where: { $0 == "\"" || $0 == "”" }) else { return nil }
        let text = String(body[..<close]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let tail = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
        let secs = Double(tail.split(separator: " ").first.map(String.init) ?? "") ?? seconds
        return (text, gone, min(max(secs, 1), most))
    }

    /// `wait SECONDS`: nil (until the screen changes) for 0 or less, else at most `most`.
    static func seconds(_ n: Int) -> Double? { n > 0 ? min(Double(n), most) : nil }

    /// Plain waits in a row (no words) become one: untimed when any is, else their sum up to `most`. A wait for
    /// words keeps its own line.
    static func fold(_ acts: [JObject]) -> [JObject] {
        var out: [JObject] = []
        for a in acts {
            if plain(a), let last = out.last, plain(last) {
                let sum = last["seconds"]?.double.flatMap { s in a["seconds"]?.double.map { min(s + $0, most) } }
                out[out.count - 1]["seconds"] = sum.map { .num($0) }
                continue
            }
            out.append(a)
        }
        return out
    }

    private static func plain(_ a: JObject) -> Bool { a["action"]?.str == "wait" && a["text"] == nil }

    static func shows(_ text: String, in lines: [String]) -> Bool {
        let want = text.lowercased().filter { !$0.isWhitespace }
        return lines.contains { $0.lowercased().filter { !$0.isWhitespace }.contains(want) }
    }
}

extension AgentLoop {
    /// The wait's outcome for the model: met after how long, or not within the time.
    func waitFor(_ a: JObject) async throws -> String? {
        guard let text = a["text"]?.str, !text.isEmpty else {
            if let seconds = a["seconds"]?.double { return try await waitForChange(upTo: seconds, timed: true) }
            return try await waitForChange()
        }
        let gone = a["gone"]?.bool == true
        let limit = a["seconds"]?.double ?? WaitFor.seconds
        let started = now()
        while true {
            if let frame = screen?.frame {
                let lines = await Self.screenLines(frame).map(\.text)
                if WaitFor.shows(text, in: lines) != gone {
                    return String(format: "\"%@\" %@ after %.1f s", text, gone ? "is gone" : "shows", now() - started)
                }
            }
            if now() - started >= limit {
                return String(format: "\"%@\" %@ after %.0f s; look at the screen before going on", text,
                              gone ? "is still there" : "did not show", limit)
            }
            try await gate?()
            try await Task.sleep(nanoseconds: UInt64(WaitFor.every * 1e9))
        }
    }

    /// Plain `wait`: until the screen changes outside what moves by itself, up to WaitFor.plainMost, then settled.
    /// `limit` and `timed` (`wait N`): up to N s, what moves by itself sampled over 1.2 s (a countdown ticks once a
    /// second); with no change, "waited N s".
    func waitForChange(upTo limit: Double? = nil, timed: Bool = false) async throws -> String? {
        let started = now(), limit = limit ?? WaitFor.plainMost
        guard let first = screen?.frame else {
            if timed { try await Task.sleep(nanoseconds: UInt64(limit * 1e9)) }
            _ = await settle()
            return timed ? String(format: "waited %.0f s", limit) : nil
        }
        try await Task.sleep(nanoseconds: UInt64(min(timed ? 1.2 : 0.5, limit) * 1e9))
        // what moved on its own in the first half second (a spinner, a video): its changes alone don't end the wait
        let base = screen?.frame ?? first
        let moving = await Task.detached(priority: .userInitiated) { Vision.motion(first, base) }.value
        while now() - started < limit {
            try Task.checkCancellation()
            try await gate?()
            if let current = screen?.frame, current != base,
               await Task.detached(priority: .userInitiated, operation: { Vision.changed(base, current, busy: moving) }).value {
                let at = now() - started
                _ = await settle(busy: moving)
                return String(format: "the screen changed after %.1f s", at)
            }
            try await Task.sleep(nanoseconds: UInt64(WaitFor.plainEvery * 1e9))
        }
        if timed { return String(format: "waited %.0f s", limit) }
        return String(format: "nothing changed in %.0f s (only what moves by itself); look at the screen before going on",
                      limit)
    }
}

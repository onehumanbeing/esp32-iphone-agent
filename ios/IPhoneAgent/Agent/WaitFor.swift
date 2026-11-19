import Foundation

/// `wait "支付成功"` / `wait gone "加载中"` [SECONDS]: wait until the words show (or are gone), read by OCR about
/// once a second, up to SECONDS (default 5, at most 20). Lets one reply hold "tap 提交, wait "成功", tap 完成"
/// instead of a look per step, and a slow page is waited for instead of tapped through. Plain `wait` settles.
enum WaitFor {
    static let seconds = 5.0, most = 20.0, every = 0.8

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

    static func shows(_ text: String, in lines: [String]) -> Bool {
        let want = text.lowercased().filter { !$0.isWhitespace }
        return lines.contains { $0.lowercased().filter { !$0.isWhitespace }.contains(want) }
    }
}

extension AgentLoop {
    /// The wait's outcome for the model: met after how long, or not within the time.
    func waitFor(_ a: JObject) async throws -> String? {
        guard let text = a["text"]?.str, !text.isEmpty else {
            _ = await settle()
            return nil
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
}

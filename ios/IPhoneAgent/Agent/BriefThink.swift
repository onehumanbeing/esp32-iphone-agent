import Foundation

/// Settings › Model › Advanced › "Short reasons": the actor's THINK line is one short sentence instead of a check of
/// the last action plus the why. The model writes ~15 ms a token, and the step waits for THINK before its DO:
/// 2026-11-17, THINK was ~110 tokens a step (~1.6 s). Off unless turned on.
enum BriefThink {
    static let key = "briefThink"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    /// actor.md's THINK line, exactly as written there (a test keeps the two the same).
    static let full = """
        THINK: <plain English a non-technical user understands: first check your last action against the
               screen (did it do what you intended?), then what you do now and why>
        """
    static let brief = "THINK: <one short sentence, at most 15 words, plain English: did the last action work, and what you do now>"

    /// The actor prompt with the short THINK line when `on`.
    static func apply(_ prompt: String, on: Bool = BriefThink.on) -> String {
        on ? prompt.replacingOccurrences(of: full, with: brief) : prompt
    }
}

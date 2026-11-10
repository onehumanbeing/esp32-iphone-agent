import Foundation

/// A local input attempt stays visible to the actor until a later input supersedes it.
/// Even a lost HID acknowledgement must not authorize a second paste.
struct LocalInput {
    enum State { case copying, attempted, invalid }
    var state = State.invalid
    static let promptMarker = "\n\nLocal input: "

    static func needsClipboard(_ text: String) -> Bool {
        text.unicodeScalars.contains { !(0x20...0x7e).contains($0.value) }
    }

    var prompt: String {
        switch state {
        case .copying:
            return Self.promptMarker + "still copying; do not type or paste."
        case .attempted:
            return Self.promptMarker + "one paste was attempted for the previous type. Inspect the actual destination field, including any paste permission. A copy receipt or changed pixels does not prove insertion. Do not repeat cmd+v or retype the whole payload. If repair is needed, inspect the field first and explicitly type only the missing text."
        case .invalid:
            return Self.promptMarker + "no paste was sent. Inspect the reported error and destination before a new type. Do not paste old clipboard data or silently transliterate the payload."
        }
    }
}

extension AgentLoop {
    func markLocalPasteAttempt() {
        localInput = LocalInput(state: .attempted)
        record(nil, ["action": .str("local_paste_attempt"),
                     "reason": .str("One paste is about to be sent; its result needs inspection even if the acknowledgement is lost.")])
    }

    /// Deliberately separate the text result from a screen-change verdict.
    func typeLocally(_ text: String) async throws -> (field: String, value: String) {
        guard localInput?.state != .copying else {
            return ("typed", "nothing typed: another local copy is still running")
        }
        localInput = LocalInput(state: .invalid)
        guard let onUnicodeInput else {
            return ("typed", "nothing typed: local Unicode input is unavailable; no transliteration or paste was sent")
        }
        localInput?.state = .copying
        do {
            let result = try await onUnicodeInput(text)
            if localInput?.state != .attempted { localInput?.state = result.field == "pasted" ? .attempted : .invalid }
            return result
        } catch {
            if localInput?.state != .attempted { localInput?.state = .invalid }
            throw error
        }
    }
}

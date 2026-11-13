import Foundation

/// `clear`: empties the focused text field from the keyboard. cmd+a then backspace does not always select, so
/// the cursor goes to the end (cmd+down, cmd+right) and words are deleted (option+backspace) in bursts, each
/// read back, until the screen's text stops changing. Bounded; a first burst that changes nothing means no
/// text was deleted (no field focused, or it was empty).
@MainActor struct FieldClearer {
    var key: (String) async throws -> Void
    /// The screen's text once it settled; nil = no live screen (then two bursts go out unchecked).
    var read: () async -> [String]?
    static let burst = 12, rounds = 8

    /// nil = the field is empty; else a note for the model.
    func clear() async throws -> String? {
        try await key("cmd+down")
        try await key("cmd+right")
        guard var before = await read() else {
            for _ in 0..<2 { try await deleteBurst() }
            return "deleted \(2 * Self.burst) words unchecked (no screen to read)"
        }
        for round in 0..<Self.rounds {
            try await deleteBurst()
            guard let now = await read() else {
                return "deleted \((round + 1) * Self.burst) words, then the screen could not be read; the field may not be empty"
            }
            if now == before {
                return round == 0 ? "nothing was deleted: no text field is focused, or it was already empty" : nil
            }
            before = now
        }
        return "text was still being deleted after \(Self.rounds * Self.burst) words; clear again for the rest"
    }

    private func deleteBurst() async throws {
        for _ in 0..<Self.burst { try await key("alt+backspace") }
    }
}

extension Gestures {
    /// Fakes and phones without a screen: the keys go out unchecked.
    func clearField() async throws -> String? {
        try await FieldClearer(key: { [self] in try await key($0) }, read: { nil }).clear()
    }
}

extension Pointer {
    /// The focused field emptied (FieldClearer); nil when it is, else a note for the model.
    func clearField() async throws -> String? {
        let clearer = FieldClearer(key: { [self] in try await key($0) }, read: { [weak self] in
            guard let screen = self?.screen, screen.live else { return nil }
            await screen.settled(quiet: 0.3, least: 0.5, most: 2.0)
            guard let image = screen.frame.flatMap(Vision.image) else { return nil }
            let top = image.height * 6 / 100  // the status bar's clock is no progress
            return await UITreeOCR.lines(image).filter { $0.box[1] > top }.map(\.text)
        })
        let note = try await clearer.clear()
        log("clear: \(note ?? "the field is empty")")
        return note
    }
}

import XCTest
@testable import IPhoneAgent

/// Symbols checked against the hardware keyboard layout, and `clear` emptying a field word by word.
@MainActor final class FieldInputTests: XCTestCase {
    /// A field on screen behind a hardware keyboard whose layout maps some U.S. keys to other characters.
    private final class Field {
        var text = "", sent: [String] = []
        var layout: [Character: Character] = [:]
        var visible = true  // false: a password field, nothing readable
        var focused = true

        func send(_ s: String) { sent.append("type \(s)"); if focused { text += String(s.map { layout[$0] ?? $0 }) } }
        func key(_ k: String) {
            sent.append("key \(k)")
            guard focused, k == "alt+backspace" else { return }
            while text.last == " " { text.removeLast() }
            while let c = text.last, c != " " { text.removeLast() }
        }
        var seen: HanTyper.Seen {
            HanTyper.Seen(words: [(visible ? text : String(repeating: "•", count: text.count), [20, 280, 700, 320])], height: 1554)
        }
        var lines: [String] { visible && !text.isEmpty ? [text] : ["Search"] }
    }

    private func typer(_ f: Field) -> HanTyper {
        HanTyper(send: { f.send($0) }, key: { f.key($0) }, toggle: {}, look: { f.seen })
    }

    func testSymbolsTypedOnAUSLayoutPass() async throws {
        let f = Field()
        let note = try await typer(f).type("test@example.com", checkLetters: false)
        XCTAssertNil(note)
        XCTAssertEqual(f.text, "test@example.com")
    }

    func testSymbolsThatCameOutAsOtherCharactersAreReported() async throws {
        let f = Field()
        f.layout = ["@": "\""]
        let note = try await typer(f).type("test@example.com", checkLetters: false)
        let text = try XCTUnwrap(note)
        XCTAssertTrue(text.contains("not U.S.") && text.contains("@"), text)
    }

    func testAFieldThatShowsNoTextGivesNoVerdict() async throws {
        let f = Field()
        (f.layout, f.visible) = (["@": "\""], false)
        let note = try await typer(f).type("pass@word123", checkLetters: false)
        XCTAssertNil(note, "a password field shows dots: nothing to compare")
    }

    func testPlainTextNeedsNoLook() async throws {
        let f = Field()
        var looks = 0
        let typer = HanTyper(send: { f.send($0) }, key: { f.key($0) }, toggle: {}, look: { looks += 1; return f.seen })
        _ = try await typer.type("hello world. ok", checkLetters: false)
        XCTAssertEqual(looks, 0)
    }

    private func clearer(_ f: Field, screen: Bool = true) -> FieldClearer {
        FieldClearer(key: { f.key($0) }, read: { screen ? f.lines : nil })
    }

    func testClearGoesToTheEndAndDeletesUntilNothingChanges() async throws {
        let f = Field()
        f.text = (1...30).map { "word\($0)" }.joined(separator: " ")
        let note = try await clearer(f).clear()
        XCTAssertNil(note)
        XCTAssertEqual(f.text, "")
        XCTAssertEqual(Array(f.sent.prefix(2)), ["key cmd+down", "key cmd+right"])
        XCTAssertLessThanOrEqual(f.sent.count, 2 + FieldClearer.burst * FieldClearer.rounds)
    }

    func testClearWithNothingDeletedSaysSo() async throws {
        let f = Field()
        f.focused = false
        f.text = "not in a field"
        let note = try await clearer(f).clear()
        XCTAssertTrue(note?.contains("nothing was deleted") == true, note ?? "nil")
    }

    func testClearIsBoundedOnAVeryLongText() async throws {
        let f = Field()
        f.text = (1...500).map { "w\($0)" }.joined(separator: " ")
        let note = try await clearer(f).clear()
        XCTAssertTrue(note?.contains("still being deleted") == true, note ?? "nil")
        XCTAssertEqual(f.sent.count, 2 + FieldClearer.burst * FieldClearer.rounds)
    }

    func testClearIsAnActionTheParserKnows() throws {
        let acts = try Actions.parseActions("THINK: x\nDO: tap 500 300\nDO: clear\nDO: type hello")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["tap", "clear", "type"])
        XCTAssertTrue(Prompts.actor.contains("clear "))
    }
}

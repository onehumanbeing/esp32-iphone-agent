import SwiftUI

/// First launch only: the Welcome page asks "Do you have an ESP32 board?". Not yet opens manina.ai's page on where to
/// get one; either way setup goes on. Asked once: the answer is kept, and a user who finished setup before this
/// question existed is never asked (`skipIfOnboarded` at launch, so "Run setup again" doesn't ask either).
enum BoardQuestion {
    static let key = "hasBoardAnswer"  // "yes", "no", or "skipped" (finished setup before the question)
    static let event = "has_board_answer"

    enum Answer: String { case yes, no }

    static func shouldAsk(onboarded: Bool, defaults: UserDefaults = .standard) -> Bool {
        !onboarded && defaults.string(forKey: key) == nil
    }

    static func skipIfOnboarded(_ onboarded: Bool, defaults: UserDefaults = .standard) {
        if onboarded && defaults.string(forKey: key) == nil { defaults.set("skipped", forKey: key) }
    }

    /// Keeps the answer; the stats event (only the answer) goes out only when the user turned stats on.
    @MainActor static func record(_ answer: Answer, defaults: UserDefaults = .standard, statsOn: Bool? = nil,
                                  send: ((String, [String: Any]) -> Void)? = nil) {
        defaults.set(answer.rawValue, forKey: key)
        guard statsOn ?? Analytics.enabled else { return }
        (send ?? { Analytics.capture($0, $1) })(event, ["answer": answer.rawValue])
    }

    /// manina.ai's where-to-buy page, in the language the app shows.
    static func url(language: String? = Bundle.main.preferredLocalizations.first) -> URL {
        let zh = language?.hasPrefix("zh") == true
        return URL(string: "https://manina.ai/" + (zh ? "zh/" : "") + "where-to-buy-esp32?from=app")!
    }
}

/// The question on the Welcome page. Until it is answered, the page's button stays off.
struct BoardQuestionPanel: View {
    let answer: BoardQuestion.Answer?
    let answered: (BoardQuestion.Answer) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Panel {
            Label("Do you have an ESP32 board?", systemImage: "cpu").font(.body.weight(.semibold))
            switch answer {
            case nil:
                Text("I see and tap this iPhone through a small ESP32 board.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                HStack(spacing: Space.m) {
                    Button("Not yet") { answered(.no); openURL(BoardQuestion.url()) }
                    Button("Yes") { answered(.yes) }
                }
                .buttonStyle(BigButton.tinted)
                .padding(.top, Space.m)
            case .yes:
                CheckRow(title: "I have a board", done: true).padding(.top, Space.s)
            case .no:
                Text("Set up the app now and connect the board when it arrives.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                Link(destination: BoardQuestion.url()) {
                    Label("Get a board", systemImage: "arrow.up.right.square")
                }
                .font(.footnote.weight(.semibold)).padding(.top, Space.s)
            }
        }
    }
}

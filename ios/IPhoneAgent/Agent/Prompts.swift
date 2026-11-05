import Foundation

/// The model prompts, kept as plain text in the repository's `prompts/` folder (bundled with the app) so they
/// can be read and tuned without touching Swift. actor/planner = the shared rules + the app-only rules.
enum Prompts {
    static let planner = load("planner")
    static let actorServer = load("actor")
    static let appRules = load("app-rules")
    /// Copies items off one screen for the notebook (the `read` action).
    static let reader = load("reader")

    static let actor = actorServer + "\n" + appRules + language
    static let plannerApp = planner + "\n" + appRules + language

    /// The plan and notes show up in the app: write them in the app's language. Actions and JSON keys stay as specified.
    static let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        ? "\nWrite the plan, notes and reasons in Simplified Chinese. Action names, JSON keys and coordinates stay as specified."
        : ""

    /// One file from the bundled prompts folder, without the file's final newline.
    static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("prompts/\(name).md is missing from the app bundle")
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

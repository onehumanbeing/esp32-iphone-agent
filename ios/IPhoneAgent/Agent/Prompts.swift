import Foundation

/// The model prompts, kept as plain text in the repository's `prompts/` folder (bundled with the app) so they
/// can be read and tuned without touching Swift. actor = the step rules + the app-only rules (one model, one loop:
/// it keeps its own plan; the Python server in server/hidagent still has the older planner + actor copies).
/// An iPad gets its own set, `prompts/ipad/` (its layouts, the dock, Split View, back); an iPhone the files in
/// `prompts/` as they are.
enum Prompts {
    enum Device {
        case phone, pad
        static var current: Device { DeviceKind.isPad ? .pad : .phone }
    }

    static let actorServer = load("actor", for: .current)
    static let appRules = load("app-rules", for: .current)
    /// Copies items off one screen for the notebook (the `read` action).
    static let reader = load("reader", for: .current)

    static let actor = actor(for: .current)

    static func actor(for device: Device) -> String {
        load("actor", for: device) + "\n" + load("app-rules", for: device) + language
    }

    /// The plan and notes show up in the app: write them in the app's language. Actions and JSON keys stay as specified.
    static let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        ? "\nWrite the plan, notes and reasons in Simplified Chinese. Action names, JSON keys and coordinates stay as specified."
        : ""

    /// One file from the bundled prompts folder (prompts/ipad/ on an iPad), without the file's final newline.
    static func load(_ name: String, for device: Device = .phone) -> String {
        let folder = device == .pad ? "prompts/ipad" : "prompts"
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: folder),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("\(folder)/\(name).md is missing from the app bundle")
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

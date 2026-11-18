import Foundation

/// The model prompts, kept as plain text in the repository's `prompts/` folder (bundled with the app) so they
/// can be read and tuned without touching Swift. actor = the step rules + the app-only rules (one model, one loop:
/// it keeps its own plan; the Python server in server/hidagent still has the older planner + actor copies).
///
/// One set for every device. An iPhone gets the files as they are (the `<!-- iPhone only -->` marker lines taken
/// out). An iPad gets the same text with "iPhone" read as "iPad", without the iPhone-only passages, and its own
/// rules after it (`prompts/devices/ipad.md`, `ipad-reader.md`): what differs comes last, the shared part stays one.
enum Prompts {
    enum Device {
        case phone, pad
        static var current: Device { DeviceKind.isPad ? .pad : .phone }
    }

    static let actorServer = shared("actor", for: .current)
    static let appRules = shared("app-rules", for: .current)
    /// Copies items off one screen for the notebook (the `read` action).
    static let reader = reader(for: .current)

    static let actor = actor(for: .current)

    static func actor(for device: Device) -> String {
        shared("actor", for: device) + "\n" + shared("app-rules", for: device) + tail("ipad", for: device) + language
    }

    static func reader(for device: Device) -> String { shared("reader", for: device) + tail("ipad-reader", for: device) }

    /// The plan and notes show up in the app: write them in the app's language. Actions and JSON keys stay as specified.
    static let language = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        ? "\nWrite the plan, notes and reasons in Simplified Chinese. Action names, JSON keys and coordinates stay as specified."
        : ""

    static let phoneOnly = "<!-- iPhone only -->", phoneOnlyEnd = "<!-- /iPhone only -->"

    /// A shared prompt for `device`: iPhone the file without the marker lines, iPad without the iPhone-only passages
    /// and with the device named "iPad".
    static func shared(_ name: String, for device: Device) -> String {
        var lines: [Substring] = [], phoneOnlyPart = false
        for line in load(name).split(separator: "\n", omittingEmptySubsequences: false) {
            if line == phoneOnly { phoneOnlyPart = true; continue }
            if line == phoneOnlyEnd { phoneOnlyPart = false; continue }
            if !phoneOnlyPart || device == .phone { lines.append(line) }
        }
        let text = lines.joined(separator: "\n")
        return device == .pad ? text.replacingOccurrences(of: "iPhone", with: "iPad") : text
    }

    /// A device's own rules (`prompts/devices/<name>.md`), after the shared text; nothing on an iPhone.
    static func tail(_ name: String, for device: Device) -> String {
        device == .pad ? "\n" + load("devices/" + name) : ""
    }

    /// One file from the bundled prompts folder, without the file's final newline.
    static func load(_ name: String) -> String {
        let parts = name.split(separator: "/")
        let folder = (["prompts"] + parts.dropLast().map(String.init)).joined(separator: "/")
        guard let url = Bundle.main.url(forResource: String(parts.last!), withExtension: "md", subdirectory: folder),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("prompts/\(name).md is missing from the app bundle")
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

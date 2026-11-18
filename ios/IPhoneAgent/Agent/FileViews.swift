import Foundation

/// `file view` calls of a run: a path viewed again with no write in between shows nothing new.
enum FileViews {
    static let again = "unchanged since you last viewed it (nothing was written since): it is as shown before. "
        + "If it is right, finish with done; else change it"

    /// The path a `file {JSON}` line views, nil for any other command.
    static func viewed(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["command"] as? String == "view" else { return nil }
        let path = (json["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return path + ((json["view_range"] as? [Int]).map { " \($0)" } ?? "")
    }
}

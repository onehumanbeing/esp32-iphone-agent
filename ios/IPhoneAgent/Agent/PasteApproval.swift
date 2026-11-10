import Foundation

enum PasteApproval {
    static func shown(_ lines: [String]) -> Bool {
        let labels = Set(lines.map { $0.lowercased().filter { !$0.isWhitespace }.replacingOccurrences(of: "’", with: "'") })
        return labels.contains("allowpaste") && labels.contains("don'tallowpaste")
            || labels.contains("允许粘贴") && (labels.contains("不允许粘贴") || labels.contains("不允许"))
    }

    static func read(_ frame: Data) async -> Bool {
        guard let image = Vision.image(frame) else { return false }
        // `languages: nil` retains whole labels; the tree's default splits "Allow Paste" into words.
        return shown(await UITreeOCR.lines(image, languages: nil).map(\.text))
    }
}

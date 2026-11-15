import SwiftUI

/// One name in the agent directory, with the facts the row needs. Identity is the name in this folder.
struct AgentFileEntry: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var bytes: Int

    var text: Bool { !isDirectory && FileSandbox.textExtensions.contains((name as NSString).pathExtension.lowercased()) }
    var image: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !isDirectory && ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
    }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        if image { return "photo" }
        if text { return "doc.text" }
        return "doc"
    }
    var tint: Color {
        if isDirectory { return .blue }
        if image { return .purple }
        if text { return .teal }
        return .secondary
    }
    var detail: String {
        if isDirectory { return String(localized: "Folder") }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }
}

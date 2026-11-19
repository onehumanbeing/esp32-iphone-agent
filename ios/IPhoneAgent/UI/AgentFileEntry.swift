import SwiftUI

/// One name in the agent directory, with the facts the row needs. Identity is the name in this folder.
struct AgentFileEntry: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var bytes: Int
    var relative: String = ""  // from Documents, e.g. "memory/results"; names the app's own folders
    var note: String? = nil  // a search hit: the matching line, or the folder it is in

    var text: Bool { !isDirectory && FileSandbox.textExtensions.contains(ext) }
    var markdown: Bool { !isDirectory && ["md", "markdown"].contains(ext) }
    var image: Bool { !isDirectory && ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) }
    var intent: Bool { !isDirectory && IntentArchive.isIntentFile(name) }
    var memory: Bool { FilesLayout.isMemoryFile(relative) }
    var title: String {
        if memory { return String(localized: "Memory") }
        if intent { return (name as NSString).deletingPathExtension }
        return FilesLayout.displayName(relative.isEmpty ? name : relative)
    }

    var symbol: String {
        if memory { return "brain.head.profile" }
        if let known = FilesLayout.symbol(relative) { return known }
        if isDirectory { return "folder.fill" }
        if intent { return "bolt.fill" }
        if image { return "photo" }
        if markdown { return "doc.richtext" }
        if text { return "doc.text" }
        return "doc"
    }
    var tint: Color {
        if memory || FilesLayout.symbol(relative) != nil { return .accentColor }
        if isDirectory { return .blue }
        if intent { return .orange }
        if image { return .purple }
        if text { return .teal }
        return .secondary
    }
    var detail: String {
        if let note { return note }
        if memory { return "MEMORY.md" }
        if isDirectory { return String(localized: "Folder") }
        if intent { return String(localized: "Intent · \(size)") }
        return size
    }

    private var ext: String { (name as NSString).pathExtension.lowercased() }
    private var size: String { Int64(bytes).formatted(.byteCount(style: .file)) }
}

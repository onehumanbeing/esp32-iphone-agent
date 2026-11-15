import Foundation
import UIKit

/// This app's files on the iPhone: Documents, where `memory/MEMORY.md` lives, along with traces and recordings.
/// Every path the file browser and the plan editor use is checked against a root so `..` and a symlink cannot leave it.
enum AgentFiles {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// True when `url` is the agent directory or something inside it, after `..` and symlinks are resolved.
    static func contains(_ url: URL) -> Bool {
        let root = Self.root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }
}

/// One tool call from the plan-editing model. The body is the text (or base64) between the call and a line `END`.
struct FileCall: Equatable {
    var name: String
    var args: [String]
    var body: String = ""
}

/// The file tools a plan edit may call. Writes are text or a real image, and only inside the sandbox.
/// The phone-driving agent does not get these: a recording is edited here, not by tapping the device.
enum FileTool {
    static let edit: Set<String> = ["list", "read", "write", "save_image", "screenshot", "crop"]
    static let review: Set<String> = ["list", "read"]

    static func parse(_ reply: String) -> (message: String, calls: [FileCall]) {
        let lines = reply.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var message: [String] = []
        var calls: [FileCall] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let head = trimmed.uppercased()
            if head == "END" { i += 1; continue }
            if head.hasPrefix("TOOL ") || head.hasPrefix("TOOL\t") {
                let rest = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let (name, args) = tokens(String(rest))
                let needsBody = name.lowercased() == "write" || name.lowercased() == "save_image"
                var body = ""
                if needsBody {
                    var buf: [String] = []
                    i += 1
                    while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "END" {
                        buf.append(lines[i])
                        i += 1
                    }
                    body = buf.joined(separator: "\n")
                }
                calls.append(FileCall(name: name.lowercased(), args: args, body: body))
            } else if head.hasPrefix("MESSAGE:") {
                let text = trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { message.append(String(text)) }
            } else if !trimmed.isEmpty {
                message.append(trimmed)
            }
            i += 1
        }
        return (message.joined(separator: "\n"), calls)
    }

    /// Words, with `"quoted parts"` kept together.
    static func tokens(_ line: String) -> (String, [String]) {
        var out: [String] = []
        var current = ""
        var quoting = false
        for ch in line {
            if quoting {
                if ch == "\"" { out.append(current); current = ""; quoting = false }
                else { current.append(ch) }
                continue
            }
            if ch == "\"" { quoting = true; continue }
            if ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return (out.first ?? "", Array(out.dropFirst()))
    }
}

/// A directory the tools may use, and nothing above it.
struct FileSandbox {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// A plan folder under Documents. Nil when the folder is missing or sits outside the agent directory.
    static func insideAgentData(_ folder: URL) -> FileSandbox? {
        guard AgentFiles.contains(folder) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return FileSandbox(root: folder)
    }

    func resolve(_ relative: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." { return root }
        if trimmed.contains("\0") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return nil }
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.isEmpty || parts.contains(where: { $0 == ".." || $0.isEmpty }) { return nil }
        var url = root
        for part in parts {
            if part == "." { continue }
            if part.contains("\0") || part.contains("/") { return nil }
            url = url.appendingPathComponent(part)
            if let dest = symlinkDestination(url) {
                guard isInside(dest) else { return nil }
                url = dest
            }
        }
        let standard = url.standardizedFileURL
        guard isInside(standard) else { return nil }
        return standard
    }

    func isInside(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }

    func textFile(_ relative: String, limit: Int = 200_000) -> String? {
        guard let url = resolve(relative), let data = try? Data(contentsOf: url), data.count <= limit,
              !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// The user saving a text file they opened. Still cannot leave the folder. Images stay on the image tools.
    func saveUserText(_ text: String, to relative: String) -> String? {
        guard let url = resolve(relative) else { return String(localized: "That file is outside this app's files.") }
        guard text.utf8.count <= 500_000, !text.utf8.contains(0) else {
            return String(localized: "That file is too large to edit here.")
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Copy a file the user picked into this folder. Nil when it landed.
    func importFile(from url: URL, name: String) -> String? {
        let base = (name as NSString).lastPathComponent
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/"), !base.contains("\0"),
              let dest = resolve(uniqueName(base)) else {
            return String(localized: "That file can't be saved here.")
        }
        guard let data = try? Data(contentsOf: url), data.count <= 40_000_000 else {
            return String(localized: "That file is too large to import.")
        }
        do {
            try data.write(to: dest, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func perform(_ call: FileCall, allow: Set<String>) -> String {
        guard FileTool.edit.contains(call.name) else { return "refused: unknown tool \(call.name)" }
        guard allow.contains(call.name) else { return "refused: \(call.name) is not available in this pass" }
        switch call.name {
        case "list": return list(call.args.first ?? ".")
        case "read":
            guard let path = call.args.first, !path.isEmpty else { return "refused: read needs a file" }
            return read(path)
        case "write":
            guard let path = call.args.first, !path.isEmpty else { return "refused: write needs a file" }
            return writeText(path, call.body)
        case "screenshot":
            guard call.args.count >= 2, let index = Int(call.args[0]) else {
                return "refused: screenshot needs a frame number and a new .jpg name"
            }
            return screenshot(index, call.args[1])
        case "crop":
            guard call.args.count >= 6, let x = Int(call.args[1]), let y = Int(call.args[2]),
                  let w = Int(call.args[3]), let h = Int(call.args[4]) else {
                return "refused: crop needs source x y w h dest.jpg"
            }
            return crop(call.args[0], x, y, w, h, call.args[5])
        case "save_image":
            guard let path = call.args.first, !path.isEmpty else { return "refused: save_image needs a .jpg name" }
            return saveImage(path, call.body)
        default:
            return "refused: unknown tool \(call.name)"
        }
    }

    // MARK: - tools

    private func list(_ relative: String) -> String {
        guard let url = resolve(relative) else { return "refused: path leaves the folder" }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return "refused: not a folder" }
        let rows = items.sorted {
            let da = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let db = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if da != db { return da }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.prefix(200).map { item -> String in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return item.lastPathComponent + "\tlink" }
            if values?.isDirectory == true { return item.lastPathComponent + "/" }
            return "\(item.lastPathComponent)\t\(values?.fileSize ?? 0)"
        }
        return rows.isEmpty ? "ok: empty" : "ok:\n" + rows.joined(separator: "\n")
    }

    private func read(_ relative: String) -> String {
        guard let url = resolve(relative) else { return "refused: path leaves the folder" }
        guard let data = try? Data(contentsOf: url) else { return "refused: no such file" }
        if Self.isImageName(url.lastPathComponent), let image = UIImage(data: data) {
            let size = image.size
            return "ok: image \(Int(size.width))x\(Int(size.height)), \(data.count) bytes"
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return "refused: not text" }
        if text.count <= 12_000 { return "ok:\n" + text }
        return "ok:\n" + text.prefix(12_000) + "\n…(truncated)"
    }

    private func writeText(_ relative: String, _ text: String) -> String {
        guard let url = resolve(relative) else { return "refused: path leaves the folder" }
        guard !Self.protected(relative) else { return "refused: that file is part of the recording and is left as it is" }
        let ext = url.pathExtension.lowercased()
        guard Self.textExtensions.contains(ext) else { return "refused: write only saves text (.txt, .md, .json, .jsonl)" }
        guard !text.isEmpty else { return "refused: empty text" }
        guard text.utf8.count <= 200_000, !text.utf8.contains(0) else { return "refused: not text, or too large" }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return "ok: wrote \(text.utf8.count) bytes to \(url.lastPathComponent)"
        } catch {
            return "refused: \(error.localizedDescription)"
        }
    }

    private func screenshot(_ index: Int, _ dest: String) -> String {
        let frames = keyframes()
        guard index >= 1, frames.indices.contains(index - 1) else { return "refused: there is no frame \(index)" }
        guard let data = try? Data(contentsOf: frames[index - 1]), UIImage(data: data) != nil else {
            return "refused: frame \(index) is not an image"
        }
        return writeImage(dest, data, "frame \(index)")
    }

    private func crop(_ source: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ dest: String) -> String {
        guard let url = resolve(source), let data = try? Data(contentsOf: url),
              let jpeg = Self.cropJPEG(data, x: x, y: y, w: w, h: h) else {
            return "refused: could not crop \(source)"
        }
        return writeImage(dest, jpeg, "crop")
    }

    private func saveImage(_ dest: String, _ body: String) -> String {
        let cleaned = body.filter { !$0.isWhitespace }
        guard cleaned.count <= 2_000_000, let data = Data(base64Encoded: cleaned),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
            return "refused: not an image"
        }
        return writeImage(dest, jpeg, "image")
    }

    private func writeImage(_ dest: String, _ data: Data, _ what: String) -> String {
        guard Self.isImageName(dest) else { return "refused: images are saved as .jpg" }
        guard !Self.protected(dest) else { return "refused: won't replace a recording frame" }
        guard let url = resolve(dest) else { return "refused: path leaves the folder" }
        do {
            try data.write(to: url, options: .atomic)
            return "ok: saved \(what) to \(url.lastPathComponent) (\(data.count) bytes)"
        } catch {
            return "refused: \(error.localizedDescription)"
        }
    }

    func keyframes() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let keyed = items.filter { $0.lastPathComponent.range(of: #"^k\d+\.jpg$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !keyed.isEmpty { return keyed }
        return items.filter { $0.lastPathComponent.range(of: #"^\d+\.jpg$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - paths

    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "jsonl", "csv", "log", "text"]

    static func isImageName(_ name: String) -> Bool {
        ["jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Recording evidence the editor may read and crop from, and must not overwrite.
    static func protected(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { $0 == "video" }) || parts.first == "video" { return true }
        let name = parts.last ?? relative
        if ["review.json", "steps.jsonl", "metrics.json", "keyframes.txt", "pending.txt"].contains(name) { return true }
        if name.range(of: #"^k\d+\.jpg$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"^\d+\.jpg$"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func cropJPEG(_ data: Data, x: Int, y: Int, w: Int, h: Int) -> Data? {
        guard w > 0, h > 0, let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard width > 1, height > 1 else { return nil }
        let px = max(0, min(width - 1, x * width / 1000))
        let py = max(0, min(height - 1, y * height / 1000))
        let pw = max(1, min(width - px, max(1, w) * width / 1000))
        let ph = max(1, min(height - py, max(1, h) * height / 1000))
        guard let cut = cg.cropping(to: CGRect(x: px, y: py, width: pw, height: ph)) else { return nil }
        return UIImage(cgImage: cut).jpegData(compressionQuality: 0.85)
    }

    /// Where a symlink points, or nil when `url` is not a link. Relative links are resolved from their parent.
    private func symlinkDestination(_ url: URL) -> URL? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func uniqueName(_ name: String) -> String {
        var candidate = name
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path), n < 50 {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}

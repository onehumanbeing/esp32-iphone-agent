import Foundation

/// The user's own changes in the Files tab: new folder, new note, rename, delete. Never outside the folder,
/// never the app's own folders (FilesLayout.isSystem), and a run's evidence only with developer files shown.
extension FileSandbox {
    /// A name the user typed, as one path component, or nil.
    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"), name.count <= 120 else {
            return nil
        }
        return name
    }

    /// A new folder in `folder`; " 2" and so on when the name is taken. The new folder's path, or a message.
    func makeFolder(in folder: String, named raw: String) -> Result<String, ManageError> {
        guard let name = Self.cleanName(raw) else { return .failure(.badName) }
        guard let parent = resolve(folder) else { return .failure(.outside) }
        let path = Self.join(folder, FileSandbox(root: parent).uniqueName(name))
        guard let url = resolve(path) else { return .failure(.outside) }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch {
            return .failure(.failed(error.localizedDescription))
        }
        return .success(path)
    }

    /// A new, empty Markdown note in `folder`.
    func makeNote(in folder: String, named raw: String) -> Result<String, ManageError> {
        guard var name = Self.cleanName(raw) else { return .failure(.badName) }
        if (name as NSString).pathExtension.lowercased() != "md" { name += ".md" }
        guard let parent = resolve(folder) else { return .failure(.outside) }
        let path = Self.join(folder, FileSandbox(root: parent).uniqueName(name))
        guard let url = resolve(path) else { return .failure(.outside) }
        let title = "# " + (name as NSString).deletingPathExtension + "\n"
        do { try Data(title.utf8).write(to: url, options: .withoutOverwriting) } catch {
            return .failure(.failed(error.localizedDescription))
        }
        return .success(path)
    }

    func rename(_ relative: String, to raw: String, developer: Bool = FilesLayout.showsDeveloper) -> ManageError? {
        if let refusal = refuseChange(relative, developer: developer) { return refusal }
        guard let name = Self.cleanName(raw) else { return .badName }
        let path = Self.join((relative as NSString).deletingLastPathComponent, name)
        guard let from = resolve(relative), let to = resolve(path) else { return .outside }
        guard !FileManager.default.fileExists(atPath: to.path) else { return .taken }
        do { try FileManager.default.moveItem(at: from, to: to) } catch { return .failed(error.localizedDescription) }
        return nil
    }

    func remove(_ relative: String, developer: Bool = FilesLayout.showsDeveloper) -> ManageError? {
        if let refusal = refuseChange(relative, developer: developer) { return refusal }
        guard let url = resolve(relative), url != root else { return .outside }
        do { try FileManager.default.removeItem(at: url) } catch { return .failed(error.localizedDescription) }
        return nil
    }

    /// May the user rename or delete this? (The same rule hides those actions in the list.)
    static func canChange(_ relative: String, developer: Bool = FilesLayout.showsDeveloper) -> Bool {
        !relative.isEmpty && !FilesLayout.isSystem(relative) && (developer || !protected(relative, frames: MemoryFiles.isReserved(relative)))
    }

    private func refuseChange(_ relative: String, developer: Bool) -> ManageError? {
        Self.canChange(relative, developer: developer) ? nil : .appFile
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty || folder == "." ? name : folder + "/" + name
    }
}

enum ManageError: Error, Equatable {
    case badName, outside, taken, appFile
    case failed(String)

    var message: String {
        switch self {
        case .badName: String(localized: "Use a name without / that doesn't start with a dot.")
        case .outside: String(localized: "That file is outside this app's files.")
        case .taken: String(localized: "Something with that name is already here.")
        case .appFile: String(localized: "The app needs this one; it can't be renamed or deleted.")
        case .failed(let reason): reason
        }
    }
}

extension Result {
    var error: Failure? { if case .failure(let e) = self { e } else { nil } }
}

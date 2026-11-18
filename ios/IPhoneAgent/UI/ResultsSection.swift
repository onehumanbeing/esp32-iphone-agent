import SwiftUI

/// A result folder at the top of Files, with the run that wrote it (if it is still among the loaded runs).
struct ResultFolder: Identifiable {
    var id: URL { url }
    let url: URL
    let date: Date
    let run: Run?
    let from: String?  // the intent's name, or the run's task

    /// Newest first, by when the folder last changed.
    @MainActor static func list(_ app: AppModel) -> [ResultFolder] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: MemoryFiles.root, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { url -> ResultFolder? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, !MemoryFiles.isReserved(url.lastPathComponent) else { return nil }
            let run = origin(of: url, app)
            // a result: a run wrote it, or it has a README or the run's notes (the user's own folders stay below)
            let marks = ["README.md", LiveNotes.file].map { url.appendingPathComponent($0).path }
            guard run != nil || marks.contains(where: FileManager.default.fileExists) else { return nil }
            return ResultFolder(url: url, date: lastChange(url, values?.contentModificationDate), run: run,
                                from: run.map { app.title(of: $0) })
        }.sorted { $0.date > $1.date }
    }

    /// When anything in the folder last changed: a note appended to notes.md leaves the folder's own date alone.
    static func lastChange(_ folder: URL, _ own: Date?) -> Date {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        let dates = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return (dates + [own].compactMap { $0 }).max() ?? .distantPast
    }

    /// The newest loaded run that wrote into this result folder.
    @MainActor static func origin(of folder: URL, _ app: AppModel) -> Run? {
        RunOutputs.source(of: folder.lastPathComponent, in: app.runs.runs)
    }
}

extension AppModel {
    /// What a run is called in a list: its intent's name, or else the words it ran.
    func title(of run: Run) -> String { intents.intent(of: run)?.name ?? run.task }
}

/// Files tab root: every result folder, newest first, each with the run it came from. They are not listed again
/// below with the other files (Henry 2026-11-19: the same folders twice looked wrong).
struct ResultsSection: View {
    @ObservedObject var app: AppModel
    let folders: [ResultFolder]
    var delete: (URL) -> Void = { _ in }

    var body: some View {
        Section {
            ForEach(folders) { folder in
                NavigationLink { LocalFilesView(app: app, directory: folder.url) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(spacing: Space.xs) {
                                Text(verbatim: folder.url.lastPathComponent).lineLimit(1)
                                if let run = folder.run, run.id == app.runs.runs.first?.id {
                                    Text("Latest Run").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(verbatim: subtitle(folder)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "tray.full").foregroundStyle(Color.accentColor).frame(width: 28)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(folder.url) }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(folder.url) }
                }
            }
        } header: {
            Text("Results")
        }
    }

    private func subtitle(_ folder: ResultFolder) -> String {
        let date = folder.date.formatted(.dateTime.month().day().hour().minute())  // updated at, to the minute
        guard let from = folder.from, !from.isEmpty else { return date }
        return String(localized: "From: \(from) · \(date)")
    }
}

/// A result folder's page: a way back to the run that made it.
struct ResultOriginSection: View {
    @ObservedObject var app: AppModel
    let run: Run

    var body: some View {
        Section {
            Button { app.openReview(run: run.id) } label: {
                Label {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("From This Run")
                        Text(verbatim: app.title(of: run) + " · " + run.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: {
                    Image(systemName: "play.rectangle")
                }
            }
        }
    }
}

/// The Files tab's search: names of folders and files, and the text of the notes and tables the agent writes
/// (README, notes.md, csv, txt), all on this iPhone. Henry 2026-11-19: many result folders, no way to find one.
/// Walks two levels (a result folder and its files); hidden and internal names are skipped as in the list.
enum FileSearch {
    struct Hit: Identifiable, Equatable {
        var id: String { relative }
        let relative: String  // from Documents
        let isDirectory: Bool
        let line: String?  // the matching line of the text, nil when the name matched
    }

    static let maxTextBytes = 2_000_000  // only for reading a file's text; a larger file is matched by name

    static func run(_ query: String, root: URL, developer: Bool) -> [Hit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ s: String) -> Bool { let l = s.lowercased(); return words.allSatisfy(l.contains) }
        var hits: [Hit] = []
        for (relative, isDirectory) in walk(root, developer: developer) {
            let name = (relative as NSString).lastPathComponent
            if matches(name) { hits.append(Hit(relative: relative, isDirectory: isDirectory, line: nil)); continue }
            guard !isDirectory, ["md", "markdown", "csv", "txt"].contains((name as NSString).pathExtension.lowercased()),
                  let line = textLine(root.appendingPathComponent(relative), words) else { continue }
            hits.append(Hit(relative: relative, isDirectory: false, line: line))
        }
        return hits
    }

    private static func walk(_ root: URL, developer: Bool) -> [(String, Bool)] {
        let fm = FileManager.default
        var out: [(String, Bool)] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard FilesLayout.isVisible(name, developer: developer) else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            out.append((name, isDir))
            guard isDir else { continue }
            let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                out.append((name + "/" + child.lastPathComponent, (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true))
            }
        }
        return out
    }

    /// The file's line with every word, else the first line with any of them (the words may sit on several lines).
    private static func textLine(_ url: URL, _ words: [String]) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxTextBytes,
              let text = try? String(contentsOf: url, encoding: .utf8), words.allSatisfy(text.lowercased().contains) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let line = lines.first { l in words.allSatisfy(l.lowercased().contains) }
            ?? lines.first { l in words.contains(where: l.lowercased().contains) } ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
    }
}

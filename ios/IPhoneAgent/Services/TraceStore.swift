import Foundation

/// Debug traces: one folder per agent run (Documents/traces/<date>) with every model call, the screenshot it
/// saw, step timings and a metrics.json snapshot. Port of debug.py; Documents is shared with Finder/devicectl.
@MainActor final class TraceStore {
    let root: URL
    private(set) var dir: URL?
    private var n = 0

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("traces")) {
        self.root = root
    }

    func start(task: String) {
        let d = root.appendingPathComponent(Self.folderName())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        n = 0
        write(kind: "task", ["task": .str(task)])
    }

    /// Go on writing an existing run folder (a run resumed from disk, a demonstration written as a run).
    func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dir = folder
        n = (try? String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
    }

    /// A new run folder's name: its start time, yyyyMMdd-HHmmss (also the run's id and its date).
    static func folderName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    func write(_ frame: Data? = nil, kind: String, _ record: JObject) {
        guard let dir else { return }
        n += 1
        var line = JObject([("n", .int(n)), ("t", .num(now())), ("kind", .str(kind))]).merging(record)
        if let frame {
            let name = String(format: "%03d.jpg", n)
            line["frame"] = .str(name)
            try? frame.write(to: dir.appendingPathComponent(name))
        }
        append(PyJSON.dumps(line, ascii: false) + "\n", to: dir.appendingPathComponent("steps.jsonl"))
    }

    func writeMetrics(_ metrics: [String: Any]) {
        guard let dir, JSONSerialization.isValidJSONObject(metrics),
              let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appendingPathComponent("metrics.json"))
    }

    func runs() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// All traces zipped (via a coordinated read "for uploading"), for the share sheet.
    nonisolated static func zip(_ folder: URL, name: String = "traces.zip") throws -> URL {
        var result: URL?, failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { tmp in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            do { try FileManager.default.copyItem(at: tmp, to: out); result = out } catch { failure = error }
        }
        if let e = coordError ?? failure { throw e }
        guard let result else { throw DeviceError(message: "zip failed") }
        return result
    }

    private func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

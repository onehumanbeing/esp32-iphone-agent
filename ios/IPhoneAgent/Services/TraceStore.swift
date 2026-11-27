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

    /// A new run folder. `intent`: the saved intent that started it, so the run, its files and the intent link up.
    func start(task: String, intent: SavedTask? = nil) {
        let d = root.appendingPathComponent(Self.folderName())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        n = 0
        var record: JObject = ["task": .str(task)]
        if let intent {
            record["intent"] = .str(intent.id.uuidString)
            record["intent_name"] = .str(intent.name)
        }
        write(kind: "task", record)
    }

    /// Go on writing an existing run folder (a run resumed from disk, a demonstration written as a run).
    func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dir = folder
        n = (try? String(contentsOf: folder.appendingPathComponent("steps.jsonl"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
    }

    static let videoDays = 3.0

    /// Debug builds (the harness, development) never delete traces: the 300 MB budget deleted a whole night of test
    /// runs before they were copied off for training (2026-11-27, Henry). Release/TestFlight/App Store still prune.
    #if DEBUG
    static var keepsAll = true
    #else
    static var keepsAll = false
    #endif

    /// The video of runs older than `videoDays` goes; their steps and screenshots stay (Henry 2026-11-19).
    func pruneVideo(now: Date = Date()) {
        guard !Self.keepsAll else { return }
        let fm = FileManager.default
        let runs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for run in runs where run != dir {
            let video = run.appendingPathComponent("video")
            guard let changed = (try? video.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(changed) > Self.videoDays * 86_400 else { continue }
            try? fm.removeItem(at: video)
        }
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

    /// Old runs go at launch so traces never fill the phone (Henry 2026-11-18: 4.5 GB of traces, a run stopped dead).
    /// The newest run (the one Continue picks up) and runs an intent points at stay; the other runs go, oldest
    /// first, until the folder fits in `budget`. Returns the folders removed.
    @discardableResult
    nonisolated static func prune(_ root: URL, keep: Set<String>, budget: Int64 = 300_000_000) -> [String] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
        var total = folders.reduce(Int64(0)) { $0 + size($1) }
        // each intent's newest run stays too: it may be the one Continue picks up after a run of another intent
        var seen = Set<String>(), keep = keep
        for folder in folders { if let intent = intent(of: folder), seen.insert(intent).inserted { keep.insert(folder.lastPathComponent) } }
        var removed: [String] = []
        for folder in folders.dropFirst().reversed() where total > budget && !keep.contains(folder.lastPathComponent) {
            let bytes = size(folder)
            guard (try? fm.removeItem(at: folder)) != nil else { continue }
            total -= bytes
            removed.append(folder.lastPathComponent)
        }
        return removed
    }

    /// The intent a run was started from: steps.jsonl's first line (the task record), read alone.
    nonisolated static func intent(of folder: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("steps.jsonl")) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        guard let line = head.split(separator: UInt8(ascii: "\n")).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        return obj["intent"] as? String
    }

    nonisolated static func size(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in files {
            let v = try? url.resourceValues(forKeys: Set(keys))
            sum += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return sum
    }

    /// Traces zipped with the debug log (secrets already redacted) and the app version, iOS version and phone
    /// model beside them: people share traces.zip, never the log on its own (2026-11-19: a user's two runs that
    /// never started came as steps.jsonl only, with no version and nothing to say why).
    nonisolated static func zipForSharing(_ folder: URL, name: String = "traces.zip") throws -> URL {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        let root = stage.appendingPathComponent((name as NSString).deletingPathExtension)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: folder, to: root.appendingPathComponent(folder.lastPathComponent))
        let logs = DebugLog.url.deletingLastPathComponent()
        for log in ["debug.1.log", "debug.log"] where fm.fileExists(atPath: logs.appendingPathComponent(log).path) {
            try? fm.copyItem(at: logs.appendingPathComponent(log), to: root.appendingPathComponent(log))
        }
        try Data(about.utf8).write(to: root.appendingPathComponent("about.txt"))
        return try zip(root, name: name)
    }

    /// App version and build, iOS version, phone model: one line each.
    nonisolated static var about: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return """
            app \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))
            iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
            model \(model)

            """
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

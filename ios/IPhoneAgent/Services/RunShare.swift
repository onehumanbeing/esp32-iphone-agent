import Compression
import Foundation

/// Community data sharing, local only (nothing is uploaded): export picked runs as one redacted .zip for the
/// share sheet, and import such a .zip as read-only "Imported" runs.
enum RunShare {
    /// "Keep run data for sharing" (off by default; Export needs it on).
    static let keepKey = "shareRunData"
    /// The consent sheet was shown once.
    static let askedKey = "sharePrivacyAsked"
    /// A file in an imported run's folder.
    static let importedMarker = ".imported"

    struct Package {
        let url: URL
        let runs: Int
        let bytes: Int
    }

    static func isImported(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(importedMarker).path)
    }

    /// Copies each run redacted (steps, metrics, review edits, screenshots, video) plus debug.log, then zips it.
    static func export(_ runs: [URL], redactor: Redactor, debugLog: URL?) throws -> Package {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("ESP32-Agent-runs")
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for run in runs {
            let out = stage.appendingPathComponent(run.lastPathComponent)
            try fm.createDirectory(at: out.appendingPathComponent("video"), withIntermediateDirectories: true)
            for name in ["steps.jsonl", "metrics.json", "review.json"] {
                guard let text = try? String(contentsOf: run.appendingPathComponent(name), encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let clean = name == "steps.jsonl" ? lines.map { $0.isEmpty ? $0 : redactor.jsonLine($0) }.joined(separator: "\n")
                    : redactor.text(text)
                try Data(clean.utf8).write(to: out.appendingPathComponent(name))
            }
            for sub in ["", "video"] {
                let dir = sub.isEmpty ? run : run.appendingPathComponent(sub)
                for jpg in ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    where jpg.pathExtension == "jpg" {
                    if let data = try? Data(contentsOf: jpg), let clean = redactor.image(data) {
                        try clean.write(to: out.appendingPathComponent(sub).appendingPathComponent(jpg.lastPathComponent))
                    }
                }
            }
        }
        if let debugLog, let text = try? String(contentsOf: debugLog, encoding: .utf8) {
            let clean = text.split(separator: "\n", omittingEmptySubsequences: false).map { redactor.text(String($0)) }
            try Data(clean.joined(separator: "\n").utf8).write(to: stage.appendingPathComponent("debug.log"))
        }
        let zip = try TraceStore.zip(stage, name: "ESP32-Agent-runs.zip")
        let bytes = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        return Package(url: zip, runs: runs.count, bytes: bytes)
    }

    /// Unpacks a shared .zip; every folder with a steps.jsonl becomes an imported run in `root`. Returns their ids.
    static func importZip(_ zip: URL, into root: URL) throws -> [String] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try Unzip.extract(zip, to: tmp)
        var ids: [String] = []
        let all = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for steps in all where steps.lastPathComponent == "steps.jsonl" {
            let run = steps.deletingLastPathComponent()
            let id = "imported-" + run.lastPathComponent
            let dest = root.appendingPathComponent(id)
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.moveItem(at: run, to: dest)
            try Data().write(to: dest.appendingPathComponent(importedMarker))
            ids.append(id)
        }
        guard !ids.isEmpty else { throw DeviceError(message: String(localized: "No runs in this file.")) }
        return ids
    }
}

/// A minimal .zip reader (stored or deflated entries, no zip64), enough for archives this app writes.
enum Unzip {
    static func extract(_ zip: URL, to dir: URL) throws {
        let b = [UInt8](try Data(contentsOf: zip))
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let bad = DeviceError(message: String(localized: "This is not a run archive."))
        guard b.count >= 22, let end = stride(from: b.count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4b50 })
        else { throw bad }
        var p = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard u32(p) == 0x0201_4b50 else { throw bad }
            let method = u16(p + 10), packed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + u16(p + 30) + u16(p + 32)
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw bad }
            let target = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard u32(local) == 0x0403_4b50, start + packed <= b.count else { throw bad }
            let raw = Array(b[start..<(start + packed)])
            let data: Data
            switch method {
            case 0: data = Data(raw)
            case 8: data = try inflate(raw, size: size)
            default: throw bad
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
    }

    private static func inflate(_ raw: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, raw, raw.count, nil, COMPRESSION_ZLIB)  // raw deflate
        guard n == size else { throw DeviceError(message: "unzip: bad deflate data") }
        return Data(out)
    }
}

extension AppModel {
    /// Everything that identifies this setup and must never be exported.
    var shareRedactor: Redactor {
        let secrets = [settings.apiKey, settings.baseURL, URL(string: settings.baseURL)?.host ?? "",
                       board.net?.ssid ?? "", board.net?.pass ?? "", hotspotSSID ?? "", manualHotspot?.pass ?? "",
                       lanSSID ?? ""]
        return Redactor(secrets: secrets.filter { !$0.isEmpty })
    }

    /// A shared .zip opened from Files, the share sheet or Runs › Import. Returns how many runs it held.
    @discardableResult
    func importRuns(_ url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ids = try RunShare.importZip(url, into: traces.root)
        runs.reload()
        tab = .runs
        say("imported \(ids.count) run(s)")
        return ids.count
    }
}

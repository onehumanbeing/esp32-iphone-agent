import Compression
import Foundation
import UIKit

/// The one-tap report for the developer: app and phone versions, the board's state, debug.log (board lines
/// included) and iOS crash reports. No runs, screenshots or keys (debug.log is already redacted).
enum DiagnosticReport {
    static let contents = [
        String(localized: "App version, iOS version and iPhone model"),
        String(localized: "The board's state (firmware, connection, Screen Mirroring)"),
        String(localized: "The debug log: app events, board lines, model request timing (never your API key)"),
        String(localized: "Crash reports iOS gave the app"),
    ]

    @MainActor static func build(_ app: AppModel) -> Data? {
        let info = Bundle.main.infoDictionary ?? [:]
        let crashes = CrashReports.files.prefix(5).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let log = (try? String(contentsOf: DebugLog.url, encoding: .utf8)) ?? ""
        let doc: [String: Any] = [
            "format": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "app": ["version": info["CFBundleShortVersionString"] ?? "", "build": info["CFBundleVersion"] ?? "",
                    "ios": UIDevice.current.systemVersion, "device": deviceModel()],
            "board": app.statusSummary,
            "log": String(log.suffix(3_000_000)),
            "crashes": crashes,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        return gzip(json)
    }

    /// Build and send; the line to show the user (the report id to quote, or why it didn't go).
    @MainActor static func send(_ app: AppModel) async -> String {
        guard let report = build(app) else { return String(localized: "Couldn't put the report together.") }
        do {
            let id = try await Trial.shared.sendReport(report)
            DebugLog.write("diagnostics sent: \(id)")
            return String(localized: "Sent. Report \(String(id.prefix(8))) — quote it when you get in touch.")
        } catch {
            DebugLog.write("diagnostics failed: \(error.localizedDescription)")
            return String(localized: "Couldn't send the report right now. Try again later, or use Export all logs.")
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// gzip (RFC 1952) around Compression's raw DEFLATE.
    static func gzip(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&out, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
                                      COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        result.append(contentsOf: out.prefix(n))
        for v in [crc32(data), UInt32(truncatingIfNeeded: data.count)] { withUnsafeBytes(of: v.littleEndian) { result.append(contentsOf: $0) } }
        return result
    }

    private static let table: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
}

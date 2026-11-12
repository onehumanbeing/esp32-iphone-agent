import Foundation
import MetricKit

/// Crash, hang and CPU/disk diagnostics from iOS (MetricKit), kept on the phone in Documents/diagnostics/.
/// iOS hands them over at the next launch (up to a day later). They ride along in Logs › Export all logs and
/// in Report a bug. With usage stats on, crashes and hangs are also sent as events (see `report`): the
/// exception, the stack as addresses (symbolicated later with the build's dSYM), never app data.
/// TestFlight builds also send crashes to App Store Connect.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    static let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diagnostics", isDirectory: true)

    func start() { MXMetricManager.shared.add(self) }

    /// Reports kept so far, newest first.
    static var files: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        for p in payloads {
            let counts: [(String, Int)] = [("crash", p.crashDiagnostics?.count ?? 0), ("hang", p.hangDiagnostics?.count ?? 0),
                                           ("cpu", p.cpuExceptionDiagnostics?.count ?? 0),
                                           ("disk", p.diskWriteExceptionDiagnostics?.count ?? 0)]
            let kinds = counts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
            let name = "\(Int(p.timeStampEnd.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try? p.jsonRepresentation().write(to: Self.dir.appendingPathComponent(name))
            DebugLog.write("diagnostics: \(kinds.isEmpty ? "report" : kinds.joined(separator: ", ")) from iOS, saved \(name)")
            let lines = Self.summaries(p)
            lines.forEach { DebugLog.write("diagnostics: " + $0) }
            if let last = lines.last { UserDefaults.standard.set(last, forKey: Self.lastKey) }
            report(p)
        }
    }

    /// One "crash_report" / "hang_report" event per diagnostic; the stack is capped at 64 KB.
    static let lastKey = "lastSystemDiagnostic"
    /// The newest one-line summary, for Diagnostics.
    static var last: String? { UserDefaults.standard.string(forKey: lastKey) }

    /// One line per CPU exception, crash and hang: type, duration and the top frame only.
    static func summaries(_ p: MXDiagnosticPayload) -> [String] {
        var lines: [String] = []
        for d in p.cpuExceptionDiagnostics ?? [] {
            lines.append(summary("cpu exception", detail: String(format: "%.0f s CPU in %.0f s",
                                                                  d.totalCPUTime.converted(to: .seconds).value,
                                                                  d.totalSampledTime.converted(to: .seconds).value),
                                 build: d.metaData.applicationBuildVersion, tree: d.callStackTree.jsonRepresentation()))
        }
        for d in p.crashDiagnostics ?? [] {
            lines.append(summary("crash", detail: "exception \(d.exceptionType?.intValue ?? -1), signal \(d.signal?.intValue ?? -1)",
                                 build: d.metaData.applicationBuildVersion, tree: d.callStackTree.jsonRepresentation()))
        }
        for d in p.hangDiagnostics ?? [] {
            lines.append(summary("hang", detail: String(format: "%.1f s", d.hangDuration.converted(to: .seconds).value),
                                 build: d.metaData.applicationBuildVersion, tree: d.callStackTree.jsonRepresentation()))
        }
        return lines
    }

    /// `kind, detail, build N, top <binary>+0x<offset>[, app <offset>]` (MetricKit stacks carry no symbols).
    static func summary(_ kind: String, detail: String, build: String, tree: Data) -> String {
        let frames = CrashFrames.crashed(tree)
        let top = frames.first.map { "\($0.binary)+0x\(String($0.offset, radix: 16))" } ?? "?"
        let app = frames.first { $0.binary == "IPhoneAgent" }.map { "IPhoneAgent+0x\(String($0.offset, radix: 16))" }
        return "\(kind), \(detail), build \(build), top \(top)" + (app.map { $0 == top ? "" : ", app \($0)" } ?? "")
    }

    private func report(_ p: MXDiagnosticPayload) {
        var events: [(String, [String: Any])] = []
        for d in p.crashDiagnostics ?? [] {
            // Error Tracking groups and lists these; crash_report below keeps the raw tree for symbolication.
            let frames = CrashFrames.crashed(d.callStackTree.jsonRepresentation())
            let type = d.exceptionType.map { "EXC \($0.intValue) / signal \(d.signal?.intValue ?? -1)" } ?? "crash"
            events.append(("$exception", CrashFrames.exception(type: type, message: d.terminationReason ?? "crash", frames: frames,
                                                              build: d.metaData.applicationBuildVersion)
                .merging(["crashed_build": d.metaData.applicationBuildVersion, "crashed_os": d.metaData.osVersion]) { $1 }))
            events.append(("crash_report", [
                "exception_type": d.exceptionType?.intValue ?? -1, "exception_code": d.exceptionCode?.intValue ?? -1,
                "signal": d.signal?.intValue ?? -1, "termination_reason": d.terminationReason ?? "",
            ].merging(Self.common(d)) { $1 }))
        }
        for d in p.hangDiagnostics ?? [] {
            events.append(("hang_report", ["hang_seconds": d.hangDuration.converted(to: .seconds).value]
                .merging(Self.common(d)) { $1 }))
        }
        guard !events.isEmpty else { return }
        Task { @MainActor in events.forEach { Analytics.capture($0.0, $0.1) }; Analytics.flush() }
    }

    private static func common(_ d: MXDiagnostic) -> [String: Any] {
        let stack = String(decoding: (d as? MXCrashDiagnostic)?.callStackTree.jsonRepresentation()
                           ?? (d as? MXHangDiagnostic)?.callStackTree.jsonRepresentation() ?? Data(), as: UTF8.self)
        return ["crashed_build": d.metaData.applicationBuildVersion, "crashed_os": d.metaData.osVersion,
                "call_stack": String(stack.prefix(65_536))]
    }
}

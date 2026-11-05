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
            report(p)
        }
    }

    /// One "crash_report" / "hang_report" event per diagnostic; the stack is capped at 64 KB.
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

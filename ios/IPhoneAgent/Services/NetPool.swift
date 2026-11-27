import Foundation

/// One URLSession per timeout pair for the model clients. Each LLMClient used to make its own, and a run makes new
/// clients (actor, planner, checkpoint, reader), so every run's first call opened a fresh TCP + TLS connection to the
/// gateway (2026-11-27, build 25: the app's first call took 2.8 s p50 more than the gateway's, later calls 2.2 s).
/// Shared, the run's clients and the runs after it go over the same warm HTTP/2 connection.
enum NetPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]
    nonisolated(unsafe) private static var warming: [String: Double] = [:]  // session + host: when last warmed

    static func session(request: Double, resource: Double, ephemeral: Bool = false) -> URLSession {
        let key = "\(request)/\(resource)/\(ephemeral)"
        return lock.withLock {
            if let session = sessions[key] { return session }
            let config: URLSessionConfiguration = ephemeral ? .ephemeral : .default
            config.timeoutIntervalForRequest = request
            config.timeoutIntervalForResource = resource
            let session = URLSession(configuration: config)
            sessions[key] = session
            return session
        }
    }

    /// Open the connection to `url`'s host before the first real call needs it: a HEAD whose answer (404, 401, …)
    /// is ignored; only the connection it leaves in `session`'s pool matters. Never throws, never waits.
    static func warm(_ url: URL, on session: URLSession) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        // the run's clients share one host: one HEAD opens the connection, a second at once would open another
        let key = "\(ObjectIdentifier(session).hashValue) \(url.host ?? "") \(url.port ?? 0)", t = now()
        guard lock.withLock({
            if let last = warming[key], t - last < 2 { return false }
            warming[key] = t
            return true
        }) else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let started = now(), host = url.host ?? "?"
        Task.detached(priority: .utility) {
            let code = await ((try? session.data(for: request, delegate: NetTimings(label: "warm \(host)")))?.1
                as? HTTPURLResponse)?.statusCode
            DebugLog.write(String(format: "net: warmed %@ in %.0f ms (%@)", host, (now() - started) * 1000,
                                  code.map { "HTTP \($0)" } ?? "no answer"))
        }
    }
}

/// One request's network timing (URLSessionTaskMetrics), logged: the body's bytes and upload time, whether the
/// connection was reused or opened (DNS + TCP + TLS), and the wait for the first byte of the answer. `reports`:
/// the upload and connect seconds also go to the gateway with the next step (StepReport.network).
final class NetTimings: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let label: String, reports: Bool

    init(label: String, reports: Bool = false) {
        self.label = label
        self.reports = reports
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) else { return }
        let timing = Self.timing(t, bytes: task.countOfBytesSent)
        DebugLog.write("net: \(label): " + timing.line)
        if reports { StepReport.shared.network(upload: timing.upload, connect: timing.connect) }
    }

    struct Timing {
        var bytes: Int64, upload: Double, connect: Double?, wait: Double?, proto: String

        var line: String {
            String(format: "%lld B up in %.0f ms, %@, first byte after %@ (%@)", bytes, upload * 1000,
                   connect.map { String(format: "new connection %.0f ms", $0 * 1000) } ?? "reused connection",
                   wait.map { String(format: "%.0f ms", $0 * 1000) } ?? "-", proto)
        }
    }

    static func timing(_ t: URLSessionTaskTransactionMetrics, bytes: Int64) -> Timing {
        func span(_ a: Date?, _ b: Date?) -> Double? { a.flatMap { a in b.map { max(0, $0.timeIntervalSince(a)) } } }
        return Timing(bytes: bytes, upload: span(t.requestStartDate, t.requestEndDate) ?? 0,
                      connect: t.isReusedConnection ? nil : span(t.domainLookupStartDate ?? t.connectStartDate, t.connectEndDate),
                      wait: span(t.requestEndDate, t.responseStartDate), proto: t.networkProtocolName ?? "?")
    }
}

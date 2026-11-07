#if DEBUG
import Foundation
import Network

/// A line link to harness/live.py on the Mac, found over Bonjour: the app's log streams out as it is written, and
/// harness commands (launch arguments as a JSON array) come in. No devicectl: its file copies hang for minutes over
/// Wi-Fi and, 2026-11-07, over the cable too until it was replugged, and the harness went blind.
/// Out: "L <log line>", "F <file name> <base64>". In: `["-run", "<task>"]` and the like, one per line.
final class HarnessLink: @unchecked Sendable {
    static let shared = HarnessLink()
    static let service = "_handsy-harness._tcp"
    private let queue = DispatchQueue(label: "harness-link")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var buffer = Data()
    /// The Mac's address from the harness (`-harness-host ip:port`), kept: tried when Bonjour finds nothing (2026-11-07
    /// the phone never saw the Mac's advertisement on the same Wi-Fi).
    static let hostKey = "harnessHost"
    /// A command from the Mac, on the main queue.
    var onCommand: ([String]) -> Void = { _ in }

    func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                DebugLog.write("harness link: found \(results.map { "\($0.endpoint)" })")
                self?.endpoint = results.first?.endpoint
                self?.connect()
            }
            b.stateUpdateHandler = { state in DebugLog.write("harness link: browse \(state)") }
            b.start(queue: queue)
            browser = b
            DebugLog.live = { [weak self] line in self?.send("L " + line) }  // already on its own queue
            connect()
        }
    }

    /// `-harness-host 192.168.1.5:7290`: connect there (now and after relaunches).
    func use(host: String) {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            connect()
        }
    }

    private var saved: NWEndpoint? {
        guard let s = UserDefaults.standard.string(forKey: Self.hostKey), let colon = s.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(s[s.index(after: colon)...])) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(s[..<colon])), port: port)
    }

    /// A file the Mac asked for (a screenshot), sent whole.
    func sendFile(_ name: String, _ data: Data) { queue.async { self.send("F \(name) \(data.base64EncodedString())") } }

    private func connect() {
        guard connection == nil, let endpoint = endpoint ?? saved else { return }
        let c = NWConnection(to: endpoint, using: .tcp)
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                send("L harness link: connected")
                receive(c)
            case .waiting(let e):
                DebugLog.write("harness link: waiting (\(e))")
                c.cancel()
            case .failed, .cancelled:
                connection = nil
                queue.asyncAfter(deadline: .now() + 3) { self.connect() }  // the Mac's listener restarted
            default: break
            }
        }
        connection = c
        c.start(queue: queue)
    }

    private func send(_ line: String) {
        guard let c = connection, c.state == .ready else { return }
        c.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                if let args = try? JSONDecoder().decode([String].self, from: Data(line)) {
                    DispatchQueue.main.async { self.onCommand(args) }
                }
            }
            if done || error != nil { c.cancel() } else { receive(c) }
        }
    }
}
#endif

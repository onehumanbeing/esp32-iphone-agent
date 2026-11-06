import Foundation

/// The Wi-Fi video channel (docs/ble-protocol.md, "Wi-Fi video"): UDP to the board's port 7200 over its
/// hotspot. Several Mbps instead of BLE's ~140 kbps, so the screen keeps up with animations. BLE stays the
/// command link, keeps the app alive in the background, and carries the video whenever this is down.
/// UDP transport with nack/resync (firmware built with WV_TCP 0). Not used for now: see VideoTransport.
@MainActor final class VideoSocket: WifiVideoLink {
    static let port: UInt16 = 7200

    var onChunk: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?             // audio needs the TCP link: never called here
    var wantsAudio: () -> Bool = { false }
    /// Video moved to Wi-Fi (true) or back to BLE (false).
    var onActive: ((Bool) -> Void)?
    var resumeAt: () -> UInt32? = { nil }
    var log: (String) -> Void = { DebugLog.write($0) }
    private(set) var active = false
    private(set) var reorder = VideoReorder()
    private(set) var kbps = 0.0
    var nacks: Int { reorder.nacks }
    var lost: Int { reorder.lost }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var target: (ip: String, token: String)?
    private var acked = false          // the board answered our hello
    private var lastDatagram = 0.0
    private var lastSent = 0.0
    private var helloSince = 0.0
    private var lastError = ""
    private var timer: Task<Void, Never>?
    private var windowBytes = 0, windowStart = now()
    private let queue = DispatchQueue(label: "video-socket")

    /// Keep a session with the board at `ip` (nil: the board is gone or doesn't support Wi-Fi video).
    func update(ip: String?, token: String?) {
        guard let ip, let token, !ip.isEmpty, !token.isEmpty, ip != "0.0.0.0" else { return stop() }
        if target?.ip == ip && target?.token == token && fd >= 0 { return }
        stop()
        target = (ip, token)
        open()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                self?.tick()
            }
        }
    }

    /// Say hello again now (back in the foreground, hotspot rejoined): the board may have dropped us.
    func kick() {
        guard target != nil else { return }
        if fd < 0 { reopen() } else { send("hello \(target!.token)") }
    }

    func resume() { if fd >= 0 { send("resync") } }  // UDP: no resume, the board starts over from the IDR

    func stop() {
        timer?.cancel()
        timer = nil
        closeSocket()
        target = nil
        setActive(false)
    }

    /// A plain BSD UDP socket, connected to the board: the kernel routes 192.168.4.x to the hotspot. (An
    /// NWConnection required to use Wi-Fi stayed "unsatisfied, no interfaces" while the phone was on the
    /// hotspot with cellular as its internet, 2026-10-19.)
    private func open() {
        guard let target else { return }
        acked = false
        helloSince = now()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return log("video: wifi socket() failed, errno \(errno)") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        guard inet_pton(AF_INET, target.ip, &addr.sin_addr) == 1 else { close(fd); return log("video: bad board ip \(target.ip)") }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { note("connect", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var batch: [Data] = []
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                batch.append(Data(buf[0..<n]))
            }
            guard !batch.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fd == fd else { return }
                batch.forEach(self.datagram)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.fd = fd
        self.source = source
        send("hello \(target.token)")
    }

    private func closeSocket() {
        source?.cancel()  // closes the descriptor
        source = nil
        fd = -1
    }

    private func reopen() {
        closeSocket()
        setActive(false)
        open()
    }

    /// A socket error, logged when it changes (ENETDOWN with the Local Network permission off, EHOSTUNREACH
    /// off the hotspot).
    private func note(_ what: String, _ code: Int32) {
        let text = "video: wifi \(what) failed: \(String(cString: strerror(code))) (errno \(code))"
        guard text != lastError else { return }
        lastError = text
        log(text)
    }

    private func datagram(_ data: Data) {
        let t = now()
        lastDatagram = t
        if !acked { log("video: wifi on"); lastError = "" }
        acked = true
        setActive(true)
        if data == Data("ok".utf8) { return }  // the answer to hello / ka
        windowBytes += data.count
        handle(reorder.add(data, at: t))
    }

    private func handle(_ out: VideoReorder.Output) {
        for chunk in out.chunks { onChunk?(chunk) }
        for r in out.requests {
            switch r {
            case .nack(let a, let b): send("nack \(a) \(b)")
            case .resync: send("resync"); log("video: wifi chunks lost, asked for the IDR again")
            }
        }
    }

    private func tick() {
        let t = now()
        handle(reorder.tick(at: t))
        if t - windowStart >= 1 {
            kbps = Double(windowBytes) * 8 / 1000 / (t - windowStart)
            windowBytes = 0
            windowStart = t
        }
        guard let token = target?.token else { return }
        // The board answers every keep-alive and drops a session it hasn't heard from in 3 s: silence that long
        // means it sends video over BLE again (iOS suspended us, the hotspot is gone).
        if acked && t - lastDatagram > 3 {
            acked = false
            helloSince = t
            setActive(false)
            log("video: wifi silent for 3 s, back to BLE")
        }
        if !acked && t - helloSince > 5 { helloSince = t; reopen(); return }
        if t - lastSent >= (acked ? 1 : 0.5) { send(acked ? "ka" : "hello \(token)") }
    }

    private func send(_ text: String) {
        guard fd >= 0 else { return }
        lastSent = now()
        let bytes = Array(text.utf8)
        if Darwin.send(fd, bytes, bytes.count, 0) < 0 { note("send", errno) }
    }

    private func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        reorder.reset()
        onActive?(on)
    }
}

import Foundation

/// Video over the board's Wi-Fi, either transport (the firmware is built for one: WV_TCP in wifi_video.h).
@MainActor protocol WifiVideoLink: AnyObject {
    var onChunk: ((Data) -> Void)? { get set }
    var onActive: ((Bool) -> Void)? { get set }
    var resumeAt: () -> UInt32? { get set }  // TCP: the decoder's last unit, for `hello … at` (UDP ignores it)
    var active: Bool { get }
    var kbps: Double { get }
    var nacks: Int { get }   // UDP resend requests (TCP: 0)
    var lost: Int { get }    // UDP gaps given up on (TCP: sessions dropped)
    init()
    func update(ip: String?, token: String?)
    func kick()
    /// The stream lost its place (a seq gap): ask the board to go on right after `resumeAt` without reconnecting.
    func resume()
    func stop()
}

enum VideoTransport {
    /// TCP: ordered and lossless, the stack does flow control. UDP (VideoSocket) stays for later tests (TODO):
    /// on weak links its resyncs became storms that starved mirroring and BLE (2026-10-20).
    static let current: WifiVideoLink.Type = VideoStream.self
}

/// TCP on port 7201: the app sends "hello <token>\n" (or "hello <token> at <ms>\n": its decoder is in step up to
/// the unit stamped <ms>, so the board goes on from there instead of the IDR), then "ka\n" every second (and "resync\n" if the
/// assembler lost its place); the board sends [u16 LE length][chunk] records, a zero-length one answering
/// hello/ka. A plain BSD socket so the kernel routes 192.168.4.x to the hotspot (see VideoSocket).
@MainActor final class VideoStream: WifiVideoLink {
    static let port: UInt16 = 7201

    var onChunk: ((Data) -> Void)?
    var onActive: ((Bool) -> Void)?
    var resumeAt: () -> UInt32? = { nil }
    var log: (String) -> Void = { DebugLog.write($0) }
    private(set) var active = false
    private(set) var kbps = 0.0
    var nacks: Int { 0 }
    private(set) var lost = 0

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var target: (ip: String, token: String)?
    private var connected = false, acked = false
    private var buffer = Data()
    private var lastByte = 0.0, lastSent = 0.0, openedAt = 0.0
    private var lastError = ""
    private var timer: Task<Void, Never>?
    private var windowBytes = 0, windowStart = now()
    private let queue = DispatchQueue(label: "video-stream")

    func update(ip: String?, token: String?) {
        guard let ip, let token, !ip.isEmpty, !token.isEmpty, ip != "0.0.0.0" else { return stop() }
        if target?.ip == ip && target?.token == token && fd >= 0 { return }
        stop()
        target = (ip, token)
        open()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.tick()
            }
        }
    }

    func kick() {
        guard target != nil, !acked else { return }
        reopen()
    }

    /// A hello on the open session is a resume request (`hello … at <ms>`): past a frozen GOP no IDR comes, and
    /// waiting for a reconnect to send it left the screen frozen while the link itself was fine (2026-11-06).
    func resume() {
        guard acked, let token = target?.token else { return }
        if send(hello(token)) { log("video: wifi stream lost its place; asked to go on" + (resumeAt().map { " after \($0)" } ?? " from the IDR")) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        closeSocket()
        target = nil
        setActive(false)
    }

    /// Non-blocking connect; the first readable/writable event finishes it.
    private func open() {
        guard let target else { return }
        connected = false
        acked = false
        buffer = Data()
        openedAt = now()
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return log("video: wifi socket() failed, errno \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        guard inet_pton(AF_INET, target.ip, &addr.sin_addr) == 1 else { close(fd); return log("video: bad board ip \(target.ip)") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 && errno != EINPROGRESS { note("connect", errno); close(fd); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var batch = Data()
            var buf = [UInt8](repeating: 0, count: 16384)
            var closed = false
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 { batch.append(contentsOf: buf[0..<n]); continue }
                closed = n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)
                break
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fd == fd else { return }
                if !batch.isEmpty { self.received(batch) }
                if closed { self.log("video: wifi stream closed by the board"); self.reopen() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.fd = fd
        self.source = source
    }

    private func closeSocket() {
        source?.cancel()  // closes the descriptor
        source = nil
        fd = -1
        connected = false
        acked = false
    }

    private func reopen() {
        closeSocket()
        setActive(false)
        open()
    }

    private func note(_ what: String, _ code: Int32) {
        let text = "video: wifi \(what) failed: \(String(cString: strerror(code))) (errno \(code))"
        guard text != lastError else { return }
        lastError = text
        log(text)
    }

    private func received(_ data: Data) {
        lastByte = now()
        windowBytes += data.count
        buffer.append(data)
        var at = buffer.startIndex
        while buffer.endIndex - at >= 2 {
            let len = Int(buffer[at]) | Int(buffer[at + 1]) << 8
            guard buffer.endIndex - at - 2 >= len else { break }
            if len == 0 {
                if !acked { log("video: wifi on (tcp)"); lastError = "" }
                acked = true
                setActive(true)
            } else if acked {
                onChunk?(buffer.subdata(in: (at + 2)..<(at + 2 + len)))
            }
            at += 2 + len
        }
        buffer.removeSubrange(buffer.startIndex..<at)
    }

    private func tick() {
        let t = now()
        if t - windowStart >= 1 {
            kbps = Double(windowBytes) * 8 / 1000 / (t - windowStart)
            windowBytes = 0
            windowStart = t
        }
        guard let token = target?.token, fd >= 0 else { return }
        if !connected {
            // Writable once the connect is done: say hello. Give up on a connect that hangs.
            if send(hello(token)) { connected = true; lastByte = t; return }
            if t - openedAt > 5 { reopen() }
            return
        }
        if t - lastByte > 3 {
            lost += 1
            log(acked ? "video: wifi silent for 3 s, back to BLE" : "video: wifi no answer to hello; reconnecting")
            reopen()
            return
        }
        if t - lastSent >= 1 { _ = send(acked ? "ka\n" : hello(token)) }
    }

    private func hello(_ token: String) -> String {
        "hello \(token)" + (resumeAt().map { " at \($0)" } ?? "") + "\n"
    }

    @discardableResult
    private func send(_ text: String) -> Bool {
        guard fd >= 0 else { return false }
        let bytes = Array(text.utf8)
        let n = Darwin.send(fd, bytes, bytes.count, 0)
        if n == bytes.count { lastSent = now(); return true }
        if n < 0 && errno != ENOTCONN && errno != EAGAIN { note("send", errno) }
        return false
    }

    private func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        onActive?(on)
    }
}

import CryptoKit
import Foundation

/// A board firmware release: `firmware.json` next to the image on handsy.tech (hardware/tools/fw_release.py). Signed with the project's Ed25519 key, so a changed release page
/// or a hacked site can't put other code on the board.
/// A firmware version like the repo's release tags: "0.2.0", shown as v0.2.0. Boards from before semver report
/// a plain number n (OTA test builds 2 and 3), read as 0.0.n so any tagged release is newer.
struct FirmwareVersion: Codable, Comparable, CustomStringConvertible, Hashable {
    let parts: [Int]

    init(_ parts: [Int]) { self.parts = parts }
    init?(_ text: String) {
        let p = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) }
        guard (1...3).contains(p.count), !p.contains(nil) else { return nil }
        parts = p.compactMap { $0 } + Array(repeating: 0, count: 3 - p.count)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { parts = [0, 0, n]; return }
        guard let v = FirmwareVersion(try c.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a version")
        }
        self = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(parts.map(String.init).joined(separator: "."))
    }

    static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    var description: String { "v" + parts.map(String.init).joined(separator: ".") }
}

struct FirmwareRelease: Codable, Equatable {
    var version: String  // "0.2.0", signed as written
    var size: Int
    var sha256: String
    var md5: String     // what the board checks after writing (ota.h)
    var url: String     // the image, relative to the manifest
    var sig: String?    // base64 Ed25519 over `signed` (only a Debug harness build may come without, HarnessOTA.swift)
    var notes: String?

    var ver: FirmwareVersion { FirmwareVersion(version) ?? FirmwareVersion([0]) }
    var signed: Data { Data("esp32agent-firmware\nversion=\(version)\nsize=\(size)\nsha256=\(sha256)\nmd5=\(md5)".utf8) }
}

enum Firmware {
    /// Releases come from handsy.tech only: we control it, so test releases can be staged there too.
    /// TestFlight builds (`fastlane beta testflight:true` sets TESTFLIGHT) read their own list, signed with the same key.
    #if TESTFLIGHT
    static let sources = [URL(string: "https://handsy.tech/firmware/testflight/firmware.json")!]
    #else
    static let sources = [URL(string: "https://handsy.tech/firmware/firmware.json")!]
    #endif
    /// The oldest board firmware this app works with; an older board gets the update before anything else.
    static let required = FirmwareVersion([0, 2, 0])
    /// The first firmware that takes updates over Wi-Fi; older boards need hardware/flash.sh over USB.
    static let firstOTA = FirmwareVersion([0, 0, 2])
    static let publicKey = Data(base64Encoded: "DfqjOJal/fdCPhpWbNJv1q2OdszGMXxExGH1qTzmO8k=")!
    static let port: UInt16 = 7300
    /// Boards from before OTA don't report `fw`.
    static func version(of status: BoardStatus?) -> FirmwareVersion { status?.fw ?? FirmwareVersion([0, 0, 1]) }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func verify(_ r: FirmwareRelease, key: Data = publicKey) -> Bool {
        guard let sig = Data(base64Encoded: r.sig ?? ""), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return key.isValidSignature(sig, for: r.signed)
    }

    static func matches(_ image: Data, _ r: FirmwareRelease) -> Bool {
        image.count == r.size && hex(SHA256.hash(data: image)) == r.sha256.lowercased()
            && hex(Insecure.MD5.hash(data: image)) == r.md5.lowercased()
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A copy placed in Documents/firmware (a test build, or a release saved earlier) comes first; it must be signed too.
    static var local: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(localDir + "/firmware.json")
    }
    /// Debug `ota <dir>`: devicectl can't replace a file it copied before, so each test build gets a new folder.
    nonisolated(unsafe) static var localDir = "firmware"

    /// A manifest from Documents/firmware, if it decodes and is signed.
    static func signedRelease(_ manifest: Data) -> FirmwareRelease? {
        guard let r = try? JSONDecoder().decode(FirmwareRelease.self, from: manifest), verify(r) else { return nil }
        return r
    }

    /// The newest signed release among the sources, and where its manifest came from.
    static func latest(session: URLSession = .shared) async throws -> (FirmwareRelease, URL) {
        var found: [(FirmwareRelease, URL)] = []
        var lastError: Error?
        if let data = try? Data(contentsOf: local), let r = signedRelease(data) { found.append((r, local)) }
        for url in sources {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("ESP32Agent", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
                let r = try JSONDecoder().decode(FirmwareRelease.self, from: data)
                guard verify(r) else { throw Failure(String(localized: "The firmware release isn't signed by \(AppName.current).")) }
                found.append((r, response.url ?? url))
                break  // the first source that answers is enough
            } catch {
                lastError = error
                DebugLog.write("firmware: \(url.host ?? "") failed: \(error.localizedDescription)")
            }
        }
        guard let best = found.max(by: { $0.0.ver < $1.0.ver }) else {
            throw lastError ?? Failure(String(localized: "No firmware release found."))
        }
        return best
    }

    /// The image, from the cache when it was downloaded before; always checked against the signed manifest.
    static func image(_ r: FirmwareRelease, manifest: URL, session: URLSession = .shared) async throws -> Data {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("firmware-\(r.version).bin")
        if let data = try? Data(contentsOf: cache), matches(data, r) { return data }
        guard let url = URL(string: r.url, relativeTo: manifest)?.absoluteURL else { throw Failure("bad firmware url") }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (d, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 60))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(String(localized: "The firmware download failed.")) }
            data = d
        }
        guard matches(data, r) else { throw Failure(String(localized: "The downloaded firmware is damaged. Try again.")) }
        try? data.write(to: cache, options: .atomic)
        return data
    }

    /// Sends the image to the board over its Wi-Fi (TCP, ota.h). Returns when the board has checked and installed
    /// it and is restarting. A cut connection leaves the running firmware as it was.
    static func push(_ image: Data, md5: String, host: String, token: String, port: UInt16 = port,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            try pushBlocking(image, md5: md5, host: host, token: token, port: port, progress: progress)
        }.value
    }

    private static func pushBlocking(_ image: Data, md5: String, host: String, token: String, port: UInt16,
                                     progress: @Sendable (Double) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Failure("socket() failed, errno \(errno)") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)  // also bounds the board's flash erase before "ok"
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw Failure("bad board address \(host)") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw Failure(String(localized: "Can't reach the board over Wi-Fi. Put the iPhone on the board's Wi-Fi (or the network the board joined) and try again.")) }
        try sendAll(fd, Data("ota \(token) \(image.count) \(md5)\n".utf8))
        let head = try readLine(fd)
        guard head == "ok" else { throw Failure(answer(head)) }
        let chunk = 16 * 1024
        var sent = 0
        while sent < image.count {
            try Task.checkCancellation()
            let end = min(sent + chunk, image.count)
            try sendAll(fd, image.subdata(in: sent..<end))
            sent = end
            progress(Double(sent) / Double(image.count))
        }
        let tail = try readLine(fd)
        guard tail == "done" else { throw Failure(answer(tail)) }
    }

    private static func answer(_ line: String) -> String {
        line.hasPrefix("err ") ? String(localized: "The board refused the update: \(String(line.dropFirst(4)))") : String(localized: "The board stopped answering.")
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
                guard n > 0 else { throw Failure(String(localized: "The Wi-Fi connection to the board dropped.")) }
                off += n
            }
        }
    }

    private static func readLine(_ fd: Int32) throws -> String {
        var bytes: [UInt8] = []
        var c: UInt8 = 0
        while bytes.count < 200 {
            guard recv(fd, &c, 1, 0) == 1 else { break }
            if c == UInt8(ascii: "\n") { break }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

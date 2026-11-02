import CryptoKit
import XCTest
@testable import IPhoneAgent

/// Firmware releases (signature, image check) and the Wi-Fi push, against a fake board on localhost.
final class FirmwareTests: XCTestCase {
    private let image = Data((0..<100_000).map { UInt8($0 % 251) })

    private func release(_ image: Data, key: Curve25519.Signing.PrivateKey, version: String = "0.2.0") throws -> FirmwareRelease {
        var r = FirmwareRelease(version: version, size: image.count, sha256: Firmware.hex(SHA256.hash(data: image)),
                                md5: Firmware.hex(Insecure.MD5.hash(data: image)), url: "fw.bin", sig: "")
        r.sig = try key.signature(for: r.signed).base64EncodedString()
        return r
    }

    func testSignedReleaseVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        var r = try release(image, key: key)
        XCTAssertTrue(Firmware.verify(r, key: key.publicKey.rawRepresentation))
        XCTAssertFalse(Firmware.verify(r, key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation), "another key")
        XCTAssertFalse(Firmware.verify(r), "not the project's key")
        r.version = "9.9.9"
        XCTAssertFalse(Firmware.verify(r, key: key.publicKey.rawRepresentation), "a changed manifest")
    }

    func testImageMustMatchManifest() throws {
        let r = try release(image, key: Curve25519.Signing.PrivateKey())
        XCTAssertTrue(Firmware.matches(image, r))
        var bad = image
        bad[500] ^= 0xFF
        XCTAssertFalse(Firmware.matches(bad, r))
        XCTAssertFalse(Firmware.matches(image.prefix(1000), r))
    }

    /// harness/fw.sh's manifest: no `sig`, the version the board runs.
    private func harnessManifest(_ image: Data, version: String = "0.2.1", md5: String? = nil) -> Data {
        let md5 = md5 ?? Firmware.hex(Insecure.MD5.hash(data: image))
        return Data(#"{"version":"\#(version)","size":\#(image.count),"sha256":"\#(Firmware.hex(SHA256.hash(data: image)))","md5":"\#(md5)","url":"hid_bridge.ino.bin"}"#.utf8)
    }

    func testHarnessTakesUnsignedSameVersion() throws {
        let board = FirmwareVersion([0, 2, 1])
        let r = try Firmware.harnessRelease(harnessManifest(image), image: image, over: board)
        XCTAssertNil(r.sig)
        XCTAssertEqual(r.ver, board)
        XCTAssertNoThrow(try Firmware.harnessRelease(harnessManifest(image, version: "9.9.9"), image: image, over: board), "a crash-test build")
        XCTAssertThrowsError(try Firmware.harnessRelease(harnessManifest(image, version: "0.2.0"), image: image, over: board), "older")
    }

    func testHarnessRejectsMismatchedImage() {
        let board = FirmwareVersion([0, 2, 1])
        XCTAssertThrowsError(try Firmware.harnessRelease(harnessManifest(image, md5: String(repeating: "0", count: 32)), image: image, over: board))
        var bad = image
        bad[500] ^= 0xFF  // harness/fw.sh --corrupt
        XCTAssertThrowsError(try Firmware.harnessRelease(harnessManifest(image), image: bad, over: board))
        XCTAssertThrowsError(try Firmware.harnessRelease(Data("{}".utf8), image: image, over: board))
    }

    func testStagedReleasesMustBeSigned() throws {
        XCTAssertNil(Firmware.signedRelease(harnessManifest(image)), "unsigned")
        var r = try release(image, key: Curve25519.Signing.PrivateKey())
        XCTAssertNil(Firmware.signedRelease(try JSONEncoder().encode(r)), "signed, not with the project's key")
        r.sig = "AAAA"
        XCTAssertNil(Firmware.signedRelease(try JSONEncoder().encode(r)))
    }

    /// Firmware.latest logs from a background task; the app's log relay asserted the main actor (build 24 crash).
    func testLoggingOffTheMainThread() async {
        DebugLog.relay = DebugLog.relay ?? { _ in }
        await Task.detached { DebugLog.write("firmware: logged off the main thread") }.value
    }

    func testOldBoardsAreVersionOne() {
        XCTAssertEqual(Firmware.version(of: nil).description, "v0.0.1")
        let status = BoardStatus.decode(Data(#"{"fw":"0.2.0","up":5}"#.utf8))
        XCTAssertEqual(status?.fw, FirmwareVersion([0, 2, 0]))
        XCTAssertEqual(BoardStatus.decode(Data(#"{"fw":2}"#.utf8))?.fw, FirmwareVersion([0, 0, 2]), "a build from before semver")
        XCTAssertEqual(status?.merged(with: BoardStatus(up: 6)).fw, FirmwareVersion([0, 2, 0]))
        XCTAssertLessThan(FirmwareVersion([0, 0, 3]), FirmwareVersion("v0.1.0")!)
        XCTAssertLessThan(FirmwareVersion("0.9.9")!, FirmwareVersion("0.10.0")!)
        XCTAssertNil(FirmwareVersion("0.2.x"))
        XCTAssertEqual(FirmwareVersion("v1.2")?.description, "v1.2.0")
    }

    func testPushSendsHeaderAndImage() async throws {
        let board = try FakeOTABoard(cutAfter: nil)
        let progress = PushProgress()
        try await Firmware.push(image, md5: "abc", host: "127.0.0.1", token: "tok", port: board.port) { p in progress.last = p }
        let (head, body) = board.received()
        XCTAssertEqual(head, "ota tok \(image.count) abc")
        XCTAssertEqual(body, image)
        XCTAssertEqual(progress.last, 1)
    }

    func testCutConnectionFails() async throws {
        let board = try FakeOTABoard(cutAfter: 30_000)
        do {
            try await Firmware.push(image, md5: "abc", host: "127.0.0.1", token: "tok", port: board.port) { _ in }
            XCTFail("a cut connection must not count as installed")
        } catch {}
    }

    func testRefusalIsReported() async throws {
        let board = try FakeOTABoard(cutAfter: nil, answer: "err wrong token")
        do {
            try await Firmware.push(image, md5: "abc", host: "127.0.0.1", token: "bad", port: board.port) { _ in }
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("wrong token"))
        }
    }
}

private final class PushProgress: @unchecked Sendable { var last = 0.0 }

/// Accepts one connection like ota.cpp: header line, "ok", the image, "done". Optionally closes after
/// `cutAfter` bytes, or refuses the header with `answer`.
private final class FakeOTABoard: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let done = DispatchSemaphore(value: 0)
    private var head = "", body = Data()

    init(cutAfter: Int?, answer: String = "ok") throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        fd = server
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) } }
        listen(server, 1)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in
            let c = accept(server, nil, nil)
            defer { close(c); close(server); done.signal() }
            var line: [UInt8] = [], ch: UInt8 = 0
            while recv(c, &ch, 1, 0) == 1, ch != 10 { line.append(ch) }
            head = String(decoding: line, as: UTF8.self)
            _ = (answer + "\n").withCString { send(c, $0, strlen($0), 0) }
            guard answer == "ok", let size = Int(head.split(separator: " ")[2]) else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            while body.count < size {
                if let cutAfter, body.count >= cutAfter { return }
                let n = recv(c, &buf, buf.count, 0)
                if n <= 0 { return }
                body.append(contentsOf: buf[0..<n])
            }
            _ = "done\n".withCString { send(c, $0, 5, 0) }
        }
    }

    func received() -> (String, Data) {
        done.wait()
        return (head, body)
    }
}

/// MetricKit crash trees as PostHog Error Tracking frames.
final class CrashFramesTests: XCTestCase {
    private let tree = Data(#"""
    {"callStacks":[{"threadAttributed":false,"callStackRootFrames":[{"binaryName":"SwiftUI","binaryUUID":"S","offsetIntoBinaryTextSegment":1}]},
     {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"libdispatch.dylib","binaryUUID":"D","offsetIntoBinaryTextSegment":21824,
      "subFrames":[{"binaryName":"IPhoneAgent","binaryUUID":"A","offsetIntoBinaryTextSegment":365024,
       "subFrames":[{"binaryName":"IPhoneAgent","binaryUUID":"A","offsetIntoBinaryTextSegment":365704}]}]}]}]}
    """#.utf8)

    func testCrashedThreadInnermostFirst() {
        let frames = CrashFrames.crashed(tree)
        XCTAssertEqual(frames.map(\.binary), ["libdispatch.dylib", "IPhoneAgent", "IPhoneAgent"])
        XCTAssertEqual(frames[1].offset, 365024)
        XCTAssertEqual(CrashFrames.fingerprint(frames, build: "24"), "24:591e0,59488")
        let e = CrashFrames.exception(type: "EXC 6 / signal 5", message: "crash", frames: frames, build: "24")
        let list = e["$exception_list"] as? [[String: Any]]
        XCTAssertEqual(list?.first?["type"] as? String, "EXC 6 / signal 5")
        XCTAssertTrue(CrashFrames.crashed(Data("{}".utf8)).isEmpty)
    }
}

import Foundation
import NetworkExtension
import XCTest
@testable import IPhoneAgent

/// LAN mode: the lock's proofs and encryption (the same vectors as hardware/tests test_lan_lock), joining a network
/// with or without a password, the join flow against a fake board, and the video and update channels' handshakes.
final class LanAuthTests: XCTestCase {
    private let token = "00112233445566778899aabbccddeeff", nonce = "0f0e0d0c0b0a09080706050403020100"

    func testProofsMatchTheFirmware() {
        XCTAssertEqual(LanAuth.mac(token: "Jefe", "what do ya want for nothing?"),  // RFC 4231 test case 2
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(LanAuth.video(token: token, nonce: nonce), "df20947056845d461c448d63b048d4ba21b3d9bf15ca7fda2be7177c74184655")
        XCTAssertEqual(LanAuth.ota(token: token, nonce: nonce, size: 1234,
                                   sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"),
                       "37fa45d2f82c619a4cef6dd88ac0978791255d6ca3acad4f54acc49442b6e3a2")
    }

    func testOneKeystreamAcrossRecords() throws {
        let plain = Data("LAN video test: one stream, two records.".utf8)  // a fixed test vector: change it only with `want`
        let want = Data(hex: "b037da6112e1e944aa5fd0a4deeccaf1f01160c01da943a1d4cd0e907946ef384efbd4183b60b93d")
        let split = try XCTUnwrap(LanAuth.Stream(token: token, nonce: nonce))
        XCTAssertEqual(split.crypt(plain.prefix(7)) + split.crypt(Data()) + split.crypt(plain.dropFirst(7)), want)
        let back = try XCTUnwrap(LanAuth.Stream(token: token, nonce: nonce))
        XCTAssertEqual(back.crypt(want), plain, "CTR: the same operation decrypts")
    }

    func testChallengeRecord() {
        XCTAssertEqual(LanAuth.challenge(Data("chal\(nonce)".utf8)), nonce)
        XCTAssertNil(LanAuth.challenge(Data("chal\(nonce.dropLast())".utf8)))
        XCTAssertNil(LanAuth.challenge(Data("chal\(nonce.dropLast())z".utf8)))
        XCTAssertNil(LanAuth.challenge(Data([0, 0, 1]) + Data(nonce.utf8)))
    }

    func testOnlyFirmwareWithTheLockIsSupported() throws {
        XCTAssertFalse(LanAuth.supported(nil))
        XCTAssertFalse(LanAuth.supported(BoardStatus.decode(Data(#"{"fw":"0.2.5","net":"sta"}"#.utf8))))
        let locked = try XCTUnwrap(BoardStatus.decode(Data(#"{"fw":"0.2.6","net":"sta","own":1}"#.utf8)))
        XCTAssertTrue(LanAuth.supported(locked))
        XCTAssertTrue(LanAuth.supported(BoardStatus.decode(Data(#"{"net":"ap","own":0}"#.utf8))))
        XCTAssertNil(locked.merged(with: BoardStatus.decode(Data(#"{"fw":"0.2.5"}"#.utf8))!).own,
                     "a board flashed back to older firmware has no lock")
    }

    func testOpenNetworksJoinWithoutAPassphrase() throws {
        let open = try Hotspot.configuration(NetConfig(mode: "sta", ssid: "Cafe"))
        XCTAssertEqual(open.ssid, "Cafe")
        XCTAssertEqual(try Hotspot.configuration(NetConfig(mode: "sta", ssid: "Cafe", pass: "")).ssid, "Cafe")
        XCTAssertEqual(try Hotspot.configuration(NetConfig(mode: "sta", ssid: "Home", pass: "secret12")).ssid, "Home")
        XCTAssertEqual(try Hotspot.configuration(NetConfig(mode: "ap", ssid: "ESP32Agent-1A2B", pass: "abcdefgh1234")).ssid,
                       "ESP32Agent-1A2B")
        XCTAssertThrowsError(try Hotspot.configuration(NetConfig(mode: "ap", ssid: "ESP32Agent-1A2B")),
                             "the board's hotspot always has a password")
        XCTAssertThrowsError(try Hotspot.configuration(NetConfig(mode: "sta", ssid: "")))
    }
}

/// LanJoinFlow against a scripted board on a virtual clock.
@MainActor final class LanJoinFlowTests: XCTestCase {
    private final class Board {
        var connected = true
        var net: String? = "ap"
        var own: Int? = 0
        var written: [NetConfig] = []
        var joinedPhone: [NetConfig] = []
        var phoneSSID: String?
        var video = false
        var saved: [String: String] = [:]
        var clock = 0.0
        var states: [LanJoinState] = []
        var joinError: Error?
        /// At these times the board's reported mode changes.
        var script: [(at: Double, net: String)] = []
        var readSSID: String?
        var boardIP = "192.168.1.50"
        var bridge: [(name: String, ipv4: String)] = []  // this phone's interfaces, for the Personal Hotspot check

        func env() -> LanJoinFlow.Env {
            LanJoinFlow.Env(
                connected: { self.connected },
                status: {
                    for step in self.script where self.clock >= step.at { self.net = step.net }
                    var s = BoardStatus.decode(Data("{}".utf8))!
                    s.net = self.net
                    s.own = self.own
                    return s
                },
                writeNet: { self.written.append($0) },
                readNet: { NetConfig(mode: "sta", ssid: self.readSSID, ip: self.boardIP) },
                phoneSSID: { self.phoneSSID },
                joinPhone: {
                    self.joinedPhone.append($0)
                    if let e = self.joinError { throw e }
                    self.phoneSSID = $0.ssid
                },
                videoActive: { self.video },
                savePassword: { self.saved[$1] = $0 },
                log: { _ in },
                phoneHosts: { Hotspot.hostsBoard(boardIP: $0, self.bridge) },
                sleep: { self.clock += $0 },
                now: { self.clock })
        }

        func run(_ ssid: String, pass: String = "secret12", remember: Bool = true) async -> Bool {
            await LanJoinFlow.run(ssid: ssid, pass: pass, remember: remember, env: env()) { self.states.append($0) }
        }
    }

    func testJoinsAndJoinsThisDeviceToo() async {
        let b = Board()
        b.script = [(3, "none"), (6, "sta")]
        b.readSSID = "Home"
        let joined = await b.run("Home")
        XCTAssertTrue(joined)
        XCTAssertEqual(b.written, [NetConfig(mode: "sta", ssid: "Home", pass: "secret12")])
        XCTAssertEqual(b.joinedPhone.map(\.ssid), ["Home"])
        XCTAssertEqual(b.saved, ["Home": "secret12"])
        XCTAssertEqual(b.states, [.boardConnecting, .checkingPhone, .joined])
    }

    func testBoardOnThisPhonesHotspotIsNotJoined() async {
        let b = Board()
        b.script = [(2, "sta")]
        b.readSSID = "PhoneHotspot"
        b.boardIP = "172.20.10.10"
        b.bridge = [("bridge100", "172.20.10.1"), ("pdp_ip0", "10.1.2.3")]
        let joined = await b.run("PhoneHotspot")
        XCTAssertTrue(joined)
        XCTAssertTrue(b.joinedPhone.isEmpty, "the phone is the access point: never asked to join its own hotspot")
        XCTAssertEqual(b.states.last, .joined)
    }

    func testOpenNetworkSendsNoPassword() async {
        let b = Board()
        b.script = [(1, "sta")]
        let joined = await b.run("Cafe", pass: "")
        XCTAssertTrue(joined)
        XCTAssertNil(b.written.first?.pass)
        XCTAssertNil(b.joinedPhone.first?.pass, "an open network is joined without a passphrase")
        XCTAssertTrue(b.saved.isEmpty)
    }

    func testOlderFirmwareIsNotPutOnAHomeNetwork() async {
        let b = Board()
        b.own = nil
        let joined = await b.run("Home")
        XCTAssertFalse(joined)
        XCTAssertTrue(b.written.isEmpty, "nothing is sent to a board without the LAN lock")
        guard case .failed(let why) = b.states.last else { return XCTFail() }
        XCTAssertTrue(why.contains("firmware"))
    }

    func testChangingNetworksWaitsForTheOldOneToDrop() async {
        let b = Board()
        b.net = "sta"
        b.phoneSSID = "Old"
        b.script = [(2, "none"), (5, "sta")]
        b.readSSID = "New"
        let joined = await b.run("New")
        XCTAssertTrue(joined)
        XCTAssertGreaterThanOrEqual(b.clock, 5, "the old network's sta is no proof of the new one")
        XCTAssertEqual(b.joinedPhone.map(\.ssid), ["New"])
    }

    func testBoardOnAnotherNetworkFails() async {
        let b = Board()
        b.script = [(1, "sta")]
        b.readSSID = "Neighbour"
        let joined = await b.run("Home")
        XCTAssertFalse(joined)
        guard case .failed(let why) = b.states.last else { return XCTFail() }
        XCTAssertTrue(why.contains("Home"))
    }

    func testBoardThatNeverJoinsFailsAfterTheWait() async {
        let b = Board()
        b.script = [(1, "none")]
        let joined = await b.run("Home")
        XCTAssertFalse(joined)
        XCTAssertGreaterThanOrEqual(b.clock, LanJoinFlow.boardWait)
        XCTAssertTrue(b.joinedPhone.isEmpty)
    }

    func testBoardLostWhileJoiningFails() async {
        let b = Board()
        b.script = [(1, "none")]
        b.connected = true
        let env = b.env()
        var states: [LanJoinState] = []
        var wrapped = env
        wrapped.sleep = { b.clock += $0; if b.clock > 3 { b.connected = false } }
        let joined = await LanJoinFlow.run(ssid: "Home", pass: "x", remember: false, env: wrapped) { states.append($0) }
        XCTAssertFalse(joined)
        guard case .failed(let why) = states.last else { return XCTFail() }
        XCTAssertTrue(why.contains("disconnected"))
        XCTAssertLessThan(b.clock, LanJoinFlow.boardWait)
    }

    func testDeclinedJoinSaysSo() async {
        let b = Board()
        b.script = [(1, "sta")]
        b.joinError = NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.userDenied.rawValue)
        let joined = await b.run("Home")
        XCTAssertFalse(joined)
        guard case .failed(let why) = b.states.last else { return XCTFail() }
        XCTAssertTrue(why.contains("declined"))
    }

    func testWorkingVideoIsProofEnough() async {
        let b = Board()
        b.script = [(1, "sta")]
        b.video = true
        b.phoneSSID = "Home 5G"  // the router's other band
        let joined = await b.run("Home")
        XCTAssertTrue(joined)
        XCTAssertTrue(b.joinedPhone.isEmpty, "already reaches the board: not moved to another network")
    }

    func testPhoneElsewhereFailsWithAHint() async {
        let b = Board()
        b.script = [(1, "sta")]
        b.joinError = NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.internal.rawValue)
        let joined = await b.run("Home")
        XCTAssertFalse(joined)
        guard case .failed(let why) = b.states.last else { return XCTFail() }
        XCTAssertTrue(why.contains("on this device"))
    }
}

/// The video channel's secure handshake (VideoStream with `secure`) against a fake board on localhost.
@MainActor final class SecureVideoTests: XCTestCase {
    func testProvesTheTokenAndDecrypts() async throws {
        let token = "00112233445566778899aabbccddeeff", nonce = "0f0e0d0c0b0a09080706050403020100"
        let plain = Data([1, 0, 0x01, 0xaa, 0xbb])  // seq 1, START
        let board = try FakeVideoBoard { line, reply in
            if line == "chal" { reply(Data("chal\(nonce)".utf8)); return }
            if line.hasPrefix("auth ") {
                XCTAssertEqual(line, "auth \(LanAuth.video(token: token, nonce: nonce))")
                reply(Data())  // the ack
                let cipher = LanAuth.Stream(token: token, nonce: nonce)!
                reply(cipher.crypt(plain))
            }
            XCTAssertFalse(line.hasPrefix("hello"), "the token never goes over the network")
        }
        let stream = VideoStream()
        stream.port = board.port
        stream.secure = { true }
        var chunks: [Data] = []
        let got = expectation(description: "decrypted chunk")
        stream.onChunk = { chunks.append($0); got.fulfill() }
        stream.update(ip: "127.0.0.1", token: token)
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(chunks, [plain])
        XCTAssertTrue(stream.active)
        stream.stop()
    }

    func testPlainHelloWithoutTheLock() async throws {
        let said = expectation(description: "hello")
        let board = try FakeVideoBoard { line, reply in
            if line.hasPrefix("hello ") {
                XCTAssertEqual(line, "hello tok")
                reply(Data())
                said.fulfill()
            }
        }
        let stream = VideoStream()
        stream.port = board.port
        stream.update(ip: "127.0.0.1", token: "tok")
        await fulfillment(of: [said], timeout: 5)
        stream.stop()
    }
}

/// The board closing the stream before it answers (a refused hello, an old session still held) is retried with a
/// growing wait, not at once.
final class VideoRetryTests: XCTestCase {
    func testRetriesBackOff() {
        XCTAssertEqual(VideoStream.retryDelay(after: 1), 0.25)
        XCTAssertEqual(VideoStream.retryDelay(after: 2), 0.5)
        XCTAssertEqual(VideoStream.retryDelay(after: 5), 4)
        XCTAssertEqual(VideoStream.retryDelay(after: 40), 5, "at most 5 s")
    }

    @MainActor func testAClosedHelloIsNotRetriedAtOnce() async throws {
        let tries = TryCounter()
        let board = try FakeVideoBoard(closeEach: true) { _, _ in }
        board.onAccept = { tries.n += 1 }
        let stream = VideoStream()
        stream.port = board.port
        stream.update(ip: "127.0.0.1", token: "tok")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        stream.stop()
        XCTAssertGreaterThan(tries.n, 1, "it does try again")
        XCTAssertLessThanOrEqual(tries.n, 5, "0.25, 0.5, 1 s apart: a handful in 1.5 s, not hundreds")
    }
}

private final class TryCounter: @unchecked Sendable { var n = 0 }

/// One connection on localhost: hands every text line from the app to `handle`, which may answer with records.
private final class FakeVideoBoard: @unchecked Sendable {
    let port: UInt16
    var onAccept: (() -> Void)?

    /// closeEach: every connection is closed at once (a board refusing the hello), any number of them.
    init(closeEach: Bool = false, handle: @escaping @Sendable (String, (Data) -> Void) -> Void) throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) } }
        listen(server, 1)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        if closeEach {
            Thread.detachNewThread { [self] in
                while true {
                    let c = accept(server, nil, nil)
                    guard c >= 0 else { return }
                    onAccept?()
                    close(c)
                }
            }
            return
        }
        Thread.detachNewThread {
            let c = accept(server, nil, nil)
            defer { close(c); close(server) }
            var tv = timeval(tv_sec: 6, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let reply: (Data) -> Void = { body in
                let record = Data([UInt8(body.count & 0xff), UInt8(body.count >> 8)]) + body
                _ = record.withUnsafeBytes { send(c, $0.baseAddress, record.count, 0) }
            }
            var line: [UInt8] = [], ch: UInt8 = 0
            while recv(c, &ch, 1, 0) == 1 {
                if ch != 10 { line.append(ch); continue }
                let text = String(decoding: line, as: UTF8.self)
                line = []
                if text != "ka" { handle(text, reply) }
            }
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }
}

/// The home network to fill in: iOS names only networks this app joined, so the last one the board joined stands in.
final class LanMemoryTests: XCTestCase {
    func testSuggestion() {
        XCTAssertEqual(LanMemory.suggestion(current: "Home", boardHotspot: "ESP32Agent-6AD5", last: "Old"), "Home")
        XCTAssertEqual(LanMemory.suggestion(current: "ESP32Agent-6AD5", boardHotspot: "ESP32Agent-6AD5", last: "qaq"), "qaq",
                       "never the board's own hotspot")
        XCTAssertEqual(LanMemory.suggestion(current: "ESP32Agent-1234", boardHotspot: nil, last: "qaq"), "qaq")
        XCTAssertEqual(LanMemory.suggestion(current: nil, boardHotspot: nil, last: "qaq"), "qaq", "iOS won't name a home network")
        XCTAssertNil(LanMemory.suggestion(current: nil, boardHotspot: nil, last: nil))
    }
}

/// Joining the board's hotspot, or not: a board that is a client of this iPhone's own Personal Hotspot.
final class HotspotJoinDecisionTests: XCTestCase {
    private let sharing: [(name: String, ipv4: String)] = [("bridge100", "172.20.10.1"), ("pdp_ip0", "10.1.2.3")]

    func testBoardOnThisPhonesHotspotIsNeverJoined() {
        let d = HotspotJoinDecision.decide(netMode: "sta", statusNet: "sta", boardIP: "172.20.10.10", interfaces: sharing)
        XCTAssertEqual(d, .phoneHostsBoard(ip: "172.20.10.10"))
        XCTAssertEqual(d.skipLine, "hotspot: board on this iPhone's Personal Hotspot at 172.20.10.10; not joining")
        XCTAssertTrue(Hotspot.hostsBoard(boardIP: "172.20.10.10", sharing))
    }

    func testBoardStillJoiningAfterABootIsNotJoinedEither() {
        // status net "none", `net` not read again yet: the board is a station, not an access point
        XCTAssertEqual(HotspotJoinDecision.decide(netMode: nil, statusNet: "none", boardIP: nil, interfaces: sharing), .boardOnOtherWiFi)
        XCTAssertEqual(HotspotJoinDecision.decide(netMode: "sta", statusNet: nil, boardIP: "", interfaces: []), .boardOnOtherWiFi)
    }

    func testBoardsOwnAccessPointIsJoinedAsBefore() {
        XCTAssertEqual(HotspotJoinDecision.decide(netMode: "ap", statusNet: "ap", boardIP: "192.168.4.1", interfaces: []), .join)
        XCTAssertEqual(HotspotJoinDecision.decide(netMode: "ap", statusNet: "ap", boardIP: "192.168.4.1", interfaces: sharing), .join,
                       "Personal Hotspot on, board on its own AP: join (the page warns about the hotspot)")
        XCTAssertNil(HotspotJoinDecision.join.skipLine)
    }

    func testAnotherIPhonesHotspotIsNotThisOne() {
        // this phone is itself a client of some hotspot (en0 on 172.20.10.x), no bridge: not the host
        XCTAssertFalse(Hotspot.hostsBoard(boardIP: "172.20.10.10", [("en0", "172.20.10.3")]))
        XCTAssertFalse(Hotspot.hostsBoard(boardIP: "192.168.1.50", sharing))
        XCTAssertFalse(Hotspot.hostsBoard(boardIP: nil, sharing))
    }
}

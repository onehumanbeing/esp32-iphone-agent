import XCTest
@testable import IPhoneAgent

private final class FakeTransport: RemoteLogTransport {
    var replies: [(String, Int)] = []
    var sent: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        sent.append(request)
        let (body, status) = replies.isEmpty ? ("{}", 200) : replies.removeFirst()
        return (Data(body.utf8), status)
    }
}

@MainActor final class RemoteLogTests: XCTestCase {
    private func log(_ transport: FakeTransport, url: String = "https://logs.example/dev", token: String = "device-token-123",
                     text: String = "") -> RemoteLog {
        let r = RemoteLog()
        r.transport = transport
        r.config = { RemoteLogConfig(url: url, token: token) }
        r.logText = { text }
        r.secrets = { [$0.token, "sk-live-model-key-abcdef"] }
        r.now = { ISO8601DateFormatter().date(from: "2026-11-11T10:00:00Z")! }
        return r
    }

    func testOffWhenEmptyOrNotHTTPS() async {
        for (url, token) in [("", ""), ("https://logs.example", ""), ("", "t"), ("http://logs.example", "t"),
                             ("https://user:pw@logs.example", "t"), ("logs.example", "t")] {
            let transport = FakeTransport()
            let id = await log(transport, url: url, token: token).tick()
            XCTAssertNil(id)
            XCTAssertTrue(transport.sent.isEmpty, "\(url) must make no network call")
        }
        XCTAssertNil(RemoteLogConfig().endpoint)
    }

    func testPollWithoutRequestUploadsNothing() async {
        let transport = FakeTransport()
        let id = await log(transport).tick()
        XCTAssertNil(id)
        XCTAssertEqual(transport.sent.map { $0.url?.absoluteString }, ["https://logs.example/dev/poll"])
        XCTAssertEqual(transport.sent[0].value(forHTTPHeaderField: "Authorization"), "Bearer device-token-123")
    }

    func testRequestThenUploadOfTheAskedMinutes() async throws {
        let text = """
        2026-11-11T09:40:00.000Z old line
        2026-11-11T09:57:00.000Z new line Authorization: Bearer abcdefghijklmnop
        continuation without a stamp sk-live-model-key-abcdef
        2026-11-11T09:59:30.500Z api_key=supersecretvalue host 192.168.4.1
        """
        let transport = FakeTransport()
        transport.replies = [(#"{"want":{"id":"ab12cd34","minutes":5}}"#, 200), (#"{"key":"k"}"#, 200)]
        let id = await log(transport, text: text).tick()
        XCTAssertEqual(id, "ab12cd34")
        XCTAssertEqual(transport.sent.count, 2)
        let up = transport.sent[1]
        XCTAssertEqual(up.url?.absoluteString, "https://logs.example/dev/upload")
        XCTAssertEqual(up.value(forHTTPHeaderField: "X-Request-Id"), "ab12cd34")
        XCTAssertTrue(up.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/plain") ?? false)
        let body = String(decoding: try XCTUnwrap(up.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("old line"))
        XCTAssertTrue(body.contains("new line"))
        XCTAssertTrue(body.contains("continuation"))
        for secret in ["abcdefghijklmnop", "sk-live-model-key-abcdef", "supersecretvalue", "192.168.4.1"] {
            XCTAssertFalse(body.contains(secret), secret)
        }
    }

    func testFailedUploadIsReported() async {
        let transport = FakeTransport()
        transport.replies = [(#"{"want":{"id":"x1","lines":10}}"#, 200), (#"{"error":"rate limited"}"#, 429)]
        let id = await log(transport, text: "a\nb\n").tick()
        XCTAssertNil(id)
        XCTAssertEqual(transport.sent.count, 2)
    }

    func testRedaction() {
        let clean = RemoteLogRedaction.clean("""
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig
        "token":"abcd1234efgh" password=hunter22 x-api-key: k-123456
        ticket v1.eyJkIjoiZGV2LTEifQ.c2lnbmF0dXJlLWJ5dGVz and ghp_abcdefghijklmnopqrstuvwxyz
        mine-own-token-value data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ
        cmd #12 type hello world → ok
        tap 120 340 → ok; run 3F2504E0-4F89-11D3-9A0C-0305E82C3301
        """, secrets: ["mine-own-token-value"])
        for leak in ["eyJhbGci", "abcd1234efgh", "hunter22", "k-123456", "v1.eyJk", "ghp_abcdef", "mine-own-token-value",
                     "/9j/4AAQ", "hello world"] {
            XCTAssertFalse(clean.contains(leak), leak)
        }
        XCTAssertTrue(clean.contains("[image removed]"))
        XCTAssertTrue(clean.contains("tap 120 340 → ok"))
        XCTAssertTrue(clean.contains("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))  // ids stay readable
    }

    func testTailByLinesAndCap() {
        let want = RemoteLogWant(id: "i", minutes: nil, lines: 2)
        XCTAssertEqual(RemoteLog.tail("1\n2\n3\n", want: want, now: Date()), "2\n3\n")
        let long = String(repeating: "x", count: 1000) + "\n"
        let capped = RemoteLog.capped(String(repeating: long, count: 2500))
        XCTAssertLessThanOrEqual(capped.utf8.count, RemoteLog.maxBytes)
        XCTAssertTrue(capped.hasPrefix("x"))
    }

    func testDroppedConfigIsImportedOnce() throws {
        XCTAssertEqual(RemoteLogConfig.parse(drop: Data(#"{"url":"https://a.example","token":"t0k"}"#.utf8)),
                       RemoteLogConfig(url: "https://a.example", token: "t0k"))
        XCTAssertNil(RemoteLogConfig.parse(drop: Data(#"{"url":"http://a.example","token":"t0k"}"#.utf8)))
        XCTAssertNil(RemoteLogConfig.parse(drop: Data("not json".utf8)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(RemoteLogConfig.dropName)
        try Data("garbage".utf8).write(to: file)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertFalse(RemoteLogConfig.importDrop(from: dir, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))  // deleted either way
        XCTAssertNil(defaults.string(forKey: RemoteLogConfig.urlKey))
    }
}

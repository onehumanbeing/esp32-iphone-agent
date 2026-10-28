import XCTest
@testable import IPhoneAgent

/// An in-memory endpoint: records request bodies and answers with `respond`.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ([String: Any]) -> (Int, String, String) = { _ in (200, "application/json", "{}") }
    nonisolated(unsafe) static var seen: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.seen.append(json)
        let (status, type, text) = Self.respond(json)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Port of server/tests/test_llm.py, plus streaming.
@MainActor final class LLMTests: XCTestCase {
    func testProviderInferenceAndCustomEndpoints() {
        XCTAssertEqual(ModelProvider.infer(baseURL: "https://openrouter.ai/api/v1/", model: "openrouter/free"), .openRouter)
        XCTAssertEqual(ModelProvider.infer(baseURL: "https://api.openai.com/v1", model: "custom"), .openAI)
        XCTAssertEqual(ModelProvider.infer(baseURL: "http://192.168.1.4:8080/v1", model: "local"), .others)
        XCTAssertNotEqual(ModelProvider.qwen.baseURL, ModelProvider.qwenInternational.baseURL)
    }

    func testProviderSwitchResetsModelOverridesAndOthersKeepsEditableConfig() async throws {
        let name = "provider-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.openRouter)
        settings.model = "openrouter/free"
        XCTAssertEqual(settings.baseURL, "https://openrouter.ai/api/v1")
        let model = try await settings.resolvedModel()
        XCTAssertEqual(model, "openrouter/free")
        settings.plannerModel = "old-planner"
        settings.actorModel = "old-actor"
        settings.selectProvider(.openAI)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.actorModel, "")
        XCTAssertEqual(settings.plannerModel, "")
        do { _ = try await settings.resolvedModel(); XCTFail("Must explicitly choose a model") } catch {}
        settings.selectProvider(.others)
        settings.baseURL = "http://192.168.1.4:8080/v1"
        settings.model = "my-custom-vision-model"
        XCTAssertTrue(settings.isConfigured)
        let custom = try await settings.resolvedModel()
        XCTAssertEqual(custom, "my-custom-vision-model")
        XCTAssertEqual(settings.provider, .others)
        settings.baseURL = "httpjunk://endpoint"
        XCTAssertFalse(settings.isConfigured)
    }

    func testImageCheckDoesNotTreatSubstringsOrNegationAsSuccess() throws {
        XCTAssertNoThrow(try ModelConnectionCheck.validate(ChatResult(text: "Red.", total: 0)))
        for text in ["infrared", "not red", "", "I cannot identify the image"] {
            XCTAssertThrowsError(try ModelConnectionCheck.validate(ChatResult(text: text, total: 0)))
        }
    }

    func testLegacyFreeProviderPreservesModelAndMigratesProvider() {
        let name = "migration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openRouterFree", forKey: "modelProvider")
        defaults.set(ModelProvider.openRouter.baseURL, forKey: "baseURL")
        defaults.set("openrouter/free", forKey: "model")
        let settings = Settings(defaults: defaults, info: [:])
        XCTAssertEqual(settings.provider, .openRouter)
        XCTAssertEqual(settings.currentModel, "openrouter/free")
    }

    func testStreamErrorIsNotMistakenForEmptyReply() async {
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            (200, "text/event-stream", "data: {\"error\": {\"message\": \"No available provider\"}}\n\ndata: [DONE]\n\n")
        }
        do {
            _ = try await client("router").chat(system: "test", text: "test")
            XCTFail("Expected provider error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No available provider")
            XCTAssertEqual(StubProtocol.seen.count, 1)
        }
    }

    func testProgressWaitsThroughKeepalivesAndStartsOnReasoning() async throws {
        let llm = client("progress")
        var progress: [ModelResponseProgress] = []
        llm.onProgress = { progress.append($0) }
        StubProtocol.respond = { _ in
            (200, "text/event-stream", ": heartbeat\n\n"
             + "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n"
             + "data: {\"choices\":[{\"delta\":{\"reasoning\":\"planning\"}}]}\n\n"
             + "data: {\"choices\":[{\"delta\":{\"content\":\"Red\"}}]}\n\n"
             + "data: [DONE]\n\n")
        }
        _ = try await llm.chat(system: "test", text: "test")
        XCTAssertEqual(progress, [.waiting, .receiving])
    }

    func client(_ model: String, extra: [String: Any] = [:], tokenParam: String = "auto") -> LLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return LLMClient(baseURL: "http://test/v1/", model: model, extra: extra, tokenParam: tokenParam,
                         session: URLSession(configuration: config))
    }

    /// Only accept the `wants` token parameter, like servers that reject the other one.
    func fakeServer(wants: String) {
        StubProtocol.seen = []
        StubProtocol.respond = { body in
            guard body[wants] != nil else {
                return (400, "application/json", "{\"error\": {\"message\": \"Unsupported parameter. Use '\(wants)' instead.\"}}")
            }
            return (200, "application/json", "{\"choices\": [{\"message\": {\"content\": \"DO: wait\"}}]}")
        }
    }

    func testClassicServersGetMaxTokensOnce() async throws {
        let llm = client("qwen")
        fakeServer(wants: "max_tokens")
        let reply = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(reply.text, "DO: wait")
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual(StubProtocol.seen[0]["max_tokens"] as? Int, 600)
        XCTAssertEqual(StubProtocol.seen[0]["stream"] as? Bool, true)
    }

    func testAutoSwitchesToMaxCompletionTokensAndRemembers() async throws {
        let llm = client("gpt")
        fakeServer(wants: "max_completion_tokens")
        _ = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        _ = try await llm.chat(system: "sys", text: "again", image: nil, maxTokens: 600, temperature: 0)
        let flags = StubProtocol.seen.map { [$0["max_tokens"] != nil, $0["max_completion_tokens"] != nil] }
        XCTAssertEqual(flags, [[true, false], [false, true], [false, true]])
    }

    func testTemperatureIsDroppedWhenTheModelRefusesIt() async throws {
        let llm = client("gpt")
        StubProtocol.seen = []
        StubProtocol.respond = { body in
            guard body["temperature"] == nil else {
                return (400, "application/json",
                        "{\"error\": {\"message\": \"Unsupported value: 'temperature' does not support 0 with this model.\"}}")
            }
            return (200, "application/json", "{\"choices\": [{\"message\": {\"content\": \"DO: wait\"}}]}")
        }
        let reply = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(reply.text, "DO: wait")
        _ = try await llm.chat(system: "sys", text: "again", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(StubProtocol.seen.map { $0["temperature"] != nil }, [true, false, false])
    }

    func testExplicitTokenParamIsUsedDirectly() async throws {
        let llm = client("gpt", tokenParam: "max_completion_tokens")
        fakeServer(wants: "max_completion_tokens")
        _ = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testExtraBodyAndImageAreSent() async throws {
        let llm = client("gpt", extra: ["reasoning_effort": "none"])
        fakeServer(wants: "max_tokens")
        _ = try await llm.chat(system: "sys", text: "hi", image: Data([0xff, 0xd8]) + Data("jpeg".utf8),
                               maxTokens: 600, temperature: 0)
        let body = StubProtocol.seen[0]
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let user = (body["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        let url = (user?[0]["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertTrue(url?.hasPrefix("data:image/jpeg;base64,") ?? false)
    }

    func testStreamedReplyIsJoinedAndTimed() async throws {
        let llm = client("qwen")
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            let events = ["THINK: ", "ok\n", "DO: wait"].map {
                "data: {\"choices\": [{\"delta\": {\"content\": \"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"}}]}\n\n"
            }
            return (200, "text/event-stream", events.joined() + "data: [DONE]\n\n")
        }
        let reply = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(reply.text, "THINK: ok\nDO: wait")
        XCTAssertNotNil(reply.firstToken)
    }

    func testEmptyReplyIsAskedOnceMoreWithItsReasonLogged() async throws {
        let llm = client("qwen")
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            let first = StubProtocol.seen.count == 1
            let delta = first ? "{\"reasoning_content\": \"hmm\"}" : "{\"content\": \"DO: wait\"}"
            let finish = first ? "length" : "stop"
            return (200, "text/event-stream", "data: {\"choices\": [{\"delta\": \(delta)}]}\n\n"
                    + "data: {\"choices\": [{\"delta\": {}, \"finish_reason\": \"\(finish)\"}], \"usage\": {\"completion_tokens\": 9}}\n\n"
                    + "data: [DONE]\n\n")
        }
        let reply = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(StubProtocol.seen.count, 2)
        XCTAssertEqual(reply.text, "DO: wait")
        XCTAssertTrue(reply.retried)
        XCTAssertEqual(reply.finishReason, "stop")
        XCTAssertEqual(reply.usage["completion_tokens"], 9)
    }

    func testHTTPErrorsAreThrown() async {
        let llm = client("qwen")
        StubProtocol.respond = { _ in (500, "text/plain", "boom") }
        do {
            _ = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }
}

import XCTest
@testable import IPhoneAgent

/// Sign in with ChatGPT: the Responses request the Codex endpoint takes, its streamed events, its limits, the account.
@MainActor final class ChatGPTTests: XCTestCase {
    private func client(_ model: String = "gpt-5.x", extra: [String: Any] = [:]) -> LLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return LLMClient(baseURL: ModelProvider.chatGPT.baseURL, model: model, apiKey: "token", extra: extra,
                         session: URLSession(configuration: config))
    }

    private func events(_ list: [[String: Any]]) -> String {
        list.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    }

    func testProviderIsASignInOutsideThePresets() {
        XCTAssertTrue(ModelProvider.chatGPT.signsIn)
        XCTAssertNil(ModelProvider.chatGPT.keyURL)
        XCTAssertEqual(ModelProvider.infer(baseURL: ModelProvider.chatGPT.baseURL + "/", model: "x"), .chatGPT)
        XCTAssertTrue(client().speaksResponses)
        XCTAssertFalse(LLMClient(baseURL: ModelProvider.openAI.baseURL, model: "gpt").speaksResponses)
    }

    func testRequestIsResponsesShapedAndTheStreamIsJoined() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            (200, "text/event-stream", self.events([
                ["type": "response.created"],
                ["type": "response.reasoning_summary_text.delta", "delta": "look"],
                ["type": "response.output_text.delta", "delta": "THINK: ok\n"],
                ["type": "response.output_text.delta", "delta": "DO: wait"],
                ["type": "response.completed", "response": ["model": "gpt-5.x", "usage": ["output_tokens": 7]]],
            ]))
        }
        let reply = try await client(extra: ["reasoning": ["effort": "medium"]])
            .chat(system: "sys", text: "hi", image: Data([1, 2, 3]), maxTokens: 600, temperature: 0)
        XCTAssertEqual(reply.text, "THINK: ok\nDO: wait")
        XCTAssertEqual(reply.finishReason, "stop")
        XCTAssertEqual(reply.usage["output_tokens"], 7)
        XCTAssertEqual(reply.reasoningChars, 4)
        let body = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(body["instructions"] as? String, "sys")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium", "Extra body wins")
        for refused in ["temperature", "max_tokens", "max_completion_tokens", "messages"] { XCTAssertNil(body[refused], refused) }
        let content = (((body["input"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_image", "input_text"])
        XCTAssertEqual(content.first?["image_url"] as? String, "data:image/jpeg;base64,AQID")
        XCTAssertEqual(StubProtocol.headers.last?["Authorization"], "Bearer token")
    }

    func testAFailedResponseThrowsItsMessage() async {
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            (200, "text/event-stream", self.events([
                ["type": "response.failed", "response": ["error": ["code": "server_error", "message": "boom"]]],
            ]))
        }
        do {
            _ = try await client().chat(system: "s", text: "t")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }
    }

    func testAStreamWithoutItsEndIsALostReply() async {
        StubProtocol.respond = { _ in (200, "text/event-stream", self.events([["type": "response.output_text.delta", "delta": "DO:"]])) }
        do {
            _ = try await client().chat(system: "s", text: "t")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? LLMError)?.reason, "stream_cut")
        }
    }

    func testAReachedUsageLimitIsFinalAndSaysWhenItResets() async {
        StubProtocol.seen = []
        StubProtocol.respond = { _ in
            (429, "application/json", #"{"error": {"type": "usage_limit_reached", "message": "limit", "resets_in_seconds": 3600}}"#)
        }
        do {
            _ = try await client().chat(system: "s", text: "t")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_limit")
            XCTAssertTrue(error.localizedDescription.contains("resets at"), error.localizedDescription)
            XCTAssertEqual(StubProtocol.seen.count, 1, "a used-up plan is not asked again")
        }
        XCTAssertNil(LLMClient.chatGPTLimitError(#"{"error": {"type": "rate_limit_exceeded"}}"#))
    }

    func testARefusedTokenAsksToSignInAgainWhenThereIsNoneToRenew() async {
        ChatGPTAuth.shared.signOut()
        StubProtocol.respond = { _ in (401, "application/json", #"{"error": {"message": "expired"}}"#) }
        do {
            _ = try await client().chat(system: "s", text: "t")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
    }

    func testTheIDTokenGivesTheAccountAndPlan() {
        func jwt(_ claims: [String: Any]) -> String {
            let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(payload).sig"
        }
        let account = ChatGPTAuth.account(fromIDToken: jwt([
            "email": "ada@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-1", "chatgpt_plan_type": "plus"],
        ]))
        XCTAssertEqual(account, ChatGPTAuth.Account(email: "ada@example.com", plan: "plus", accountID: "acc-1"))
        XCTAssertNil(ChatGPTAuth.account(fromIDToken: jwt(["email": "a@b.c"])), "no ChatGPT account: nothing to run on")
        XCTAssertNil(ChatGPTAuth.account(fromIDToken: "not-a-jwt"))
        XCTAssertEqual(ChatGPTAccountRows.masked("ada@example.com"), "a•••@example.com")
    }

    func testUsageWindowsComeFromTheReplyHeaders() {
        let auth = ChatGPTAuth.shared
        let response = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 200, httpVersion: nil, headerFields: [
            "x-codex-primary-used-percent": "23.4", "x-codex-primary-window-minutes": "300",
            "x-codex-primary-reset-at": "1900000000", "x-codex-secondary-used-percent": "41",
        ])!
        auth.noteLimits(response)
        XCTAssertEqual(auth.limits.primary?.usedPercent, 23.4)
        XCTAssertEqual(auth.limits.primary?.minutes, 300)
        XCTAssertEqual(auth.limits.primary?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(auth.limits.secondary?.usedPercent, 41)
        auth.signOut()
        XCTAssertNil(auth.limits.primary)
    }
}

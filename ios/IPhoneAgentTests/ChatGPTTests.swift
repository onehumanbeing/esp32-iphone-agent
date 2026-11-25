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

    // MARK: - #965 item 6, simulated: fake tokens, an in-memory store, stubbed replies (never a real request)

    /// A JWT-shaped fake (unsigned): the app reads only its claims.
    private func fakeJWT(_ claims: [String: Any]) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return b64(Data(#"{"alg":"none"}"#.utf8)) + "." + b64(try! JSONSerialization.data(withJSONObject: claims)) + ".fake"
    }

    private func fakeAccess(_ tag: String, expiresIn seconds: TimeInterval) -> String {
        fakeJWT(["exp": Date().addingTimeInterval(seconds).timeIntervalSince1970, "tag": tag])
    }

    private var fakeID: String {
        fakeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-fake", "chatgpt_plan_type": "plus"],
                 "email": "tester@example.invalid"])
    }

    private struct Isolated {
        let auth: ChatGPTAuth
        let store: InMemoryKeychain
        let access: String
        let client: LLMClient
    }

    /// A sign-in of its own: fake tokens in an in-memory store, every request answered by StubProtocol.
    private func isolated(expiresIn seconds: TimeInterval) -> Isolated {
        let store = InMemoryKeychain(), access = fakeAccess("old", expiresIn: seconds)
        let saved = ["idToken": fakeID, "accessToken": access, "refreshToken": "fake-refresh-1"]
        store.set(String(decoding: try! JSONSerialization.data(withJSONObject: saved), as: UTF8.self), for: "chatgpt-auth")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let auth = ChatGPTAuth(store: store, session: session, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let client = LLMClient(baseURL: ModelProvider.chatGPT.baseURL, model: "gpt-5.x", apiKey: access, session: session,
                               headers: { try auth.headers() }, chatGPTAuth: auth)
        StubProtocol.failure = nil
        (StubProtocol.seen, StubProtocol.headers, StubProtocol.urls) = ([], [], [])
        return Isolated(auth: auth, store: store, access: access, client: client)
    }

    private var refreshes: Int { StubProtocol.seen.filter { $0["grant_type"] as? String == "refresh_token" }.count }
    private var modelCalls: Int { StubProtocol.seen.filter { $0["model"] != nil }.count }

    /// Only the two endpoints, and only through the stub.
    private func assertOnlyStubbedEndpoints(file: StaticString = #filePath, line: UInt = #line) {
        let allowed = ["https://auth.openai.com/oauth/token", ModelProvider.chatGPT.baseURL + "/responses"]
        for url in StubProtocol.urls {
            XCTAssertTrue(allowed.contains(url.absoluteString.components(separatedBy: "?")[0]), "\(url)", file: file, line: line)
        }
    }

    private func refreshed(_ tag: String) -> (Int, String, String) {
        (200, "application/json", String(decoding: try! JSONSerialization.data(withJSONObject: [
            "access_token": fakeAccess(tag, expiresIn: 3600), "refresh_token": "fake-refresh-2", "id_token": fakeID,
        ]), as: UTF8.self))
    }

    private var completed: (Int, String, String) {
        (200, "text/event-stream", events([["type": "response.output_text.delta", "delta": "DO: wait"],
                                           ["type": "response.completed", "response": [:]]]))
    }

    /// The app's own sign-in, to check a test never touched it.
    private func appSignIn() -> (Bool, String?) { (ChatGPTAuth.shared.signedIn, SystemKeychain().get("chatgpt-auth")) }

    func testSimulatedUsageLimitSaysWhenItResetsAndIsNotRetried() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 3600)
        StubProtocol.respond = { body in
            body["grant_type"] != nil ? self.refreshed("new")
                : (429, "application/json", #"{"error": {"type": "usage_limit_reached", "message": "limit", "resets_in_seconds": 3600}}"#)
        }
        do {
            _ = try await s.client.chat(system: "s", text: "t")
            XCTFail("expected the usage limit")
        } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_limit")
            XCTAssertTrue(error.localizedDescription.contains("resets at"), error.localizedDescription)
        }
        XCTAssertEqual(modelCalls, 1, "a used-up plan is not asked again")
        XCTAssertEqual(refreshes, 0, "a usage limit is not a sign-in problem")
        XCTAssertTrue(s.auth.signedIn, "the sign-in stays")
        assertOnlyStubbedEndpoints()
        XCTAssertEqual(appSignIn().0, before.0); XCTAssertEqual(appSignIn().1, before.1)
    }

    func testSimulatedNearExpiryRenewsOnceAndKeepsTheNewTokens() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 300)  // within 10 minutes
        StubProtocol.respond = { body in body["grant_type"] != nil ? self.refreshed("new") : self.completed }
        let first = try await s.auth.accessToken()
        XCTAssertNotEqual(first, s.access)
        XCTAssertEqual(refreshes, 1)
        let second = try await s.auth.accessToken()
        XCTAssertEqual(second, first, "the new token is good for an hour")
        XCTAssertEqual(refreshes, 1, "renewed once, not on every call")
        XCTAssertEqual(StubProtocol.seen.first?["refresh_token"] as? String, "fake-refresh-1")
        XCTAssertTrue(s.store.get("chatgpt-auth")?.contains("fake-refresh-2") == true, "the rotated refresh token is kept")
        assertOnlyStubbedEndpoints()
        XCTAssertEqual(appSignIn().0, before.0); XCTAssertEqual(appSignIn().1, before.1)
    }

    func testSimulatedTokenFarFromExpiryIsNotRenewed() async throws {
        let s = isolated(expiresIn: 3600)
        StubProtocol.respond = { body in body["grant_type"] != nil ? self.refreshed("new") : self.completed }
        let token = try await s.auth.accessToken()
        XCTAssertEqual(token, s.access)
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(StubProtocol.urls.isEmpty, "nothing was sent")
    }

    /// Two callers at once near expiry (say, the model list loading while a run starts): still one renewal.
    func testSimulatedNearExpiryRenewsOnceForTwoCallersAtOnce() async throws {
        let s = isolated(expiresIn: 300)
        StubProtocol.respond = { body in body["grant_type"] != nil ? self.refreshed("new") : self.completed }
        async let a = s.auth.accessToken()
        async let b = s.auth.accessToken()
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta, tb, "both callers get the same new token")
        XCTAssertNotEqual(ta, s.access)
        XCTAssertEqual(refreshes, 1, "a second renewal would spend the rotated refresh token twice")
        XCTAssertTrue(s.store.get("chatgpt-auth")?.contains(ta) == true, "the token they got is the one kept")
        let later = try await s.auth.accessToken()
        XCTAssertEqual(later, ta, "and after it, no renewal is pending")
        XCTAssertEqual(refreshes, 1)
        assertOnlyStubbedEndpoints()
    }

    /// A renewal that fails without a refusal (a server error, a dropped connection) leaves nothing pending: both
    /// waiters get the error, the session stays, and the next legitimate try renews afresh.
    func testSimulatedFailedRenewalClearsTheWaitAndTheNextTryRenews() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 300)
        StubProtocol.respond = { body in body["grant_type"] != nil ? (500, "application/json", "{}") : self.completed }
        let a = Task { try await s.auth.accessToken() }, b = Task { try await s.auth.accessToken() }
        let results = [await a.result, await b.result]
        for r in results {
            guard case .failure(let error) = r else { return XCTFail("expected the failed renewal for both waiters") }
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
        XCTAssertEqual(refreshes, 1, "one renewal for both")
        XCTAssertTrue(s.auth.signedIn, "a server error is not a refusal: still signed in, as before")

        StubProtocol.failure = URLError(.networkConnectionLost)
        do { _ = try await s.auth.accessToken(); XCTFail("expected the dropped connection") } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        StubProtocol.failure = nil
        XCTAssertEqual(refreshes, 2, "the next try after a failure renews again")
        XCTAssertTrue(s.auth.signedIn)

        StubProtocol.respond = { body in body["grant_type"] != nil ? self.refreshed("new") : self.completed }
        let token = try await s.auth.accessToken()
        XCTAssertNotEqual(token, s.access, "a legitimate try after the failures succeeds")
        XCTAssertEqual(refreshes, 3)
        XCTAssertTrue(s.store.get("chatgpt-auth")?.contains("fake-refresh-2") == true)
        assertOnlyStubbedEndpoints()
        XCTAssertEqual(appSignIn().0, before.0); XCTAssertEqual(appSignIn().1, before.1)
    }

    /// A refusal while two callers wait: one request, both told to sign in again, the session signed out once — the
    /// same handling as before.
    func testSimulatedRefusedRenewalForTwoCallersSignsOutOnce() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 300)
        StubProtocol.respond = { body in
            body["grant_type"] != nil ? (400, "application/json", #"{"error": "invalid_grant"}"#) : self.completed
        }
        let a = Task { try await s.auth.accessToken() }, b = Task { try await s.auth.accessToken() }
        let results = [await a.result, await b.result]
        for r in results {
            guard case .failure(let error) = r else { return XCTFail("expected sign in again for both") }
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(s.auth.signedIn)
        XCTAssertNil(s.store.get("chatgpt-auth"))
        do { _ = try await s.auth.accessToken(); XCTFail("signed out stays signed out") } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
        XCTAssertEqual(refreshes, 1, "nothing to renew once signed out")
        XCTAssertEqual(appSignIn().0, before.0); XCTAssertEqual(appSignIn().1, before.1)
        assertOnlyStubbedEndpoints()
    }

    func testSimulatedRefusedTokenRenewsOnceAndRetriesOnce() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 3600)
        var answered = 0
        StubProtocol.respond = { body in
            if body["grant_type"] != nil { return self.refreshed("new") }
            answered += 1
            return answered == 1 ? (401, "application/json", #"{"error": {"message": "expired"}}"#) : self.completed
        }
        let reply = try await s.client.chat(system: "s", text: "t")
        XCTAssertEqual(reply.text, "DO: wait")
        XCTAssertEqual(modelCalls, 2, "the request once more after the renewal")
        XCTAssertEqual(refreshes, 1)
        let auths = StubProtocol.headers.compactMap { $0["Authorization"] }.filter { $0.hasPrefix("Bearer ") && !$0.contains("fake-refresh") }
        XCTAssertEqual(auths.first, "Bearer " + s.access)
        XCTAssertNotEqual(auths.last, "Bearer " + s.access, "the retry carries the new token")
        assertOnlyStubbedEndpoints()
        XCTAssertEqual(appSignIn().0, before.0); XCTAssertEqual(appSignIn().1, before.1)
    }

    func testSimulatedTokenRefusedTwiceAsksToSignInAgainWithoutLooping() async throws {
        let s = isolated(expiresIn: 3600)
        StubProtocol.respond = { body in
            body["grant_type"] != nil ? self.refreshed("new") : (401, "application/json", #"{"error": {"message": "expired"}}"#)
        }
        do {
            _ = try await s.client.chat(system: "s", text: "t")
            XCTFail("expected sign in again")
        } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
        XCTAssertEqual(modelCalls, 2, "one retry, no loop")
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(s.auth.signedIn, "a refused access token alone does not sign out (the renewal itself worked)")
        assertOnlyStubbedEndpoints()
    }

    func testSimulatedRefusedRenewalSignsOutOnlyThatSession() async throws {
        let before = appSignIn()
        let s = isolated(expiresIn: 300)
        StubProtocol.respond = { body in
            body["grant_type"] != nil ? (400, "application/json", #"{"error": "invalid_grant"}"#) : self.completed
        }
        do {
            _ = try await s.auth.accessToken()
            XCTFail("expected sign in again")
        } catch {
            XCTAssertEqual((error as? LLMError)?.kind, "chatgpt_signed_out")
        }
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(s.auth.signedIn, "the simulated session is signed out")
        XCTAssertNil(s.store.get("chatgpt-auth"), "and its store cleared")
        XCTAssertEqual(appSignIn().0, before.0, "the app's own sign-in is untouched")
        XCTAssertEqual(appSignIn().1, before.1)
        assertOnlyStubbedEndpoints()
    }

    /// A /models reply keeps the listed models in priority order and names the client version; one in another
    /// shape says so instead of reading as "no models".
    func testTheModelListSaysWhenItCannotReadTheReply() async throws {
        let s = isolated(expiresIn: 3600)
        StubProtocol.respond = { _ in
            (200, "application/json", #"{"models": [{"slug": "b", "priority": 2}, {"slug": "hidden", "visibility": "hide"}, {"slug": "a", "priority": 1, "visibility": "list"}]}"#)
        }
        let list = try await s.auth.models()
        XCTAssertEqual(list, ["a", "b"])
        let query = URLComponents(url: try XCTUnwrap(StubProtocol.urls.last), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "client_version" }?.value, ChatGPTAuth.codexVersion)
        XCTAssertEqual(StubProtocol.urls.last?.absoluteString.components(separatedBy: "?")[0], ModelProvider.chatGPT.baseURL + "/models")

        for body in ["<html>busy</html>", #"{"data": []}"#] {
            StubProtocol.respond = { _ in (200, "application/json", body) }
            do {
                _ = try await s.auth.models()
                XCTFail("expected an error, not an empty list: \(body)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("unexpected body"), error.localizedDescription)
            }
        }
    }

    /// Each listed model's reasoning efforts, as the list names them (names, or objects with an "effort"), kept
    /// for the next launch.
    func testTheModelListGivesEachModelsReasoningEfforts() async throws {
        let s = isolated(expiresIn: 3600)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let auth = ChatGPTAuth(store: s.store, session: URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]; return c }()), defaults: defaults)
        StubProtocol.respond = { _ in (200, "application/json", #"""
            {"models": [
              {"slug": "fast", "priority": 1, "supported_reasoning_levels": [{"effort": "low", "description": "x"}, {"effort": "xhigh"}]},
              {"slug": "plain", "priority": 2, "supported_reasoning_levels": ["minimal", "high"]},
              {"slug": "none", "priority": 3}
            ]}
            """#) }
        let listed = try await auth.models()
        XCTAssertEqual(listed, ["fast", "plain", "none"])
        XCTAssertEqual(auth.efforts, ["fast": ["low", "xhigh"], "plain": ["minimal", "high"], "none": []])
        let relaunched = ChatGPTAuth(store: InMemoryKeychain(), session: .shared, defaults: defaults)
        XCTAssertEqual(relaunched.efforts["fast"], ["low", "xhigh"], "kept for the next launch")
    }

    /// The chosen effort goes out only when the model lists it, and Extra body's own "reasoning" wins.
    func testTheReasoningEffortIsSentOnlyWhenTheModelListsIt() throws {
        func effort(_ extra: [String: Any]) -> String? { (extra["reasoning"] as? [String: Any])?["effort"] as? String }
        XCTAssertEqual(effort(Settings.withReasoningEffort([:], effort: "xhigh", levels: ["low", "xhigh"])), "xhigh")
        XCTAssertNil(effort(Settings.withReasoningEffort([:], effort: "xhigh", levels: ["low", "high"])), "not offered by this model")
        XCTAssertNil(effort(Settings.withReasoningEffort([:], effort: "xhigh", levels: nil)), "the list not loaded")
        XCTAssertNil(effort(Settings.withReasoningEffort([:], effort: "", levels: ["low", "xhigh"])), "none chosen: the request's low")
        XCTAssertEqual(effort(Settings.withReasoningEffort([:], effort: "", levels: ["minimal", "high"])), "minimal",
                       "a model without low: its first, never an unlisted low")
        XCTAssertEqual(Settings.shownReasoningEffort("", levels: ["low", "xhigh"]), "low", "shown as what goes out")
        XCTAssertEqual(Settings.shownReasoningEffort("xhigh", levels: ["low", "xhigh"]), "xhigh")
        XCTAssertEqual(Settings.shownReasoningEffort("xhigh", levels: ["minimal", "high"]), "minimal", "another model's choice")
        XCTAssertEqual(effort(Settings.withReasoningEffort(["reasoning": ["effort": "medium"]], effort: "xhigh", levels: ["medium", "xhigh"])),
                       "medium", "Extra body wins")
        let body = LLMClient.responsesBody(model: "m", system: "s", text: "t", images: [],
                                           extra: Settings.withReasoningEffort([:], effort: "xhigh", levels: ["xhigh"]))
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")
        let plain = LLMClient.responsesBody(model: "m", system: "s", text: "t", images: [], extra: [:])
        XCTAssertEqual((plain["reasoning"] as? [String: Any])?["effort"] as? String, "low", "the default stays low")
    }

    /// The setting is kept, "" (the default) when never set.
    func testTheReasoningEffortSettingIsKept() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = Settings(defaults: defaults, info: [:])
        XCTAssertEqual(settings.reasoningEffort, "")
        settings.reasoningEffort = "xhigh"
        XCTAssertEqual(Settings(defaults: defaults, info: [:]).reasoningEffort, "xhigh")
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

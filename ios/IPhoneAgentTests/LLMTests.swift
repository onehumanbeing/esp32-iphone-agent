import XCTest
@testable import IPhoneAgent

/// API keys live in the Keychain, which an unsigned simulator build (CI: CODE_SIGNING_ALLOWED=NO) can't use.
let keychainWorks: Bool = {
    Keychain.set("probe", for: "keychain-probe")
    defer { Keychain.set("", for: "keychain-probe") }
    return Keychain.get("keychain-probe") == "probe"
}()

/// An in-memory endpoint: records request bodies and answers with `respond`.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ([String: Any]) -> (Int, String, String) = { _ in (200, "application/json", "{}") }
    nonisolated(unsafe) static var seen: [[String: Any]] = []
    nonisolated(unsafe) static var headers: [[String: String]] = []

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
        Self.headers.append(request.allHTTPHeaderFields ?? [:])
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
        for p in [ModelProvider.nvidia, .nebius, .hCompany, .zhipu] {
            XCTAssertEqual(ModelProvider.infer(baseURL: p.baseURL + "/", model: "x"), p)
        }
    }

    func testTestedModelsCarryValidParametersAndTwoRecommended() {
        let all = ModelProvider.allCases.flatMap { p in TestedModels.list(for: p).map { (p, $0) } }
        for (_, m) in all {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(m.extraBody.utf8)) as? [String: Any], m.id)
        }
        XCTAssertEqual(all.filter { $0.1.recommended }.map(\.1.id).sorted(), ["gemini-3.8-flash", "qwen3.8-flash"])
        XCTAssertEqual(ModelProvider.allCases.filter(\.recommended), [.gemini, .qwen])
    }

    func testRecommendedProviderPreselectsItsTestedModel() {
        let name = "tested-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.qwen)
        XCTAssertEqual(settings.model, "qwen3.8-flash")
        XCTAssertEqual(settings.extra["enable_thinking"] as? Bool, false)
        settings.selectProvider(.nvidia)  // no recommended model: pick one first
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.extraBody, "{}")
        settings.chooseModel("nvidia/nemotron-3.5-super-vl-120b-a12b")
        XCTAssertNotNil(settings.extra["chat_template_kwargs"])
        settings.extraBody = #"{"mine": 1}"#
        settings.chooseModel("some/listed-model")  // not tested: keeps the user's parameters
        XCTAssertEqual(settings.model, "some/listed-model")
        XCTAssertEqual(settings.extra["mine"] as? Int, 1)
    }

    func testModelCallStatsCarryNoContent() {
        var reply = ChatResult(text: "secret reply", firstToken: 1.234, total: 4.567)
        reply.usage = ["prompt_tokens": 1200, "completion_tokens": 80]
        reply.servedModel = "google/gemma-4-31b-it:free"
        let ok = ModelCall(role: "actor", model: "openrouter/free", reply: reply, error: nil, imageKB: 90).props
        XCTAssertEqual(ok["total_s"] as? Double, 4.57)
        XCTAssertEqual(ok["prompt_tokens"] as? Int, 1200)
        XCTAssertEqual(ok["served_model"] as? String, "google/gemma-4-31b-it:free")
        XCTAssertFalse(ok.values.contains { ($0 as? String)?.contains("secret") == true })
        let failed = ModelCall(role: "actor", model: "m", reply: nil, error: LLMError(message: "x", status: 429), imageKB: 0)
        XCTAssertEqual(failed.props["error"] as? String, "http_429")
        XCTAssertEqual(ModelCall(role: "a", model: "m", reply: nil, error: URLError(.timedOut), imageKB: 0).props["error"] as? String,
                       "timeout")
        var usage = ModelUsage()
        usage.add(ModelCall(role: "actor", model: "m", reply: reply, error: nil, imageKB: 0))
        usage.add(failed)
        XCTAssertEqual(usage.props["model_calls"] as? Int, 2)
        XCTAssertEqual(usage.props["model_failures"] as? Int, 1)
        XCTAssertEqual(usage.props["avg_total_s"] as? Double, 4.57)
        XCTAssertEqual(usage.props["actor_calls"] as? Int, 2)
        XCTAssertEqual(usage.props["prompt_tokens"] as? Int, 1200)
        XCTAssertEqual(usage.props["completion_tokens"] as? Int, 80)
        XCTAssertEqual(usage.props["usage_partial"] as? Bool, false)

        // Missing usage must not become 0, and must mark the run partial.
        let bare = ChatResult(text: "ok", firstToken: nil, total: 1.0)
        var partial = ModelUsage()
        partial.add(ModelCall(role: "planner", model: "m", reply: reply, error: nil, imageKB: 0))
        partial.add(ModelCall(role: "actor", model: "m", reply: bare, error: nil, imageKB: 42))
        XCTAssertEqual(partial.props["planner_calls"] as? Int, 1)
        XCTAssertEqual(partial.props["actor_calls"] as? Int, 1)
        XCTAssertEqual(partial.props["image_requests"] as? Int, 1)
        XCTAssertEqual(partial.props["prompt_tokens"] as? Int, 1200)
        XCTAssertEqual(partial.props["completion_tokens"] as? Int, 80)
        XCTAssertEqual(partial.props["usage_partial"] as? Bool, true)
        XCTAssertTrue(partial.summaryLine.contains("partial"))
        XCTAssertTrue(partial.summaryLine.contains("images 1"))

        // No call reported usage: no token fields at all, not zeros.
        var none = ModelUsage()
        none.add(ModelCall(role: "actor", model: "m", reply: bare, error: nil, imageKB: 42))
        XCTAssertNil(none.props["prompt_tokens"])
        XCTAssertNil(none.props["usage_partial"])
        XCTAssertFalse(none.summaryLine.contains("tokens"))
        XCTAssertEqual(none.tokens, 0)

        // A provider that sends only total_tokens still counts, as Run.load reads it.
        var total = bare
        total.usage = ["total_tokens": 900]
        var totals = ModelUsage()
        totals.add(ModelCall(role: "actor", model: "m", reply: total, error: nil, imageKB: 42))
        XCTAssertEqual(totals.tokens, 900)
        XCTAssertEqual(totals.props["total_tokens"] as? Int, 900)
        XCTAssertEqual(totals.props["usage_partial"] as? Bool, false)
    }

    func testProviderSwitchResetsModelOverridesAndOthersKeepsEditableConfig() async throws {
        let name = "provider-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.openRouter)
        XCTAssertEqual(settings.model, "openrouter/free")  // the default, no pick needed
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

    func testEachProviderKeepsItsConfigurationAndKey() throws {
        try XCTSkipUnless(keychainWorks, "no Keychain in an unsigned simulator build (CI)")
        let name = "profile-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let custom = "http://10.0.0.\(Int.random(in: 2...250)):8080/v1"
        defer {
            defaults.removePersistentDomain(forName: name)
            Keychain.set("", for: "llm-endpoint-" + ModelProvider.gemini.baseURL)
            Keychain.set("", for: "llm-endpoint-" + custom)
        }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.gemini)
        settings.apiKey = "gemini-key"
        settings.chooseModel("my-gemini")
        settings.plannerModel = "gemini-planner"
        settings.selectProvider(.others)
        settings.baseURL = custom
        settings.model = "local-model"
        settings.extraBody = #"{"local": true}"#
        XCTAssertTrue(settings.isConfigured(.gemini))
        XCTAssertFalse(settings.isConfigured(.deepSeek))
        settings.selectProvider(.gemini)
        XCTAssertEqual(settings.model, "my-gemini")
        XCTAssertEqual(settings.plannerModel, "gemini-planner")
        XCTAssertEqual(settings.apiKey, "gemini-key")
        XCTAssertTrue(settings.isConfigured(.others))
        settings.selectProvider(.others)
        XCTAssertEqual(settings.baseURL, custom)
        XCTAssertEqual(settings.model, "local-model")
        XCTAssertEqual(settings.extra["local"] as? Bool, true)
        // Persisted: a fresh Settings (next launch) restores the same way.
        let reopened = Settings(defaults: defaults, info: [:])
        reopened.selectProvider(.gemini)
        XCTAssertEqual(reopened.model, "my-gemini")
        XCTAssertEqual(reopened.apiKey, "gemini-key")
    }

    func testClearingKeyDoesNotResurrectIt() throws {
        try XCTSkipUnless(keychainWorks, "no Keychain in an unsigned simulator build (CI)")
        let name = "clear-key-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let gemini = ModelProvider.gemini.baseURL
        defer {
            defaults.removePersistentDomain(forName: name)
            Keychain.set("", for: "llm-endpoint-" + gemini)
        }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectProvider(.gemini)
        settings.apiKey = "gemini-key"
        settings.selectProvider(.others)   // saveCurrent() stores the key under the gemini endpoint
        settings.selectProvider(.gemini)
        XCTAssertEqual(settings.apiKey, "gemini-key")  // the key really was persisted

        settings.apiKey = ""                // the user clears it
        settings.selectProvider(.others)   // saveCurrent() must drop the stored copy
        settings.selectProvider(.gemini)
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertFalse(settings.isConfigured(.gemini))
    }

    func testSeveralCustomEndpointsAreKept() {
        let name = "custom-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        settings.selectCustom(nil)
        settings.baseURL = "http://10.0.0.5:8080/v1"
        settings.model = "first"
        settings.selectCustom(nil)  // add another
        XCTAssertEqual(settings.baseURL, "")
        settings.baseURL = "https://example.com/v1"
        settings.model = "second"
        settings.selectProvider(.qwen)
        XCTAssertEqual(settings.customEndpoints.map(\.model), ["first", "second"])
        XCTAssertEqual(settings.customEndpoints.first?.title, "10.0.0.5:8080")
        settings.selectCustom(settings.customEndpoints[0].id)
        XCTAssertEqual(settings.baseURL, "http://10.0.0.5:8080/v1")
        XCTAssertEqual(settings.model, "first")
        settings.deleteCustom(settings.customEndpoints[0].id)  // in use: kept
        XCTAssertEqual(settings.customEndpoints.count, 2)
        settings.deleteCustom(settings.customEndpoints[1].id)
        XCTAssertEqual(Settings(defaults: defaults, info: [:]).customEndpoints.map(\.model), ["first"])
    }

    func testLegacySingleCustomProfileMigrates() {
        let name = "legacy-custom-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["baseURL": "http://10.0.0.9/v1", "model": "m"], forKey: "modelProfile.others")
        let settings = Settings(defaults: defaults, info: [:])
        XCTAssertEqual(settings.customEndpoints.map(\.baseURL), ["http://10.0.0.9/v1"])
        XCTAssertTrue(settings.isConfigured(.others))
    }

    #if DEBUG
    func testLaunchModelConfigurationParsesExplicitParametersOnly() throws {
        XCTAssertNil(try ModelLaunchConfiguration.parse(["app", "-test-model"], environment: ["IA_LLM_API_KEY": "unused"]))
        let parsed = try XCTUnwrap(ModelLaunchConfiguration.parse(
            ["app", "-llm-model", " vision/model ", "-llm-base-url", " http://model-server.local:8000/v1/ ", "-test-model"],
            environment: ["IA_LLM_API_KEY": " test-server-key "]))
        XCTAssertEqual(parsed.baseURL, "http://model-server.local:8000/v1/")
        XCTAssertEqual(parsed.model, "vision/model")
        XCTAssertEqual(parsed.apiKey, "test-server-key")
        let noKey = try XCTUnwrap(ModelLaunchConfiguration.parse(
            ["app", "-llm-base-url", "https://model-server.local/v1", "-llm-model", "vision"]))
        XCTAssertEqual(noKey.apiKey, "")
        XCTAssertEqual(noKey.extraBody, "{}")
    }

    func testLaunchModelConfigurationParsesOptionalProviderOptionsAsJSON() throws {
        let parsed = try XCTUnwrap(ModelLaunchConfiguration.parse([
            "app", "-llm-base-url", "https://model-server.local/v1", "-llm-model", "vision",
            "-llm-extra-body", " { \"top_p\": 0.8, \"chat_template_kwargs\": { \"enable_thinking\": false } } "
        ]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parsed.extraBody.utf8)) as? [String: Any])
        XCTAssertEqual((object["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(object["top_p"] as? Double), 0.8, accuracy: 0.000001)
    }

    func testLaunchModelConfigurationRejectsMissingDuplicateOrNonObjectExtraBody() {
        let base = ["app", "-llm-base-url", "https://model-server.local/v1", "-llm-model", "vision"]
        for args in [base + ["-llm-extra-body"], base + ["-llm-extra-body", " "],
                     base + ["-llm-extra-body", "{}", "-llm-extra-body", "{}"],
                     ["app", "-llm-extra-body", "{}"]] {
            XCTAssertThrowsError(try ModelLaunchConfiguration.parse(args))
        }
        for body in ["{", "[]", "true", "null", "42", "\"string\""] {
            XCTAssertThrowsError(try ModelLaunchConfiguration.parse(base + ["-llm-extra-body", body]))
        }
    }

    func testLaunchModelConfigurationRejectsMissingDuplicateOrUnsafeInput() {
        let base = ["app", "-llm-base-url", "http://model-server.local:8000/v1", "-llm-model", "vision"]
        for args in [
            ["app", "-llm-base-url", "http://model-server.local/v1"],
            ["app", "-llm-model", "vision"],
            ["app", "-llm-base-url", "-llm-model", "vision"],
            Array(base.dropLast()),
            Array(base.dropLast()) + [" "],
            base + ["-llm-model", "other"],
            base + ["-llm-base-url", "http://other-server.local/v1"]
        ] {
            XCTAssertThrowsError(try ModelLaunchConfiguration.parse(args))
        }
        for endpoint in ["ftp://model-server.local/v1", "/v1", "http:///v1", "http://", "http://bad host/v1",
                         "http://user@model-server.local/v1", "http://user:password@model-server.local/v1",
                         "http://model-server.local/v1?key=secret", "http://model-server.local/v1#fragment"] {
            XCTAssertThrowsError(try ModelLaunchConfiguration.parse(
                ["app", "-llm-base-url", endpoint, "-llm-model", "vision"]))
        }
    }

    func testLaunchModelImportClearsSameHostCredentialsAndOverridesAndPersists() throws {
        let name = "launch-model-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("others", forKey: "modelProvider")
        defaults.set("http://model-server.local:8000/v1", forKey: "baseURL")
        defaults.set("stale-auto", forKey: "autoModel")
        Keychain.set("old-cloud-api-key", for: "llm-api-key")
        let settings = Settings(defaults: defaults, info: [:])
        defer { settings.apiKey = "" }
        XCTAssertEqual(settings.autoModel, "stale-auto")
        settings.model = "vision"
        settings.plannerModel = "old-planner"
        settings.actorModel = "old-actor"
        settings.tokenParam = "max_completion_tokens"
        settings.extraBody = "{\"reasoning_effort\":\"high\"}"
        let revision = settings.configurationRevision
        XCTAssertTrue(try settings.importLaunchConfiguration(arguments:
            ["app", "-llm-base-url", settings.baseURL, "-llm-model", "vision"]))
        XCTAssertEqual(settings.provider, .others)
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertEqual(settings.plannerModel, "")
        XCTAssertEqual(settings.actorModel, "")
        XCTAssertEqual(settings.tokenParam, "auto")
        XCTAssertEqual(settings.extraBody, "{}")
        XCTAssertEqual(settings.autoModel, "")
        XCTAssertTrue(settings.models.isEmpty)
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        let reloaded = Settings(defaults: defaults, info: [:])
        XCTAssertEqual(reloaded.provider, .others)
        XCTAssertEqual(reloaded.baseURL, "http://model-server.local:8000/v1")
        XCTAssertEqual(reloaded.currentModel, "vision")
        XCTAssertEqual(reloaded.apiKey, "")
        XCTAssertEqual(reloaded.plannerModel, "")
        XCTAssertEqual(reloaded.actorModel, "")
        XCTAssertEqual(reloaded.tokenParam, "auto")
        XCTAssertEqual(reloaded.extraBody, "{}")
        XCTAssertEqual(defaults.string(forKey: "modelProvider"), "others")
    }

    func testLaunchModelImportUsesOnlyExplicitEnvironmentCredential() throws {
        try XCTSkipUnless(keychainWorks, "no Keychain in an unsigned simulator build (CI)")
        let name = "launch-model-key-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        defer { settings.apiKey = "" }
        settings.selectProvider(.openRouter)
        settings.apiKey = "old-cloud-api-key"
        XCTAssertTrue(try settings.importLaunchConfiguration(arguments:
            ["app", "-llm-base-url", "http://model-server.local:8000/v1", "-llm-model", "vision"],
            environment: ["IA_LLM_API_KEY": "new-local-server-key"]))
        XCTAssertEqual(settings.provider, .others)
        XCTAssertEqual(settings.apiKey, "new-local-server-key")
        XCTAssertEqual(Settings(defaults: defaults, info: [:]).apiKey, "new-local-server-key")
    }

    func testLaunchModelImportAppliesAndPersistsExplicitProviderOptions() throws {
        let name = "launch-model-options-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        defer { settings.apiKey = "" }
        settings.extraBody = "{\"old_provider_option\":true}"
        XCTAssertTrue(try settings.importLaunchConfiguration(arguments: [
            "app", "-llm-base-url", "https://model-server.local/v1", "-llm-model", "vision",
            "-llm-extra-body", "{\"chat_template_kwargs\":{\"enable_thinking\":false}}"
        ]))
        let options = try XCTUnwrap(settings.extra["chat_template_kwargs"] as? [String: Any])
        XCTAssertEqual(options["enable_thinking"] as? Bool, false)
        XCTAssertNil(settings.extra["old_provider_option"])
        let reloaded = Settings(defaults: defaults, info: [:])
        XCTAssertEqual(reloaded.extraBody, settings.extraBody)
        XCTAssertEqual((reloaded.extra["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
    }

    func testInvalidLaunchModelImportLeavesConfigurationUnchanged() throws {
        let name = "launch-model-invalid-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults, info: [:])
        defer { settings.apiKey = "" }
        settings.selectProvider(.openRouter)
        settings.apiKey = "existing-test-key"
        settings.plannerModel = "existing-planner"
        settings.actorModel = "existing-actor"
        settings.extraBody = "{\"existing_option\":true}"
        let revision = settings.configurationRevision
        let saved = defaults.persistentDomain(forName: name) as NSDictionary?
        XCTAssertThrowsError(try settings.importLaunchConfiguration(arguments:
            ["app", "-llm-base-url", "http://user@model-server.local/v1", "-llm-model", "vision"],
            environment: ["IA_LLM_API_KEY": "ignored-test-key"]))
        XCTAssertThrowsError(try settings.importLaunchConfiguration(arguments: ["app", "-llm-model", "vision"]))
        let base = ["app", "-llm-base-url", "https://model-server.local/v1", "-llm-model", "vision"]
        for args in [base + ["-llm-extra-body"],
                     base + ["-llm-extra-body", "{}", "-llm-extra-body", "{}"],
                     base + ["-llm-extra-body", "[]"],
                     base + ["-llm-extra-body", "{"],
                     ["app", "-llm-extra-body", "{}"]] {
            XCTAssertThrowsError(try settings.importLaunchConfiguration(arguments: args,
                environment: ["IA_LLM_API_KEY": "ignored-test-key"]))
        }
        XCTAssertFalse(try settings.importLaunchConfiguration(arguments: ["app", "-test-model"]))
        XCTAssertEqual(settings.provider, .openRouter)
        XCTAssertEqual(settings.baseURL, ModelProvider.openRouter.baseURL)
        XCTAssertEqual(settings.apiKey, "existing-test-key")
        XCTAssertEqual(settings.plannerModel, "existing-planner")
        XCTAssertEqual(settings.actorModel, "existing-actor")
        XCTAssertEqual(settings.extraBody, "{\"existing_option\":true}")
        XCTAssertEqual(settings.configurationRevision, revision)
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, saved)
    }
    #endif

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

    func client(_ model: String, extra: [String: Any] = [:], tokenParam: String = "auto",
                baseURL: String = "http://test/v1/") -> LLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return LLMClient(baseURL: baseURL, model: model, extra: extra, tokenParam: tokenParam,
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

    func testBothRefusedParametersAreDroppedTemperatureFirst() async throws {
        let llm = client("gpt")
        StubProtocol.seen = []
        StubProtocol.respond = { body in
            if body["temperature"] != nil {
                return (400, "application/json", "{\"error\": {\"message\": \"Unsupported value: 'temperature'.\"}}")
            }
            if body["max_tokens"] != nil {
                return (400, "application/json", "{\"error\": {\"message\": \"Use 'max_completion_tokens' instead.\"}}")
            }
            return (200, "application/json", "{\"choices\": [{\"message\": {\"content\": \"DO: wait\"}}]}")
        }
        let reply = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(reply.text, "DO: wait")
        XCTAssertEqual(StubProtocol.seen.count, 3)
    }

    func testExplicitTokenParamIsUsedDirectly() async throws {
        let llm = client("gpt", tokenParam: "max_completion_tokens")
        fakeServer(wants: "max_completion_tokens")
        _ = try await llm.chat(system: "sys", text: "hi", image: nil, maxTokens: 600, temperature: 0)
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testCustomOutputBudgetSurvivesTokenParameterNegotiation() async throws {
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"max_tokens":4096}"#.utf8)) as? [String: Any])
        let llm = client("custom", extra: extra)
        fakeServer(wants: "max_completion_tokens")
        _ = try await llm.chat(system: "sys", text: "first", maxTokens: 600)
        _ = try await llm.chat(system: "sys", text: "next", maxTokens: 200)
        XCTAssertEqual(StubProtocol.seen.map { $0["max_tokens"] as? Int }, [4096, nil, nil])
        XCTAssertEqual(StubProtocol.seen.map { $0["max_completion_tokens"] as? Int }, [nil, 4096, 4096])
    }

    func testCustomCompletionBudgetUsesSelectedParameterName() async throws {
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"max_completion_tokens":1}"#.utf8)) as? [String: Any])
        let llm = client("custom", extra: extra, tokenParam: "max_tokens")
        fakeServer(wants: "max_tokens")
        _ = try await llm.chat(system: "sys", text: "first", maxTokens: 600)
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual(StubProtocol.seen.first?["max_tokens"] as? Int, 1)
        XCTAssertNil(StubProtocol.seen.first?["max_completion_tokens"])
    }

    func testInvalidOrConflictingCustomBudgetsSendNoRequest() async throws {
        let invalidBudgets: [[String: Any]] = [
            ["max_tokens": 0], ["max_tokens": -1], ["max_tokens": true],
            ["max_tokens": 1.5], ["max_tokens": "100"], ["max_tokens": NSNull()],
            ["max_completion_tokens": false], ["max_completion_tokens": -1],
            ["max_completion_tokens": []], ["max_completion_tokens": [:]],
            ["max_tokens": 1024, "max_completion_tokens": 2048],
        ]
        for configured in invalidBudgets {
            // 与设置页共用 JSON 解码形态，覆盖 NSNumber 与布尔值的桥接差异。
            let data = try JSONSerialization.data(withJSONObject: configured)
            let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            fakeServer(wants: "max_tokens")
            do {
                _ = try await client("custom", extra: extra).chat(system: "sys", text: "first")
                XCTFail("应拒绝无效的输出上限")
            } catch {
                XCTAssertTrue(error is LLMError)
            }
            XCTAssertTrue(StubProtocol.seen.isEmpty)
        }
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
        XCTAssertNil(body["thinking"])
    }

    func testDeepSeekRequestsDisableThinkingUnlessExtraBodySetsIt() async throws {
        fakeServer(wants: "max_tokens")
        _ = try await client("deepseek-flash", baseURL: "https://api.deepseek.com").chat(system: "sys", text: "hi")
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertEqual((StubProtocol.seen[0]["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(StubProtocol.seen[0]["stream"] as? Bool, true)

        let json = #"{"thinking":{"type":"enabled"},"reasoning_effort":"low"}"#
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        fakeServer(wants: "max_tokens")
        _ = try await client("deepseek-flash", extra: extra, baseURL: "https://api.deepseek.com")
            .chat(system: "sys", text: "hi")
        XCTAssertEqual((StubProtocol.seen[0]["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(StubProtocol.seen[0]["reasoning_effort"] as? String, "low")

        fakeServer(wants: "max_tokens")
        _ = try await client("gpt", baseURL: "https://api.openai.com/v1").chat(system: "sys", text: "hi")
        XCTAssertNil(StubProtocol.seen[0]["thinking"])
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

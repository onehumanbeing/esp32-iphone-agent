import XCTest
@testable import IPhoneAgent

/// The free line stays out of builds without IA_TRIAL_ORIGIN, and only adds headers to model requests.
@MainActor final class TrialTests: XCTestCase {
    func testOpenSourceBuildHasNoFreeLine() {
        XCTAssertFalse(Trial.available)
        XCTAssertFalse(Trial.isTrial("https://api.openai.com/v1"))
        XCTAssertNotEqual(ModelProvider.infer(baseURL: "", model: ""), .handsyTrial)
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!, info: [:])
        XCTAssertFalse(settings.isConfigured(.handsyTrial))
    }

    func testModelRequestsNeedARun() {
        XCTAssertThrowsError(try Trial.shared.headers())  // tests and intent analysis never use the free line
    }

    func testRequestHeadersAreAddedAndAFailureSendsNothing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.headers = []
        StubProtocol.respond = { _ in (200, "application/json", "{\"choices\": [{\"message\": {\"content\": \"DO: wait\"}}]}") }
        let llm = LLMClient(baseURL: "http://test/v1", model: "m", session: URLSession(configuration: config),
                            headers: { ["X-Run-ID": "run-1"] })
        _ = try await llm.chat(system: "s", text: "t")
        XCTAssertEqual(StubProtocol.headers.last?["X-Run-ID"], "run-1")

        let refused = LLMClient(baseURL: "http://test/v1", model: "m", session: URLSession(configuration: config),
                                headers: { throw TrialError.runsOnly })
        do { _ = try await refused.chat(system: "s", text: "t"); XCTFail("sent without a run") } catch {}
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }
}

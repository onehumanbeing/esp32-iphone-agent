import XCTest
@testable import IPhoneAgent

/// The model picker's list (GET /models). #172: an endpoint whose list never came was asked again every time the
/// picker showed, so it sat on "Loading models…"; now it is asked once per endpoint and key, Refresh asks again.
@MainActor final class ModelListTests: XCTestCase {
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.seen = []
        StubProtocol.headers = []
        let defaults = UserDefaults(suiteName: "ModelListTests-\(UUID().uuidString)")!
        settings = Settings(defaults: defaults, info: [:], keychain: InMemoryKeychain())
        settings.baseURL = "https://models.example.test/v1"
        settings.apiKey = "sk-test"
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.respond = { _ in (200, "application/json", "{}") }
        super.tearDown()
    }

    func testAFailedListIsAskedOncePerSetupAndRefreshAsksAgain() async {
        StubProtocol.respond = { _ in (404, "application/json", #"{"message":"not found"}"#) }
        await settings.loadModelsIfNeeded()
        await settings.loadModelsIfNeeded()  // the picker shown again
        XCTAssertEqual(StubProtocol.seen.count, 1)
        XCTAssertFalse(settings.loadingModels)
        XCTAssertNotNil(settings.modelsError)
        await settings.loadModels()  // Refresh
        XCTAssertEqual(StubProtocol.seen.count, 2)
        settings.apiKey = "sk-other"  // a new key: asked again on its own
        await settings.loadModelsIfNeeded()
        XCTAssertEqual(StubProtocol.seen.count, 3)
    }

    func testAnEmptyListSaysWhereToEnterTheModel() async {
        StubProtocol.respond = { _ in (200, "application/json", #"{"object":"list","data":[]}"#) }
        await settings.loadModelsIfNeeded()
        XCTAssertEqual(settings.models, [])
        XCTAssertTrue(settings.modelsError?.contains("Custom model") == true)
    }

    func testListsOfPlainIDsAndBareArraysAreRead() async {
        StubProtocol.respond = { _ in (200, "application/json", #"{"data":["qwen3-vl-plus","qwen3.5-plus"]}"#) }
        await settings.loadModels()
        XCTAssertEqual(settings.models, ["qwen3-vl-plus", "qwen3.5-plus"])
        StubProtocol.respond = { _ in (200, "application/json", #"[{"model":"a"},{"id":"b"}]"#) }
        await settings.loadModels()
        XCTAssertEqual(settings.models, ["a", "b"])
    }
}

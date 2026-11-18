import XCTest
@testable import IPhoneAgent

final class FilesLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    func testDeveloperFoldersHideUntilTurnedOn() {
        for name in ["traces", "threads", "recordings", "intent-frames", "developer", "firmware", "harness-fw-20261106-1",
                     "treebench540", "remote-debug-log.json"] {
            XCTAssertFalse(FilesLayout.isVisible(name, developer: false), name)
            XCTAssertTrue(FilesLayout.isVisible(name, developer: true), name)
        }
        for name in ["memory", "logs", "my notes", "duolingo.intent", "memory/results", "traces-of-mine/x"] {
            XCTAssertTrue(FilesLayout.isVisible(name, developer: false), name)
        }
    }

    func testAppFoldersCannotBeRenamedOrDeleted() {
        for path in ["memory", "memory/MEMORY.md", "logs"] {
            XCTAssertTrue(FilesLayout.isSystem(path), path)
            XCTAssertFalse(FileSandbox.canChange(path, developer: true), path)
        }
        XCTAssertTrue(FileSandbox.canChange("orders", developer: false), "a result folder is the user's")
        XCTAssertFalse(FileSandbox.canChange("traces/20261116-101010/steps.jsonl", developer: false), "run evidence")
        XCTAssertTrue(FileSandbox.canChange("traces/20261116-101010/steps.jsonl", developer: true))
    }

    func testMigrationMovesLogsAndHarnessFolders() throws {
        try touch("debug.log", "old")
        try touch("debug.recent.log")
        try touch("crash-trace.txt")
        try touch("diagnostics/1.json")
        try touch("logs/diagnostics/2.json")
        try touch("logs/debug.log", "new")
        try touch("harness-inbox/a.json")
        try touch("harness-fw-20261106-143453/firmware.json")
        try touch("memory/MEMORY.md")
        try touch("notes.md")

        FilesLayout.migrate(root: root)

        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("logs/debug.log"), encoding: .utf8), "new",
                       "a log already in logs/ is the newer one")
        for path in ["logs/debug.recent.log", "logs/crash-trace.txt", "logs/diagnostics/1.json", "logs/diagnostics/2.json",
                     "developer/harness-inbox/a.json", "developer/harness-fw-20261106-143453/firmware.json",
                     "memory/MEMORY.md", "notes.md"] {
            XCTAssertTrue(exists(path), path)
        }
        for path in ["debug.log", "debug.recent.log", "crash-trace.txt", "diagnostics", "harness-inbox", "harness-fw-20261106-143453"] {
            XCTAssertFalse(exists(path), path)
        }
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        FilesLayout.migrate(root: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("memory/MEMORY.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("memory/results").path), "results live at the top")
        FilesLayout.migrate(root: root)  // again: nothing to do, nothing lost
        XCTAssertTrue(exists("logs/diagnostics/1.json"))
    }

    func testUserMakesRenamesAndDeletes() throws {
        let box = FileSandbox(root: root)
        try touch("memory/MEMORY.md")
        XCTAssertEqual(box.makeFolder(in: ".", named: "Trips").error, nil)
        XCTAssertEqual(try box.makeFolder(in: ".", named: "Trips").get(), "Trips 2")
        XCTAssertEqual(try box.makeNote(in: "Trips", named: "Tokyo").get(), "Trips/Tokyo.md")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Trips/Tokyo.md"), encoding: .utf8), "# Tokyo\n")
        XCTAssertNil(box.rename("Trips/Tokyo.md", to: "Kyoto.md", developer: false))
        XCTAssertTrue(exists("Trips/Kyoto.md"))
        XCTAssertNil(box.remove("Trips 2", developer: false))
        XCTAssertFalse(exists("Trips 2"))

        XCTAssertEqual(box.makeFolder(in: ".", named: "../out").error, .badName)
        XCTAssertEqual(box.makeFolder(in: ".", named: ".hidden").error, .badName)
        XCTAssertEqual(box.rename("Trips/Kyoto.md", to: "a/b", developer: false), .badName)
        XCTAssertEqual(box.remove("memory/MEMORY.md", developer: true), .appFile)
        XCTAssertEqual(box.rename("memory", to: "mine", developer: true), .appFile)
        XCTAssertTrue(exists("memory/MEMORY.md"))
        try touch("Trips/Osaka.md")
        XCTAssertEqual(box.rename("Trips/Kyoto.md", to: "Osaka.md", developer: false), .taken)
    }

    func testIntentFilesOldAndNewExtension() {
        XCTAssertEqual(IntentArchive.fileExtension, "intent")
        XCTAssertTrue(IntentArchive.isIntentFile("Alarm.intent"))
        XCTAssertTrue(IntentArchive.isIntentFile("duolingo-streak.esp32intent"))
        XCTAssertFalse(IntentArchive.isIntentFile("notes.md"))
        let entry = AgentFileEntry(name: "a.esp32intent", isDirectory: false, bytes: 10, relative: "a.esp32intent")
        XCTAssertTrue(entry.intent)
        XCTAssertTrue(AgentFileEntry(name: "MEMORY.md", isDirectory: false, bytes: 1, relative: "memory/MEMORY.md").memory)
    }

    /// Files search: a folder by name, a file inside by name, and a README line by its text (2026-11-19).
    func testSearchFindsNamesAndTheTextOfNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("高德打车订单-11月9日至18日")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "| 11-12 | ¥35.20 | 望京 | 国贸 |\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Data([0xff]).write(to: folder.appendingPathComponent("01-望京.jpg"))
        XCTAssertEqual(FileSearch.run("高德", root: root, developer: false).map(\.relative), ["高德打车订单-11月9日至18日"])
        XCTAssertEqual(FileSearch.run("望京", root: root, developer: false).map(\.relative),
                       ["高德打车订单-11月9日至18日/01-望京.jpg", "高德打车订单-11月9日至18日/README.md"])
        XCTAssertEqual(FileSearch.run("国贸 35.20", root: root, developer: false).first?.line, "| 11-12 | ¥35.20 | 望京 | 国贸 |")
        XCTAssertTrue(FileSearch.run("上海", root: root, developer: false).isEmpty)
    }
}

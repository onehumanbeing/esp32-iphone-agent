import UIKit
import XCTest
@testable import IPhoneAgent

final class MemoryFilesTests: XCTestCase {
    private var root: URL!
    private var files: MemoryFiles!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("memfiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = MemoryFiles(box: FileSandbox(root: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ args: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        return files.run(String(decoding: data, as: UTF8.self))
    }

    func testCreateViewEditInsertRenameDelete() throws {
        XCTAssertTrue(try run(["command": "create", "path": "/memories/results/orders/README.md",
                               "file_text": "# Orders\n| total |\n| 12 |"]).hasPrefix("ok: created"))
        XCTAssertTrue(try run(["command": "view", "path": ""]).contains("orders/\n  README.md"))
        let view = try run(["command": "view", "path": "results/orders/README.md", "view_range": [2, -1]])
        XCTAssertTrue(view.contains("     2\t| total |"))
        XCTAssertFalse(view.contains("# Orders"))

        XCTAssertTrue(try run(["command": "str_replace", "path": "results/orders/README.md",
                               "old_str": "| 12 |", "new_str": "| 12 |\n| 30 |"]).hasPrefix("ok: edited"))
        XCTAssertTrue(try run(["command": "insert", "path": "results/orders/README.md", "insert_line": 1,
                               "insert_text": "Two orders."]).hasPrefix("ok: edited"))
        let body = try String(contentsOf: root.appendingPathComponent("orders/README.md"), encoding: .utf8)
        XCTAssertEqual(body, "# Orders\nTwo orders.\n| total |\n| 12 |\n| 30 |")

        XCTAssertTrue(try run(["command": "rename", "old_path": "results/orders",
                               "new_path": "results/meituan"]).hasPrefix("ok: renamed"))
        XCTAssertTrue(try run(["command": "delete", "path": "results/meituan"]).hasPrefix("ok: deleted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("meituan").path))
    }

    func testMemoryFileAndPathsOutsideAreRefused() throws {
        try Data("- a fact".utf8).write(to: root.appendingPathComponent("MEMORY.md"))
        for args: [String: Any] in [
            ["command": "create", "path": "MEMORY.md", "file_text": "x"],
            ["command": "str_replace", "path": "/memories/memory.md", "old_str": "fact", "new_str": "x"],
            ["command": "delete", "path": "MEMORY.md"],
            ["command": "delete", "path": "./MEMORY.md"],
            ["command": "create", "path": "/MEMORY.md", "file_text": "x"],
            ["command": "rename", "old_path": "/memories/./Memory.md", "new_path": "old.md"],
            ["command": "rename", "old_path": "MEMORY.md", "new_path": "old.md"],
            ["command": "create", "path": "../escape.md", "file_text": "x"],
            ["command": "create", "path": "run.sh", "file_text": "x"],
            ["command": "delete", "path": "/"],
        ] {
            XCTAssertTrue(try run(args).hasPrefix("refused"), "\(args)")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("MEMORY.md"), encoding: .utf8), "- a fact")
        XCTAssertTrue(files.run("not json").hasPrefix("refused"))
        XCTAssertTrue(files.run("} {").hasPrefix("refused"))
        XCTAssertTrue(files.run(#"`{"command":"view","path":"/memories"}`"#).hasPrefix("ok: ./"))
        XCTAssertTrue(try run(["command": "view", "path": "MEMORY.md"]).hasPrefix("ok"), "reading it is fine")
    }

    func testSnapSavesTheScreenOrABoxOfIt() throws {
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }.jpegData(compressionQuality: 0.8)

        XCTAssertTrue(files.snap(frame, "results/list/page-01").hasPrefix("ok: saved list/page-01.jpg"))
        XCTAssertTrue(files.snap(frame, "results/list/total.jpg 0 0 500 250").hasPrefix("ok: saved"))
        XCTAssertTrue(files.snap(frame, "orders/page-01.jpg").hasPrefix("ok: saved orders/page-01.jpg"))  // where the goal said
        let full = try XCTUnwrap(UIImage(contentsOfFile: root.appendingPathComponent("list/page-01.jpg").path))
        let box = try XCTUnwrap(UIImage(contentsOfFile: root.appendingPathComponent("list/total.jpg").path))
        XCTAssertLessThan(box.size.width * box.scale, full.size.width * full.scale)

        XCTAssertTrue(files.snap(nil, "a.jpg").hasPrefix("refused"))
        XCTAssertTrue(files.snap(frame, "a.png").hasPrefix("refused"))
        XCTAssertTrue(files.snap(frame, "a.jpg 500 500 400 600").hasPrefix("refused"))
        XCTAssertTrue(files.snap(frame, "../a.jpg").hasPrefix("refused"))
    }

    func testAnEarlierRunsFilesAreNotOverwritten() throws {
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }.jpegData(compressionQuality: 0.5)
        XCTAssertTrue(try run(["command": "create", "path": "results/orders/README.md", "file_text": "# Orders"]).hasPrefix("ok"))
        XCTAssertTrue(files.snap(frame, "results/orders/page-01.jpg").hasPrefix("ok"))
        let later = MemoryFiles(box: files.box, since: Date().addingTimeInterval(5))  // the next run
        let again = later.run(##"{"command":"create","path":"results/orders/README.md","file_text":"# New"}"##)
        XCTAssertTrue(again.hasPrefix("refused: orders/README.md is from an earlier run"), again)
        XCTAssertTrue(again.contains("orders-" + MemoryFiles.day(Date())), again)
        XCTAssertTrue(later.snap(frame, "results/orders/page-01.jpg").hasPrefix("refused"))
        XCTAssertTrue(later.snap(frame, "results/orders/page-02.jpg").hasPrefix("ok"))  // adding to it
        let edit = later.run(##"{"command":"str_replace","path":"results/orders/README.md","old_str":"# Orders","new_str":"# All orders"}"##)
        XCTAssertTrue(edit.hasPrefix("ok"), edit)
        // this run's own files: written again as before
        XCTAssertTrue(try run(["command": "create", "path": "results/orders/README.md", "file_text": "# Again"]).hasPrefix("ok"))
    }

    func testAReadmeSaysWhereItsImagesAre() throws {
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }.jpegData(compressionQuality: 0.5)
        XCTAssertTrue(files.snap(frame, "shots/page-01.jpg").hasPrefix("ok"))
        let made = try run(["command": "create", "path": "美团订单/README.md",
                            "file_text": "# 订单\n![](page-01.jpg)\n![](page-02.jpg)\n![](https://x.test/a.png)"])
        XCTAssertTrue(made.contains("page-01.jpg (it is at shots/page-01.jpg: rename it into 美团订单)"), made)
        XCTAssertTrue(made.contains("page-02.jpg (not saved)"), made)
        XCTAssertFalse(made.contains("x.test"), made)
        XCTAssertTrue(try run(["command": "rename", "old_path": "shots/page-01.jpg", "new_path": "美团订单/page-01.jpg"]).hasPrefix("ok"))
        let fine = try run(["command": "create", "path": "美团订单/README.md", "file_text": "![](page-01.jpg)"])
        XCTAssertFalse(fine.contains("missing"), fine)
    }

    func testResultsListNewestFirstWithTitles() throws {
        XCTAssertEqual(files.results(), "")
        _ = try run(["command": "create", "path": "results/a/README.md", "file_text": "# 美团外卖订单\nrows"])
        _ = try run(["command": "create", "path": "results/b/notes.txt", "file_text": "x"])
        let list = files.results().components(separatedBy: "\n")
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains { $0.hasPrefix("- a/ (") && $0.hasSuffix(") — 美团外卖订单") }, list.joined())
        XCTAssertTrue(list.contains { $0.hasPrefix("- b/ (") && $0.hasSuffix(")") }, list.joined())
    }

    func testRelativeStripsTheMemoryToolPrefix() {
        XCTAssertEqual(MemoryFiles.relative("/memories/results/a.md"), "a.md", "results/ was a folder of its own")
        XCTAssertEqual(MemoryFiles.relative("/memories"), "")
        XCTAssertEqual(MemoryFiles.relative(" ./ "), "")
        XCTAssertEqual(MemoryFiles.relative("results/"), "")
        XCTAssertEqual(MemoryFiles.relative("/MEMORY.md"), "MEMORY.md")
        XCTAssertEqual(MemoryFiles.relative("/memoryfoo/a.md"), "memoryfoo/a.md")
        XCTAssertEqual(MemoryFiles.relative("memory/results"), "")
    }

    func testTheAppsOwnFoldersAreNotTheAgents() throws {
        for name in ["logs", "traces", "memory", "developer", "harness-inbox"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("logs/debug.log"))
        _ = try run(["command": "create", "path": "orders/README.md", "file_text": "# Orders"])
        let listing = try run(["command": "view", "path": ""])
        XCTAssertTrue(listing.contains("orders/"), listing)
        for hidden in ["logs", "traces", "memory/", "developer", "harness-inbox"] { XCTAssertFalse(listing.contains(hidden), listing) }
        XCTAssertEqual(try run(["command": "view", "path": "logs/debug.log"]), MemoryFiles.reservedRefusal)
        XCTAssertEqual(try run(["command": "delete", "path": "traces"]), MemoryFiles.reservedRefusal)
        XCTAssertEqual(try run(["command": "rename", "old_path": "orders", "new_path": "logs/orders"]), MemoryFiles.reservedRefusal)
        XCTAssertEqual(files.snap(Data([1]), "developer/a.jpg"), MemoryFiles.reservedRefusal)
        XCTAssertFalse(files.results().contains("logs"))
    }

    func testOldResultsMoveToTheTop() throws {
        let old = root.appendingPathComponent("memory/results", isDirectory: true)
        for name in ["orders", "trip"] {
            try FileManager.default.createDirectory(at: old.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("trip"), withIntermediateDirectories: true)
        FilesLayout.moveResultsUp(from: old, to: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("orders").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("trip-1").path), "a taken name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testFolderZipPacksAResult() throws {
        let folder = root.appendingPathComponent("orders", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Orders".utf8).write(to: folder.appendingPathComponent("README.md"))
        let zip = try XCTUnwrap(FolderZip.make(folder))
        XCTAssertEqual(zip.pathExtension, "zip")
        let head = try Data(contentsOf: zip).prefix(2)
        XCTAssertEqual(Array(head), [0x50, 0x4B])  // "PK"
    }
}

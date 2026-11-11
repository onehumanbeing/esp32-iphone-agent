import CoreGraphics
import ImageIO
import XCTest
@testable import IPhoneAgent

/// The CV must not change the tree: public r1 frames (540 px) with frozen Vision lines, against the trees the
/// pre-Accelerate code (6e65b62) built from the same lines. The simulator reads Fixtures/uitree-golden; the phone
/// reads Documents/treebench540 (the same jpgs plus uitree-golden-trees.json), skipped when it is not there.
final class UITreeGoldenTests: XCTestCase {
    private func golden() throws -> (dir: URL, frames: [(stem: String, lines: UITree.Lines, tree: String)]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("treebench540")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/uitree-golden")
        let name = "uitree-golden-trees.json"
        guard let dir = [fixtures, docs].first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) })
        else { throw XCTSkip("no \(name) on this host") }
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        return (dir, try all.sorted { $0.key < $1.key }.map { stem, want in
            let lines = try XCTUnwrap(want["lines"] as? [[Any]]).map { (text: $0[0] as! String, box: $0[1] as! [Int]) }
            return (stem, lines, try XCTUnwrap(want["tree"] as? String))
        })
    }

    func testTreesMatchThePreSpeedupCode() throws {
        let (dir, frames) = try golden()
        XCTAssertEqual(frames.count, 6)
        for f in frames {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent(f.stem + ".jpg") as CFURL, nil), f.stem)
            let img = try XCTUnwrap(Raster(try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))))
            XCTAssertEqual(PyJSON.dumps(UITree.build(img, f.lines).json), f.tree, f.stem)
        }
    }

    /// The JPEG pipeline (CV alongside OCR, then the OCR-dependent stages) builds the same trees, and a
    /// repeated frame reuses the lines from the cache without running OCR again.
    func testOverlappedPipelineAndCacheBuildTheSameTrees() async throws {
        let (dir, frames) = try golden()
        let cache = OCRCache(), calls = Counter()
        for f in frames {
            let jpeg = try Data(contentsOf: dir.appendingPathComponent(f.stem + ".jpg"))
            let lines = f.lines
            for pass in 0..<2 {
                let made = await UITree.build(jpeg: jpeg, cache: cache) { _ in calls.add(); return lines }
                let tree = try XCTUnwrap(made)
                XCTAssertEqual(PyJSON.dumps(tree.json), f.tree, "\(f.stem) pass \(pass)")
                XCTAssertEqual(tree.ocrCached, pass == 1)
                XCTAssertEqual(tree.cvSeconds, tree.preSeconds + tree.postSeconds, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(calls.n, frames.count, "OCR ran once per distinct frame")
    }

    @MainActor func testOCRCacheHitsOnlyOnIdenticalBytes() async throws {
        let cache = OCRCache(), calls = Counter()
        let a = UITreeTests.screen()
        var b = a
        b[b.count / 2] ^= 1  // one bit off
        let lines: UITree.Lines = [("Sign in", [170, 585, 370, 635])]
        cache.store(a, lines)
        XCTAssertEqual(cache.lines(for: a)?.map(\.text), ["Sign in"])
        XCTAssertEqual(cache.lines(for: a)?.map(\.box), [[170, 585, 370, 635]])
        XCTAssertNil(cache.lines(for: b))
        XCTAssertNil(cache.lines(for: a.prefix(a.count - 1)))
        cache.clear()
        XCTAssertNil(cache.lines(for: a))
        for jpeg in [a, a, b, a] { _ = await UITree.build(jpeg: jpeg, cache: cache) { _ in calls.add(); return lines } }
        XCTAssertEqual(calls.n, 3, "a, (a cached), b, a again after b")
        _ = await UITree.build(jpeg: a, cache: nil) { _ in calls.add(); return lines }
        XCTAssertEqual(calls.n, 4, "no cache: always OCR")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var n: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

import CoreGraphics
import ImageIO
import XCTest
@testable import IPhoneAgent

/// The CV must not change the tree. Public r1 frames (540 px) with frozen Vision lines: the new code against
/// RefTree (the 6e65b62 code, test-only) on this host's own decode of the JPEGs, and on the simulator also
/// against the trees 6e65b62 built on the Mac (the phone's hardware JPEG decoder gives other pixels).
/// The simulator reads Fixtures/uitree-golden; the phone reads Documents/treebench540 (the same jpgs plus
/// uitree-golden-trees.json), skipped when it is not there.
final class UITreeGoldenTests: XCTestCase {
    private struct Frame { let stem: String, jpeg: Data, lines: UITree.Lines, mac: String?, ref: String }

    private func frames() throws -> [Frame] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("treebench540")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/uitree-golden")
        let name = "uitree-golden-trees.json"
        guard let dir = [fixtures, docs].first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) })
        else { throw XCTSkip("no \(name) on this host") }
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        return try all.sorted { $0.key < $1.key }.map { stem, want in
            let lines = try XCTUnwrap(want["lines"] as? [[Any]]).map { (text: $0[0] as! String, box: $0[1] as! [Int]) }
            let jpeg = try Data(contentsOf: dir.appendingPathComponent(stem + ".jpg"))
            let ref = PyJSON.dumps(RefTree.build(try Self.raster(jpeg), lines).json)
            return Frame(stem: stem, jpeg: jpeg, lines: lines, mac: dir == fixtures ? want["tree"] as? String : nil, ref: ref)
        }
    }

    private static func raster(_ jpeg: Data) throws -> Raster {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try XCTUnwrap(Raster(try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))))
    }

    func testTreesMatchThePreSpeedupCode() throws {
        let all = try frames()
        XCTAssertEqual(all.count, 6)
        for f in all {
            XCTAssertEqual(PyJSON.dumps(UITree.build(try Self.raster(f.jpeg), f.lines).json), f.ref, f.stem)
            if let mac = f.mac { XCTAssertEqual(f.ref, mac, "RefTree is the 6e65b62 code: \(f.stem)") }
        }
    }

    /// The JPEG pipeline (CV alongside OCR, then the OCR-dependent stages) builds the same trees, and a
    /// repeated frame reuses the lines from the cache without running OCR again.
    func testOverlappedPipelineAndCacheBuildTheSameTrees() async throws {
        let frames = try frames()
        let cache = OCRCache(), calls = Counter()
        for f in frames {
            let jpeg = f.jpeg, lines = f.lines
            for pass in 0..<2 {
                let made = await UITree.build(jpeg: jpeg, cache: cache) { _ in calls.add(); return lines }
                let tree = try XCTUnwrap(made)
                XCTAssertEqual(PyJSON.dumps(tree.json), f.ref, "\(f.stem) pass \(pass)")
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

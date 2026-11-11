import CoreGraphics
import ImageIO
import XCTest
@testable import IPhoneAgent

/// The CV must not change the tree: public r1 frames (540 px) with frozen Vision lines, against the trees the
/// pre-Accelerate code (6e65b62) built from the same lines. The simulator reads Fixtures/uitree-golden; the phone
/// reads Documents/treebench540 (the same jpgs plus uitree-golden-trees.json), skipped when it is not there.
final class UITreeGoldenTests: XCTestCase {
    func testTreesMatchThePreSpeedupCode() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("treebench540")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/uitree-golden")
        let name = "uitree-golden-trees.json"
        guard let dir = [fixtures, docs].first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) })
        else { throw XCTSkip("no \(name) on this host") }
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(golden.count, 6)
        for (stem, want) in golden.sorted(by: { $0.key < $1.key }) {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent(stem + ".jpg") as CFURL, nil), stem)
            let img = try XCTUnwrap(Raster(try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))))
            let lines = try XCTUnwrap(want["lines"] as? [[Any]]).map { (text: $0[0] as! String, box: $0[1] as! [Int]) }
            XCTAssertEqual(PyJSON.dumps(UITree.build(img, lines).json), want["tree"] as? String, stem)
        }
    }
}

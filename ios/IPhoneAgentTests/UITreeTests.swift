import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IPhoneAgent

/// The on-device screen tree (UITree*): listing, `tap #ID`, and the free line's actor seeing both.
@MainActor final class UITreeTests: XCTestCase {
    private func tree() -> UITree {
        let a = UINode("button", [100, 200, 300, 260], label: "Sign in")
        let b = UINode("text", [20, 1000, 120, 1030], label: String(repeating: "长", count: 50))
        let row = UINode("row", [0, 990, 540, 1040], children: [b])
        for (i, n) in [a, row, b].enumerated() { n.id = i + 1 }
        return UITree(w: 540, h: 1170, nodes: [a, row])
    }

    func testListingNumbersElementsWithoutLayoutRows() {
        let listing = tree().listing
        XCTAssertTrue(listing.contains("#1 button \"Sign in\" at 370 196"), listing)
        XCTAssertTrue(listing.contains("#2 text \"" + String(repeating: "长", count: 40) + "\" at 129 867"), listing)
        XCTAssertFalse(listing.contains(" row "))
        XCTAssertTrue(listing.hasSuffix("To tap one of these you may write: tap #ID"))
    }

    /// Byte for byte the gateway's treetext.listing(compact=True) on a tree its tree.py built (public r1 frame
    /// open_whiteboard/1 at 540 px, Mac Vision lines as the OCR): scripts/uitree/compact_fixture.py.
    func testCompactListingMatchesTheGateway() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/uitree-compact-r1-open_whiteboard-1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tree = try XCTUnwrap(UITree(json: JSONSerialization.data(withJSONObject: fixture["tree"]!)))
        let want = try XCTUnwrap(fixture["compact"] as? String)
        XCTAssertEqual(Data(tree.compactListing.utf8), Data(want.utf8), tree.compactListing)
        XCTAssertTrue(want.contains(" row ") && !want.contains(" container "), "the fixture exercises both rules")
    }

    func testCompactListingKeepsRowsCutsLabelsAndNumbersOverAllNodes() {
        let listing = tree().compactListing
        XCTAssertEqual(listing, "\n\nScreen elements parsed from the screenshot (id, role, label, center x y in 0-1000):\n"
                       + "#1 button \"Sign in\" at 370 196\n#2 row \"\" at 500 867\n"
                       + "#3 text \"" + String(repeating: "长", count: 40) + "\" at 129 867\nTo tap one of these you may write: tap #ID")
    }

    func testResolveTapID() {
        let t = tree()
        XCTAssertEqual(t.resolve("THINK: sign in\nDO: tap #1"), "THINK: sign in\nDO: tap 370 196")
        XCTAssertEqual(t.resolve("DO： tap #2\nDO: tap #1"), "DO： tap 129 867\nDO: tap 370 196")
        XCTAssertEqual(t.resolve("DO: tap #9"), "DO: tap #9", "an unknown id is left for the parser to reject")
        XCTAssertEqual(t.resolve("DO: tap 10 20"), "DO: tap 10 20")
    }

    /// Spark's listing (treetext.candidates) numbers rows and cells too: #3 is the text after the row (#2).
    func testSparkIDsCountRowsAndCells() {
        let t = tree()
        XCTAssertEqual(t.resolve("DO: tap #3", spark: true), "DO: tap 129 867")
        XCTAssertEqual(t.resolve("DO: tap #1", spark: true), "DO: tap 370 196")
        XCTAssertEqual(t.resolve("DO: tap #3"), "DO: tap #3", "the app's own listing has only 2 ids")
    }

    func testBuildFindsAFilledButton() async throws {
        let made = await UITree.build(jpeg: Self.screen())
        let built = try XCTUnwrap(made)
        XCTAssertEqual(built.w, 540)
        let hit = built.elements.first { $0.box[0] <= 270 && 270 <= $0.box[2] && $0.box[1] <= 610 && 610 <= $0.box[3] }
        XCTAssertNotNil(hit, built.listing)
    }

    func testFreeLineActorSeesTheListingAndTapsByID() async throws {
        let phone = FakeGestures(), screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: the button\nDO: tap #1" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: nil, trace: nil)
        agent.screenTree = true
        let planned = try await agent.nextActions()
        let prompt = try XCTUnwrap(actor.prompts.first)
        XCTAssertTrue(prompt.contains("Screen elements (id, role, label, center x y in 0-1000):\n#1 "), prompt)
        let made = await UITree.build(jpeg: ModelImage.forModel(Self.screen()))
        let built = try XCTUnwrap(made)
        let (x, y) = built.point(built.elements[0])
        XCTAssertEqual(planned.first?.act["x"], .int(x))
        XCTAssertEqual(planned.first?.act["y"], .int(y))
    }

    /// The free line's Spark tree (handsy.tree) reads back as the same elements, listing and `tap #ID`.
    func testSparkTreeJSONRoundTrips() throws {
        let t = tree()
        let back = try XCTUnwrap(UITree(json: Data(PyJSON.dumps(t.json).utf8)))
        XCTAssertEqual(back.listing, t.listing)
        XCTAssertEqual(back.resolve("DO: tap #2"), t.resolve("DO: tap #2"))
        let sse = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"handsy":{"tree":{"w":540,"h":1170,"ocr":"ppocr","tree":[]}}}"#.utf8)) as? [String: Any])
        XCTAssertNotNil(LLMClient.tree(sse))
        XCTAssertNil(LLMClient.tree(["choices": []]))
    }

    func testServerTreeSkipsThePhonesTreeAndResolvesFromTheReply() async throws {
        let screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: sign in\nDO: tap #1" }
        actor.tree = Data(PyJSON.dumps(tree().json).utf8)
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        agent.screenTree = true
        agent.serverTree = true
        let planned = try await agent.nextActions()
        XCTAssertFalse(try XCTUnwrap(actor.prompts.first).contains("Screen elements"))  // Spark appends it
        XCTAssertEqual(planned.first?.act["x"], .int(370))
        XCTAssertEqual(planned.first?.act["y"], .int(196))
    }

    func testTreeSourceDefaultsToServerAndDeviceDropsTheTreeHeader() {
        let saved = UserDefaults.standard.string(forKey: TreeSource.key)
        defer { UserDefaults.standard.set(saved, forKey: TreeSource.key) }
        UserDefaults.standard.removeObject(forKey: TreeSource.key)
        XCTAssertEqual(TreeSource.current, .server)
        XCTAssertTrue(Settings.serverTree(.handsyTrial))
        XCTAssertEqual(Settings.treeHeaders("actor", .handsyTrial), ["X-Handsy-Tree": "slim"])
        TreeSource.set(.device)
        XCTAssertEqual(TreeSource.current, .device)
        XCTAssertFalse(Settings.serverTree(.handsyTrial))
        XCTAssertEqual(Settings.treeHeaders("actor", .handsyTrial), ["X-Handsy-Tree-Source": "device"])
        XCTAssertEqual(Settings.treeHeaders("planner", .handsyTrial), [:])
        XCTAssertEqual(Settings.treeHeaders("actor", .openRouter, source: .device), [:])
    }

    /// Spark numbers `tap #ID` over all candidates (rows too), like the compact listing.
    func testCompactResolveNumbersOverCandidates() {
        let t = tree()
        XCTAssertEqual(t.resolve("DO: tap #2", spark: true), "DO: tap 500 867")
        XCTAssertEqual(t.resolve("DO: tap #3", spark: true), "DO: tap 129 867")
    }

    func testOnDeviceTreeAppendsTheCompactListingAndResolvesOnThePhone() async throws {
        let screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: the button\nDO: tap #1" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        agent.screenTree = true
        agent.compactTree = true
        let planned = try await agent.nextActions()
        let prompt = try XCTUnwrap(actor.prompts.first)
        let made = await UITree.build(jpeg: ModelImage.forModel(Self.screen()))
        let built = try XCTUnwrap(made)
        XCTAssertTrue(prompt.hasSuffix(built.compactListing), prompt)
        XCTAssertFalse(prompt.contains("Screen elements (id, role"), "not the old listing")
        let (x, y) = built.point(built.candidates[0])
        XCTAssertEqual(planned.first?.act["x"], .int(x))
        XCTAssertEqual(planned.first?.act["y"], .int(y))
    }

    /// The concurrent Lab-channel Canny passes give the same edge map as one after another.
    func testEdgeMapMatchesSerialCanny() throws {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(Self.screen() as CFData, nil))
        let img = try XCTUnwrap(Raster(try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))))
        var want = Plane(w: img.w, h: img.h)
        for channel in UITreeCV.labPlanes(UITreeCV.blur3(img), w: img.w, h: img.h) {
            let e = UITreeCV.canny(channel, low: 30, high: 90)
            for i in 0..<want.v.count where e.v[i] != 0 { want.v[i] = 255 }
        }
        XCTAssertEqual(UITreeCV.edgeMap(img).v, want.v)
        XCTAssertTrue(want.v.contains(255))
    }

    func testOtherLinesSendThePromptAsBefore() async throws {
        let screen = FakeScreen()
        screen.frame = Self.screen()
        let actor = FakeModel { _ in "THINK: x\nDO: tap 100 200" }
        let agent = AgentLoop(phone: FakeGestures(), screen: screen, actor: actor, planner: nil, trace: nil)
        _ = try await agent.nextActions()
        XCTAssertFalse(try XCTUnwrap(actor.prompts.first).contains("Screen elements"))
    }

    /// On-device tree timing (run on the phone, -O): Documents/treebench540 and treebench718 of the test host hold
    /// public r1 frames (copied in with devicectl); skipped where they are absent (simulator, CI). Warm-up, then 30
    /// builds per size: total/ocr/cv p50/p90 and the CV half stage by stage, printed as TREEBENCH lines and saved
    /// to Documents/treebench-result.txt.
    func testTreeBuildTimingOnDevice() async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String] = ["thermal \(ProcessInfo.processInfo.thermalState.rawValue)"]
        func pct(_ xs: [Double]) -> String {
            let s = xs.sorted()
            return String(format: "p50 %.1f p90 %.1f max %.1f", s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!)
        }
        func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }
        for name in ["treebench540", "treebench718"] {
            let dir = docs.appendingPathComponent(name)
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
            let frames = files.compactMap { try? Data(contentsOf: $0) }
            if frames.isEmpty { continue }
            for f in frames { _ = await UITree.build(jpeg: f, cache: nil) }  // warm-up
            var total: [Double] = [], ocr: [Double] = [], cv: [Double] = [], pre: [Double] = [], post: [Double] = [], els: [Double] = [], compact: [Double] = []
            var stage: [String: [Double]] = [:], size = ""
            for i in 0..<30 {
                let jpeg = frames[i % frames.count]
                let made = await UITree.build(jpeg: jpeg, cache: nil)  // every build runs Vision
                let t = try XCTUnwrap(made)
                size = "\(t.w)x\(t.h)"
                total.append(t.totalSeconds * 1000); ocr.append(t.ocrSeconds * 1000); cv.append(t.cvSeconds * 1000)
                pre.append(t.preSeconds * 1000); post.append(t.postSeconds * 1000)
                els.append(Double(t.elements.count)); compact.append(Double(t.candidates.filter { $0.role != "container" }.count))
                // the CV half again, stage by stage (the calls of UITree.build(_:_:))
                let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                var s = Date()
                let img = try XCTUnwrap(Raster(image)); stage["1 raster (decode+RGB)", default: []].append(ms(s)); s = Date()
                let W = img.w, H = img.h
                let blurred = UITreeCV.blur3(img); stage["2 edge blur3", default: []].append(ms(s)); s = Date()
                let lab = UITreeCV.labPlanes(blurred, w: W, h: H); stage["3 edge lab", default: []].append(ms(s)); s = Date()
                var edges = Plane(w: W, h: H)
                for ch in lab {
                    let e = UITreeCV.canny(ch, low: 30, high: 90)
                    for k in 0..<edges.v.count where e.v[k] != 0 { edges.v[k] = 255 }
                }
                stage["4 edge canny x3", default: []].append(ms(s)); s = Date()
                let textBoxes = t.lines.map(\.box)
                var leaves = t.lines.map { UINode("text", $0.box, label: $0.text) }
                for (kind, b) in UITree.blobs(edges, textBoxes, W, H) where kind == "blob" {
                    if Double(textBoxes.reduce(0) { $0 + UITree.inter(b, $1) }) < 0.5 * Double(UITree.area(b)) {
                        leaves.append(UINode(UITree.classify(img, b, W), b))
                    }
                }
                stage["5 blobs (mask, dilate3, close7, components) + classify", default: []].append(ms(s)); s = Date()
                let rects = UITree.filledRects(edges, W, H).map { UINode("container", $0) }
                stage["6 filledRects (close3, contours)", default: []].append(ms(s)); s = Date()
                UITree.labelIcons(leaves)
                var top = UITree.xyCut(UITree.prune(UITree.nest(rects, leaves), W, H), [0, 0, W, H])
                UITree.finish(&top, W, H)
                stage["7 labels, nest, prune, xyCut, finish", default: []].append(ms(s))
            }
            report.append("\(size), 30 builds over \(frames.count) frames: total \(pct(total)) ms; ocr \(pct(ocr)); cv \(pct(cv)) (pre alongside ocr \(pct(pre)); post \(pct(post))); "
                          + "elements \(pct(els)); compact \(pct(compact))")
            for k in stage.keys.sorted() { report.append("  \(size) stage \(k): \(pct(stage[k]!)) ms") }
        }
        guard report.count > 1 else { throw XCTSkip("no Documents/treebench540 or treebench718 frames on this host") }
        report.append("thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
        for line in report { print("TREEBENCH " + line) }
        try report.joined(separator: "\n").write(to: docs.appendingPathComponent("treebench-result.txt"), atomically: true, encoding: .utf8)
    }

    /// A white 540 x 1170 screen with one dark filled button.
    static func screen() -> Data {
        let ctx = CGContext(data: nil, width: 540, height: 1170, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 540, height: 1170))
        ctx.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 170, y: 1170 - 635, width: 200, height: 50))  // y flipped: top 585 ... 635
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

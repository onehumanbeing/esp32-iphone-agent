import XCTest
import UIKit
@testable import IPhoneAgent

/// Redacted run export and import.
final class ShareTests: XCTestCase {
    let redactor = Redactor(secrets: ["sk-test-secret-123", "https://llm.example.com/v1", "llm.example.com", "AgentNet-7C3E", "hunter22"])

    func testTextLosesSecretsIPsAndTypedText() {
        let line = "POST https://llm.example.com/v1 key sk-test-secret-123 on AgentNet-7C3E (hunter22) at 192.168.4.1"
        XCTAssertEqual(redactor.text(line), "POST [redacted] key [redacted] on [redacted] ([redacted]) at [redacted]")
        XCTAssertEqual(redactor.text("THINK: set it\nDO: type 0700\nDO: key enter"), "THINK: set it\nDO: type •••\nDO: key enter")
        XCTAssertEqual(redactor.text("cmd #12 type my secret → ok  (21 ms)"), "cmd #12 type ••• → ok  (21 ms)")
    }

    func testStepLinesRedactTypeActionsAndPromptHistory() throws {
        let line = #"{"kind": "llm", "prompt": "Recent actions:\n{\"action\": \"type\", \"text\": \"hello mom\"}", "reply": "DO: type hi"}"#
        let step = #"{"kind": "step", "action": "type", "text": "hello mom", "act_s": 0.05}"#
        let a = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redactor.jsonLine(line).utf8)) as? [String: Any])
        XCTAssertEqual(a["prompt"] as? String, "Recent actions:\n{\"action\": \"type\", \"text\": \"•••\"}")
        XCTAssertEqual(a["reply"] as? String, "DO: type •••")
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redactor.jsonLine(step).utf8)) as? [String: Any])
        XCTAssertEqual(b["text"] as? String, "•••")
        XCTAssertEqual(b["act_s"] as? Double, 0.05)
    }

    func testScreenshotTopBandIsBlack() throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 100)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 100))
        }
        let out = try XCTUnwrap(redactor.image(try XCTUnwrap(img.jpegData(compressionQuality: 1))))
        let cg = try XCTUnwrap(UIImage(data: out)?.cgImage)
        let pixels = try XCTUnwrap(cg.dataProvider?.data as Data?)
        let bpr = cg.bytesPerRow
        XCTAssertLessThan(pixels[bpr * 2], 40)            // row 2: blacked out
        XCTAssertGreaterThan(pixels[bpr * (cg.height - 2)], 200)  // near the bottom: untouched
    }

    @MainActor func testExportThenImportRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        let run = root.appendingPathComponent("20261015-060431")
        try fm.createDirectory(at: run.appendingPathComponent("video"), withIntermediateDirectories: true)
        try Data(#"{"kind": "task", "task": "Alarm at 192.168.4.1"}"#.utf8).write(to: run.appendingPathComponent("steps.jsonl"))
        let package = try RunShare.export([run], redactor: redactor, debugLog: nil)
        XCTAssertEqual(package.runs, 1)
        XCTAssertGreaterThan(package.bytes, 0)

        let into = root.appendingPathComponent("imported")
        XCTAssertEqual(try RunShare.importZip(package.url, into: into), ["imported-20261015-060431"])
        let back = into.appendingPathComponent("imported-20261015-060431")
        XCTAssertTrue(RunShare.isImported(back))
        let loaded = try XCTUnwrap(RunStore.load(back))
        XCTAssertEqual(loaded.task, "Alarm at [redacted]")
        XCTAssertTrue(loaded.imported)
        try? fm.removeItem(at: root)
    }
}

/// The first-launch sheet: Agree records the per-run yes (so the first run doesn't ask again), Not Now records
/// none, and another host or Jev target later is asked again. Runs as a store build, where the gate is on.
@MainActor final class FirstConsentTests: XCTestCase {
    private let host = "http://127.0.0.1:9/v1"  // refused at once if the model list is fetched

    private func fresh() -> Settings {
        let standard = UserDefaults.standard
        let keys = [AIConsent.key, JevConsent.key, RunShare.askedKey, JevConfig.ownKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let store = AIConsent.store
        let suite = UUID().uuidString
        addTeardownBlock { @MainActor in
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            AIConsent.store = store
            UserDefaults().removePersistentDomain(forName: suite)
        }
        keys.forEach(standard.removeObject(forKey:))
        AIConsent.store = true
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!, info: [:])
        settings.selectProvider(.others)
        settings.baseURL = host
        return settings
    }

    func testAgreeGrantsBothAndMarksAsked() {
        let settings = fresh()
        XCTAssertTrue(settings.pendingConsent.model)
        FirstConsent.agree(settings)
        XCTAssertEqual(AIConsent.grantedHost, "127.0.0.1")
        XCTAssertEqual(JevConsent.granted, settings.jevOn, "Jev is agreed to when the sheet shows it")
        XCTAssertTrue(FirstConsent.asked)
        settings.grantConsent(model: true, jev: true)  // what Agree records when the sheet shows both
        XCTAssertTrue(AIConsent.granted(host))
        XCTAssertTrue(JevConsent.granted)
    }

    func testNotNowGrantsNothing() {
        let settings = fresh()
        FirstConsent.notNow()
        XCTAssertTrue(FirstConsent.asked)
        XCTAssertNil(AIConsent.grantedHost)
        XCTAssertFalse(JevConsent.granted)
        XCTAssertTrue(settings.pendingConsent.model, "the first run still asks")
    }

    func testFirstRunAfterAgreeNeedsNoConsent() {
        let settings = fresh()
        FirstConsent.agree(settings)
        XCTAssertFalse(settings.pendingConsent.model)
        XCTAssertFalse(settings.pendingConsent.jev)
    }

    func testAnotherHostOrJevTargetLaterAsksAgain() {
        let settings = fresh()
        FirstConsent.agree(settings)
        settings.baseURL = "http://127.0.0.2:9/v1"  // e.g. one's own key on another service
        XCTAssertTrue(settings.pendingConsent.model)
        settings.grantConsent(model: false, jev: true)
        XCTAssertTrue(JevConsent.granted)
        UserDefaults.standard.set(true, forKey: JevConfig.ownKey)  // Jev on one's own TypeSafe key
        XCTAssertFalse(JevConsent.granted)
    }

    func testNothingSetUpYetDisclosesAndGrantsNoModel() {
        let settings = fresh()
        settings.baseURL = ""
        XCTAssertFalse(FirstConsent.parts(settings).model)
        FirstConsent.agree(settings)
        XCTAssertNil(AIConsent.grantedHost)
    }
}

import XCTest
@testable import IPhoneAgent

/// Which screen source a run gets (CaptureBackend.resolve) for every combination of what the phone, the build and
/// the user say, and what the board is told (StopWatchUI's `o`). The board's firmware plays no part in the choice:
/// every firmware moves the pointer the same way, and `o` is a key older firmware skips.
final class CaptureBackendTests: XCTestCase {
    private typealias Support = CaptureBackend.Support

    private let full = Support(os27: true, sdk: true, allowed: true, background: true, phone: true)

    func testOnlyAPhoneWithEverythingCanRecordItsOwnScreen() {
        XCTAssertTrue(full.onDevice)
        for path in [\Support.os27, \.sdk, \.allowed, \.background, \.phone] {
            var missing = full
            missing[keyPath: path] = false
            XCTAssertFalse(missing.onDevice, "\(path) missing must keep AirPlay")
        }
    }

    /// Every cell of iOS (before / from 27) x SDK x allowed x background mode x iPhone / iPad x saved choice.
    func testTheWholeMatrixFallsBackToAirPlayUnlessEverythingIsThere() {
        let saves: [String?] = [nil, "airPlay", "onDevice", "garbage", ""]
        var cells = 0
        for os27 in [false, true] { for sdk in [false, true] { for allowed in [false, true] {
            for background in [false, true] { for phone in [false, true] { for saved in saves {
                let support = Support(os27: os27, sdk: sdk, allowed: allowed, background: background, phone: phone)
                let want: CaptureBackend = os27 && sdk && allowed && background && phone && saved == "onDevice"
                    ? .onDevice : .airPlay
                XCTAssertEqual(CaptureBackend.resolve(support, saved: saved), want, "\(support) saved \(saved ?? "nil")")
                cells += 1
            }}}
        }}}
        XCTAssertEqual(cells, 160)
    }

    func testBeforeIOS27TheSavedChoiceIsIgnoredAndKept() {
        var old = full
        old.os27 = false
        XCTAssertEqual(CaptureBackend.resolve(old, saved: "onDevice"), .airPlay)
        XCTAssertEqual(CaptureBackend.resolve(full, saved: "onDevice"), .onDevice)  // the same saved value, back on 27
    }

    func testTheBackgroundModeIsReadFromInfoPlist() {
        XCTAssertTrue(CaptureBackend.declaresBackgroundMode(["UIBackgroundModes": ["bluetooth-central", "screen-capture"]]))
        XCTAssertFalse(CaptureBackend.declaresBackgroundMode(["UIBackgroundModes": ["bluetooth-central", "bluetooth-central"]]))
        XCTAssertFalse(CaptureBackend.declaresBackgroundMode(["UIBackgroundModes": "screen-capture"]))
        XCTAssertFalse(CaptureBackend.declaresBackgroundMode([:]))
        XCTAssertFalse(CaptureBackend.declaresBackgroundMode(nil))
    }

    /// The default build (IA_CAPTURE_BACKGROUND_MODE = bluetooth-central) does not declare the mode, so it never
    /// offers Screen Recording, whatever the phone runs.
    @MainActor func testThisBuildKeepsAirPlay() {
        XCTAssertFalse(CaptureBackend.declaresBackgroundMode(Bundle.main.infoDictionary))
        XCTAssertFalse(CaptureBackend.onDeviceAvailable)
        let saved = UserDefaults.standard.object(forKey: CaptureBackend.key)
        defer { UserDefaults.standard.set(saved, forKey: CaptureBackend.key) }
        for value in [nil, "airPlay", "onDevice", "unknown"] {
            UserDefaults.standard.set(value, forKey: CaptureBackend.key)
            XCTAssertEqual(CaptureBackend.current, .airPlay)
        }
    }

    // MARK: the StopWatch hint

    private func payload(ownScreen: Bool, max: Int = StopWatchUI.maxLine) throws -> (String, [String: Any]) {
        var state = StopWatchUI.State(mood: .acting, step: 4, limit: 300, line: String(repeating: "Open Settings ", count: 8),
                                      phase: .running)
        (state.done, state.total) = (3, 12)
        let (line, _) = try XCTUnwrap(StopWatchUI.command(.show(state), max: max, ownScreen: ownScreen))
        let body = try XCTUnwrap(line.split(separator: " ", maxSplits: 1).last)
        return (line, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]))
    }

    func testAirPlayLinesAreWhatOldFirmwareAlreadyGets() throws {
        let (_, o) = try payload(ownScreen: false)
        XCTAssertNil(o["o"])
        XCTAssertEqual(StopWatchUI.command(.off, ownScreen: true)?.0, "ui off")
    }

    func testScreenRecordingAddsOInsideTheLineLimit() throws {
        let (line, o) = try payload(ownScreen: true)
        XCTAssertEqual(o["o"] as? Int, 1)
        XCTAssertLessThanOrEqual(line.utf8.count, StopWatchUI.maxLine)
        let (tight, t) = try payload(ownScreen: true, max: 120)  // the text gives way first, `o` stays
        XCTAssertLessThanOrEqual(tight.utf8.count, 120)
        XCTAssertEqual(t["o"] as? Int, 1)
    }
}

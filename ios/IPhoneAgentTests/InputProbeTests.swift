import UIKit
import XCTest
@testable import IPhoneAgent

final class InputProbeTests: XCTestCase {
    private let signals = InputProbe.Signals(screenCaptured: true, sceneCaptureState: "active", screens: 1, assistiveTouch: true,
                                             guidedAccess: false, voiceOver: false, switchControl: false, mouseCurrent: true,
                                             mice: 1, keyboard: false, ios: "26.1", indirectInputEvents: "absent")

    private func phase(_ name: String, _ dt: Double, radius: Double, force: Double = 0) -> InputProbe.Phase {
        .init(phase: name, dtMs: dt, majorRadius: radius, majorRadiusTolerance: 5.2, force: force, maximumPossibleForce: 0,
              altitudeAngle: 1.571, azimuth: 0, x: 100, y: 120)
    }

    private func sample(_ i: Int, _ label: String, type: String = "direct", duration: Double, radii: [Double], moved: Int = 0,
                        hover: Bool = false, captured: Bool = true) -> InputProbe.Sample {
        var s = signals
        s.screenCaptured = captured
        var phases = [phase("began", 0, radius: radii[0])]
        phases += (0..<moved).map { phase("moved", Double($0 + 1) * 8, radius: radii[min($0 + 1, radii.count - 1)]) }
        phases.append(phase("ended", duration, radius: radii.last!))
        return .init(index: i, label: label, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)), type: type, tapCount: 1,
                     durationMs: duration, moved: moved, pathPt: Double(moved), hoverBefore: hover, hoverEvents: hover ? 3 : 0,
                     eventType: "touches", eventSubtype: "none", buttonMask: type == "indirectPointer" ? 1 : 0, modifierFlags: 0,
                     phases: phases, signals: s)
    }

    func testSummariesGroupByLabelInFirstSeenOrder() {
        let samples = [
            sample(1, "finger", duration: 90, radii: [20.9, 26.1, 23.4], moved: 2, captured: false),
            sample(2, "board", duration: 48, radii: [10.4]),
            sample(3, "finger", duration: 110, radii: [18.2, 20.9], moved: 1, captured: false),
            sample(4, "board", type: "indirectPointer", duration: 52, radii: [10.4], hover: true),
            sample(5, "finger", duration: 70, radii: [31.3]),
        ]
        let sums = InputProbe.summaries(samples)
        XCTAssertEqual(sums.map(\.label), ["finger", "board"])
        let finger = sums[0], board = sums[1]
        XCTAssertEqual(finger.count, 3)
        XCTAssertEqual(finger.types, ["direct": 3])
        XCTAssertEqual(finger.majorRadiusMin, 18.2)
        XCTAssertEqual(finger.majorRadiusMax, 31.3)
        XCTAssertEqual(finger.medianDurationMs, 90)
        XCTAssertEqual(finger.moved, 2)
        XCTAssertEqual(finger.captured, 1)
        XCTAssertEqual(board.count, 2)
        XCTAssertEqual(board.types, ["direct": 1, "indirectPointer": 1])
        XCTAssertEqual(board.medianDurationMs, 50)  // even count: the mean of the middle two
        XCTAssertEqual(board.majorRadiusMin, board.majorRadiusMax)
        XCTAssertEqual(board.hoverBefore, 1)
        XCTAssertEqual(board.moved, 0)
        XCTAssertTrue(InputProbe.summaries([]).isEmpty)
    }

    func testReportJSONIsStableAndRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let events = [InputProbe.Event(at: now, name: "screenCaptured", detail: "captured true")]
        let report = InputProbe.report(samples: [sample(1, "board", duration: 48, radii: [10.4])], signals: signals,
                                       events: events, app: "1.0.11 (1)", now: now)
        let data = try InputProbe.json(report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try InputProbe.json(report), data)  // sorted keys: the same bytes every time
        XCTAssertTrue(text.contains("\"generated\" : \"2027-01-15T08:01:40Z\""), text)
        XCTAssertTrue(text.contains("\"schema\" : 1"))
        XCTAssertTrue(text.contains("\"indirectInputEvents\" : \"absent\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "generated", "app", "signals", "summary", "samples", "events"])
        let first = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        for key in ["label", "type", "tapCount", "durationMs", "moved", "pathPt", "hoverBefore", "eventType", "eventSubtype",
                    "buttonMask", "phases", "signals"] {
            XCTAssertNotNil(first[key], key)
        }
        let p = try XCTUnwrap((first["phases"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(p.keys), ["phase", "dtMs", "majorRadius", "majorRadiusTolerance", "force", "maximumPossibleForce",
                                     "altitudeAngle", "azimuth", "x", "y"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(InputProbe.Report.self, from: data), report)
    }

    func testSceneCaptureStateIsOmittedWhenUnavailable() throws {
        var old = signals
        old.sceneCaptureState = nil
        let data = try InputProbe.json(InputProbe.report(samples: [], signals: old, events: [], app: "x"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sceneCaptureState"))
    }

    func testNamesAndRounding() {
        XCTAssertEqual(InputProbe.name(UITouch.TouchType.direct), "direct")
        XCTAssertEqual(InputProbe.name(UITouch.TouchType.indirectPointer), "indirectPointer")
        XCTAssertEqual(InputProbe.name(UITouch.TouchType.pencil), "pencil")
        XCTAssertEqual(InputProbe.name(UITouch.Phase.cancelled), "cancelled")
        XCTAssertEqual(InputProbe.name(UITouch.Phase.regionEntered), "regionEntered")
        XCTAssertEqual(InputProbe.name(UIEvent.EventType.touches), "touches")
        XCTAssertEqual(InputProbe.name(UIEvent.EventType.hover), "hover")
        XCTAssertEqual(InputProbe.name(UIEvent.EventSubtype.none), "none")
        XCTAssertEqual(InputProbe.round3(20.86412), 20.864)
        XCTAssertEqual(InputProbe.round3(.nan), 0)
        XCTAssertEqual(InputProbe.plistFlag(nil), "absent")
        XCTAssertEqual(InputProbe.plistFlag(true), "true")
        XCTAssertEqual(InputProbe.plistFlag(NSNumber(value: false)), "false")
        XCTAssertEqual(InputProbe.plistFlag("YES"), "true")
    }

    func testTheLogLineCarriesTheTells() {
        let line = InputProbe.line(sample(7, "board", type: "indirectPointer", duration: 48.4, radii: [10.4], hover: true))
        XCTAssertEqual(line, "probe: #7 [board] indirectPointer tap1 48ms moved 0 r 10.40-10.40 f 0.00 hover yes captured yes AT on")
    }
}

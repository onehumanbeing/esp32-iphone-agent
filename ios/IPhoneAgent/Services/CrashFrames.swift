import Foundation

/// The crashed thread of a MetricKit call stack tree, as frames PostHog's Error Tracking can show and group.
/// Frames stay addresses (binary + offset); scripts/symbolicate_crash.py turns them into function names with the
/// build's dSYM.
enum CrashFrames {
    struct Frame: Equatable {
        var binary: String
        var uuid: String
        var offset: Int
    }

    /// Innermost first. MetricKit nests each caller as the `subFrames` of its callee.
    static func crashed(_ tree: Data) -> [Frame] {
        guard let root = try? JSONSerialization.jsonObject(with: tree) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frames: [Frame] = []
        var level = stack?["callStackRootFrames"] as? [[String: Any]]
        while let f = level?.first, frames.count < 128 {
            frames.append(Frame(binary: f["binaryName"] as? String ?? "?", uuid: f["binaryUUID"] as? String ?? "",
                                offset: f["offsetIntoBinaryTextSegment"] as? Int ?? 0))
            level = f["subFrames"] as? [[String: Any]]
        }
        return frames
    }

    /// Same crash site, same group: the first five frames in the app (offsets move only with a new build).
    static func fingerprint(_ frames: [Frame], build: String) -> String {
        let app = frames.filter { $0.binary == "IPhoneAgent" }.prefix(5).map { String($0.offset, radix: 16) }
        return "\(build):" + (app.isEmpty ? frames.prefix(3).map { "\($0.binary)+\(String($0.offset, radix: 16))" } : Array(app))
            .joined(separator: ",")
    }

    /// PostHog's `$exception` event properties for one crash.
    static func exception(type: String, message: String, frames: [Frame], build: String) -> [String: Any] {
        [
            "$exception_list": [[
                "type": type, "value": message,
                "mechanism": ["handled": false, "synthetic": false, "type": "metrickit"],
                "stacktrace": ["type": "raw", "frames": frames.map { f in
                    ["platform": "ios", "module": f.binary, "function": "\(f.binary) + 0x\(String(f.offset, radix: 16))",
                     "instruction_addr": "0x" + String(f.offset, radix: 16), "image_uuid": f.uuid,
                     "in_app": f.binary == "IPhoneAgent"] as [String: Any]
                }],
            ]],
            "$exception_fingerprint": fingerprint(frames, build: build),
        ]
    }
}

// Mac CLI over the app's own tree code (Agent/UITree*.swift), for the handsy-benchmark regression runs:
//   ios/scripts/uitree/build.sh && /tmp/uitree <dir of 540-wide jpgs> <out.json>
// out.json: {"<file stem>": {"tree": {w, h, ocr, tree}, "ms": build ms}}, what `regress.py --tree` reads.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: uitree <dir> <out.json>\n".utf8)); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
var out: [String: Any] = [:]
var ms: [Double] = []
let done = DispatchSemaphore(value: 0)
Task {
    for f in files {
        let data = try Data(contentsOf: f)
        let t0 = Date()
        guard let tree = await UITree.build(jpeg: data) else { continue }
        let took = Date().timeIntervalSince(t0) * 1000
        ms.append(took)
        let json = try JSONSerialization.jsonObject(with: Data(PyJSON.dumps(tree.json).utf8))
        out[f.deletingPathExtension().lastPathComponent] = ["tree": json, "ms": took,
                                                          "ocr_ms": tree.ocrSeconds * 1000, "cv_ms": tree.cvSeconds * 1000,
                                                          "lines": tree.lines.map { ["text": $0.text, "box": $0.box] as [String: Any] }]
    }
    done.signal()
}
done.wait()
try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))
ms.sort()
if !ms.isEmpty {
    print("\(ms.count) trees, p50 \(Int(ms[ms.count / 2])) ms, p90 \(Int(ms[ms.count * 9 / 10])) ms, max \(Int(ms.last!)) ms")
}

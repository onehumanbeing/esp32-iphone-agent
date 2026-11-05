import Foundation
import JavaScriptCore

/// Runs pi-agent-core + pi-ai inside a bare JSContext (the engine an iOS app gets) with Swift timers and a
/// streaming URLSession fetch bridge. Usage: pi-jsc-host <dist dir> <base url> <model> [prompt]. API key: $PI_API_KEY.
let args = CommandLine.arguments
let dist = URL(fileURLWithPath: args[1])
let ctx = JSContext()!
ctx.exceptionHandler = { _, e in print("JS exception:", e?.toString() ?? "?", e?.objectForKeyedSubscript("stack")?.toString() ?? "") }

final class Bridge: NSObject, URLSessionDataDelegate {
    var timers: [Int: DispatchWorkItem] = [:], nextTimer = 0
    var tasks: [Int: URLSessionDataTask] = [:], ids: [Int: Int] = [:]  // task identifier -> fetch id
    lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    var requests = 0, bytes = 0

    func js(_ name: String, _ a: [Any]) { ctx.objectForKeyedSubscript(name).call(withArguments: a) }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let h = r as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in h.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        if let id = ids[dataTask.taskIdentifier] { js("__fetchHead", [id, h.statusCode, headers]) }
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += data.count
        if let id = ids[dataTask.taskIdentifier] { js("__fetchChunk", [id, [UInt8](data)]) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = ids.removeValue(forKey: task.taskIdentifier) else { return }
        tasks[id] = nil
        js("__fetchEnd", [id, error.map { $0.localizedDescription } ?? NSNull()])
    }
}
let bridge = Bridge()
let native = JSValue(newObjectIn: ctx)!
func fn(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }
fn("log", { (s: String) in print("js:", s) } as @convention(block) (String) -> Void)
fn("setTimeout", { (f: JSValue, ms: Double) -> Int in
    bridge.nextTimer += 1
    let id = bridge.nextTimer
    let item = DispatchWorkItem { bridge.timers[id] = nil; f.call(withArguments: []) }
    bridge.timers[id] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: item)
    return id
} as @convention(block) (JSValue, Double) -> Int)
fn("clearTimeout", { (id: Int) in bridge.timers.removeValue(forKey: id)?.cancel() } as @convention(block) (Int) -> Void)
fn("randomBytes", { (n: Int) -> [UInt8] in (0..<n).map { _ in UInt8.random(in: 0...255) } } as @convention(block) (Int) -> [UInt8])
fn("uuid", { UUID().uuidString.lowercased() } as @convention(block) () -> String)
fn("atob", { (s: String) in String(decoding: Data(base64Encoded: s) ?? Data(), as: UTF8.self) } as @convention(block) (String) -> String)
fn("btoa", { (s: String) in Data(s.utf8).base64EncodedString() } as @convention(block) (String) -> String)
fn("cancel", { (id: Int) in bridge.tasks[id]?.cancel() } as @convention(block) (Int) -> Void)
fn("fetch", { (id: Int, url: String, method: String, headers: [String: String], body: JSValue) in
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    if body.isString { req.httpBody = Data(body.toString().utf8) }
    let task = bridge.session.dataTask(with: req)
    bridge.tasks[id] = task
    bridge.ids[task.taskIdentifier] = id
    bridge.requests += 1
    task.resume()
} as @convention(block) (Int, String, String, [String: String], JSValue) -> Void)
ctx.setObject(native, forKeyedSubscript: "__native" as NSString)

let t0 = Date()
for file in ["polyfills.min.js", "pi-bundle.min.js"] {
    ctx.evaluateScript(try! String(contentsOf: dist.appendingPathComponent(file), encoding: .utf8), withSourceURL: dist.appendingPathComponent(file))
}
let loaded = Date().timeIntervalSince(t0)
var finished = false
let config: [String: Any] = ["baseUrl": args[2], "modelId": args[3], "apiKey": ProcessInfo.processInfo.environment["PI_API_KEY"] ?? "x",
                             "prompt": args.count > 4 ? args[4] : "Open Settings"]
let promise = ctx.evaluateScript("PiSpike").objectForKeyedSubscript("run").call(withArguments: [config])!
let done: @convention(block) (JSValue) -> Void = { v in print("result:", v.toString()!); finished = true }
let failed: @convention(block) (JSValue) -> Void = { e in print("rejected:", e.toString()!, e.objectForKeyedSubscript("stack")?.toString() ?? ""); finished = true }
promise.invokeMethod("then", withArguments: [unsafeBitCast(done, to: AnyObject.self), unsafeBitCast(failed, to: AnyObject.self)])
let deadline = Date().addingTimeInterval(120)
while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
print(String(format: "load %.0f ms, total %.2f s, %d HTTP requests, %d bytes streamed", loaded * 1000, Date().timeIntervalSince(t0), bridge.requests, bridge.bytes))
exit(finished ? 0 : 1)

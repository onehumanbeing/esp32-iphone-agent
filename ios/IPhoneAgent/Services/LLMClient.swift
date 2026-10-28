import Foundation

struct ChatResult {
    var text: String
    var firstToken: Double?  // seconds until the first streamed token
    var total: Double
    var finishReason: String?       // "stop", "length" (max tokens hit), …
    var usage: [String: Int] = [:]  // prompt_tokens, completion_tokens, … when the server sends them
    var reasoningChars = 0          // reasoning_content the model wrote (not part of `text`)
    var rawChars = 0                // content before trimming
    var responseSeconds: Double?  // time to HTTP headers, including server queue time
    var retried = false             // the first reply was empty

    /// For the trace and the debug log: why a reply came back empty or cut.
    var diagnostics: JObject {
        var d: JObject = ["finish_reason": .str(finishReason ?? "-"), "reasoning_chars": .int(reasoningChars),
                          "raw_chars": .int(rawChars)]
        if !usage.isEmpty { d["usage"] = .obj(JObject(usage.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) })) }
        if retried { d["retried_empty"] = .bool(true) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reasoningChars > 0 {
            d["note"] = .str("empty content, reasoning only")
        }
        return d
    }
}

/// A chat model the agent can ask (LLMClient, or a fake in tests).
@MainActor protocol ChatModel: AnyObject {
    var model: String { get }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult
}

struct LLMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Client for any OpenAI-compatible chat endpoint (vision models). Port of llm.py, with streaming:
/// Cloudflare cuts requests that send nothing for ~100 s, so replies are streamed (SSE). A server that
/// ignores `stream` and answers with plain JSON works too.
@MainActor final class LLMClient: ChatModel, ModelProgressReporting {
    var onProgress: ((ModelResponseProgress) -> Void)?
    static let tokenParams = ["max_tokens", "max_completion_tokens"]

    let model: String
    let baseURL: URL
    private let apiKey: String
    private let extra: [String: Any]
    private(set) var tokenParam: String
    private var auto: Bool
    // some reasoning models allow only their default temperature; drop it for good once the server says so
    private var sendsTemperature = true
    private let session: URLSession

    init(baseURL: String, model: String, apiKey: String = "", extra: [String: Any] = [:],
         tokenParam: String = "auto", session: URLSession? = nil) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = URL(string: trimmed) ?? URL(string: "http://invalid")!
        self.model = model
        self.apiKey = apiKey
        self.extra = extra
        // "auto": send max_tokens; switch for good if the server asks for max_completion_tokens
        if Self.tokenParams.contains(tokenParam) { (self.tokenParam, auto) = (tokenParam, false) }
        else { (self.tokenParam, auto) = ("max_tokens", true) }
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30  // no byte for this long = hung; the agent retries
            config.timeoutIntervalForResource = 90
            return URLSession(configuration: config)
        }()
    }

    func chat(system: String, text: String, image: Data? = nil, maxTokens: Int = 600,
              temperature: Double = 0) async throws -> ChatResult {
        try await chat(system: system, text: text, images: image.map { [$0] } ?? [], maxTokens: maxTokens,
                       temperature: temperature)
    }

    /// Several screenshots in order (a demonstration's keyframes), then the text. An empty reply is asked once more.
    func chat(system: String, text: String, images: [Data], maxTokens: Int = 600,
              temperature: Double = 0) async throws -> ChatResult {
        let first = try await once(system: system, text: text, images: images, maxTokens: maxTokens, temperature: temperature)
        guard first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return first }
        DebugLog.write("llm: empty reply (finish \(first.finishReason ?? "-"), reasoning \(first.reasoningChars) chars); asking once more")
        var again = try await once(system: system, text: text, images: images, maxTokens: maxTokens, temperature: temperature)
        again.retried = true
        again.total += first.total
        return again
    }

    private func once(system: String, text: String, images: [Data], maxTokens: Int,
                      temperature: Double) async throws -> ChatResult {
        onProgress?(.waiting)
        var content: [[String: Any]] = images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        var body: [String: Any] = ["model": model]
        if sendsTemperature { body["temperature"] = temperature }
        extra.forEach { body[$0.key] = $0.value }
        body["messages"] = [["role": "system", "content": system], ["role": "user", "content": content]]
        body["stream"] = true

        let started = now()
        let kb = images.reduce(0) { $0 + $1.count } / 1024
        DebugLog.write("llm → \(model): \(images.count) image(s) \(kb) KB, \(text.count) chars")
        var status = 0, result: ChatResult?, errorText = ""
        do {
            (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            if status == 400 && auto && errorText.contains("max_completion_tokens") {
                (tokenParam, auto) = ("max_completion_tokens", false)
                (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            }
            if status == 400 && sendsTemperature && errorText.contains("temperature") {
                sendsTemperature = false
                body["temperature"] = nil
                DebugLog.write("llm: \(model) rejects an explicit temperature; retrying without it")
                (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            }
        } catch {
            DebugLog.write(String(format: "llm ✗ %@ after %.1f s: %@", model, now() - started, error.localizedDescription))
            throw error
        }
        guard (200..<300).contains(status), var result else {
            DebugLog.write(String(format: "llm ✗ HTTP %d after %.1f s: %@", status, now() - started, String(errorText.prefix(200))))
            throw LLMError(message: "LLM HTTP \(status): \(errorText.prefix(300))")
        }
        result.total = now() - started
        DebugLog.write(String(format: "llm ← HTTP %d, first token %@, total %.1f s, %d chars", status,
                              result.firstToken.map { String(format: "%.1f s", $0) } ?? "-", result.total, result.text.count)
                       + " " + PyJSON.dumps(.obj(result.diagnostics)))
        return result
    }

    /// The first model id from GET {base}/models.
    static func firstModel(baseURL: String, apiKey: String) async throws -> String {
        guard let id = try await models(baseURL: baseURL, apiKey: apiKey).first else {
            throw LLMError(message: "the endpoint lists no models; type a model id in Settings › Model")
        }
        return id
    }

    /// The model ids from GET {base}/models (OpenAI list format: {"data": [{"id": ...}]}), in the endpoint's order.
    static func models(baseURL: String, apiKey: String) async throws -> [String] {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let base = URL(string: trimmed) else { throw LLMError(message: "invalid base URL") }
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 20)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(message: "GET /models: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return list.compactMap { ($0["id"] ?? $0["name"]) as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func post(_ body: [String: Any], maxTokens: Int, started: Double) async throws
        -> (Int, ChatResult?, String) {
        var body = body
        body[tokenParam] = maxTokens
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let responseSeconds = now() - started
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        DebugLog.write(String(format: "llm   headers: HTTP %d %@ after %.1f s", status, type, now() - started))
        guard (200..<300).contains(status) else {
            var raw = Data()
            for try await b in bytes { raw.append(b) }
            return (status, nil, String(decoding: raw, as: UTF8.self))
        }
        if !type.contains("text/event-stream") {  // a plain JSON answer
            var raw = Data()
            for try await b in bytes { raw.append(b) }
            var result = try Self.message(raw)
            result.responseSeconds = responseSeconds
            if !result.text.isEmpty || result.reasoningChars > 0 { onProgress?(.receiving) }
            return (status, result, "")
        }
        var result = ChatResult(text: "", firstToken: nil, total: 0)
        result.responseSeconds = responseSeconds
        var reportedReceiving = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            try Self.checkError(json)
            let choice = (json["choices"] as? [[String: Any]])?.first
            let delta = choice?["delta"] as? [String: Any]
            Self.note(json, choice, into: &result)
            let reasoning = Self.reasoning(delta)
            if !reportedReceiving, !reasoning.isEmpty || !(delta?["content"] as? String ?? "").isEmpty {
                reportedReceiving = true
                onProgress?(.receiving)
            }
            result.reasoningChars += reasoning.count
            guard let piece = delta?["content"] as? String, !piece.isEmpty else { continue }
            if result.firstToken == nil { result.firstToken = now() - started }
            result.text += piece
        }
        result.rawChars = result.text.count
        return (status, result, "")
    }

    /// choices[0].message of a non-streamed reply.
    static func message(_ raw: Data) throws -> ChatResult {
        let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        if let json { try Self.checkError(json) }
        let choice = (json?["choices"] as? [[String: Any]])?.first
        guard let json, let msg = choice?["message"] as? [String: Any] else {
            throw LLMError(message: "bad LLM reply: \(String(decoding: raw.prefix(200), as: UTF8.self))")
        }
        var result = ChatResult(text: msg["content"] as? String ?? "", firstToken: nil, total: 0)
        note(json, choice, into: &result)
        result.reasoningChars = reasoning(msg).count
        result.rawChars = result.text.count
        return result
    }

    /// Providers can report errors inside an HTTP 200 stream or JSON response.
    private static func checkError(_ json: [String: Any]) throws {
        guard let error = json["error"] else { return }
        let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "Provider error"
        throw LLMError(message: String(message.prefix(300)))
    }

    /// finish_reason and usage, from whichever event carries them.
    private static func note(_ json: [String: Any], _ choice: [String: Any]?, into result: inout ChatResult) {
        if let reason = choice?["finish_reason"] as? String { result.finishReason = reason }
        if let usage = json["usage"] as? [String: Any] { result.usage = usage.compactMapValues { $0 as? Int } }
    }

    /// Reasoning text (vLLM/DeepSeek `reasoning_content`, others `reasoning`).
    private static func reasoning(_ part: [String: Any]?) -> String {
        part?["reasoning_content"] as? String ?? part?["reasoning"] as? String ?? ""
    }
}

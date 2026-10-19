import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The screen as sent to the model: at most 540 px wide, JPEG 0.6. Upload is the slow part of a step
/// (2026-10-17: a 153 KB home screen took ~6-9 s through the tunnel, the model itself 1.4 s), and the
/// model answers in 0-1000 coordinates, so a smaller image keeps taps where they were.
enum ModelImage {
    static let maxWidth = 540, quality = 0.6
    /// Settings › Model › Advanced; on unless turned off.
    static let key = "shrinkModelImage"
    static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The copy for the model: shrunk, or the full frame with the setting off.
    static func forModel(_ jpeg: Data) -> Data { on ? shrink(jpeg) : jpeg }

    static func shrink(_ jpeg: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return jpeg }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height) * min(maxWidth, width) / width]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return jpeg }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return jpeg }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length < jpeg.count else { return jpeg }
        return out as Data
    }
}

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
    var servedModel: String?        // the model that answered (e.g. the one openrouter/free picked)

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
    var status = 0  // the HTTP status, when the server answered with an error
    var kind: String?  // for usage stats, e.g. "rate_limit_day"
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
    private let headers: (() throws -> [String: String])?  // extra per-request headers (e.g. the free line's lease)
    private(set) var tokenParam: String
    private var auto: Bool
    private let session: URLSession
    private var retryAfter: Double?  // seconds, from the last response's Retry-After header

    /// Local diagnostics identify the destination without credentials, path or query parameters.
    private var endpointOrigin: String {
        var origin = URLComponents()
        origin.scheme = baseURL.scheme
        origin.host = baseURL.host
        origin.port = baseURL.port
        return origin.string ?? "<invalid>"
    }

    init(baseURL: String, model: String, apiKey: String = "", extra: [String: Any] = [:],
         tokenParam: String = "auto", session: URLSession? = nil, headers: (() throws -> [String: String])? = nil) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = URL(string: trimmed) ?? URL(string: "http://invalid")!
        self.model = model
        self.apiKey = apiKey
        self.extra = extra
        self.headers = headers
        // "auto": send max_tokens; switch for good if the server asks for max_completion_tokens
        if Self.tokenParams.contains(tokenParam) { (self.tokenParam, auto) = (tokenParam, false) }
        else { (self.tokenParam, auto) = ("max_tokens", true) }
        let slow = self.baseURL.host?.hasSuffix("openrouter.ai") == true  // free models queue and route
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = slow ? 60 : 30  // no byte for this long = hung; the agent retries
            config.timeoutIntervalForResource = slow ? 180 : 90
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
        var body: [String: Any] = ["model": model, "temperature": temperature]
        extra.forEach { body[$0.key] = $0.value }
        body["messages"] = [["role": "system", "content": system], ["role": "user", "content": content]]
        body["stream"] = true

        let started = now()
        let kb = images.reduce(0) { $0 + $1.count } / 1024
        DebugLog.write("llm → \(model) @ \(endpointOrigin): \(images.count) image(s) \(kb) KB, \(text.count) chars")
        var status = 0, result: ChatResult?, errorText = ""
        do {
            (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            if status == 400 && auto && errorText.contains("max_completion_tokens") {
                (tokenParam, auto) = ("max_completion_tokens", false)
                (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            }
            // A busy upstream: once more. A per-minute rate limit: wait as told (Retry-After, at most 20 s), up
            // to twice. A daily quota (OpenRouter free models): retrying can't help, so say so plainly.
            for attempt in 0..<2 where [429, 502, 503, 504].contains(status) {
                if status == 429 && Self.dailyLimit(errorText) { break }
                if status != 429 && attempt > 0 { break }
                let wait = status == 429 ? min(retryAfter ?? 5, 20) : 3
                DebugLog.write(String(format: "llm: HTTP %d, retrying in %.0f s", status, wait))
                try await Task.sleep(for: .seconds(wait))
                (status, result, errorText) = try await post(body, maxTokens: maxTokens, started: started)
            }
        } catch {
            DebugLog.write(String(format: "llm ✗ %@ after %.1f s: %@", model, now() - started, error.localizedDescription))
            throw error
        }
        guard (200..<300).contains(status), var result else {
            DebugLog.write(String(format: "llm ✗ HTTP %d after %.1f s: %@", status, now() - started, String(errorText.prefix(200))))
            if status == 429 { throw Self.rateLimitError(errorText, openRouter: baseURL.host?.hasSuffix("openrouter.ai") == true) }
            throw LLMError(message: "LLM HTTP \(status): \(errorText.prefix(300))", status: status)
        }
        result.total = now() - started
        DebugLog.write(String(format: "llm ← HTTP %d, first token %@, total %.1f s, %d chars", status,
                              result.firstToken.map { String(format: "%.1f s", $0) } ?? "-", result.total, result.text.count)
                       + " " + PyJSON.dumps(.obj(result.diagnostics)))
        return result
    }

    /// OpenRouter's daily free-model quota ("free-models-per-day"), as opposed to the per-minute limit.
    static func dailyLimit(_ errorText: String) -> Bool {
        let t = errorText.lowercased()
        return t.contains("per-day") || t.contains("per day") || t.contains("daily")
    }

    static func rateLimitError(_ errorText: String, openRouter: Bool) -> LLMError {
        if dailyLimit(errorText) {
            return LLMError(message: openRouter
                ? String(localized: "Today's OpenRouter free-model requests are used up (50 a day, 1,000 after you buy $10 of credits). Try again tomorrow or choose a paid model.")
                : String(localized: "The AI service's daily limit is used up. Try again tomorrow or choose another model."),
                status: 429, kind: "rate_limit_day")
        }
        return LLMError(message: openRouter
            ? String(localized: "OpenRouter's free models allow about 20 requests a minute and the limit was hit. Wait a minute and try again, or choose a paid model.")
            : String(localized: "The AI service is rate-limiting requests. Wait a minute and try again."),
            status: 429, kind: "rate_limit_minute")
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
        var seen = Set<String>()
        return try await listing(baseURL: baseURL, apiKey: apiKey).compactMap { ($0["id"] ?? $0["name"]) as? String }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// OpenRouter's models that read images and answer in text (no music or image generators, no safety
    /// classifiers), and which of them are free. `openrouter/auto` is listed as image output, so it is added.
    static func openRouterModels(apiKey: String) async throws -> (ids: [String], free: Set<String>) {
        var ids = ["openrouter/auto"], free = Set<String>()
        for m in try await listing(baseURL: ModelProvider.openRouter.baseURL, apiKey: apiKey) {
            guard let id = m["id"] as? String, !ids.contains(id),
                  !id.contains("guard"), !id.contains("content-safety") else { continue }
            let arch = m["architecture"] as? [String: Any]
            guard (arch?["input_modalities"] as? [String])?.contains("image") == true,
                  arch?["output_modalities"] as? [String] == ["text"] else { continue }
            let price = m["pricing"] as? [String: Any]
            let zero = ["prompt", "completion"].allSatisfy { Double(price?[$0] as? String ?? "") == 0 }
            if zero || id.hasSuffix(":free") { free.insert(id) }
            ids.append(id)
        }
        return (ids, free)
    }

    private static func listing(baseURL: String, apiKey: String) async throws -> [[String: Any]] {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let base = URL(string: trimmed) else { throw LLMError(message: "invalid base URL") }
        try AIConsent.check(trimmed)
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 20)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(message: "GET /models: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
    }

    private func post(_ body: [String: Any], maxTokens: Int, started: Double) async throws
        -> (Int, ChatResult?, String) {
        try AIConsent.check(baseURL.absoluteString)
        var body = body
        body[tokenParam] = maxTokens
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in try headers?() ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        retryAfter = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
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
        if let model = json["model"] as? String, !model.isEmpty { result.servedModel = model }
    }

    /// Reasoning text (vLLM/DeepSeek `reasoning_content`, others `reasoning`).
    private static func reasoning(_ part: [String: Any]?) -> String {
        part?["reasoning_content"] as? String ?? part?["reasoning"] as? String ?? ""
    }
}

import Foundation

/// The Responses API, for ChatGPT sign-in (the Codex endpoint speaks only this): the same call as chat/completions,
/// in its request shape and its streamed events. The Codex endpoint refuses temperature and an output limit, and
/// needs store=false and a stream.
extension LLMClient {
    var speaksResponses: Bool { baseURL.host?.lowercased() == "chatgpt.com" }

    static func responsesBody(model: String, system: String, text: String, images: [Data], extra: [String: Any]) -> [String: Any] {
        var content: [[String: Any]] = images.map {
            ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString()]
        }
        content.append(["type": "input_text", "text": text])
        var body: [String: Any] = ["model": model, "instructions": system,
                                   "reasoning": ["effort": "low"]]  // a step is a quick look; Extra body can raise it
        extra.forEach { body[$0.key] = $0.value }
        body["input"] = [["type": "message", "role": "user", "content": content]]
        body["store"] = false
        body["stream"] = true
        return body
    }

    /// What one streamed event adds: text, reasoning, the end. Errors inside the stream throw.
    struct ResponsesEvent {
        var text = ""
        var reasoning = ""
        var done = false
    }

    nonisolated static func responsesEvent(_ json: [String: Any], into result: inout ChatResult) throws -> ResponsesEvent {
        var event = ResponsesEvent()
        switch json["type"] as? String ?? "" {
        case "response.output_text.delta":
            event.text = json["delta"] as? String ?? ""
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            event.reasoning = json["delta"] as? String ?? ""
        case "response.completed", "response.incomplete":
            let response = json["response"] as? [String: Any]
            let incomplete = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
            result.finishReason = incomplete == "max_output_tokens" ? "length" : incomplete ?? "stop"
            if let usage = response?["usage"] as? [String: Any] { result.usage = usage.compactMapValues { $0 as? Int } }
            if let model = response?["model"] as? String, !model.isEmpty { result.servedModel = model }
            event.done = true
        case "response.failed", "error":
            let error = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
            let message = error["message"] as? String ?? "ChatGPT returned an error"
            throw LLMError(message: String(message.prefix(300)), reason: (error["code"] as? String) ?? "stream_error")
        default: break
        }
        return event
    }

    /// The plan's usage limit is reached (HTTP 429, error type usage_limit_reached): final until it resets.
    static func chatGPTLimitError(_ errorText: String) -> LLMError? {
        let json = (try? JSONSerialization.jsonObject(with: Data(errorText.utf8))) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        guard error?["type"] as? String == "usage_limit_reached" || errorText.contains("usage_limit_reached") else { return nil }
        let resets = (error?["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? (error?["resets_in_seconds"] as? Double).map { Date().addingTimeInterval($0) }
        let message = resets.map {
            String(localized: "Your ChatGPT plan's usage limit is reached. It resets at \($0.formatted(date: .omitted, time: .shortened)).")
        } ?? String(localized: "Your ChatGPT plan's usage limit is reached. Try again later.")
        return LLMError(message: message, status: 429, kind: "chatgpt_limit")
    }
}

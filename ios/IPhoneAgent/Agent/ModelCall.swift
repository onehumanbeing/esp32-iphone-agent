import Foundation

/// One model request, for usage stats: timing, token counts and which model answered. Never the prompt,
/// the screenshot or the reply.
struct ModelCall {
    let role: String
    let model: String
    let reply: ChatResult?
    let error: Error?
    let imageKB: Int

    var props: [String: Any] {
        var p: [String: Any] = ["role": role, "model": model, "ok": reply != nil, "image_kb": imageKB]
        if let error { p["error"] = ModelRequestFailure.kind(error) }
        guard let r = reply else { return p }
        p["total_s"] = Self.round(r.total)
        if let s = r.firstToken { p["first_token_s"] = Self.round(s) }
        if let s = r.responseSeconds { p["response_s"] = Self.round(s) }
        if let n = r.usage["prompt_tokens"] { p["prompt_tokens"] = n }
        if let n = r.usage["completion_tokens"] { p["completion_tokens"] = n }
        if r.reasoningChars > 0 { p["reasoning_chars"] = r.reasoningChars }
        if let f = r.finishReason { p["finish_reason"] = f }
        if r.retried { p["retried_empty"] = true }
        if let m = r.servedModel { p["served_model"] = m }
        return p
    }

    private static func round(_ s: Double) -> Double { (s * 100).rounded() / 100 }
}

/// A run's model requests added up, for "run_ended".
struct ModelUsage {
    private(set) var calls = 0, failures = 0, promptTokens = 0, completionTokens = 0
    private var seconds = 0.0

    mutating func add(_ call: ModelCall) {
        calls += 1
        guard let r = call.reply else { failures += 1; return }
        seconds += r.total
        promptTokens += r.usage["prompt_tokens"] ?? 0
        completionTokens += r.usage["completion_tokens"] ?? 0
    }

    var props: [String: Any] {
        var p: [String: Any] = ["model_calls": calls, "model_failures": failures,
                                "prompt_tokens": promptTokens, "completion_tokens": completionTokens]
        if calls > failures { p["avg_total_s"] = (seconds / Double(calls - failures) * 100).rounded() / 100 }
        return p
    }
}

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
        if let reason = (error as? LLMError)?.reason { p["error_reason"] = reason }  // e.g. the free line's refusal
        guard let r = reply else { return p }
        p["total_s"] = Self.round(r.total)
        if let s = r.firstToken { p["first_token_s"] = Self.round(s) }
        if let s = r.responseSeconds { p["response_s"] = Self.round(s) }
        // Omit token fields when the provider sent no usage — never coerce missing to 0.
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
    private(set) var calls = 0, failures = 0
    private(set) var plannerCalls = 0, actorCalls = 0
    private(set) var imageRequests = 0  // requests that carried a screenshot, failed and retried ones included
    private(set) var promptTokens = 0, completionTokens = 0
    private var totalOnly = 0  // from calls that sent only total_tokens
    /// Some call reported usage. Without any, the token fields stay out: missing is never sent as 0.
    private(set) var reported = false
    /// True when a successful call omitted usage (or a side of it). Sums then understate the run.
    private(set) var usagePartial = false
    private var seconds = 0.0

    var tokens: Int { promptTokens + completionTokens + totalOnly }

    mutating func add(_ call: ModelCall) {
        calls += 1
        switch call.role {
        case "planner": plannerCalls += 1
        case "actor": actorCalls += 1
        default: break
        }
        if call.imageKB > 0 { imageRequests += 1 }
        guard let r = call.reply else { failures += 1; return }
        seconds += r.total
        let prompt = r.usage["prompt_tokens"], completion = r.usage["completion_tokens"]
        if prompt == nil && completion == nil {
            // as Run.load reads a trace: a total alone still counts
            if let t = r.usage["total_tokens"] { totalOnly += t; reported = true } else { usagePartial = true }
            return
        }
        reported = true
        if let p = prompt { promptTokens += p } else { usagePartial = true }
        if let c = completion { completionTokens += c } else { usagePartial = true }
    }

    var props: [String: Any] {
        var p: [String: Any] = ["model_calls": calls, "model_failures": failures, "planner_calls": plannerCalls,
                                "actor_calls": actorCalls, "image_requests": imageRequests]
        if reported {
            p["prompt_tokens"] = promptTokens
            p["completion_tokens"] = completionTokens
            p["total_tokens"] = tokens
            p["usage_partial"] = usagePartial
        }
        if calls > failures { p["avg_total_s"] = (seconds / Double(calls - failures) * 100).rounded() / 100 }
        return p
    }

    /// One DebugLog line: planner/actor/image requests, plus tokens when any call reported them.
    var summaryLine: String {
        var parts = ["planner \(plannerCalls)", "actor \(actorCalls)", "images \(imageRequests)"]
        if reported {
            parts.append(totalOnly > 0 ? "tokens \(Self.compact(tokens))"
                                       : "tokens \(Self.compact(promptTokens)) in / \(Self.compact(completionTokens)) out")
            if usagePartial { parts.append("partial") }
        }
        return parts.joined(separator: " · ")
    }

    private static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

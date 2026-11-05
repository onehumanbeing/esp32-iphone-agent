import Foundation

/// A vision model measured with the app's own actor prompt (handsy-benchmark r1, 2026-10), with the request
/// parameters it was measured with (thinking off).
struct TestedModel: Equatable {
    let id: String
    var extraBody = "{}"
    var recommended = false
}

/// Per provider, best first. Only models that scored usable on real screens are listed.
enum TestedModels {
    private static let noReasoning = #"{"reasoning": {"enabled": false}}"#
    private static let noTemplateThinking = #"{"chat_template_kwargs": {"enable_thinking": false}}"#

    static func list(for provider: ModelProvider) -> [TestedModel] {
        switch provider {
        case .qwen:
            return [TestedModel(id: "qwen3.8-flash", extraBody: #"{"enable_thinking": false}"#, recommended: true)]
        case .gemini:
            return [TestedModel(id: "gemini-3.8-flash", extraBody: #"{"reasoning_effort": "none"}"#, recommended: true),
                    TestedModel(id: "gemini-3.5-flash-lite", extraBody: #"{"reasoning_effort": "minimal"}"#)]
        case .openRouter:
            return ["qwen/qwen3.8-flash", "z-ai/glm-4.5v", "qwen/qwen3.8-27b", "qwen/qwen3.6-35b-a3b", "qwen/qwen3.5-35b-a3b"]
                .map { TestedModel(id: $0, extraBody: noReasoning) }
                + ["google/gemma-4-26b-a4b-it", "qwen/qwen3-vl-30b-a3b-instruct", "qwen/qwen3-vl-8b-instruct"]
                .map { TestedModel(id: $0) }
        case .nvidia:
            return ["nvidia/nemotron-3.5-super-vl-120b-a12b", "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"]
                .map { TestedModel(id: $0, extraBody: noTemplateThinking) }
        case .nebius:
            return [TestedModel(id: "nvidia/Nemotron-3.5-Super-VL", extraBody: noTemplateThinking),
                    TestedModel(id: "openbmb/MiniCPM-V-4_5")]
        case .hCompany:
            return ["holo4-35b-a3b", "holo3-1-35b-a3b"].map { TestedModel(id: $0, extraBody: noTemplateThinking) }
        case .zhipu:
            return [TestedModel(id: "glm-4.6v-flash", extraBody: #"{"thinking": {"type": "disabled"}}"#),
                    TestedModel(id: "glm-4.1v-thinking-flash")]
        case .handsyTrial:  // free line
            return [TestedModel(id: Trial.model)]
        case .openAI, .qwenInternational, .deepSeek, .others:
            return []
        }
    }

    static func find(_ id: String, for provider: ModelProvider) -> TestedModel? {
        list(for: provider).first { $0.id == id }
    }
}

import Foundation

/// Presets only configure public endpoints. Users always supply their own credentials.
enum ModelProvider: String, CaseIterable, Identifiable {
    case openAI, gemini, qwen, qwenInternational, deepSeek, openRouter, requesty, others
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .qwen: return "Qwen · China"
        case .qwenInternational: return "Qwen · International"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .requesty: return "Requesty"
        case .others: return "Others"
        }
    }
    var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .requesty: return "https://router.requesty.ai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .qwenInternational: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .others: return ""
        }
    }
    var keyURL: URL? {
        let address: String
        switch self {
        case .openRouter: address = "https://openrouter.ai/settings/keys"
        case .requesty: address = "https://app.requesty.ai/api-keys"
        case .openAI: address = "https://platform.openai.com/api-keys"
        case .gemini: address = "https://aistudio.google.com/apikey"
        case .qwen: address = "https://bailian.console.aliyun.com/"
        case .qwenInternational: address = "https://modelstudio.console.alibabacloud.com/"
        case .deepSeek: address = "https://platform.deepseek.com/api_keys"
        case .others: return nil
        }
        return URL(string: address)
    }
    static func infer(baseURL: String, model: String) -> Self {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base == openRouter.baseURL { return .openRouter }
        return allCases.first { $0 != .others && $0.baseURL == base } ?? .others
    }
}


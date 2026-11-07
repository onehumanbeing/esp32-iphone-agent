import Foundation

/// Presets only configure public endpoints. Users always supply their own credentials.
enum ModelProvider: String, CaseIterable, Identifiable {
    case openAI, gemini, qwen, qwenInternational, deepSeek, openRouter, nvidia, nebius, hCompany, zhipu, others
    case handsyTrial  // free line (Trial/); listed only in builds that have it
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .qwen: return "Qwen"
        case .qwenInternational: return "Qwen · International"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .nvidia: return "NVIDIA"
        case .nebius: return "Nebius"
        case .hCompany: return "H Company"
        case .zhipu: return "Zhipu GLM"
        case .others: return "Others"
        case .handsyTrial: return "Handsy Free"
        }
    }
    var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .qwenInternational: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .nvidia: return "https://integrate.api.nvidia.com/v1"
        case .nebius: return "https://api.tokenfactory.nebius.com/v1"
        case .hCompany: return "https://api.hcompany.ai/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .others: return ""
        case .handsyTrial: return Trial.baseURL
        }
    }
    var keyURL: URL? {
        let address: String
        switch self {
        case .openRouter: address = "https://openrouter.ai/settings/keys"
        case .openAI: address = "https://platform.openai.com/api-keys"
        case .gemini: address = "https://aistudio.google.com/apikey"
        case .qwen: address = "https://bailian.console.aliyun.com/"
        case .qwenInternational: address = "https://modelstudio.console.alibabacloud.com/"
        case .deepSeek: address = "https://platform.deepseek.com/api_keys"
        case .nvidia: address = "https://build.nvidia.com/settings/api-keys"
        case .nebius: address = "https://tokenfactory.nebius.com/"
        case .hCompany: address = "https://hub.hcompany.ai/"
        case .zhipu: address = "https://open.bigmodel.cn/usercenter/apikeys"
        case .others, .handsyTrial: return nil
        }
        return URL(string: address)
    }
    /// Monochrome mark for the provider list: an asset (Simple Icons), else a letter.
    enum Logo { case asset(String), letter(String), symbol(String) }
    var logo: Logo {
        switch self {
        case .openAI: return .asset("OpenAILogo")
        case .gemini: return .asset("GeminiLogo")
        case .qwen, .qwenInternational: return .asset("QwenLogo")
        case .deepSeek: return .asset("DeepSeekLogo")
        case .openRouter: return .asset("OpenRouterLogo")
        case .nvidia: return .asset("NVIDIALogo")
        case .nebius: return .asset("NebiusLogo")
        case .hCompany: return .asset("HCompanyLogo")
        case .zhipu: return .asset("ZhipuLogo")
        case .others: return .symbol("server.rack")
        case .handsyTrial: return .symbol("gift")
        }
    }
    /// Shown first in the provider list (their tested model is preselected).
    var recommended: Bool { TestedModels.list(for: self).contains { $0.recommended } }
    var host: String { URL(string: baseURL)?.host ?? "" }
    static func infer(baseURL: String, model: String) -> Self {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base == openRouter.baseURL { return .openRouter }
        return allCases.first { $0 != .others && $0 != .handsyTrial && $0.baseURL == base } ?? .others
    }
}


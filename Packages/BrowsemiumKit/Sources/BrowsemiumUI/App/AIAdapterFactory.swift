import BrowsemiumAI
import BrowsemiumCore

/// The one place that turns a provider id + credential into an adapter, so a
/// provider's request shape is defined exactly once.
public enum AIAdapterFactory {
    public static func make(for provider: AIProviderID, credential: String) -> any AIProviderAdapter {
        switch provider {
        case .openAI:
            OpenAIAdapter(credential: credential)
        case .anthropic:
            AnthropicAdapter(credential: credential)
        case .gemini:
            GeminiAdapter(credential: credential)
        case .xAI:
            XAIAdapter(credential: credential)
        case .ollama:
            OllamaAdapter()
        case .vercelV0:
            V0Adapter(credential: credential)
        }
    }
}

import BrowsemiumCore
import Foundation

public struct ProviderPanelDescriptor: Sendable, Identifiable {
    public enum PrefillReliability: String, Sendable {
        case documented
        case community
        case unsupported
    }

    public let id: AIProviderID
    public let displayName: String
    public let baseURL: URL
    public let newConversationURL: URL
    public let queryParameter: String?
    public let maximumQueryCharacters: Int
    public let prefillReliability: PrefillReliability
    public let termsURL: URL
    public let privacyURL: URL

    /// Only these HTTPS hosts may receive Browsemium's composer bridge.
    /// Provider pages can navigate within their own subdomains, but the bridge
    /// is never enabled on an unrelated origin.
    public var trustedHosts: [String] {
        guard let host = baseURL.host?.lowercased() else { return [] }
        return [host]
    }

    public func trusts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return trustedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    public static let chatGPT = ProviderPanelDescriptor(
        id: .openAI,
        displayName: "ChatGPT",
        baseURL: URL(string: "https://chatgpt.com")!,
        newConversationURL: URL(string: "https://chatgpt.com/")!,
        queryParameter: "q",
        maximumQueryCharacters: 6000,
        prefillReliability: .documented,
        termsURL: URL(string: "https://openai.com/policies/terms-of-use")!,
        privacyURL: URL(string: "https://openai.com/policies/privacy-policy")!
    )

    public static let claude = ProviderPanelDescriptor(
        id: .anthropic,
        displayName: "Claude",
        baseURL: URL(string: "https://claude.ai")!,
        newConversationURL: URL(string: "https://claude.ai/new")!,
        queryParameter: "q",
        maximumQueryCharacters: 6000,
        prefillReliability: .documented,
        termsURL: URL(string: "https://www.anthropic.com/legal/consumer-terms")!,
        privacyURL: URL(string: "https://www.anthropic.com/legal/privacy")!
    )

    public static let gemini = ProviderPanelDescriptor(
        id: .gemini,
        displayName: "Gemini",
        baseURL: URL(string: "https://gemini.google.com")!,
        newConversationURL: URL(string: "https://gemini.google.com/app")!,
        queryParameter: nil,
        maximumQueryCharacters: 0,
        prefillReliability: .unsupported,
        termsURL: URL(string: "https://policies.google.com/terms")!,
        privacyURL: URL(string: "https://policies.google.com/privacy")!
    )

    public static let grok = ProviderPanelDescriptor(
        id: .xAI,
        displayName: "Grok",
        baseURL: URL(string: "https://grok.com")!,
        newConversationURL: URL(string: "https://grok.com/")!,
        queryParameter: "q",
        maximumQueryCharacters: 2000,
        prefillReliability: .community,
        termsURL: URL(string: "https://x.ai/legal/terms-of-service")!,
        privacyURL: URL(string: "https://x.ai/legal/privacy-policy")!
    )

    public static let ollama = ProviderPanelDescriptor(
        id: .ollama,
        displayName: "Ollama (local)",
        baseURL: URL(string: "http://localhost:11434")!,
        newConversationURL: URL(string: "http://localhost:11434")!,
        queryParameter: nil,
        maximumQueryCharacters: 0,
        prefillReliability: .unsupported,
        termsURL: URL(string: "https://ollama.com/")!,
        privacyURL: URL(string: "https://ollama.com/")!
    )

    public static let all: [ProviderPanelDescriptor] = [.chatGPT, .claude, .gemini, .grok, .ollama]

    public static func descriptor(for provider: AIProviderID) -> ProviderPanelDescriptor {
        all.first { $0.id == provider } ?? .chatGPT
    }

    public func prefillURL(prompt: String) -> URL? {
        guard let queryParameter,
              prefillReliability != .unsupported,
              prompt.count <= maximumQueryCharacters else {
            return nil
        }
        guard var components = URLComponents(url: newConversationURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: queryParameter, value: prompt))
        components.queryItems = items
        return components.url
    }
}

import BrowsemiumCore
import Foundation

public struct ProviderHandoff: Sendable {
    public enum Method: Sendable, Equatable {
        case prefilledURL(URL)
        case clipboardOnly
    }

    public let provider: AIProviderID
    public let method: Method
    public let prompt: String
    public let note: String?
    public let includesImage: Bool
}

public struct ProviderHandoffBuilder: Sendable {
    public var policy: AIContextPolicy

    public init(policy: AIContextPolicy = AIContextPolicy()) {
        self.policy = policy
    }

    public func makeHandoff(
        provider: AIProviderID,
        userPrompt: String,
        attachments: [AIContextAttachment]
    ) -> ProviderHandoff {
        let descriptor = ProviderPanelDescriptor.descriptor(for: provider)
        let prompt = AIRequestBuilder.composePrompt(
            userPrompt: userPrompt,
            attachments: attachments,
            policy: policy
        )

        let includesImage = attachments.contains { attachment in
            if case .viewportImage = attachment { return true }
            return false
        }
        let imageNote = includesImage
            ? " Screenshots cannot travel through a link; copy the image and attach it in the panel."
            : ""

        if let url = descriptor.prefillURL(prompt: prompt) {
            let note: String?
            if descriptor.prefillReliability == .community {
                note = "\(descriptor.displayName) does not officially support prompt links. If the prompt does not appear, use Copy and paste it yourself." + imageNote
            } else if includesImage {
                note = imageNote.trimmingCharacters(in: .whitespaces)
            } else {
                note = nil
            }
            return ProviderHandoff(
                provider: provider,
                method: .prefilledURL(url),
                prompt: prompt,
                note: note,
                includesImage: includesImage
            )
        }

        let note: String
        if descriptor.prefillReliability == .unsupported {
            note = "\(descriptor.displayName) does not accept a prompt through a link. Copy the context, paste it into the panel, and press Send there." + imageNote
        } else {
            note = "This context is longer than \(descriptor.displayName) accepts through a link. Copy it, paste it into the panel, and press Send there." + imageNote
        }
        return ProviderHandoff(
            provider: provider,
            method: .clipboardOnly,
            prompt: prompt,
            note: note,
            includesImage: includesImage
        )
    }
}

import BrowsemiumCore
import Foundation

/// Why Apple's on-device model cannot answer right now, in words a person
/// can act on.
public enum AppleIntelligenceUnavailable: Error, Equatable, Sendable, LocalizedError {
    case osTooOld
    case frameworkMissing
    case deviceNotEligible
    case notEnabled
    case modelNotReady

    public var errorDescription: String? {
        switch self {
        case .osTooOld:
            "Apple Intelligence needs macOS 26 or newer."
        case .frameworkMissing:
            "This build of Browsemium was made without Apple's on-device model."
        case .deviceNotEligible:
            "This Mac does not support Apple Intelligence."
        case .notEnabled:
            "Turn on Apple Intelligence in System Settings, then try again."
        case .modelNotReady:
            "Apple Intelligence is still preparing its model. Try again in a few minutes."
        }
    }
}

/// The entry point the app uses. It hides the availability and compile-time
/// gating, so callers just get an adapter that works or explains itself.
public enum AppleIntelligence {
    public static let modelID = "apple.on-device"
    public static let modelName = "Apple Intelligence (on this Mac)"

    public static func makeAdapter() -> any AIProviderAdapter {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleIntelligenceAdapter()
        }
        return UnavailableAppleIntelligenceAdapter(reason: .osTooOld)
        #else
        return UnavailableAppleIntelligenceAdapter(reason: .frameworkMissing)
        #endif
    }
}

/// Stands in where the real adapter cannot exist, so every code path still
/// has an adapter and reports the same plain reason.
struct UnavailableAppleIntelligenceAdapter: AIProviderAdapter {
    let reason: AppleIntelligenceUnavailable
    let id: AIProviderID = .appleIntelligence

    func validateCredential() async throws { throw reason }
    func listModels() async throws -> [AIModel] { throw reason }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: reason) }
    }
}

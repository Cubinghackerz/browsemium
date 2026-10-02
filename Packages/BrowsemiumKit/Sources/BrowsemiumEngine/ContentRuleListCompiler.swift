import Foundation
import WebKit

/// Injectable boundary; fixture compilers can suspend or fail without networking.
@MainActor public protocol ContentRuleListCompiling {
    func compile(identifier: String, rulesJSON: String) async throws -> WKContentRuleList
}

@MainActor public struct WebKitContentRuleListCompiler: ContentRuleListCompiling {
    public init() {}

    public func compile(identifier: String, rulesJSON: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw ContentRuleListManager.UserRuleError.compilationFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rulesJSON) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: ContentRuleListManager.UserRuleError.compilationFailed) }
            }
        }
    }
}

/// Only its manager can create a receipt. Compiling is not installation or a
/// database commit; the caller must finish its last-good transaction first.
@MainActor public struct CompiledUserContentRules {
    public var identifier: String { list.identifier }
    let owner: UUID
    let generation: UUID
    let list: WKContentRuleList
    let ruleCount: Int
    let byteCount: Int

    init(owner: UUID, generation: UUID, list: WKContentRuleList, ruleCount: Int, byteCount: Int) {
        self.owner = owner
        self.generation = generation
        self.list = list
        self.ruleCount = ruleCount
        self.byteCount = byteCount
    }
}

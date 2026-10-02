import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation
import WebKit

/// Compiles and caches the WebKit content rule list used to block ads and
/// trackers.
///
/// WebKit is the only thing that can enforce these rules, and it does not
/// report how many requests it stopped — so Browsemium reports whether rules
/// are active, never a blocked-request count it cannot verify.
@MainActor
public final class ContentRuleListManager {
    public enum State: Sendable, Equatable {
        case inactive
        case compiling
        case active
        case failed(String)
    }

    public private(set) var state: State = .inactive
    public var ruleCount: Int {
        isEnabled ? starterRuleCount + userRules.reduce(0) { $0 + $1.ruleCount } : 0
    }

    /// Fired once the rules become usable, so pages that are already open can
    /// pick them up without waiting for the next tab.
    public var onActivated: (() -> Void)?

    /// The compiled list, once available.
    public var compiledRuleList: WKContentRuleList? { isEnabled ? ruleList : nil }
    public var compiledRuleLists: [WKContentRuleList] {
        guard isEnabled else { return [] }
        return (ruleList.map { [$0] } ?? []) + userRules.map(\.list)
    }
    public var installedUserRuleIdentifiers: [String] { userRules.map(\.identifier) }

    public enum UserRuleError: Error, LocalizedError, Equatable {
        case profileNotSelected, staleCompilation, invalidRuleSet, compilationFailed
        public var errorDescription: String? {
            switch self {
            case .profileNotSelected: "Select a profile before importing filter lists."
            case .staleCompilation: "The profile changed while compiling. Existing rules were not replaced."
            case .invalidRuleSet: "The rules exceed the supported limits or are empty. Existing rules were not replaced."
            case .compilationFailed: "WebKit could not compile the filter list. Existing rules were not replaced."
            }
        }
    }

    private static let identifier = "BrowsemiumStarterRules"
    private var ruleList: WKContentRuleList?
    private var compileTask: Task<Void, Never>?
    private let compiler: any ContentRuleListCompiling
    private let owner = UUID()
    private var userGeneration = UUID()
    private var profileID: UUID?
    private var userRules: [CompiledUserContentRules] = []
    private var starterRuleCount = 0
    private var isEnabled = false
    private var activation = UUID()

    public init(compiler: any ContentRuleListCompiling = WebKitContentRuleListCompiler()) {
        self.compiler = compiler
    }

    /// Invalidates pending receipts and drops only the previous profile's lists.
    public func beginUserProfile(_ profileID: UUID) {
        self.profileID = profileID
        userGeneration = UUID()
        userRules = []
        onActivated?()
    }

    public func compileUserRules(identifier: String, rulesJSON: String) async throws -> CompiledUserContentRules {
        guard profileID != nil else { throw UserRuleError.profileNotSelected }
        try Task.checkCancellation()
        guard rulesJSON.utf8.count <= 16 * 1024 * 1024 else { throw UserRuleError.invalidRuleSet }
        let generation = userGeneration
        let validation = Task.detached(priority: .utility) { Self.countRules(in: rulesJSON) }
        let count = await withTaskCancellationHandler { await validation.value } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        guard generation == userGeneration else { throw UserRuleError.staleCompilation }
        guard count > 0, count <= 50_000 else {
            throw UserRuleError.invalidRuleSet
        }
        let compiled: WKContentRuleList
        do { compiled = try await compiler.compile(identifier: identifier, rulesJSON: rulesJSON) }
        catch {
            try Task.checkCancellation()
            throw UserRuleError.compilationFailed // Do not expose input or compiler error text.
        }
        try Task.checkCancellation()
        guard generation == userGeneration else { throw UserRuleError.staleCompilation }
        guard compiled.identifier == identifier else { throw UserRuleError.compilationFailed }
        return CompiledUserContentRules(owner: owner, generation: generation, list: compiled,
                                        ruleCount: count, byteCount: rulesJSON.utf8.count)
    }

    /// Swap the whole enabled set atomically, after the caller commits metadata.
    public func installUserRules(_ rules: [CompiledUserContentRules]) throws {
        guard rules.allSatisfy({ $0.owner == owner && $0.generation == userGeneration }) else {
            throw UserRuleError.staleCompilation
        }
        guard rules.count <= 10, Set(rules.map(\.identifier)).count == rules.count,
              rules.reduce(0, { $0 + $1.ruleCount }) <= 50_000,
              rules.reduce(0, { $0 + $1.byteCount }) <= 16 * 1024 * 1024 else {
            throw UserRuleError.invalidRuleSet
        }
        userRules = rules
        onActivated?()
    }

    /// Compiles the bundled starter rules once and keeps them cached by WebKit.
    public func activate() {
        if !isEnabled {
            isEnabled = true
            onActivated?()
        }
        guard ruleList == nil, compileTask == nil else { return }
        guard let source = Self.bundledRulesJSON() else {
            state = .failed("The bundled rule set is missing.")
            return
        }

        state = .compiling
        let token = UUID()
        activation = token
        compileTask = Task { [weak self] in
            defer { if self?.activation == token { self?.compileTask = nil } }
            do {
                guard let store = WKContentRuleListStore.default() else {
                    self?.state = .failed("WebKit did not provide a content rule store.")
                    return
                }
                let list: WKContentRuleList = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<WKContentRuleList, Error>) in
                    store.compileContentRuleList(
                        forIdentifier: Self.identifier,
                        encodedContentRuleList: source
                    ) { compiled, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let compiled {
                            continuation.resume(returning: compiled)
                        } else {
                            continuation.resume(
                                throwing: BrowsemiumError.captureFailed("Content rules did not compile.")
                            )
                        }
                    }
                }
                guard !Task.isCancelled, self?.activation == token, self?.isEnabled == true else { return }
                self?.ruleList = list
                self?.starterRuleCount = Self.countRules(in: source)
                self?.state = .active
                self?.onActivated?()
            } catch {
                guard !Task.isCancelled, self?.activation == token else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    public func deactivate() {
        isEnabled = false
        activation = UUID()
        compileTask?.cancel()
        compileTask = nil
        ruleList = nil
        starterRuleCount = 0
        state = .inactive
        onActivated?()
    }

    /// Applies the compiled rules to a web view's configuration.
    public func apply(to configuration: WKWebViewConfiguration) {
        for list in compiledRuleLists { configuration.userContentController.add(list) }
    }

    nonisolated public static func bundledRulesJSON() -> String? {
        guard let url = Bundle.module.url(forResource: "StarterContentRules", withExtension: "json") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    nonisolated public static func countRules(in json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }
        return array.count
    }
}

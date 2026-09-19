import BrowsemiumCore
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
    public private(set) var ruleCount: Int = 0

    private static let identifier = "BrowsemiumStarterRules"
    private var ruleList: WKContentRuleList?
    private var compileTask: Task<Void, Never>?

    public init() {}

    /// Compiles the bundled starter rules once and keeps them cached by WebKit.
    public func activate() {
        guard ruleList == nil, compileTask == nil else { return }
        guard let source = Self.bundledRulesJSON() else {
            state = .failed("The bundled rule set is missing.")
            return
        }

        state = .compiling
        compileTask = Task { [weak self] in
            defer { self?.compileTask = nil }
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
                self?.ruleList = list
                self?.ruleCount = Self.countRules(in: source)
                self?.state = .active
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    public func deactivate() {
        compileTask?.cancel()
        compileTask = nil
        ruleList = nil
        ruleCount = 0
        state = .inactive
    }

    /// Applies the compiled rules to a web view's configuration.
    public func apply(to configuration: WKWebViewConfiguration) {
        guard let ruleList else { return }
        configuration.userContentController.add(ruleList)
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

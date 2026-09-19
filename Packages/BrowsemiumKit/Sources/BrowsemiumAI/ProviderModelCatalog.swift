import BrowsemiumCore
import Foundation

public struct ModelCapabilityCatalog: Sendable {
    public struct Rule: Sendable {
        public let pattern: String
        public let supportsVision: Bool
    }

    public struct ProviderRules: Sendable {
        public let defaultVision: Bool
        public let rules: [Rule]
    }

    private let providers: [AIProviderID: ProviderRules]

    public init(providers: [AIProviderID: ProviderRules]) {
        self.providers = providers
    }

    public func supportsVision(provider: AIProviderID, modelID: String) -> Bool {
        guard let providerRules = providers[provider] else {
            return false
        }
        var result = providerRules.defaultVision
        for rule in providerRules.rules where Glob.matches(pattern: rule.pattern, value: modelID) {
            result = rule.supportsVision
        }
        return result
    }

    public static let bundled: ModelCapabilityCatalog = {
        guard let url = Bundle.module.url(forResource: "ModelCapabilities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? ModelCapabilityCatalog(json: data) else {
            return ModelCapabilityCatalog(providers: [:])
        }
        return catalog
    }()

    public init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let providerEntries = root["providers"] as? [String: Any] else {
            throw AIHTTPClient.HTTPError.invalidResponse
        }

        var providers: [AIProviderID: ProviderRules] = [:]
        for (key, value) in providerEntries {
            guard let providerID = AIProviderID(rawValue: key),
                  let entry = value as? [String: Any] else {
                continue
            }
            let defaultVision = entry["defaultVision"] as? Bool ?? false
            let rawRules = entry["rules"] as? [[String: Any]] ?? []
            let rules = rawRules.compactMap { rule -> Rule? in
                guard let pattern = rule["pattern"] as? String,
                      let vision = rule["vision"] as? Bool else {
                    return nil
                }
                return Rule(pattern: pattern, supportsVision: vision)
            }
            providers[providerID] = ProviderRules(defaultVision: defaultVision, rules: rules)
        }
        self.providers = providers
    }
}

enum Glob {
    static func matches(pattern: String, value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        let regexPattern = "^" + escaped + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}

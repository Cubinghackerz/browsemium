import BrowsemiumCore
import BrowsemiumEngineKit
import Foundation

/// Honest copy from installed list metadata, not rule totals or request events.
enum SiteShieldRuleSummary {
    static func pauseNote(level: ProtectionLevel, isPrivate: Bool) -> String {
        if isPrivate { return "A private window does not remember site exceptions." }
        if !level.blocksContentRules { return "Blocking is already off." }
        return "Pausing turns off the rule lists for this site only. The page reloads."
    }

    static func text(level: ProtectionLevel, state: BlockingState, counts: RuleListHostCounts?,
                     paused: Bool, isPrivate: Bool) -> String {
        let rules: String
        if !level.blocksContentRules || paused {
            rules = "Rules off on this site."
        } else {
            switch state {
            case .inactive: rules = "Rules off on this site."
            case .compiling: rules = "Rule lists are compiling."
            case .failed: rules = "Rule lists could not be compiled. Check Settings."
            case .active:
                if let counts {
                    let bundled = counts.bundledHostCount.formatted(.number.locale(Locale(identifier: "en_US")))
                    rules = "Rule list: \(bundled) \(counts.bundledHostCount == 1 ? "host" : "hosts")" +
                        (counts.userListCount > 0 ? "\nplus \(counts.additionalUserHostCount.formatted(.number.locale(Locale(identifier: "en_US")))) from your lists" : "")
                } else { rules = "Rule lists active. Host count unavailable." }
            }
        }
        return "\(level.title). \(rules)" +
            (isPrivate ? "\nA private window does not remember site exceptions." : "")
    }
}

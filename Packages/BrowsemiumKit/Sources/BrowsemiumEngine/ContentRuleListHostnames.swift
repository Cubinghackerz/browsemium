import Foundation

/// Recognizes only the two hostname encodings emitted by our own generators.
/// Unknown regexes yield no count rather than pretending to know their scope.
enum ContentRuleListHostnames {
    static func namedHosts(in json: String) -> Set<String>? {
        guard let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return nil }
        let prefix = #"^https?://([a-z0-9-]+\.)*"#
        var hosts: Set<String> = []
        for rule in rules {
            let filter = rule.trigger.urlFilter
            if filter.hasPrefix(#"^https?://[^/]+/"#) {
                // Bundled path/script rules do not name any request hostname.
                continue
            }
            guard filter.hasPrefix(prefix) else { return nil }
            let remainder = filter.dropFirst(prefix.count)
            let hostPattern: Substring
            if remainder.hasSuffix("[:/]") { hostPattern = remainder.dropLast(4) }
            else if remainder.hasSuffix("/") { hostPattern = remainder.dropLast() }
            else { return nil }
            let host = hostPattern.replacingOccurrences(of: #"\."#, with: ".").lowercased()
            guard isHostname(host),
                  host.replacingOccurrences(of: ".", with: #"\."#) == hostPattern.lowercased() else { return nil }
            hosts.insert(host)
        }
        return hosts
    }

    private static func isHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private struct Rule: Decodable {
        let trigger: Trigger
        struct Trigger: Decodable {
            let urlFilter: String
            enum CodingKeys: String, CodingKey { case urlFilter = "url-filter" }
        }
    }
}

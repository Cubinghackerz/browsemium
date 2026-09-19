import BrowsemiumCore
import Foundation

public struct NavigationResolver: Sendable {
    public let searchURL: URL

    public init(searchURL: URL = URL(string: SearchEnginePreset.google.template)!) {
        self.searchURL = searchURL
    }

    public func resolve(_ input: String) throws -> NavigationRequest {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BrowsemiumError.emptyNavigationInput
        }

        if let explicitScheme = Self.explicitScheme(in: value) {
            let scheme = explicitScheme.lowercased()
            if ["javascript", "data", "file"].contains(scheme) {
                throw BrowsemiumError.blockedScheme(scheme)
            }
            if scheme == "http" || scheme == "https" {
                return NavigationRequest(url: try validatedWebURL(value))
            }
            if value.contains("://") {
                throw BrowsemiumError.unsupportedScheme(scheme)
            }
        }

        if let directURL = try directURL(for: value) {
            return NavigationRequest(url: directURL)
        }

        if let explicitScheme = Self.explicitScheme(in: value) {
            throw BrowsemiumError.unsupportedScheme(explicitScheme.lowercased())
        }

        guard var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw BrowsemiumError.malformedURL(searchURL.absoluteString)
        }

        var queryItems = components.queryItems ?? []
        if let queryIndex = queryItems.firstIndex(where: { $0.name == "q" }) {
            queryItems[queryIndex] = URLQueryItem(name: "q", value: value)
        } else {
            queryItems.append(URLQueryItem(name: "q", value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw BrowsemiumError.malformedURL(value)
        }
        return NavigationRequest(url: url)
    }

    private func directURL(for value: String) throws -> URL? {
        guard !value.contains(where: { $0.isWhitespace }) else {
            return nil
        }

        let candidate = "https://\(value)"
        guard let components = URLComponents(string: candidate), let host = components.host else {
            return nil
        }

        if components.user != nil || components.password != nil {
            throw BrowsemiumError.credentialsNotAllowed
        }

        let loweredHost = host.lowercased()
        guard loweredHost == "localhost" || loweredHost.contains(".") else {
            return nil
        }

        guard let url = components.url else {
            throw BrowsemiumError.malformedURL(value)
        }
        return url
    }

    private func validatedWebURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            throw BrowsemiumError.malformedURL(value)
        }
        if components.user != nil || components.password != nil {
            throw BrowsemiumError.credentialsNotAllowed
        }
        return url
    }

    private static func explicitScheme(in value: String) -> String? {
        guard let separator = value.firstIndex(of: ":") else {
            return nil
        }
        let candidate = String(value[..<separator])
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return candidate
    }
}

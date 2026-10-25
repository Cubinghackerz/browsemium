import Foundation

/// A navigation-class command another app can send with a `browsemium://`
/// link: open a page, search, or switch space. This is the whole of what
/// outside callers may ask for. There is deliberately no command that sends
/// anything to an AI provider, grants an agent access, opens a private
/// window, reads page contents, or deletes anything, so a link in a
/// document or a message can only ever navigate.
public enum AppURLCommand: Equatable, Sendable {
    case open(URL)
    case search(String)
    case switchSpace(name: String)

    public static let scheme = "browsemium"
    public static let maximumLength = 8_192
    public static let maximumSearchLength = 2_000
    public static let maximumSpaceNameLength = 80

    public enum ParseError: Error, Equatable, Sendable {
        case wrongScheme
        case tooLong
        case unknownCommand(String)
        case missingParameter(String)
        case duplicateParameter(String)
        case invalidURL
        case credentialsNotAllowed
        case tooLongParameter(String)

        public var message: String {
            switch self {
            case .wrongScheme: "That is not a browsemium:// link."
            case .tooLong: "That link is too long."
            case .unknownCommand(let name): "Browsemium has no “\(name)” command."
            case .missingParameter(let name): "The link is missing “\(name)”."
            case .duplicateParameter(let name): "The link repeats “\(name)”."
            case .invalidURL: "The link to open is not a web address."
            case .credentialsNotAllowed: "Addresses with a username or password are not opened from links."
            case .tooLongParameter(let name): "“\(name)” is too long."
            }
        }
    }

    public static func parse(_ url: URL) -> Result<AppURLCommand, ParseError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard url.absoluteString.utf8.count <= maximumLength else { return .failure(.tooLong) }
        let command = (url.host ?? "").lowercased()
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unknownCommand(command))
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if parameters[item.name] != nil { return .failure(.duplicateParameter(item.name)) }
            parameters[item.name] = item.value ?? ""
        }

        switch command {
        case "open":
            guard let raw = parameters["url"], !raw.isEmpty else { return .failure(.missingParameter("url")) }
            guard let target = URL(string: raw), let scheme = target.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = target.host, !host.isEmpty else { return .failure(.invalidURL) }
            guard target.user == nil, target.password == nil else { return .failure(.credentialsNotAllowed) }
            return .success(.open(target))
        case "search":
            let query = (parameters["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .failure(.missingParameter("q")) }
            guard query.count <= maximumSearchLength else { return .failure(.tooLongParameter("q")) }
            return .success(.search(query))
        case "space":
            let name = (parameters["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.missingParameter("name")) }
            guard name.count <= maximumSpaceNameLength else { return .failure(.tooLongParameter("name")) }
            return .success(.switchSpace(name: name))
        default:
            return .failure(.unknownCommand(command))
        }
    }

    /// The link that sends this command. Used by the command-line tool and
    /// by tests, so what is built is exactly what is parsed.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .open(let target):
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .switchSpace(let name):
            components.host = "space"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        }
        // Building from components with only valid parts cannot fail.
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }
}

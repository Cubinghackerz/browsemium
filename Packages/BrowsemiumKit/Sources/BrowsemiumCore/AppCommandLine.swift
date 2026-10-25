import Foundation

/// The command-line grammar of `browsemium-ctl`, kept apart from the tool's
/// `main` so it can be tested without launching anything. The tool only ever
/// builds a `browsemium://` link; it has no other way to reach the browser.
public enum AppCommandLine {
    public enum Outcome: Equatable, Sendable {
        /// Hand this link to the system, which routes it to Browsemium.
        case send(URL)
        /// Print this to standard output and exit successfully.
        case info(String)
        /// Print this to standard error and exit with the given status.
        case failure(String, status: Int32)
    }

    public static let version = "1"

    public static let usage = """
        usage: browsemium-ctl <command>

          open <url>         open a web address in a new tab
          search <words…>    search with your chosen search engine
          space <name…>      switch to a space (a locked space asks for Touch ID)
          --help, --version

        These commands only navigate. Nothing here reads a page, sends anything
        to an AI provider, or changes settings.
        """

    public static func interpret(_ arguments: [String]) -> Outcome {
        guard let command = arguments.first else {
            return .failure(usage, status: 64)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--help", "-h", "help":
            return .info(usage)
        case "--version", "-v":
            return .info("browsemium-ctl \(version)")
        case "open":
            guard rest.count == 1 else { return .failure("open takes exactly one address.\n\n" + usage, status: 64) }
            guard let target = URL(string: rest[0]) else {
                return .failure(AppURLCommand.ParseError.invalidURL.message, status: 65)
            }
            return validated(.open(target))
        case "search":
            guard !rest.isEmpty else { return .failure("search needs some words.\n\n" + usage, status: 64) }
            return validated(.search(rest.joined(separator: " ")))
        case "space":
            guard !rest.isEmpty else { return .failure("space needs a name.\n\n" + usage, status: 64) }
            return validated(.switchSpace(name: rest.joined(separator: " ")))
        default:
            return .failure("Unknown command “\(command)”.\n\n" + usage, status: 64)
        }
    }

    /// The same checks the app applies, so a bad request fails here with a
    /// message instead of silently doing nothing in the browser.
    private static func validated(_ command: AppURLCommand) -> Outcome {
        switch AppURLCommand.parse(command.url) {
        case .success: .send(command.url)
        case .failure(let error): .failure(error.message, status: 65)
        }
    }
}

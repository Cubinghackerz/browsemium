import Foundation

/// HTTP authentication never changes certificate validation or persists secrets.
public enum AuthChallengePolicy {
    public enum Action: Sendable, Equatable { case prompt, performDefaultHandling }

    public static func action(forMethod method: String) -> Action {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            return .prompt
        default:
            return .performDefaultHandling
        }
    }
}

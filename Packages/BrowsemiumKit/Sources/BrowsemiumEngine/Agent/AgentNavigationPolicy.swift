import Foundation

/// The navigation rules for a task-owned page, kept free of WebKit types so
/// every branch can be tested directly.
///
/// While agent access is on, a top-level navigation must pass the gate's
/// authorizer *before* the request is made. WebKit asks for each server
/// redirect as well, so a redirect to another origin is refused before its
/// first byte is fetched. While access is off the person is driving and only
/// the scheme rules apply.
enum AgentNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
    }

    static func decide(
        url: URL?,
        isMainFrame: Bool,
        opensNewWindow: Bool,
        isDownload: Bool,
        agentAccess: Bool,
        authorize: (URL) -> Bool
    ) -> Decision {
        // Pop-ups and downloads never happen on a task page.
        if opensNewWindow || isDownload { return .cancel }
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }

        if scheme == "about" {
            return ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased()) ? .allow : .cancel
        }
        // javascript:, file:, data:, blob:, and app schemes (which could launch
        // another program) are all refused. Only web pages load here.
        guard scheme == "http" || scheme == "https" else { return .cancel }

        // Embedded frames are page content, not a change of the page the task
        // was granted; the grant is about the top-level origin.
        guard isMainFrame else { return .allow }
        guard agentAccess else { return .allow }
        return authorize(url) ? .allow : .cancel
    }
}

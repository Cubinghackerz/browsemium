import BrowsemiumCore
import Foundation

/// Answers site permission requests on behalf of the browser window.
///
/// The engine asks; the UI decides. WebKit routes camera and microphone
/// requests through `WKUIDelegate`, and without a decision handler the request
/// is denied without ever telling the user — which is how voice and video
/// features on provider sites used to fail silently.
///
/// With several windows open, the most recently registered window hosts the
/// prompt. That is safe because a decision belongs to the origin, not to the
/// window: whichever tab asked, the stored answer applies to the site.
@MainActor
public protocol PermissionPrompting: AnyObject {
    /// The remembered decision for this origin, the user's answer to a fresh
    /// prompt, or `.deny` when nothing can ask. Implementations are expected
    /// to record "always" answers so the next request is answered from storage.
    func permissionDecision(origin: String, kind: SitePermissionKind) async -> SitePermissionDecision
}

/// Human-readable names, shared by the prompt and the settings list.
extension SitePermissionKind {
    public var displayName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .popups: "Pop-up windows"
        case .downloads: "Downloads"
        }
    }

    /// What the site is asking for, in the user's words.
    public var requestDescription: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .location: "know your location"
        case .notifications: "send you notifications"
        case .popups: "open pop-up windows"
        case .downloads: "download files"
        }
    }
}

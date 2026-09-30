import AppKit
import Foundation

@MainActor
enum HTTPAuthPrompt {
    static func credential(for challenge: URLAuthenticationChallenge, window: NSWindow?) async -> URLCredential? {
        // Never fall back to an app-wide modal prompt for a detached tab.
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = "This website requires a username and password. Browsemium will not save them."
        if challenge.previousFailureCount > 0 {
            alert.informativeText = "The website did not accept those credentials. Try again, or cancel. Browsemium will not save them."
        }
        let username = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        username.placeholderString = "Username"
        username.setAccessibilityLabel("Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = "Password"
        password.setAccessibilityLabel("Password")
        let fields = NSStackView(views: [username, password])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = username
        let response = await alert.beginSheetModal(for: window)
        defer { password.stringValue = "" }
        guard response == .alertFirstButtonReturn else { return nil }
        return URLCredential(user: username.stringValue, password: password.stringValue, persistence: .none)
    }
}

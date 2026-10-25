import Foundation

/// One input of a submitted form, as the page reported it. Only the fields
/// that can matter for a sign-in are ever sent here.
public struct SignInField: Sendable, Equatable {
    public let name: String
    public let type: String
    public let autocomplete: String
    public let value: String

    public init(name: String, type: String, autocomplete: String = "", value: String) {
        self.name = name.lowercased()
        self.type = type.lowercased()
        self.autocomplete = autocomplete.lowercased()
        self.value = value
    }
}

/// A sign-in the person just submitted, reduced to what saving a password
/// needs. The description never contains the password, so it cannot reach a
/// log by accident.
public struct SignInCandidate: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let host: String
    public let username: String
    public let password: String

    public init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    public var description: String { "SignInCandidate(host: \(host), username: <redacted>, password: <redacted>)" }
    public var debugDescription: String { description }
}

/// Decides whether a submitted form is a plain sign-in worth offering to
/// remember. It is deliberately conservative: a missed offer costs nothing,
/// while a wrong one saves the wrong secret. Sign-up and password-change
/// forms, payment forms and one-time-code entry are left alone.
public enum SignInFormDetector {
    public static let maximumFieldLength = 256
    private static let userNamePriority = ["email", "e-mail", "username", "user_name", "userid", "user_id", "user", "login", "identifier", "account", "uid"]
    private static let secretLikePattern = #"confirm|repeat|retype|verify|again|new|old|current|card|cvv|cvc|otp|code|token|pin"#

    public static func detect(
        fields: [SignInField],
        pageURL: URL?,
        formAction: URL?
    ) -> SignInCandidate? {
        guard let pageURL, pageURL.scheme?.lowercased() == "https",
              let host = SpaceRouteHost.routableHost(of: pageURL) else { return nil }
        // The form must stay on the site the person is signing in to.
        if let formAction {
            guard formAction.scheme?.lowercased() == "https",
                  let target = SpaceRouteHost.routableHost(of: formAction),
                  RegistrableDomain.of(host: target) == RegistrableDomain.of(host: host) else { return nil }
        }

        // Payment and one-time-code fields disqualify the whole form,
        // whatever else it contains.
        if fields.contains(where: { isPaymentOrOneTimeCode($0) }) { return nil }

        let passwords = fields.filter { $0.type == "password" }
        guard passwords.count == 1, let password = passwords.first,
              password.autocomplete != "new-password",
              !password.value.isEmpty, password.value.count <= maximumFieldLength,
              password.name.range(of: secretLikePattern, options: .regularExpression) == nil else { return nil }

        guard let username = username(in: fields, before: password) else { return nil }
        guard username != password.value else { return nil }
        return SignInCandidate(host: host, username: username, password: password.value)
    }

    private static func isPaymentOrOneTimeCode(_ field: SignInField) -> Bool {
        if field.autocomplete.hasPrefix("cc-") || field.autocomplete == "one-time-code" { return true }
        return field.name.range(of: #"card|cvv|cvc|otp"#, options: .regularExpression) != nil
    }

    private static func username(in fields: [SignInField], before password: SignInField) -> String? {
        let candidates = fields.filter { $0 != password && $0.type != "password" }
        func clean(_ field: SignInField?) -> String? {
            guard let value = field?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= maximumFieldLength else { return nil }
            return value
        }
        // The page's own declaration is the most reliable signal.
        if let declared = candidates.first(where: { $0.autocomplete == "username" || $0.autocomplete == "email" }),
           let value = clean(declared) { return value }
        if let email = candidates.first(where: { $0.type == "email" }), let value = clean(email) { return value }
        for key in userNamePriority {
            if let match = candidates.first(where: { $0.name.contains(key) }), let value = clean(match) { return value }
        }
        // Otherwise the text-like field closest before the password field.
        if let index = fields.firstIndex(of: password) {
            let before = fields[..<index].reversed().first { ["text", "tel", "email", "search", ""].contains($0.type) }
            if let value = clean(before) { return value }
        }
        return nil
    }
}

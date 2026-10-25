import BrowsemiumCore
import Foundation
import Testing

private let page = URL(string: "https://app.example.com/login")
private let action = URL(string: "https://app.example.com/session")

private func field(_ name: String, _ type: String = "text", _ value: String, auto: String = "") -> SignInField {
    SignInField(name: name, type: type, autocomplete: auto, value: value)
}

private func detect(_ fields: [SignInField], page: URL? = page, action: URL? = action) -> SignInCandidate? {
    SignInFormDetector.detect(fields: fields, pageURL: page, formAction: action)
}

@Test
func aPlainSignInIsRecognisedByFieldType() {
    let found = detect([field("email", "email", " me@example.com "), field("pw", "password", "s3cret!")])
    #expect(found == SignInCandidate(host: "app.example.com", username: "me@example.com", password: "s3cret!"))
}

@Test
func theUsernameComesFromTheMostReliableSignal() {
    // Declared autocomplete beats a field that merely sits closer.
    let declared = detect([
        field("handle", "text", "ann", auto: "username"),
        field("note", "text", "ignored"),
        field("x", "password", "pw")
    ])
    #expect(declared?.username == "ann")

    // Unnamed fields fall back to the text field just before the password.
    let positional = detect([field("a", "text", "first"), field("b", "text", "second"), field("c", "password", "pw")])
    #expect(positional?.username == "second")

    // A name hint beats position.
    let named = detect([field("login", "text", "ann"), field("zzz", "text", "later"), field("p", "password", "pw")])
    #expect(named?.username == "ann")
}

@Test(arguments: [
    // Two secrets: sign-up, change-password or confirm.
    [field("email", "email", "a@x.test"), field("p1", "password", "pw"), field("p2", "password", "pw")],
    // The page says this is a new password.
    [field("email", "email", "a@x.test"), field("p", "password", "pw", auto: "new-password")],
    // Names that read as another kind of secret.
    [field("email", "email", "a@x.test"), field("new_password", "password", "pw")],
    [field("email", "email", "a@x.test"), field("current-password", "password", "pw")],
    // Payment and one-time-code forms.
    [field("name", "text", "Ann"), field("cardnumber", "text", "4111"), field("p", "password", "pw")],
    [field("name", "text", "Ann"), field("cc", "text", "4111", auto: "cc-number"), field("p", "password", "pw")],
    [field("u", "text", "ann"), field("otp", "text", "123456"), field("p", "password", "pw")],
    [field("u", "text", "ann", auto: "username"), field("c", "text", "1", auto: "one-time-code"), field("p", "password", "pw")],
    // No username to remember it under.
    [field("p", "password", "pw")],
    // Empty or oversized secrets.
    [field("email", "email", "a@x.test"), field("p", "password", "")],
    [field("email", "email", "a@x.test"), field("p", "password", String(repeating: "x", count: 300))],
    // A password-looking name that is not a password field.
    [field("email", "email", "a@x.test"), field("password", "text", "pw")]
])
func formsThatAreNotPlainSignInsAreIgnored(fields: [SignInField]) {
    #expect(detect(fields) == nil)
}

@Test
func onlyHTTPSFormsThatStayOnTheSiteQualify() {
    let fields = [field("email", "email", "a@x.test"), field("p", "password", "pw")]
    #expect(detect(fields, page: URL(string: "http://app.example.com/login")) == nil)
    #expect(detect(fields, action: URL(string: "http://app.example.com/session")) == nil)
    #expect(detect(fields, action: URL(string: "https://evil.test/collect")) == nil)
    #expect(detect(fields, page: nil) == nil)
    // No explicit action means the form posts to its own page.
    #expect(detect(fields, action: nil) != nil)
    // A sibling subdomain of the same site is the same sign-in.
    #expect(detect(fields, action: URL(string: "https://auth.example.com/session")) != nil)
}

@Test
func theCandidateNeverPrintsItsSecrets() {
    let candidate = SignInCandidate(host: "example.com", username: "ann@example.com", password: "hunter2")
    for text in [String(describing: candidate), String(reflecting: candidate), "\(candidate)"] {
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("ann@example.com"))
    }
}

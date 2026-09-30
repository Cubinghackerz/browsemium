import BrowsemiumEngine
import Foundation
import Testing

@Suite struct AuthChallengePolicyTests {
    @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM])
    func passwordMethodsPrompt(method: String) {
        #expect(AuthChallengePolicy.action(forMethod: method) == .prompt)
    }

    @Test(arguments: [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault, "unknown"])
    func allOtherMethodsKeepPlatformValidation(method: String) {
        #expect(AuthChallengePolicy.action(forMethod: method) == .performDefaultHandling)
    }
}

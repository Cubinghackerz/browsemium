import BrowsemiumCore
import Foundation
import LocalAuthentication

/// Touch ID / login-password prompt for locked spaces.
///
/// `deviceOwnerAuthentication` (not `...Biometrics`) is deliberate: a Mac
/// without a Touch ID sensor, or with a wet finger, must still be able to
/// open a locked space. The fallback is the login password.
@MainActor
public final class BiometricSpaceUnlockAuthenticator: SpaceUnlockAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        // An explicit short reuse window keeps back-to-back unlocks from
        // re-prompting while never holding a successful check for long.
        context.touchIDAuthenticationAllowableReuseDuration = 30
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}

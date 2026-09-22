@testable import BrowsemiumEngine
import Foundation
import Testing

// didFailProvisionalNavigation also fires for expected interruptions —
// downloads, redirects, user stops — which must never surface as failures.

@Test @MainActor
func urlCancellationIsAnExpectedInterruption() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    #expect(WebNavigationDelegate.isExpectedInterruption(error))
}

@Test @MainActor
func policyDownloadInterruptionIsExpected() {
    // WebKitErrorFrameLoadInterruptedByPolicyChange — WebKitErrorDomain 102 —
    // is what the .download policy answer delivers through the failure path.
    let error = NSError(domain: "WebKitErrorDomain", code: 102)
    #expect(WebNavigationDelegate.isExpectedInterruption(error))
}

@Test @MainActor
func genuineFailuresAreNotInterruptions() {
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(WebNavigationDelegate.isExpectedInterruption(offline) == false)

    // The same code in another domain must not be swallowed.
    let alien = NSError(domain: "com.example.other", code: NSURLErrorCancelled)
    #expect(WebNavigationDelegate.isExpectedInterruption(alien) == false)
}

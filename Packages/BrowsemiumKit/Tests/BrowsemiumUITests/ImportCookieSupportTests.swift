import BrowsemiumCore
import BrowsemiumData
@testable import BrowsemiumUI
import Foundation
import Testing

@Suite @MainActor
struct ImportCookieSupportTests {
    @Test
    func anEngineWithoutACookieWriterDoesNotOfferCookieImport() {
        let environment = BrowserEnvironment.inMemory(engine: StubEngine())
        #expect(!environment.canImportCookies, "Cookies written to WebKit would never reach this engine")
    }

    @Test
    func theWebKitEditionOffersCookieImport() {
        #expect(BrowserEnvironment.inMemory().canImportCookies)
    }

    @Test
    func unsupportedCookiesAreStrippedFromTheOptionsBeforeAnyRead() {
        var options = BrowserImportOptions()
        options.includesCookies = true
        options.includesPasswords = true
        let stripped = ImportKeyAccess.withoutCookies(options)
        #expect(!stripped.includesCookies)
        #expect(stripped.includesPasswords, "Passwords are unaffected")
    }
}

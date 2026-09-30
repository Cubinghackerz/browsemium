import Foundation
import Testing
@testable import BrowsemiumUI

@Test @MainActor
func inMemoryPreferencesNeverUseStandardDomain() throws {
    let environment = BrowserEnvironment.inMemory(engine: StubEngine())
    // Fail before any write if an in-memory model would use real preferences.
    try #require(environment.userDefaults !== UserDefaults.standard)
    let first = BrowserWindowModel(environment: environment)
    #expect(!first.isSidebarCollapsed)
    first.toggleSidebarCollapsed()
    #expect(environment.userDefaults.bool(forKey: "browsemium.sidebarCollapsed"))
    let reopened = BrowserWindowModel(environment: environment)
    #expect(reopened.isSidebarCollapsed)
    let independent = BrowserWindowModel(environment: .inMemory(engine: StubEngine()))
    #expect(!independent.isSidebarCollapsed)
}

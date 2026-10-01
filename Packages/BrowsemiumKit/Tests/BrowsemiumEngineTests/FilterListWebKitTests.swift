import BrowsemiumCore
import Foundation
import Testing
import WebKit

@Suite @MainActor struct FilterListWebKitTests {
    @Test func representativeConvertedRulesCompileInWebKit() async throws {
        let conversion = try FilterListConverter.convert(Data("""
            @@||allowed.example^
            ||ads.example^
            ||resources.example^$image,script,stylesheet,font,media
            """.utf8))
        #expect(conversion.acceptedCount == 3 && conversion.skipped.isEmpty)
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "BrowsemiumFixture-" + UUID().uuidString
        defer { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
        let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: conversion.rulesJSON) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
            }
        }
        #expect(compiled.identifier == identifier)
    }
}

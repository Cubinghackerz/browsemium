import BrowsemiumCore
import Foundation
import Testing

@Suite struct FilterListConverterTests {
    @Test func hostRulesAreBoundedEscapedAndExceptionsComeLast() throws {
        let conversion = try FilterListConverter.convert(Data("""
            ! Generated fixture, not a downloaded list
            [Adblock Plus 2.0]
            @@||allowed.example^
            ||ads.example^
            ||images.example^$image,script
            ||ads.example^
            """.utf8))
        #expect(conversion.acceptedCount == 3)
        #expect(conversion.skipped == [.init(line: 6, reason: .duplicate)])
        let rules = try #require(JSONSerialization.jsonObject(with: Data(conversion.rulesJSON.utf8)) as? [[String: Any]])
        #expect(rules.count == 3)
        let lastAction = try #require(rules.last?["action"] as? [String: Any])
        #expect(lastAction["type"] as? String == "ignore-previous-rules")
        let trigger = try #require(rules.first?["trigger"] as? [String: Any])
        let pattern = try #require(trigger["url-filter"] as? String)
        #expect(!pattern.contains("|"))
        let expression = try NSRegularExpression(pattern: pattern)
        for input in ["https://ads.example/ad.js", "http://deep.sub.ads.example:8080/ad.js"] {
            #expect(expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil)
        }
        for input in ["https://ads.example.evil/ad.js", "https://badads.example/ad.js", "https://site.example/ads.example/ad.js"] {
            #expect(expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) == nil)
        }
    }

    @Test func unsupportedModifiersNeverBecomeUnqualifiedBlocks() throws {
        let conversion = try FilterListConverter.convert(Data("""
            ||supported.example^
            ||party.example^$third-party
            ||domain.example^$domain=site.example
            ||redirect.example^$redirect=noopjs
            ||negative.example^$~image
            @@||page.example^$document
            /ads|trackers/
            site.example##.advertisement
            ||path.example/ads/*
            ||bad..example^
            """.utf8))
        #expect(conversion.acceptedCount == 1)
        #expect(conversion.skipped.count == 9)
        #expect(!conversion.rulesJSON.contains("party"))
        #expect(!conversion.rulesJSON.contains("redirect"))
        #expect(!conversion.rulesJSON.contains("path"))
        #expect(conversion.skipped.contains { $0.reason == .invalidDomain })
        #expect(conversion.skipped.contains { $0.reason == .cosmeticRule })
    }

    @Test func validatesEncodingAndEveryResourceBound() {
        #expect(throws: FilterListConverter.ConversionError.invalidUTF8) {
            _ = try FilterListConverter.convert(Data([0xff, 0xfe]))
        }
        #expect(throws: FilterListConverter.ConversionError.inputTooLarge) {
            _ = try FilterListConverter.convert(Data("||fixture.example^".utf8), limits: .init(maximumBytes: 5))
        }
        #expect(throws: FilterListConverter.ConversionError.lineTooLong) {
            _ = try FilterListConverter.convert(Data("||fixture.example^".utf8), limits: .init(maximumLineBytes: 5))
        }
        #expect(throws: FilterListConverter.ConversionError.tooManyLines) {
            _ = try FilterListConverter.convert(Data("! comment\n||fixture.example^".utf8), limits: .init(maximumLines: 1))
        }
        #expect(throws: FilterListConverter.ConversionError.tooManyRules) {
            _ = try FilterListConverter.convert(Data("||one.example^\n||two.example^".utf8), limits: .init(maximumRules: 1))
        }
        #expect(throws: FilterListConverter.ConversionError.outputTooLarge) {
            _ = try FilterListConverter.convert(Data("||fixture.example^".utf8), limits: .init(maximumOutputBytes: 5))
        }
        #expect(throws: FilterListConverter.ConversionError.cancelled) {
            _ = try FilterListConverter.convert(Data("||fixture.example^".utf8), isCancelled: { true })
        }
    }

    @Test func rejectsEmptyConversionsAndControlDirectives() {
        #expect(throws: FilterListConverter.ConversionError.noSupportedRules) {
            _ = try FilterListConverter.convert(Data("! comments only".utf8))
        }
        for directive in ["!#include secret.txt", "!#if another_platform", "!#else", "!#endif"] {
            #expect(throws: FilterListConverter.ConversionError.unsupportedDirectives) {
                _ = try FilterListConverter.convert(Data("||fixture.example^\n\(directive)".utf8))
            }
        }
    }

    @Test func reportsCannotContainSourceText() throws {
        let conversion = try FilterListConverter.convert(Data("||fixture.example^\nprivate.example##secret-selector".utf8))
        let encoded = String(decoding: try JSONEncoder().encode(conversion.skipped), as: UTF8.self)
        #expect(!encoded.contains("private.example"))
        #expect(!encoded.contains("secret-selector"))
    }

    @Test func canonicalizesOnlyASCIIHostsAndPositiveResourceSets() throws {
        let conversion = try FilterListConverter.convert(Data("\u{feff}||EXAMPLE.test^$script,image\r\n||example.test^$image,script\r\n||K.example^".utf8))
        #expect(conversion.acceptedCount == 1)
        #expect(conversion.skipped == [.init(line: 2, reason: .duplicate), .init(line: 3, reason: .invalidDomain)])
        let rules = try #require(JSONSerialization.jsonObject(with: Data(conversion.rulesJSON.utf8)) as? [[String: Any]])
        let trigger = try #require(rules[0]["trigger"] as? [String: Any])
        #expect(trigger["resource-type"] as? [String] == ["image", "script"])
        #expect(trigger["if-domain"] == nil)
    }

    @Test func cancellationDuringParsingDiscardsTheEntireConversion() {
        var checks = 0
        #expect(throws: FilterListConverter.ConversionError.cancelled) {
            _ = try FilterListConverter.convert(Data("||one.example^\n||two.example^".utf8), isCancelled: {
                checks += 1
                return checks >= 3
            })
        }
    }
}

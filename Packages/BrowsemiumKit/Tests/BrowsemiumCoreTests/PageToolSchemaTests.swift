import BrowsemiumCore
import Foundation
import Testing

@Suite("Page tool schema check")
struct PageToolSchemaTests {
    private func accepts(_ arguments: String, _ schema: String) -> Bool {
        PageToolSchema.accepts(arguments: arguments, schema: schema)
    }

    @Test func anEmptySchemaAcceptsAnyObject() {
        #expect(accepts("{}", "{}"))
        #expect(accepts("{\"a\":[1,2,{\"b\":null}]}", "{}"))
    }

    @Test func typesAreEnforced() {
        let schema = "{\"type\":\"object\",\"properties\":{\"s\":{\"type\":\"string\"},\"n\":{\"type\":\"number\"},\"i\":{\"type\":\"integer\"},\"b\":{\"type\":\"boolean\"}}}"
        #expect(accepts("{\"s\":\"x\",\"n\":1.5,\"i\":3,\"b\":true}", schema))
        #expect(!accepts("{\"s\":1}", schema))
        #expect(!accepts("{\"n\":\"1\"}", schema))
        #expect(!accepts("{\"i\":1.5}", schema))
        #expect(!accepts("{\"b\":1}", schema), "A number is not a boolean")
        #expect(!accepts("{\"n\":true}", schema), "A boolean is not a number")
        #expect(!accepts("[]", schema))
    }

    @Test func requiredAndAdditionalPropertiesAreEnforced() {
        let schema = "{\"type\":\"object\",\"required\":[\"a\"],\"additionalProperties\":false,\"properties\":{\"a\":{}}}"
        #expect(accepts("{\"a\":1}", schema))
        #expect(!accepts("{}", schema))
        #expect(!accepts("{\"a\":1,\"b\":2}", schema))
        // Without the keyword, extra properties are allowed.
        #expect(accepts("{\"a\":1,\"b\":2}", "{\"type\":\"object\",\"properties\":{\"a\":{}}}"))
    }

    @Test func enumsAndArraysAreEnforced() {
        let schema = "{\"properties\":{\"mode\":{\"enum\":[\"fast\",\"slow\"]},\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}}}"
        #expect(accepts("{\"mode\":\"fast\",\"ids\":[1,2]}", schema))
        #expect(!accepts("{\"mode\":\"medium\"}", schema))
        #expect(!accepts("{\"ids\":[1,\"2\"]}", schema))
    }

    @Test func unknownKeywordsNeverRefuseAValidArgument() {
        let schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"pattern\":\"^x\",\"minLength\":5,\"format\":\"email\"}},\"oneOf\":[{}]}"
        #expect(accepts("{\"a\":\"y\"}", schema))
    }

    @Test func malformedInputIsRefused() {
        #expect(!accepts("not json", "{}"))
        #expect(!accepts("{}", "not json"))
        #expect(!accepts("{}", "[]"))
    }

    @Test func nestingBeyondTheDepthLimitIsRefused() {
        var schema = "{}"
        var value = "{}"
        for _ in 0..<12 {
            schema = "{\"properties\":{\"x\":\(schema)}}"
            value = "{\"x\":\(value)}"
        }
        #expect(!accepts(value, schema))
    }
}

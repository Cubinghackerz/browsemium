import Foundation

/// A deliberately small JSON Schema check for WebMCP tool arguments, run
/// before the person is asked, so a client cannot put a call on the card that
/// the page's own schema says is malformed.
///
/// Supported keywords: `type`, `enum`, `required`, `properties`,
/// `additionalProperties: false`, and `items`, nested to a fixed depth.
/// Every other keyword is ignored, which means this can accept an argument a
/// full validator would refuse. It never refuses a valid one because of a
/// keyword it does not know. The page's own code remains the real validator;
/// this is a guard against malformed calls, not a security boundary.
public enum PageToolSchema {
    private static let maxDepth = 8

    /// Whether the JSON text `arguments` satisfies the JSON text `schema`.
    /// An unparseable schema accepts nothing it cannot read as an object, and
    /// an empty schema accepts any JSON object.
    public static func accepts(arguments: String, schema: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [.fragmentsAllowed]),
              let spec = try? JSONSerialization.jsonObject(with: Data(schema.utf8), options: []) as? [String: Any] else {
            return false
        }
        return check(value, against: spec, depth: 0)
    }

    private static func check(_ value: Any, against spec: [String: Any], depth: Int) -> Bool {
        guard depth <= maxDepth else { return false }

        if let type = spec["type"] {
            let allowed = (type as? [String]) ?? (type as? String).map { [$0] } ?? []
            guard allowed.contains(where: { matches(value, type: $0) }) else { return false }
        }
        if let options = spec["enum"] as? [Any], !options.contains(where: { equal($0, value) }) { return false }

        if let object = value as? [String: Any], !isBoolean(value) {
            let properties = spec["properties"] as? [String: Any] ?? [:]
            for key in (spec["required"] as? [String]) ?? [] where object[key] == nil { return false }
            for (key, child) in object {
                if let childSpec = properties[key] as? [String: Any] {
                    guard check(child, against: childSpec, depth: depth + 1) else { return false }
                } else if spec["additionalProperties"] as? Bool == false {
                    return false
                }
            }
        }
        if let array = value as? [Any], let items = spec["items"] as? [String: Any] {
            for element in array where !check(element, against: items, depth: depth + 1) { return false }
        }
        return true
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "null": return value is NSNull
        case "boolean": return isBoolean(value)
        case "number": return value is NSNumber && !isBoolean(value)
        case "integer":
            guard let number = value as? NSNumber, !isBoolean(value) else { return false }
            return number.doubleValue == number.doubleValue.rounded() && number.doubleValue.isFinite
        default: return false
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if a is NSNull, b is NSNull { return true }
        if let a = a as? NSNumber, let b = b as? NSNumber { return isBoolean(a) == isBoolean(b) && a == b }
        return false
    }
}

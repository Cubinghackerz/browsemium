import Foundation

/// Answers arithmetic and unit conversions typed into the address bar, with
/// no network and no `NSExpression` (which traps on malformed input). The
/// parser is small, bounded and total: any string either gives an answer or
/// gives nil, and nothing can crash or run long.
public enum QuickAnswer {
    public struct Result: Equatable, Sendable {
        /// What is shown and copied: "42", "3.5", "-0.25".
        public let text: String
        /// A short label for the row's second line.
        public let kind: String
    }

    public static let maximumLength = 200
    static let maximumDepth = 32

    public static func evaluate(_ input: String) -> Result? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength else { return nil }
        // A leading "=" says "this is a calculation", as in a spreadsheet.
        let forced = text.hasPrefix("=")
        if forced { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let converted = convertUnits(text) { return converted }
        if let percent = percentOf(text) { return percent }
        guard forced || looksLikeCalculation(text) else { return nil }

        var parser = Parser(text)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Result(text: format(value), kind: "Calculation")
    }

    // MARK: - Is this a calculation at all?

    /// Plain numbers, dates, phone numbers and versions are not sums.
    static func looksLikeCalculation(_ text: String) -> Bool {
        let operators = CharacterSet(charactersIn: "+*/^%×÷()")
        let hasOperator = text.unicodeScalars.contains { operators.contains($0) }
            || text.contains(" - ")
            || text.contains(" x ")
        let hasBareMinus = text.dropFirst().contains("-")
        guard hasOperator || hasBareMinus else { return false }
        // Only digits, operators, spaces, a decimal point and a few words.
        let allowed = CharacterSet(charactersIn: "0123456789+-*/^%×÷() .,xXpi")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard text.contains(where: \.isNumber) || text.lowercased().contains("pi") else { return false }
        if isDateLike(text) || isPhoneLike(text) { return false }
        return true
    }

    private static func isDateLike(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil
            || text.range(of: #"^\d{1,2}-\d{1,2}-\d{2,4}$"#, options: .regularExpression) != nil
            || text.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#, options: .regularExpression) != nil
    }

    private static func isPhoneLike(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber).count
        let onlyPhoneCharacters = text.range(of: #"^\+?[\d\s()-]+$"#, options: .regularExpression) != nil
        if onlyPhoneCharacters && digits >= 9 { return true }
        return text.range(of: #"^\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}$"#, options: .regularExpression) != nil
    }

    // MARK: - Percentages

    private static func percentOf(_ text: String) -> Result? {
        let pattern = #"^(-?\d+(?:\.\d+)?)\s*%\s*of\s*(-?\d+(?:\.\d+)?)$"#
        guard let range = text.lowercased().range(of: pattern, options: .regularExpression),
              range.lowerBound == text.lowercased().startIndex else { return nil }
        let parts = text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "% "))
            .filter { !$0.isEmpty && $0 != "of" }
        guard parts.count == 2, let percent = Double(parts[0]), let base = Double(parts[1]) else { return nil }
        let value = percent / 100 * base
        guard value.isFinite else { return nil }
        return Result(text: format(value), kind: "Percentage")
    }

    // MARK: - Units

    private enum Dimension { case length, mass, volume, temperature }

    /// Factor to the dimension's base unit (metres, kilograms, litres).
    private static let units: [String: (Dimension, Double)] = [
        "mm": (.length, 0.001), "cm": (.length, 0.01), "m": (.length, 1), "km": (.length, 1000),
        "in": (.length, 0.0254), "inch": (.length, 0.0254), "inches": (.length, 0.0254),
        "ft": (.length, 0.3048), "foot": (.length, 0.3048), "feet": (.length, 0.3048),
        "yd": (.length, 0.9144), "yard": (.length, 0.9144), "yards": (.length, 0.9144),
        "mi": (.length, 1609.344), "mile": (.length, 1609.344), "miles": (.length, 1609.344),
        "mg": (.mass, 0.000001), "g": (.mass, 0.001), "kg": (.mass, 1),
        "oz": (.mass, 0.028349523125), "lb": (.mass, 0.45359237), "lbs": (.mass, 0.45359237),
        "pound": (.mass, 0.45359237), "pounds": (.mass, 0.45359237),
        "ml": (.volume, 0.001), "l": (.volume, 1), "liter": (.volume, 1), "litre": (.volume, 1),
        "floz": (.volume, 0.0295735295625), "cup": (.volume, 0.2365882365), "cups": (.volume, 0.2365882365),
        "gal": (.volume, 3.785411784), "gallon": (.volume, 3.785411784), "gallons": (.volume, 3.785411784),
        "c": (.temperature, 0), "f": (.temperature, 0), "k": (.temperature, 0),
        "°c": (.temperature, 0), "°f": (.temperature, 0)
    ]

    private static func convertUnits(_ text: String) -> Result? {
        let pattern = #"^(-?\d+(?:[.,]\d+)?)\s*([a-z°]+)\s+(?:to|in|as|into)\s+([a-z°]+)$"#
        let lowered = text.lowercased()
        guard lowered.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let tokens = lowered.split(whereSeparator: { $0 == " " }).map(String.init)
        // "<number><unit>" may or may not have a space before the unit.
        var numberAndUnit: (String, String)?
        if tokens.count == 4 {
            numberAndUnit = (tokens[0], tokens[1])
        } else if tokens.count == 3, let split = tokens[0].firstIndex(where: { $0.isLetter || $0 == "°" }) {
            numberAndUnit = (String(tokens[0][..<split]), String(tokens[0][split...]))
        }
        guard let (numberText, fromUnit) = numberAndUnit,
              let value = Double(numberText.replacingOccurrences(of: ",", with: ".")),
              let toUnit = tokens.last,
              let from = units[fromUnit], let to = units[toUnit], from.0 == to.0 else { return nil }
        let converted: Double
        if from.0 == .temperature {
            guard let result = convertTemperature(value, from: fromUnit, to: toUnit) else { return nil }
            converted = result
        } else {
            converted = value * from.1 / to.1
        }
        guard converted.isFinite else { return nil }
        return Result(text: "\(format(converted)) \(displayName(toUnit))", kind: "Conversion")
    }

    private static func convertTemperature(_ value: Double, from: String, to: String) -> Double? {
        func canonical(_ unit: String) -> Character? { unit.replacingOccurrences(of: "°", with: "").first }
        guard let source = canonical(from), let target = canonical(to) else { return nil }
        let celsius: Double
        switch source {
        case "c": celsius = value
        case "f": celsius = (value - 32) * 5 / 9
        case "k": celsius = value - 273.15
        default: return nil
        }
        switch target {
        case "c": return celsius
        case "f": return celsius * 9 / 5 + 32
        case "k": return celsius + 273.15
        default: return nil
        }
    }

    private static func displayName(_ unit: String) -> String {
        switch unit {
        case "c", "°c": "°C"
        case "f", "°f": "°F"
        case "k": "K"
        default: unit
        }
    }

    // MARK: - Formatting

    /// Up to ten significant digits, no grouping, no trailing zeros, and
    /// scientific notation only where plain digits would be unreadable.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var text = String(format: "%.10g", value)
        if text.contains("e") { return text }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    // MARK: - Parser

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private var depth = 0

        init(_ text: String) {
            // "×" and "÷" are the same operators as "*" and "/"; "," groups
            // thousands and is dropped between digits.
            var normalised = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            normalised = normalised.replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
            characters = Array(normalised.lowercased())
        }

        mutating func parse() -> Double? {
            guard let value = expression() else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index] == " " { index += 1 }
        }

        private func peek() -> Character? { index < characters.count ? characters[index] : nil }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                skipSpaces()
                guard let op = peek(), op == "+" || op == "-" else { return value }
                index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while true {
                skipSpaces()
                guard let op = peek(), op == "*" || op == "/" || op == "x" else { return value }
                index += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*", "x": value *= rhs
                default:
                    guard rhs != 0 else { return nil }
                    value /= rhs
                }
            }
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            skipSpaces()
            guard peek() == "^" else { return base }
            index += 1
            guard let exponent = power() else { return nil }
            // Keep the answer finite and cheap: no huge exponents.
            guard abs(exponent) <= 1_000 else { return nil }
            let result = pow(base, exponent)
            return result.isFinite ? result : nil
        }

        private mutating func unary() -> Double? {
            skipSpaces()
            if let sign = peek(), sign == "-" || sign == "+" {
                index += 1
                depth += 1
                defer { depth -= 1 }
                guard depth <= QuickAnswer.maximumDepth, let value = unary() else { return nil }
                return sign == "-" ? -value : value
            }
            return postfix()
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            skipSpaces()
            while peek() == "%" {
                index += 1
                value /= 100
                skipSpaces()
            }
            return value
        }

        private mutating func primary() -> Double? {
            skipSpaces()
            guard let character = peek() else { return nil }
            if character == "(" {
                index += 1
                depth += 1
                defer { depth -= 1 }
                guard depth <= QuickAnswer.maximumDepth, let value = expression() else { return nil }
                skipSpaces()
                guard peek() == ")" else { return nil }
                index += 1
                return value
            }
            if character == "p", index + 1 < characters.count, characters[index + 1] == "i" {
                index += 2
                return Double.pi
            }
            return number()
        }

        private mutating func number() -> Double? {
            let start = index
            var sawDot = false
            while let character = peek(), character.isNumber || (character == "." && !sawDot) {
                if character == "." { sawDot = true }
                index += 1
            }
            guard index > start else { return nil }
            let text = String(characters[start..<index])
            guard text != "." else { return nil }
            return Double(text)
        }
    }
}

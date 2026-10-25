import BrowsemiumCore
import Foundation
import Testing

private func answer(_ input: String) -> String? { QuickAnswer.evaluate(input)?.text }

@Test(arguments: [
    ("2+2", "4"), ("2 + 2", "4"), ("10-3", "7"), ("10 - 3", "7"), ("6*7", "42"), ("6 x 7", "42"),
    ("6×7", "42"), ("84/2", "42"), ("84 ÷ 2", "42"), ("2^10", "1024"), ("2^3^2", "512"),
    ("(1+2)*3", "9"), ("-4+10", "6"), ("3*-2", "-6"), ("1.5*4", "6"), ("10/4", "2.5"),
    ("1/3", "0.3333333333"), ("0.1+0.2", "0.3"), ("50%", "0.5"), ("200*10%", "20"),
    ("1,000+500", "1500"), ("=42", "42"), ("= 2 + 2", "4"), ("pi*2", "6.283185307"),
    ("(((1+2)))*2", "6"), ("2*(3+4)*5", "70")
])
func arithmeticIsAnswered(input: String, expected: String) {
    #expect(answer(input) == expected)
}

@Test(arguments: [
    // Not calculations.
    "42", "3.14", "swift", "github.com", "example.com/path", "192.168.1.1", "1.2.3", "10:30", "-5", "hello world",
    // Dates and phone numbers that merely contain minus signs or digits.
    "2024-10-04", "10-04-2024", "10/04/2024", "555-123-4567", "(555) 123-4567", "+1 555 123 4567",
    // Malformed.
    "2+", "*3", "(1+2", "1+2)", "2**3", "1..2+3", "1/0", "0/0", "2^10000", "9^9^9",
    "", "   ", "=", "= ", "()", "(*)"
])
func nonCalculationsAndBadInputGetNoAnswer(input: String) {
    #expect(answer(input) == nil)
}

@Test(arguments: [
    ("5 km to mi", "3.106855961 mi"), ("5km to mi", "3.106855961 mi"), ("1 mi in km", "1.609344 km"),
    ("12 in to cm", "30.48 cm"), ("6 ft to m", "1.8288 m"), ("1 lb to kg", "0.45359237 kg"),
    ("1 kg to lb", "2.204622622 lb"), ("1000 g to kg", "1 kg"), ("1 l to ml", "1000 ml"),
    ("1 gal to l", "3.785411784 l"), ("100 c to f", "212 °F"), ("32 f to c", "0 °C"),
    ("0 c to k", "273.15 K"), ("98.6 °f to °c", "37 °C"), ("-40 c to f", "-40 °F")
])
func unitsAreConverted(input: String, expected: String) {
    #expect(answer(input) == expected)
}

@Test(arguments: [
    "5 km to kg", "5 xyz to mi", "5 km to", "km to mi", "5 c to m", "1 oz to floz", "5 km mi"
])
func incompatibleOrUnknownUnitsGetNoAnswer(input: String) {
    #expect(answer(input) == nil)
}

@Test
func percentOfWorks() {
    #expect(answer("20% of 50") == "10")
    #expect(answer("12.5 % of 80") == "10")
    #expect(answer("150% of 10") == "15")
    #expect(QuickAnswer.evaluate("20% of 50")?.kind == "Percentage")
}

@Test
func resultsCarryTheirKind() {
    #expect(QuickAnswer.evaluate("2+2")?.kind == "Calculation")
    #expect(QuickAnswer.evaluate("5 km to mi")?.kind == "Conversion")
}

@Test
func inputAndNestingAreBounded() {
    #expect(answer(String(repeating: "1+", count: 150) + "1") == nil, "over the length cap")
    let deep = String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)
    #expect(answer("=" + deep) == nil, "over the nesting cap")
    let fine = String(repeating: "(", count: 20) + "1+1" + String(repeating: ")", count: 20)
    #expect(answer(fine) == "2")
    let unary = String(repeating: "-", count: 100) + "1"
    #expect(answer("=" + unary) == nil)
}

@Test
func randomInputNeverCrashesOrHangs() {
    var generator = SystemRandomNumberGenerator()
    let alphabet = Array("0123456789+-*/^%×÷()., xXpi=abcdefgkmloz°ºt")
    for _ in 0..<4_000 {
        let length = Int.random(in: 0...60, using: &generator)
        let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
        _ = QuickAnswer.evaluate(text)
    }
}

@Test
func formattingIsStableAndFree() {
    #expect(answer("=1000000*1000000") == "1000000000000")
    #expect(answer("=2^100")?.contains("e") == true)
    #expect(answer("=0-0") == "0")
    #expect(answer("=-0.5*2") == "-1")
}

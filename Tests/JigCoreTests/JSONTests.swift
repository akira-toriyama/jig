import XCTest
@testable import JigCore

/// Parser + writer contracts: the three jq semantics that justify the
/// hand-rolled model (key order, number literals, stream inputs) plus the
/// robustness rule (errors, never crashes).
final class JSONTests: XCTestCase {

    private func roundTrip(_ s: String) throws -> String {
        writeJSON(try parseOneJSON(s), style: .compact)
    }

    // MARK: number literal preservation (jq 1.7 semantics)

    func testBigIntegerLiteralSurvivesRoundTrip() throws {
        // The classic jq <=1.6 data-corruption case.
        XCTAssertEqual(try roundTrip("12345678901234567890"), "12345678901234567890")
    }

    func testDecimalLiteralKeepsItsSpelling() throws {
        XCTAssertEqual(try roundTrip("1.0"), "1.0")
        XCTAssertEqual(try roundTrip("1e2"), "1e2")
    }

    func testComputedIntegralDoublePrintsAsInteger() {
        XCTAssertEqual(writeJSON(.number(JigNumber(4.0))), "4")
        XCTAssertEqual(writeJSON(.number(JigNumber(2.5))), "2.5")
    }

    func testNaNPrintsAsNullAndInfinityClamps() {
        XCTAssertEqual(writeJSON(.number(JigNumber(Double.nan))), "null")
        XCTAssertEqual(writeJSON(.number(JigNumber(Double.infinity))),
                       "1.7976931348623157e+308")
    }

    // MARK: object key order

    func testObjectKeyOrderIsPreserved() throws {
        XCTAssertEqual(try roundTrip(#"{"z":1,"a":2,"m":3}"#), #"{"z":1,"a":2,"m":3}"#)
    }

    func testDuplicateKeysKeepLast() throws {
        XCTAssertEqual(try roundTrip(#"{"a":1,"a":2}"#), #"{"a":2}"#)
    }

    func testObjectEqualityIsOrderInsensitive() throws {
        XCTAssertEqual(try parseOneJSON(#"{"a":1,"b":2}"#),
                       try parseOneJSON(#"{"b":2,"a":1}"#))
    }

    // MARK: strings

    func testEscapes() throws {
        XCTAssertEqual(try parseOneJSON(#""a\nb\t\"\\A""#), .string("a\nb\t\"\\A"))
    }

    func testSurrogatePair() throws {
        XCTAssertEqual(try parseOneJSON(#""😀""#), .string("😀"))
    }

    func testUTF8Passthrough() throws {
        XCTAssertEqual(try roundTrip(#""治具""#), #""治具""#)
    }

    func testControlCharacterEscapedOnOutput() {
        XCTAssertEqual(writeJSON(.string("\u{01}"), style: .compact), "\"\\u0001\"")
    }

    // MARK: streams

    func testWhitespaceSeparatedStream() throws {
        var p = JSONStreamParser("1 2  [3]\n{\"a\":4}")
        var docs: [JigValue] = []
        while let v = try p.next() { docs.append(v) }
        XCTAssertEqual(docs.count, 4)
        XCTAssertEqual(docs[2], .array([.number(JigNumber(literal: "3", double: 3))]))
    }

    func testEmptyInputYieldsNoDocuments() throws {
        var p = JSONStreamParser("  \n ")
        XCTAssertNil(try p.next())
    }

    // MARK: pretty printing

    func testPrettyFormatMatchesJqShape() throws {
        let v = try parseOneJSON(#"{"a":[1,2],"b":{}}"#)
        XCTAssertEqual(writeJSON(v), """
        {
          "a": [
            1,
            2
          ],
          "b": {}
        }
        """)
    }

    // MARK: errors, never crashes

    func testErrorCarriesLineAndColumn() {
        var p = JSONStreamParser("{\n  \"a\": ]\n}")
        XCTAssertThrowsError(try p.next()) { error in
            guard let e = error as? JSONParseError else { return XCTFail("\(error)") }
            XCTAssertEqual(e.line, 2)
            XCTAssertEqual(e.column, 8)
        }
    }

    func testSingleQuoteGetsAHint() {
        var p = JSONStreamParser("'foo'")
        XCTAssertThrowsError(try p.next()) { error in
            guard let e = error as? JSONParseError else { return XCTFail("\(error)") }
            XCTAssertNotNil(e.hint)
        }
    }

    func testDeepNestingErrorsInsteadOfCrashing() {
        var p = JSONStreamParser(String(repeating: "[", count: 4096))
        XCTAssertThrowsError(try p.next()) { error in
            XCTAssertTrue(error is JSONParseError)
        }
    }

    func testTruncatedInputErrors() {
        for bad in ["{", "[1,", "\"abc", "{\"a\"", "12e", "-", "tru"] {
            var p = JSONStreamParser(bad)
            XCTAssertThrowsError(try p.next(), "input: \(bad)")
        }
    }
}

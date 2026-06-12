import XCTest
@testable import JigCore

/// Literals + the `//` / `??` operators, including the humane H1 divergence.
final class LiteralsAndOpsTests: XCTestCase {

    private func run(_ program: String, on json: String = "null",
                     mode: JigMode = .jq) throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json), mode: mode)
            .map { writeJSON($0, style: .compact) }
    }

    func testScalarLiteralsIgnoreInput() throws {
        XCTAssertEqual(try run("1", on: #"{"x":9}"#), ["1"])
        XCTAssertEqual(try run(#""hi""#), [#""hi""#])
        XCTAssertEqual(try run("true"), ["true"])
        XCTAssertEqual(try run("false"), ["false"])
        XCTAssertEqual(try run("null"), ["null"])
        XCTAssertEqual(try run("-3.5"), ["-3.5"])
    }

    func testNullKeywordIsNotIdentity() throws {
        // `null` is the literal null, distinct from `.` (identity).
        XCTAssertEqual(try parseFilter("null"), .literal(.null))
        XCTAssertNotEqual(try parseFilter("null"), .identity)
    }

    // MARK: // (alternative) — jq drops false AND null

    func testAlternativeDropsFalseAndNull() throws {
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":false}"#), [#""d""#])
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":null}"#), [#""d""#])
        XCTAssertEqual(try run(#".a // "d""#, on: #"{}"#), [#""d""#])
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":1}"#), ["1"])
        // empty LHS → fall through.
        XCTAssertEqual(try run(#"empty // "d""#), [#""d""#])
    }

    // MARK: ?? (nullish) — keeps false, drops only null, both modes

    func testNullishKeepsFalse() throws {
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":false}"#), ["false"])
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":null}"#), [#""d""#])
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{}"#), [#""d""#])
        // Nullish is mode-independent.
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":false}"#, mode: .humane), ["false"])
    }

    // MARK: H1 — humane `//` becomes nullish (keeps false)

    func testHumaneAlternativeKeepsFalse() throws {
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":false}"#, mode: .humane), ["false"])
        // null still falls through in humane mode.
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":null}"#, mode: .humane), [#""d""#])
    }
}

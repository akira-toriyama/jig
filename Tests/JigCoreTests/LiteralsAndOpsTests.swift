import XCTest
@testable import JigCore

/// Literals + the `//` (drops false+null) / `??` (nullish, drops only null)
/// operators — kept deliberately distinct (roadmap §3/§5).
final class LiteralsAndOpsTests: XCTestCase {

    private func run(_ program: String, on json: String = "null") throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
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

    // MARK: ?? (nullish) — keeps false, drops only null

    func testNullishKeepsFalse() throws {
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":false}"#), ["false"])
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":null}"#), [#""d""#])
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{}"#), [#""d""#])
    }

    // `//` and `??` are distinct: `//` drops false (→ "d"), `??` keeps it.
    // (Old dual-mode "humane //" that kept false is gone; use `??` for that.)
    func testAlternativeAndNullishDifferOnFalse() throws {
        XCTAssertEqual(try run(#".a // "d""#, on: #"{"a":false}"#), [#""d""#])
        XCTAssertEqual(try run(#".a ?? "d""#, on: #"{"a":false}"#), ["false"])
    }
}

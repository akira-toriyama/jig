import XCTest
@testable import JigCore

/// Wave-1 builtins. Semantics track jq; the assertions double as a
/// mini-conformance set ahead of importing jq's own test suite.
final class BuiltinsTests: XCTestCase {

    private func run(_ program: String, on json: String) throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
            .map { writeJSON($0, style: .compact) }
    }

    func testLength() throws {
        XCTAssertEqual(try run("length", on: "null"), ["0"])
        XCTAssertEqual(try run("length", on: #""abc""#), ["3"])
        XCTAssertEqual(try run("length", on: "[1,2,3,4]"), ["4"])
        XCTAssertEqual(try run("length", on: #"{"a":1,"b":2}"#), ["2"])
        XCTAssertEqual(try run("length", on: "-5"), ["5"])
        XCTAssertThrowsError(try run("length", on: "true"))
    }

    func testKeysSortedAndUnsorted() throws {
        XCTAssertEqual(try run("keys", on: #"{"b":2,"a":1,"c":3}"#), [#"["a","b","c"]"#])
        XCTAssertEqual(try run("keys_unsorted", on: #"{"b":2,"a":1,"c":3}"#), [#"["b","a","c"]"#])
        XCTAssertEqual(try run("keys", on: "[10,20]"), ["[0,1]"])
        XCTAssertThrowsError(try run("keys", on: "5"))
    }

    func testTypeofCanonicalAndTypeAlias() throws {
        // typeof is the canonical (es-toolkit/JS) name.
        XCTAssertEqual(try run("typeof", on: "null"), [#""null""#])
        XCTAssertEqual(try run("typeof", on: "true"), [#""boolean""#])
        XCTAssertEqual(try run("typeof", on: "1"), [#""number""#])
        XCTAssertEqual(try run("typeof", on: #""x""#), [#""string""#])
        XCTAssertEqual(try run("typeof", on: "[]"), [#""array""#])
        XCTAssertEqual(try run("typeof", on: "{}"), [#""object""#])
        // `type` is the accepted jq alias (same implementation).
        XCTAssertEqual(try run("type", on: "1"), [#""number""#])
    }

    func testNot() throws {
        XCTAssertEqual(try run("not", on: "true"), ["false"])
        XCTAssertEqual(try run("not", on: "false"), ["true"])
        XCTAssertEqual(try run("not", on: "null"), ["true"])
        XCTAssertEqual(try run("not", on: "0"), ["false"])  // 0 is truthy in jq
    }

    func testReverse() throws {
        XCTAssertEqual(try run("reverse", on: "[1,2,3]"), ["[3,2,1]"])
        XCTAssertEqual(try run("reverse", on: #""abc""#), [#""cba""#])
        XCTAssertEqual(try run("reverse", on: "null"), ["null"])
        XCTAssertThrowsError(try run("reverse", on: "5"))
    }

    func testSumCanonicalAndAddAlias() throws {
        // sum is the canonical (es-toolkit) name.
        XCTAssertEqual(try run("sum", on: "[1,2,3]"), ["6"])
        XCTAssertEqual(try run("sum", on: "[[1],[2],[3]]"), ["[1,2,3]"])
        XCTAssertEqual(try run("sum", on: #"["a","b","c"]"#), [#""abc""#])
        XCTAssertEqual(try run("sum", on: "[]"), ["null"])
        XCTAssertEqual(try run("sum", on: "null"), ["null"])
        XCTAssertEqual(try run("sum", on: #"[{"a":1},{"b":2}]"#), [#"{"a":1,"b":2}"#])
        XCTAssertThrowsError(try run("sum", on: "[1,\"x\"]"))
        // `add` is the accepted jq alias (same implementation).
        XCTAssertEqual(try run("add", on: "[1,2,3]"), ["6"])
    }

    func testEmpty() throws {
        XCTAssertEqual(try run("empty", on: "1"), [])
    }

    func testMap() throws {
        XCTAssertEqual(try run("map(.name)", on: #"[{"name":"ann"},{"name":"bob"}]"#),
                       [#"["ann","bob"]"#])
        // map over an object iterates its values (jq def map(f): [.[]|f]).
        XCTAssertEqual(try run("map(.)", on: #"{"a":1,"b":2}"#), ["[1,2]"])
    }

    func testFilterCanonicalAndSelectAlias() throws {
        // filter is the canonical (es-toolkit/JS) name.
        XCTAssertEqual(
            try run("map(filter(.active))",
                    on: #"[{"active":true,"n":1},{"active":false,"n":2}]"#),
            [#"[{"active":true,"n":1}]"#])
        // `select` is the accepted jq alias of filter (same implementation).
        XCTAssertEqual(
            try run("map(select(.active))",
                    on: #"[{"active":true,"n":1},{"active":false,"n":2}]"#),
            [#"[{"active":true,"n":1}]"#])
    }

    func testHas() throws {
        XCTAssertEqual(try run(#"has("a")"#, on: #"{"a":1}"#), ["true"])
        XCTAssertEqual(try run(#"has("z")"#, on: #"{"a":1}"#), ["false"])
        XCTAssertEqual(try run("has(0)", on: "[10]"), ["true"])
        XCTAssertEqual(try run("has(5)", on: "[10]"), ["false"])
    }

    func testUnknownBuiltinErrorsWithSpan() throws {
        XCTAssertThrowsError(try run("frobnicate", on: "1")) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("not defined"), e.message)
            XCTAssertNotNil(e.span)
        }
    }
}

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

    // MARK: Wave 1 composition set (docs/plan-wave1.md)

    func testRange() throws {
        XCTAssertEqual(try run("[range(5)]", on: "null"), ["[0,1,2,3,4]"])
        XCTAssertEqual(try run("[range(2;7)]", on: "null"), ["[2,3,4,5,6]"])
        XCTAssertEqual(try run("[range(0;10;3)]", on: "null"), ["[0,3,6,9]"])
        XCTAssertEqual(try run("[range(5;0;-2)]", on: "null"), ["[5,3,1]"])
        XCTAssertEqual(try run("[range(0)]", on: "null"), ["[]"])
        // range is a stream (not an array) — it emits each number.
        XCTAssertEqual(try run("range(3)", on: "null"), ["0", "1", "2"])
    }

    func testRangeErrors() throws {
        XCTAssertThrowsError(try run("range(0;5;0)", on: "null")) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("step cannot be zero"), e.message)
        }
        XCTAssertThrowsError(try run(#"range("x")"#, on: "null")) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("must be a number"), e.message)
        }
    }

    func testGroupBy() throws {
        XCTAssertEqual(
            try run("groupBy(.g)", on: #"[{"g":"a","n":1},{"g":"b","n":2},{"g":"a","n":3}]"#),
            [#"{"a":[{"g":"a","n":1},{"g":"a","n":3}],"b":[{"g":"b","n":2}]}"#])
        // Numeric/boolean keys coerce to compact-JSON strings (the tostring rule).
        XCTAssertEqual(try run("groupBy(.k)", on: #"[{"k":1},{"k":1},{"k":2}]"#),
                       [#"{"1":[{"k":1},{"k":1}],"2":[{"k":2}]}"#])
        // A null/missing key is a humane error, not a silent "null" bucket.
        XCTAssertThrowsError(try run("groupBy(.missing)", on: #"[{"x":1}]"#)) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("keys must be string, number, or boolean"), e.message)
        }
        XCTAssertThrowsError(try run("groupBy(.x)", on: "5"))
    }

    func testMapValues() throws {
        XCTAssertEqual(try run("mapValues(length)", on: #"{"a":[1,2],"b":[3,4,5]}"#),
                       [#"{"a":2,"b":3}"#])
        // Arrays keep order; an empty f output drops the entry (jq `.[] |= f`).
        XCTAssertEqual(try run("mapValues(. + 10)", on: "[1,2,3]"), ["[11,12,13]"])
        XCTAssertEqual(try run("mapValues(select(. > 1))", on: #"{"a":1,"b":2,"c":3}"#),
                       [#"{"b":2,"c":3}"#])
        // `map_values` is the accepted jq alias.
        XCTAssertEqual(try run("map_values(. + 1)", on: #"{"a":1}"#), [#"{"a":2}"#])
        XCTAssertThrowsError(try run("mapValues(.)", on: "5"))
    }

    func testToPairsAndFromPairs() throws {
        XCTAssertEqual(try run("toPairs", on: #"{"a":1,"b":2}"#), [#"[["a",1],["b",2]]"#])
        XCTAssertEqual(try run("fromPairs", on: #"[["a",1],["b",2]]"#), [#"{"a":1,"b":2}"#])
        // Round-trip and last-wins on a duplicate key (first position kept).
        XCTAssertEqual(try run("toPairs | fromPairs", on: #"{"x":10,"y":20}"#), [#"{"x":10,"y":20}"#])
        XCTAssertEqual(try run("fromPairs", on: #"[["a",1],["a",9]]"#), [#"{"a":9}"#])
        XCTAssertThrowsError(try run("toPairs", on: "5"))
        XCTAssertThrowsError(try run("fromPairs", on: "[[1,2,3]]"))   // wrong arity
        XCTAssertThrowsError(try run("fromPairs", on: "[[1,2]]"))     // non-string key
    }

    func testOrderBy() throws {
        XCTAssertEqual(try run("orderBy(.age)", on: #"[{"age":30},{"age":10},{"age":20}]"#),
                       [#"[{"age":10},{"age":20},{"age":30}]"#])
        // Multi-key: comma forms the key TUPLE (a stream, not an arg separator).
        XCTAssertEqual(
            try run("orderBy(.d, .a)", on: #"[{"d":"x","a":2},{"d":"x","a":1},{"d":"a","a":9}]"#),
            [#"[{"d":"a","a":9},{"d":"x","a":1},{"d":"x","a":2}]"#])
        // Descending is composition, not a direction arg.
        XCTAssertEqual(try run("orderBy(.age) | reverse", on: #"[{"age":30},{"age":10},{"age":20}]"#),
                       [#"[{"age":30},{"age":20},{"age":10}]"#])
        // Total order across types: null < false < true < number < string.
        XCTAssertEqual(try run("orderBy(.)", on: #"[3,"b",null,true,1,"a",false]"#),
                       [#"[null,false,true,1,3,"a","b"]"#])
        XCTAssertEqual(try run("orderBy(.age)", on: "[]"), ["[]"])
    }

    func testOrderByIsStable() throws {
        // Equal keys preserve input order (index tie-break).
        XCTAssertEqual(
            try run("orderBy(.k)", on: #"[{"k":1,"id":"a"},{"k":1,"id":"b"},{"k":0,"id":"c"}]"#),
            [#"[{"k":0,"id":"c"},{"k":1,"id":"a"},{"k":1,"id":"b"}]"#])
    }

    func testOrderByMissingKeySortsAsNull() throws {
        XCTAssertEqual(try run("orderBy(.age)", on: #"[{"age":5},{"x":1},{"age":2}]"#),
                       [#"[{"x":1},{"age":2},{"age":5}]"#])
    }

    func testOrderByNonArrayErrors() throws {
        XCTAssertThrowsError(try run("orderBy(.a)", on: #"{"a":1}"#)) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("cannot orderBy"), e.message)
        }
    }

    // The `orderBy(.x, "desc")` footgun: a string literal is sorted as a constant
    // key (a no-op), never a direction. jig flags it with a humane hint instead
    // of silently doing nothing (principles §5).
    func testOrderByStringLiteralKeyIsDiagnosed() throws {
        for prog in [#"orderBy(.x, "desc")"#, #"orderBy("desc")"#] {
            XCTAssertThrowsError(try run(prog, on: #"[{"x":1}]"#)) { error in
                guard let e = error as? EvalError else { return XCTFail() }
                XCTAssertTrue(e.message.contains("string literal"), e.message)
                XCTAssertTrue((e.hint ?? "").contains("| reverse"), e.hint ?? "")
            }
        }
        // A string PRODUCED by an expression is a legitimate key — not flagged.
        XCTAssertEqual(try run(#"orderBy("\(.n)")"#, on: #"[{"n":"bo"},{"n":"al"}]"#),
                       [#"[{"n":"al"},{"n":"bo"}]"#])
    }

    // The headline "small composables" goal (docs/plan-wave1.md): countBy is just
    // groupBy then mapValues(length) — no dedicated builtin needed.
    func testGroupByMapValuesComposesToCountBy() throws {
        XCTAssertEqual(try run("groupBy(.g) | mapValues(length)", on: #"[{"g":"a"},{"g":"b"},{"g":"a"}]"#),
                       [#"{"a":2,"b":1}"#])
    }

    // MARK: Wave 1 aggregation set (docs/roadmap.md §3 — reductions over arrays)

    func testMinMax() throws {
        XCTAssertEqual(try run("min", on: "[3,1,2,1]"), ["1"])
        XCTAssertEqual(try run("max", on: "[3,1,2,1]"), ["3"])
        // Empty → null (the empty-aggregate discipline), not an error.
        XCTAssertEqual(try run("min", on: "[]"), ["null"])
        XCTAssertEqual(try run("max", on: "[]"), ["null"])
        // Mixed types use jq's total order: null < false < true < number < string.
        XCTAssertEqual(try run("min", on: #"[3,"b",null,true,1]"#), ["null"])
        XCTAssertEqual(try run("max", on: #"[3,"b",null,true,1]"#), [#""b""#])
        XCTAssertThrowsError(try run("min", on: "5"))
    }

    func testMinByMaxByTieBreakMatchesJq() throws {
        // jq tie-break: minBy keeps the FIRST minimum, maxBy the LAST maximum.
        let data = #"[{"k":2,"id":"a"},{"k":1,"id":"b"},{"k":1,"id":"c"},{"k":2,"id":"d"}]"#
        XCTAssertEqual(try run("minBy(.k)", on: data), [#"{"k":1,"id":"b"}"#])
        XCTAssertEqual(try run("maxBy(.k)", on: data), [#"{"k":2,"id":"d"}"#])
        // `min_by` / `max_by` are the accepted jq aliases.
        XCTAssertEqual(try run("min_by(.k)", on: data), [#"{"k":1,"id":"b"}"#])
        XCTAssertEqual(try run("max_by(.k)", on: data), [#"{"k":2,"id":"d"}"#])
        XCTAssertEqual(try run("minBy(.k)", on: "[]"), ["null"])
    }

    func testUniqIsOrderPreserving() throws {
        // jig's uniq keeps input order (jq's `unique` SORTS — uniq is not aliased).
        XCTAssertEqual(try run("uniq", on: "[3,1,2,1,3]"), ["[3,1,2]"])
        // Equality is jq's `==` — objects compare order-insensitively.
        XCTAssertEqual(try run("uniq", on: #"[{"a":1,"b":2},{"b":2,"a":1}]"#), [#"[{"a":1,"b":2}]"#])
        XCTAssertEqual(try run("uniqBy(.t)", on: #"[{"t":"x","n":1},{"t":"y","n":2},{"t":"x","n":3}]"#),
                       [#"[{"t":"x","n":1},{"t":"y","n":2}]"#])
        XCTAssertThrowsError(try run("uniq", on: "5"))
    }

    func testCountByKeyBySumBy() throws {
        XCTAssertEqual(try run("countBy(.g)", on: #"[{"g":"a"},{"g":"b"},{"g":"a"}]"#), [#"{"a":2,"b":1}"#])
        // keyBy: duplicate key keeps first position, last record wins.
        XCTAssertEqual(try run("keyBy(.id)", on: #"[{"id":"x","v":1},{"id":"y","v":2},{"id":"x","v":9}]"#),
                       [#"{"x":{"id":"x","v":9},"y":{"id":"y","v":2}}"#])
        XCTAssertEqual(try run("sumBy(.x)", on: #"[{"x":1},{"x":2},{"x":3}]"#), ["6"])
        XCTAssertEqual(try run("sumBy(.x)", on: "[]"), ["null"])   // empty → null, like sum
        // countBy == groupBy | mapValues(length) (the composition it bottles).
        XCTAssertEqual(try run("countBy(.g)", on: #"[{"g":"a"},{"g":"b"},{"g":"a"}]"#),
                       try run("groupBy(.g) | mapValues(length)", on: #"[{"g":"a"},{"g":"b"},{"g":"a"}]"#))
        XCTAssertThrowsError(try run("keyBy(.id)", on: "5"))
    }
}

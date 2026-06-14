import XCTest
@testable import JigCore

/// `reduce SOURCE as $x (INIT; UPDATE)` and `$variable` binding
/// (docs/roadmap.md §5(5)). Semantics track jq: ONE independent fold per INIT
/// output (an empty INIT → no output; N INIT outputs → N results); within a
/// fold each SOURCE value updates the accumulator, taking UPDATE's LAST output
/// (empty → null). Binding is by substitution, so lexical shadowing holds.
final class ReduceTests: XCTestCase {

    private func run(_ program: String, on json: String) throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
            .map { writeJSON($0, style: .compact) }
    }

    func testBasicFolds() throws {
        XCTAssertEqual(try run("reduce .[] as $x (0; . + $x)", on: "[1,2,3,4]"), ["10"])
        XCTAssertEqual(try run("reduce .[] as $x (1; . * $x)", on: "[1,2,3,4,5]"), ["120"])
        XCTAssertEqual(try run("reduce .[] as $x ([]; . + [$x*$x])", on: "[1,2,3]"), ["[1,4,9]"])
    }

    func testUpdateLastOutputWinsEmptyIsNull() throws {
        // UPDATE yielding several values uses the LAST (jq).
        XCTAssertEqual(try run("reduce .[] as $x (0; . + $x, . + $x*10)", on: "[1,2]"), ["30"])
        // UPDATE yielding nothing makes the accumulator null (jq).
        XCTAssertEqual(try run("reduce .[] as $x (0; empty)", on: "[1,2]"), ["null"])
    }

    // jq folds INIT's stream 1:1 — one independent fold (and one output) per
    // INIT value; an empty INIT yields no output. (Regression: an earlier
    // version collapsed INIT to its first output and always emitted one value.)
    func testInitStreamFoldsOnePerOutput() throws {
        XCTAssertEqual(try run("reduce range(2) as $x ((1,2); . + 1)", on: "null"), ["3", "4"])
        XCTAssertEqual(try run("reduce (4,5) as $x ((1,10,100); . + $x)", on: "null"),
                       ["10", "19", "109"])
        // Empty INIT → no folds, no output.
        XCTAssertEqual(try run("reduce range(3) as $x (empty; . + 1)", on: "null"), [])
        // Empty SOURCE → each INIT value passes through unchanged.
        XCTAssertEqual(try run("reduce empty as $x (1,2,3; . + $x)", on: "null"), ["1", "2", "3"])
    }

    func testNestedVariableAndSources() throws {
        XCTAssertEqual(try run("reduce .[] as $x (0; . + ($x | . * 2))", on: "[1,2,3]"), ["12"])
        XCTAssertEqual(try run("reduce .xs[] as $x (0; . + $x)", on: #"{"xs":[1,2,3]}"#), ["6"])
        XCTAssertEqual(try run("reduce range(5) as $x (0; . + $x)", on: "null"), ["10"])
        // A $var can reach into the bound value's fields.
        XCTAssertEqual(
            try run("reduce .[] as $r (0; . + ($r.qty * $r.price))",
                    on: #"[{"qty":2,"price":3},{"qty":1,"price":10}]"#),
            ["16"])
    }

    func testNestedReduceShadowsSameName() throws {
        // The inner `as $x` shadows the outer; substitution must not cross it.
        XCTAssertEqual(
            try run("reduce .[] as $x (0; . + (reduce $x as $x (0; . + $x)))", on: "[1,2,3]"),
            ["6"])
    }

    func testReduceComposesInAPipe() throws {
        XCTAssertEqual(try run("reduce .[] as $x (0; . + $x) | . * 2", on: "[1,2,3]"), ["12"])
    }

    func testUnboundVariableErrors() throws {
        XCTAssertThrowsError(try run(". + $x", on: "1")) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("$x is not defined"), e.message)
            XCTAssertNotNil(e.span)
        }
    }

    func testParseErrors() throws {
        XCTAssertThrowsError(try parseFilter("reduce .[] $x (0; .)"))      // missing `as`
        XCTAssertThrowsError(try parseFilter("reduce .[] as x (0; .)"))    // missing `$`
        XCTAssertThrowsError(try parseFilter("reduce .[] as $x (0 . )"))   // missing `;`
        XCTAssertThrowsError(try parseFilter("reduce .[] as $x (0; .")) // missing `)`
    }

    // `reduce` is a keyword in value position only — it must not shadow object
    // keys or field names.
    func testReduceWordStillWorksAsKeyAndField() throws {
        XCTAssertEqual(try run("{reduce}", on: #"{"reduce":5}"#), [#"{"reduce":5}"#])
        XCTAssertEqual(try run(".reduce", on: #"{"reduce":5}"#), ["5"])
    }

    func testRenderAndJs() {
        XCTAssertEqual(render(try! parseFilter("reduce .[] as $x (0; . + $x)")),
                       "reduce .[] as $x (0; . + $x)")
        // A compound source is parenthesized so it re-parses as one term.
        XCTAssertEqual(render(try! parseFilter("reduce (.a, .b) as $x (0; . + $x)")),
                       "reduce (.a, .b) as $x (0; . + $x)")
        XCTAssertEqual(render(try! parseFilter("$x")), "$x")
        XCTAssertEqual(jsEquivalent(try! parseFilter("reduce .[] as $x (0; . + $x)")),
                       "input.reduce((acc, x) => (acc + x), 0)")
    }
}

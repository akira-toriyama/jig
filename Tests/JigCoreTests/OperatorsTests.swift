import XCTest
@testable import JigCore

/// Arithmetic (`+ - * / %`), comparison (`== != < <= > >=`), logical
/// (`and` / `or`), and unary minus — roadmap step 3. Golden checks against
/// jig's own spec; the expectations were originally cross-checked against
/// jq 1.8.1. Object/array *construction* literals predate this file's operands,
/// so collection operands come from the input JSON.
final class OperatorsTests: XCTestCase {

    private func run(_ program: String, on json: String = "null") throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
            .map { writeJSON($0, style: .compact) }
    }

    /// Assert the program raises a runtime EvalError whose message contains
    /// `needle`.
    private func assertEvalError(_ program: String, on json: String = "null",
                                 contains needle: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            let out = try run(program, on: json)
            XCTFail("expected error, got \(out)", file: file, line: line)
        } catch let e as EvalError {
            XCTAssertTrue(e.message.contains(needle),
                          "message was: \(e.message)", file: file, line: line)
        } catch {
            XCTFail("expected EvalError, got \(error)", file: file, line: line)
        }
    }

    // MARK: arithmetic — +

    func testAddition() throws {
        XCTAssertEqual(try run("2 + 3"), ["5"])
        XCTAssertEqual(try run("2.5 + 0.5"), ["3"])           // integral result drops .0
        XCTAssertEqual(try run(#""a" + "b""#), [#""ab""#])    // string concat
        XCTAssertEqual(try run(".a + .b", on: #"{"a":[1],"b":[2,3]}"#), ["[1,2,3]"])  // array concat
        XCTAssertEqual(try run(".x + .y", on: #"{"x":{"a":1},"y":{"b":2,"a":9}}"#), [#"{"a":9,"b":2}"#])
    }

    func testAddNullIdentity() throws {
        // jq: null is the identity of + (on either side); null+null = null.
        XCTAssertEqual(try run("null + 1"), ["1"])
        XCTAssertEqual(try run("1 + null"), ["1"])
        XCTAssertEqual(try run("null + null"), ["null"])
    }

    func testAddTypeMismatchErrors() {
        assertEvalError("1 + \"a\"", contains: #"number (1) and string ("a") cannot be added"#)
    }

    // MARK: arithmetic — - (subtraction is NOT null-identity, unlike +)

    func testSubtraction() throws {
        XCTAssertEqual(try run("5 - 3"), ["2"])
        XCTAssertEqual(try run("3 - 5"), ["-2"])
        // array difference: remove every element that appears in the rhs,
        // keeping order and duplicates that survive.
        XCTAssertEqual(try run(".a - .b", on: #"{"a":[1,1,2,3,2],"b":[2]}"#), ["[1,1,3]"])
    }

    func testSubtractNullErrors() {
        assertEvalError("1 - null", contains: "number (1) and null (null) cannot be subtracted")
        assertEvalError("null - 1", contains: "null (null) and number (1) cannot be subtracted")
    }

    // MARK: arithmetic — *

    func testMultiplication() throws {
        XCTAssertEqual(try run("6 * 7"), ["42"])
        XCTAssertEqual(try run("-2 * 3"), ["-6"])
    }

    func testStringRepeat() throws {
        // string × number repeats; commutative in jq; trunc(count); 0 → "";
        // negative → null (jq's quirk).
        XCTAssertEqual(try run(#""ab" * 3"#), [#""ababab""#])
        XCTAssertEqual(try run(#"3 * "ab""#), [#""ababab""#])      // number × string too
        XCTAssertEqual(try run(#""ab" * 1.9"#), [#""ab""#])        // truncated to 1
        XCTAssertEqual(try run(#""ab" * 0"#), [#""""#])            // empty string
        XCTAssertEqual(try run(#""ab" * -1"#), ["null"])           // negative → null
    }

    func testObjectDeepMerge() throws {
        // `*` deep-merges objects recursively (right wins on scalar leaves).
        XCTAssertEqual(
            try run(".x * .y", on: #"{"x":{"a":{"p":1},"b":2},"y":{"a":{"q":9},"c":3}}"#),
            [#"{"a":{"p":1,"q":9},"b":2,"c":3}"#])
    }

    func testMultiplyTypeMismatchErrors() {
        assertEvalError(".a * 2", on: #"{"a":[1]}"#,
                        contains: "array ([1]) and number (2) cannot be multiplied")
    }

    func testComputedNegativeZeroKeepsSign() throws {
        // jq prints a computed -0.0 as -0 (the integral fast path must not
        // drop the sign). A literal +0 result stays 0.
        XCTAssertEqual(try run("0 * -1"), ["-0"])
        XCTAssertEqual(try run("0 / -1"), ["-0"])
        XCTAssertEqual(try run("-3 * 0"), ["-0"])
        XCTAssertEqual(try run("0 * 1"), ["0"])
        XCTAssertEqual(try run("0 * 0"), ["0"])
    }

    // MARK: arithmetic — /

    func testDivision() throws {
        XCTAssertEqual(try run("7 / 2"), ["3.5"])
        XCTAssertEqual(try run("6 / 2"), ["3"])               // integral result
        XCTAssertEqual(try run("8 / 2 / 2"), ["2"])           // left-associative
    }

    func testStringSplit() throws {
        XCTAssertEqual(try run(#""a,b,c" / ",""#), [#"["a","b","c"]"#])
        XCTAssertEqual(try run(#""a,,b" / ",""#), [#"["a","","b"]"#])   // empty fields kept
        XCTAssertEqual(try run(#""a::b::c" / "::""#), [#"["a","b","c"]"#])  // multi-char sep
        XCTAssertEqual(try run(#""abc" / """#), [#"["a","b","c"]"#])    // empty sep → chars
    }

    func testStringSplitEmptyInput() throws {
        // jq quirk: splitting the empty string yields [] (not [""]), for any
        // separator including the empty one.
        XCTAssertEqual(try run(#""" / ",""#), ["[]"])
        XCTAssertEqual(try run(#""" / "abc""#), ["[]"])
        XCTAssertEqual(try run(#""" / """#), ["[]"])
    }

    func testDivideByZeroErrors() {
        assertEvalError("1 / 0", contains: "cannot be divided because the divisor is zero")
    }

    // MARK: arithmetic — % (integer remainder, C sign semantics)

    func testModulo() throws {
        XCTAssertEqual(try run("7 % 3"), ["1"])
        XCTAssertEqual(try run("-7 % 3"), ["-1"])     // sign follows dividend
        XCTAssertEqual(try run("7 % -3"), ["1"])
        XCTAssertEqual(try run("7.9 % 3.2"), ["1"])   // operands truncated to ints first
    }

    func testModuloByZeroErrors() {
        assertEvalError("1 % 0", contains: "cannot be divided (remainder) because the divisor is zero")
    }

    // MARK: comparison — == / !=  (deep, numeric-aware)

    func testEquality() throws {
        XCTAssertEqual(try run("1 == 1.0"), ["true"])        // numeric, not textual
        XCTAssertEqual(try run("1 == 2"), ["false"])
        XCTAssertEqual(try run("1 != 2"), ["true"])
        XCTAssertEqual(try run(#""a" == "a""#), ["true"])
        // objects compare as maps (key order irrelevant); arrays element-wise.
        XCTAssertEqual(try run(".p == .q", on: #"{"p":{"a":1,"b":2},"q":{"b":2,"a":1}}"#), ["true"])
        XCTAssertEqual(try run(".p != .q", on: #"{"p":[1,2],"q":[2,1]}"#), ["true"])
    }

    // MARK: comparison — < <= > >=  (jq total order across types)

    func testOrderAcrossTypes() throws {
        // null < false < true < number < string < array < object
        XCTAssertEqual(try run("null < false"), ["true"])
        XCTAssertEqual(try run("false < true"), ["true"])
        XCTAssertEqual(try run("true < 0"), ["true"])
        XCTAssertEqual(try run(#"5 < "a""#), ["true"])
        XCTAssertEqual(try run(#".a < .b"#, on: #"{"a":"z","b":[1]}"#), ["true"])  // string < array
        XCTAssertEqual(try run(#".a < .b"#, on: #"{"a":[9],"b":{}}"#), ["true"])   // array < object
    }

    func testOrderWithinType() throws {
        XCTAssertEqual(try run("2 < 10"), ["true"])           // numeric, not lexical
        XCTAssertEqual(try run(#""ab" < "b""#), ["true"])     // codepoint order
        XCTAssertEqual(try run("3 <= 3"), ["true"])
        XCTAssertEqual(try run("3 >= 4"), ["false"])
        XCTAssertEqual(try run("5 > 2"), ["true"])
        // arrays lexicographically; a proper prefix is the smaller one.
        XCTAssertEqual(try run(".p < .q", on: #"{"p":[1,2],"q":[1,3]}"#), ["true"])
        XCTAssertEqual(try run(".p < .q", on: #"{"p":[1],"q":[1,0]}"#), ["true"])
    }

    func testObjectOrder() throws {
        // Sorted key lists compare first, then values in sorted-key order.
        XCTAssertEqual(try run(".p < .q", on: #"{"p":{"a":1},"q":{"a":2}}"#), ["true"])   // by value
        XCTAssertEqual(try run(".p < .q", on: #"{"p":{"a":1,"b":2},"q":{"a":1}}"#), ["false"]) // more keys → greater
        XCTAssertEqual(try run(".p < .q", on: #"{"p":{"b":1},"q":{"a":9}}"#), ["false"]) // "b" > "a"
    }

    // MARK: cartesian product (rhs is the outer loop, matching jq)

    func testCartesianOrder() throws {
        // (1,2) - (0,10): r=0 → 1,2 ; r=10 → -9,-8
        XCTAssertEqual(try run("(1,2) - (0,10)"), ["1", "2", "-9", "-8"])
        XCTAssertEqual(try run(#"("a","b") + ("x","y")"#), [#""ax""#, #""bx""#, #""ay""#, #""by""#])
        XCTAssertEqual(try run("(1,2) < 2"), ["true", "false"])
    }

    func testEmptyOperandShortsToEmpty() throws {
        XCTAssertEqual(try run("empty + 1"), [])
        XCTAssertEqual(try run("1 + empty"), [])
    }

    // MARK: logical — and / or  (short-circuit, always boolean)

    func testAndOr() throws {
        XCTAssertEqual(try run("true and true"), ["true"])
        XCTAssertEqual(try run("true and false"), ["false"])
        XCTAssertEqual(try run("false or true"), ["true"])
        // non-booleans are coerced by truthiness; result is always a boolean.
        XCTAssertEqual(try run("1 and 2"), ["true"])
        XCTAssertEqual(try run("null or 5"), ["true"])
        XCTAssertEqual(try run("0 and \"\""), ["true"])   // 0 and "" are truthy in jq
    }

    func testLogicalShortCircuit() throws {
        // The rhs is never evaluated when the lhs already decides the result,
        // so a would-be runtime error on the rhs does not fire.
        XCTAssertEqual(try run("false and (1 / 0)"), ["false"])
        XCTAssertEqual(try run("true or (1 / 0)"), ["true"])
    }

    func testLogicalCartesian() throws {
        // lhs drives (short-circuit), so a falsy lhs emits one false.
        XCTAssertEqual(try run("(true,false) and (true,false)"), ["true", "false", "false"])
        XCTAssertEqual(try run("(null,1) or (2,3)"), ["true", "true", "true"])
    }

    func testNotBuiltinInterplay() throws {
        // `not` is the 0-arity builtin (wave 1); it composes with the new ops.
        XCTAssertEqual(try run("(1 == 2) | not"), ["true"])
        XCTAssertEqual(try run("true and false | not"), ["true"])
    }

    // MARK: unary minus

    func testUnaryMinus() throws {
        XCTAssertEqual(try run("-.a", on: #"{"a":3}"#), ["-3"])
        XCTAssertEqual(try run("-.a", on: #"{"a":-2.5}"#), ["2.5"])
        XCTAssertEqual(try run("-(1 + 2)"), ["-3"])
    }

    func testLeadingDotDecimal() throws {
        // jq accepts the leading-dot decimal form `.5` (= 0.5); jig normalizes
        // it to a 0-prefixed literal so output and arithmetic match jq.
        XCTAssertEqual(try run(".5"), ["0.5"])
        XCTAssertEqual(try run(".5 + 1"), ["1.5"])
        XCTAssertEqual(try run(".25 * 4"), ["1"])
        XCTAssertEqual(try run("-.5"), ["-0.5"])    // via unary minus
        // `.5` must not be confused with identity `.` or a `.field`.
        guard case .literal(.number) = try parseFilter(".5") else { return XCTFail() }
        XCTAssertEqual(try parseFilter("."), .identity)
    }

    func testNegativeLiteralPreservesText() throws {
        // `-<digits>` is folded into a number literal, so the exact source
        // text round-trips (a 64-bit id stays intact, like jq).
        XCTAssertEqual(try run("-10000000000000000001"), ["-10000000000000000001"])
        XCTAssertEqual(try parseFilter("-3"), .literal(.number(JigNumber(literal: "-3", double: -3))))
    }

    func testNegateNonNumberErrors() {
        assertEvalError("-.a", on: #"{"a":"x"}"#, contains: #"string ("x") cannot be negated"#)
    }

    // MARK: precedence & associativity (behavioral — proves the parse tree)

    func testPrecedence() throws {
        XCTAssertEqual(try run("2 + 3 * 4"), ["14"])      // * over +
        XCTAssertEqual(try run("2 * 3 + 4"), ["10"])
        XCTAssertEqual(try run("10 - 2 - 3"), ["5"])      // - left-associative
        XCTAssertEqual(try run("2 - 3 + 4"), ["3"])
        XCTAssertEqual(try run("1 + 1 == 2"), ["true"])   // + over == (else 1==2 → 1+false errors)
        XCTAssertEqual(try run("true or false and false"), ["true"])  // and over or
    }

    func testNegBindsTighterThanMultiply() throws {
        // -2 * 3 = (-2) * 3, not -(2 * 3) — both are -6, but -.a * 2 disambiguates.
        XCTAssertEqual(try run("-.a * 2", on: #"{"a":4}"#), ["-8"])
    }

    func testComparisonIsNonAssociative() {
        // jq rejects `1 < 2 < 3`; jig stops after the single comparison and
        // reports the trailing operator.
        XCTAssertThrowsError(try parseFilter("1 < 2 < 3")) { error in
            guard let e = error as? FilterParseError else { return XCTFail("\(error)") }
            XCTAssertTrue(e.message.contains("unexpected"), e.message)
        }
    }

    func testDivisionVsAlternativeOperator() throws {
        // `/` is division, `//` is the alternative — the multiplicative layer
        // must not swallow the first slash of `//`.
        XCTAssertEqual(try run("6 / 2"), ["3"])
        XCTAssertEqual(try run(#".a // 5"#, on: #"{"a":null}"#), ["5"])
        XCTAssertEqual(try run(#".a // 5"#, on: #"{"a":7}"#), ["7"])
    }

    func testKeywordBoundary() throws {
        // `.order` / `.and` are field accesses, not the operators or/and.
        XCTAssertEqual(try run(".order", on: #"{"order":9}"#), ["9"])
        XCTAssertEqual(try run(".and", on: #"{"and":true}"#), ["true"])
    }

    // MARK: explain / render of the new nodes

    func testRenderRoundTrip() throws {
        // render() parenthesizes infix operands so its text re-parses to the
        // same tree (precedence-faithful) — feeds `jig explain`.
        XCTAssertEqual(render(try parseFilter("2 + 3 * 4")), "2 + (3 * 4)")
        XCTAssertEqual(render(try parseFilter("(2 + 3) * 4")), "(2 + 3) * 4")
        XCTAssertEqual(render(try parseFilter(".a and .b")), ".a and .b")
        XCTAssertEqual(render(try parseFilter("-.x")), "-.x")
        XCTAssertEqual(render(try parseFilter("-(.a + .b)")), "-(.a + .b)")
    }

    func testJsEquivalent() throws {
        XCTAssertEqual(jsEquivalent(try parseFilter(".a + .b")), "(input.a + input.b)")
        XCTAssertEqual(jsEquivalent(try parseFilter(".a == .b")), "(input.a === input.b)")
        XCTAssertEqual(jsEquivalent(try parseFilter(".a and .b")), "(input.a && input.b)")
    }
}

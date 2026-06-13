import XCTest
@testable import JigCore

/// String interpolation `"\(…)"` and its additive ECMAScript alias `"${…}"` —
/// docs/jq-compat.md step 2 (the last of construction). Golden-style
/// parse → eval → write checks; every `\(…)` expectation was confirmed
/// byte-for-byte against the jq 1.8 reference binary (jq mode must not diverge).
/// `${…}` has no jq oracle — jq treats `${` as literal text — so its tests
/// assert it produces the SAME result as the equivalent `\(…)`.
final class InterpolationTests: XCTestCase {

    private func run(_ program: String, on json: String = "null",
                     mode: JigMode = .jq) throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json), mode: mode)
            .map { writeJSON($0, style: .compact) }
    }

    // MARK: coercion — jq's `tostring` rule (string verbatim, else compact JSON)

    func testScalarCoercion() throws {
        XCTAssertEqual(try run(#""\(1)""#), [#""1""#])
        XCTAssertEqual(try run(#""\("x")""#), [#""x""#])   // a string drops its quotes
        XCTAssertEqual(try run(#""\(null)""#), [#""null""#])
        XCTAssertEqual(try run(#""\(true)""#), [#""true""#])
    }

    func testCompoundCoercionIsCompactJSON() throws {
        XCTAssertEqual(try run(#""\([1,2])""#), [#""[1,2]""#])
        XCTAssertEqual(try run(#""\({"a":1})""#), [##""{\"a\":1}""##])
        // Only the TOP-LEVEL string is de-quoted; strings nested in a compound
        // keep their quotes (it's plain compact JSON).
        XCTAssertEqual(try run(#""\(["a","b"])""#), [##""[\"a\",\"b\"]""##])
        XCTAssertEqual(try run(#""\({"a":[1,{"b":2}]})""#), [##""{\"a\":[1,{\"b\":2}]}""##])
    }

    func testNumberLiteralPreservationRidesThrough() throws {
        // An untouched input number keeps its source text through interpolation.
        XCTAssertEqual(try run(#""\(.x)""#, on: #"{"x":1.0}"#), [#""1.0""#])
        XCTAssertEqual(try run(#""\(1.0)""#), [#""1.0""#])
        // …but a COMPUTED number decays to its double form (jq 1.7), same as +.
        XCTAssertEqual(try run(#""\(2+2)""#), [#""4""#])
        XCTAssertEqual(try run(#""\(100000000000000000000)""#),
                       [#""100000000000000000000""#])
    }

    // MARK: literal fragments, prefix / infix / suffix

    func testFragmentsAroundInterpolation() throws {
        XCTAssertEqual(try run(#""a\(.x)b""#, on: #"{"x":5}"#), [#""a5b""#])
        XCTAssertEqual(try run(#""\(.x)-\(.y)""#, on: #"{"x":5,"y":6}"#), [#""5-6""#])
        XCTAssertEqual(try run(#""[\(.x)]""#, on: #"{"x":""}"#), [#""[]""#])
    }

    func testStringWithNoInterpolationStaysAPlainLiteral() throws {
        XCTAssertEqual(try run(#""no interp""#), [#""no interp""#])
        // Parses to a plain `.literal`, NOT a `.stringInterp` node.
        guard case .literal(.string("no interp")) = try parseFilter(#""no interp""#)
        else { return XCTFail("\(try parseFilter(#""no interp""#))") }
    }

    // MARK: embedded full pipe / nesting

    func testEmbeddedExpressionIsAFullPipe() throws {
        XCTAssertEqual(try run(#""\(.x | length)""#, on: #"{"x":[1,2,3]}"#), [#""3""#])
        XCTAssertEqual(try run(#""\(.a.b)""#, on: #"{"a":{"b":7}}"#), [#""7""#])
        XCTAssertEqual(try run(#""\((1+2)*3)""#), [#""9""#])
    }

    func testNestedInterpolation() throws {
        XCTAssertEqual(try run(#""\("inner=\(.x)")""#, on: #"{"x":5}"#), [#""inner=5""#])
        XCTAssertEqual(try run(#""L1 \("L2 \("L3 \(.x)")")""#, on: #"{"x":5}"#),
                       [#""L1 L2 L3 5""#])
    }

    // MARK: generators — cartesian product, RIGHTMOST varies slowest (jq order)

    func testSingleGeneratorEmitsOnePerOutput() throws {
        XCTAssertEqual(try run(#""\(1,2)""#), [#""1""#, #""2""#])
    }

    func testTwoGeneratorsRightmostVariesSlowest() throws {
        XCTAssertEqual(try run(#""\(1,2)-\(3,4)""#),
                       [#""1-3""#, #""2-3""#, #""1-4""#, #""2-4""#])
    }

    func testThreeGeneratorsOrdering() throws {
        XCTAssertEqual(
            try run(#""\(1,2)x\(3,4)x\(5,6)""#),
            [#""1x3x5""#, #""2x3x5""#, #""1x4x5""#, #""2x4x5""#,
             #""1x3x6""#, #""2x3x6""#, #""1x4x6""#, #""2x4x6""#])
    }

    func testEmptyEmbeddedStreamEmptiesTheWholeString() throws {
        XCTAssertEqual(try run(#""\(empty)""#), [])
        XCTAssertEqual(try run(#""a\(empty)b\(1,2)""#), [])  // one empty kills the product
    }

    // MARK: interaction with construction (key-side + value-side)

    func testValueSideInterpolation() throws {
        XCTAssertEqual(try run(#"{a: "n=\(.x)"}"#, on: #"{"x":5}"#), [#"{"a":"n=5"}"#])
    }

    func testStringKeyInterpolation() throws {
        // {"\(.n)": 1} routes through the generic computed-key path.
        XCTAssertEqual(try run(#"{"\(.n)": 1}"#, on: #"{"n":"dyn"}"#), [#"{"dyn":1}"#])
        XCTAssertEqual(try run(#"{"k\(.n)": 1}"#, on: #"{"n":"dyn"}"#), [#"{"kdyn":1}"#])
        XCTAssertEqual(try run(#"{"a\(.k)b": .k}"#, on: #"{"k":2}"#), [#"{"a2b":2}"#])
    }

    func testInterpolationInsideArrayAndMap() throws {
        XCTAssertEqual(try run(#"["\(.x)", "\(.y)"]"#, on: #"{"x":5,"y":6}"#),
                       [#"["5","6"]"#])
        XCTAssertEqual(try run(#"[.[] | "name=\(.n)"]"#, on: #"[{"n":"a"},{"n":"b"}]"#),
                       [#"["name=a","name=b"]"#])
    }

    // MARK: ${…} — additive ECMAScript alias (same tree, same result as \(…))

    func testDollarBraceMatchesBackslashParen() throws {
        XCTAssertEqual(try run(#""a${.x}b""#, on: #"{"x":5}"#),
                       try run(#""a\(.x)b""#, on: #"{"x":5}"#))
        XCTAssertEqual(try run(#""${.x}-${.y}""#, on: #"{"x":5,"y":6}"#), [#""5-6""#])
        XCTAssertEqual(try run(#""${1,2}-${3,4}""#),
                       [#""1-3""#, #""2-3""#, #""1-4""#, #""2-4""#])
        // The two spellings can be mixed in one string.
        XCTAssertEqual(try run(#""\(.x) and ${.x}""#, on: #"{"x":5}"#), [#""5 and 5""#])
        XCTAssertEqual(try run(#"{"k${.n}": 1}"#, on: #"{"n":"dyn"}"#), [#"{"kdyn":1}"#])
    }

    func testLoneDollarStaysLiteral() throws {
        // Only `${` interpolates; a bare `$` is ordinary text (matches jq).
        XCTAssertEqual(try run(#""price $5""#), [#""price $5""#])
        XCTAssertEqual(try run(#""a$b""#), [#""a$b""#])
        guard case .literal(.string("price $5")) = try parseFilter(#""price $5""#)
        else { return XCTFail() }
    }

    // MARK: errors — friendly, with span (diagnostics are contract-free)

    func testUnterminatedInterpolationIsFriendly() {
        for bad in [#""\(.x""#, #""${.x""#] {
            XCTAssertThrowsError(try parseFilter(bad)) { error in
                guard let e = error as? FilterParseError else { return XCTFail() }
                XCTAssertTrue(e.message.contains("interpolation"), e.message)
            }
        }
    }

    func testInterpolatedKeyRequiresAValue() {
        // {"\(.n)"} — an interpolated key is computed; like {(.k)} it needs a
        // value (no shorthand). Friendly error, not a trap.
        XCTAssertThrowsError(try parseFilter(#"{"\(.n)"}"#)) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("interpolated string key"), e.message)
        }
    }

    func testRuntimeErrorInsideInterpolationCarriesSpan() throws {
        // The embedded filter's runtime error surfaces with a span, like any
        // other sub-expression (`"s" + 1` is a jq type error).
        do {
            _ = try run(#""\(.x + 1)""#, on: #"{"x":"s"}"#)
            XCTFail("expected EvalError")
        } catch let e as EvalError {
            XCTAssertNotNil(e.span)
            XCTAssertTrue(e.message.contains("cannot be added"), e.message)
        }
    }

    func testParserNeverTrapsOnInterpolationPrefixes() {
        // Mini-fuzz: every prefix of a gnarly interpolation program must parse
        // or error, never trap (real fuzzing is roadmap — docs/jq-compat.md).
        let gnarly = #""a\(.x)b${.y|length}c\((1,2)+3)" | {k: "\(.z)"}"#
        for end in gnarly.indices {
            _ = try? parseFilter(String(gnarly[..<end]))
        }
    }

    // MARK: AST shape

    func testInterpolationAstShape() throws {
        guard case .stringInterp(let parts) = try parseFilter(#""a\(.x)b""#),
              parts.count == 3,
              case .literal("a") = parts[0],
              case .interp(.field(name: "x", optional: false, _)) = parts[1],
              case .literal("b") = parts[2]
        else { return XCTFail("\(try parseFilter(#""a\(.x)b""#))") }
    }

    func testDollarBraceParsesToSameTreeAsBackslashParen() throws {
        XCTAssertEqual(try parseFilter(#""a${.x}b""#), try parseFilter(#""a\(.x)b""#))
    }

    // MARK: render + JS analogy (explain surface)

    func testRenderRoundTripEvaluatesIdentically() throws {
        let on = try parseOneJSON(#"{"x":5,"y":[1,2,3],"n":"dyn"}"#)
        for program in [#""a\(.x)b""#, #""\(.x)-\(.y | length)""#, #""\(1,2)""#,
                        #""q\"\(.x)\"q""#, #"{"\(.n)": .x}"#, #""${.x}""#] {
            let direct = try evaluate(parseFilter(program), on: on)
            let roundTripped = try evaluate(parseFilter(render(parseFilter(program))), on: on)
            XCTAssertEqual(roundTripped, direct, "render round-trip changed meaning of \(program)")
        }
    }

    func testRenderNormalizesDollarBraceToBackslashParen() throws {
        // `${…}` and `\(…)` share one AST, so render picks the canonical `\(…)`.
        XCTAssertEqual(render(try parseFilter(#""a${.x}b""#)), #""a\(.x)b""#)
    }

    func testJsEquivalentIsATemplateLiteral() throws {
        XCTAssertEqual(jsEquivalent(try parseFilter(#""hello \(.name)!""#)),
                       "`hello ${input.name}!`")
        // Under a map, each interpolation runs on the element.
        XCTAssertEqual(jsEquivalent(try parseFilter(#"[.[] | "id=\(.id)"]"#)),
                       "input.map(x => `id=${x.id}`)")
    }

    func testExplainNamesInterpolation() throws {
        let out = explain(try parseFilter(#""hi \(.x)""#), source: #""hi \(.x)""#, mode: .jq)
        XCTAssertTrue(out.contains("build a string by interpolation"), out)
        XCTAssertTrue(out.contains("`hi ${input.x}`"), out)
    }
}

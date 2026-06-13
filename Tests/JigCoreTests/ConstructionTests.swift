import XCTest
@testable import JigCore

/// Object / array construction (`{a: .b}`, `[.x]`) — roadmap step 2.
/// Golden-style parse → eval → write checks against jig's own spec; the
/// expectations were originally cross-checked byte-for-byte against jq 1.8.
final class ConstructionTests: XCTestCase {

    private func run(_ program: String, on json: String = "null") throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
            .map { writeJSON($0, style: .compact) }
    }

    // MARK: array construction

    func testEmptyArray() throws {
        XCTAssertEqual(try run("[]", on: #"{"x":9}"#), ["[]"])
    }

    func testArrayCollectsCommaStream() throws {
        XCTAssertEqual(try run("[.a, .b]", on: #"{"a":1,"b":2}"#), ["[1,2]"])
        XCTAssertEqual(try run("[1,2,3]"), ["[1,2,3]"])
    }

    func testArrayCollectsIteration() throws {
        XCTAssertEqual(try run("[.[]]", on: #"{"a":1,"b":2}"#), ["[1,2]"])
        XCTAssertEqual(try run("[.[] | . + 1]", on: "[1,2,3]"), ["[2,3,4]"])
    }

    func testArrayCollectsEmptyStreamToEmptyArray() throws {
        XCTAssertEqual(try run("[empty]"), ["[]"])
    }

    func testArrayConstructIsOneValueNotAStream() throws {
        // `[ .a, .b ]` is a single array value, unlike `.a, .b` (two outputs).
        XCTAssertEqual(try run("[.a, .b]", on: #"{"a":1,"b":2}"#).count, 1)
    }

    func testArrayConstructThenSuffix() throws {
        // The prefix `[` (construction) and the suffix `[` (index) compose:
        // `[1,2,3][0]` indexes element 0 of the built array.
        XCTAssertEqual(try run("[1,2,3][0]"), ["1"])
        XCTAssertEqual(try run("[.[]][1]", on: "[7,8,9]"), ["8"])
        XCTAssertEqual(try run("[1,2,3] | length"), ["3"])
    }

    func testArrayConstructParsesAsPrefixNotSuffix() throws {
        guard case .arrayConstruct(.some) = try parseFilter("[1,2,3]") else {
            return XCTFail("\(try parseFilter("[1,2,3]"))")
        }
        guard case .arrayConstruct(.none) = try parseFilter("[]") else { return XCTFail() }
    }

    // MARK: object construction — basics, shorthand, key kinds

    func testEmptyObject() throws {
        XCTAssertEqual(try run("{}", on: #"{"x":9}"#), ["{}"])
    }

    func testObjectLiteralAndFieldValues() throws {
        XCTAssertEqual(try run("{a:1}"), [#"{"a":1}"#])
        XCTAssertEqual(try run("{a:.b}", on: #"{"b":9}"#), [#"{"a":9}"#])
        XCTAssertEqual(try run("{a:.b, d:.c}", on: #"{"b":9,"c":8}"#), [#"{"a":9,"d":8}"#])
    }

    func testShorthandIsFieldAccessOfTheKey() throws {
        XCTAssertEqual(try run("{foo}", on: #"{"foo":1,"bar":2}"#), [#"{"foo":1}"#])
        XCTAssertEqual(try run("{foo, bar}", on: #"{"foo":1,"bar":2}"#), [#"{"foo":1,"bar":2}"#])
        // String-literal shorthand reads `.["a b"]`.
        XCTAssertEqual(try run(#"{"a b"}"#, on: #"{"a b":7}"#), [#"{"a b":7}"#])
    }

    func testKeywordsArePlainStringKeys() throws {
        // Reserved words are ordinary keys in key position (jq).
        XCTAssertEqual(try run("{if:1, true:2, and:3, null:4}"),
                       [#"{"if":1,"true":2,"and":3,"null":4}"#])
    }

    func testStringKey() throws {
        XCTAssertEqual(try run(#"{"a":1}"#), [#"{"a":1}"#])
    }

    func testComputedKey() throws {
        XCTAssertEqual(try run("{(.k):.v}", on: #"{"k":"dyn","v":5}"#), [#"{"dyn":5}"#])
    }

    // MARK: cartesian product (the subtle ordering — matches jq exactly)

    func testCartesianFirstEntryVariesSlowest() throws {
        XCTAssertEqual(
            try run("{a:(1,2), b:(3,4)}"),
            [#"{"a":1,"b":3}"#, #"{"a":1,"b":4}"#, #"{"a":2,"b":3}"#, #"{"a":2,"b":4}"#])
    }

    func testWithinEntryKeyVariesSlowerThanValue() throws {
        XCTAssertEqual(
            try run(#"{(("a","b")):(1,2)}"#),
            [#"{"a":1}"#, #"{"a":2}"#, #"{"b":1}"#, #"{"b":2}"#])
    }

    func testComputedKeyStreamBuildsOneObjectPerKey() throws {
        XCTAssertEqual(try run("{(.[]):1}", on: #"["x","y"]"#),
                       [#"{"x":1}"#, #"{"y":1}"#])
    }

    // MARK: value-side grammar (comma-free; everything tighter is allowed)

    func testValueAcceptsOperatorsAndPipeUnparenthesized() throws {
        XCTAssertEqual(try run("{a: 1+2}"), [#"{"a":3}"#])
        XCTAssertEqual(try run("{a: .x // 9}", on: #"{"x":null}"#), [#"{"a":9}"#])
        XCTAssertEqual(try run("{a: 1 | . + 1}"), [#"{"a":2}"#])
        XCTAssertEqual(try run("{a: .x | .y}", on: #"{"x":{"y":7}}"#), [#"{"a":7}"#])
        XCTAssertEqual(try run("{a: -.x}", on: #"{"x":5}"#), [#"{"a":-5}"#])
        XCTAssertEqual(try run("{a: true and false}"), [#"{"a":false}"#])
        XCTAssertEqual(try run("{a: 1 < 2}"), [#"{"a":true}"#])
    }

    func testCommaSeparatesPairsAndIsNotAValueOperator() throws {
        // `{a:1, 2}` — `,` ends the pair, then `2` is not a valid key → error
        // (matches jq's "syntax error" here).
        XCTAssertThrowsError(try parseFilter("{a:1, 2}"))
    }

    func testParenthesizedCommaInValueIsCartesian() throws {
        XCTAssertEqual(try run("{a: (1,2)}"), [#"{"a":1}"#, #"{"a":2}"#])
    }

    // MARK: duplicates, empty streams, trailing comma

    func testDuplicateKeyLastValueWinsFirstPositionKept() throws {
        XCTAssertEqual(try run("{a:1, b:2, a:3}"), [#"{"a":3,"b":2}"#])
    }

    func testEmptyValueStreamYieldsNoObject() throws {
        XCTAssertEqual(try run("{a: empty}"), [])
        XCTAssertEqual(try run("{a: empty, b: 1}"), [])  // later entry not evaluated
    }

    func testTrailingCommaAllowedInObjectButNotArray() throws {
        XCTAssertEqual(try run("{a:1,}"), [#"{"a":1}"#])
        XCTAssertThrowsError(try parseFilter("[1,2,]"))  // jq rejects this too
    }

    func testOptionalInValueSuppressesAndEmptiesTheObject() throws {
        // `.b?` on a scalar → empty value → no object emitted (jq).
        XCTAssertEqual(try run("{a: .b?}", on: "5"), [])
    }

    // MARK: nesting + interaction

    func testNestedConstruction() throws {
        XCTAssertEqual(try run("{a: {b: .c}}", on: #"{"c":9}"#), [#"{"a":{"b":9}}"#])
        XCTAssertEqual(try run("{a: [.x, .y]}", on: #"{"x":1,"y":2}"#), [#"{"a":[1,2]}"#])
    }

    func testConstructionPipesAndMaps() throws {
        XCTAssertEqual(try run("{a:1} | .a"), ["1"])
        XCTAssertEqual(try run("{a:1}.a"), ["1"])
        XCTAssertEqual(
            try run("[.[] | {id: .id, n: .name}]",
                    on: #"[{"id":1,"name":"a"},{"id":2,"name":"b"}]"#),
            [#"[{"id":1,"n":"a"},{"id":2,"n":"b"}]"#])
    }

    func testConstructedObjectFeedsBuiltins() throws {
        XCTAssertEqual(try run("{a:1,b:2} | keys"), [#"["a","b"]"#])
        XCTAssertEqual(try run("{a:1,b:2} | length"), ["2"])
    }

    // MARK: errors — non-string keys (jq vocabulary), span + hint

    func testNonStringComputedKeyErrorsWithSpanAndHint() throws {
        for (json, kind) in [(#"{"k":[1]}"#, "array"), (#"{"k":null}"#, "null"),
                             (#"{"k":true}"#, "boolean"), (#"{"k":2}"#, "number")] {
            do {
                _ = try run("{(.k):1}", on: json)
                XCTFail("expected EvalError for \(kind) key")
            } catch let e as EvalError {
                let brief = try briefValueForTest(json)
                XCTAssertEqual(e.message, "cannot use \(kind) (\(brief)) as object key", e.message)
                XCTAssertNotNil(e.span)
                XCTAssertTrue(e.hint?.contains("string") == true)
            }
        }
    }

    func testComputedKeyRequiresAValue() throws {
        // `{(.k)}` — a computed key has no shorthand form (jq syntax error).
        XCTAssertThrowsError(try parseFilter("{(.k)}"))
    }

    func testMalformedObjectsErrorNotCrash() throws {
        for bad in ["{a", "{a:", "{:1}", "{,}", "{a 1}", "{a:1 b:2}", "{(.k):}", "{"] {
            XCTAssertThrowsError(try parseFilter(bad), "should reject \(bad)")
        }
    }

    func testConstructionParserNeverTraps() {
        // Mini-fuzz: every prefix of a gnarly construction program must parse
        // or error, never trap (real fuzzing is roadmap — docs/roadmap.md).
        let gnarly = #"{a:(1,2), (.[]): [.x // 9 | .+1], "k": {n}, }"#
        for end in gnarly.indices {
            _ = try? parseFilter(String(gnarly[..<end]))
        }
    }

    // MARK: AST shape

    func testObjectConstructAstShape() throws {
        guard case .objectConstruct(let entries) = try parseFilter("{a:.b}"),
              entries.count == 1,
              case .literal(.string("a")) = entries[0].key,
              case .field(name: "b", optional: false, _) = entries[0].value
        else { return XCTFail("\(try parseFilter("{a:.b}"))") }
    }

    func testShorthandDesugarsToFieldValue() throws {
        guard case .objectConstruct(let entries) = try parseFilter("{foo}"),
              case .literal(.string("foo")) = entries[0].key,
              case .field(name: "foo", optional: false, _) = entries[0].value
        else { return XCTFail() }
    }

    // MARK: render round-trip — render(p) must re-parse to a program that
    // evaluates identically (render is the seed of a future `jig fmt`).

    func testRenderRoundTripEvaluatesIdentically() throws {
        let input = #"{"":42,"a":1,"b":2,"k":"dyn","v":9,"items":[{"id":1},{"id":2}]}"#
        let on = try parseOneJSON(input)
        for program in ["{a: .b}", "{a, b}", "{a: .a}", "[.a, .b]", "[]", "{}",
                        "{(.k): .v}", "[.items[] | {id}]", "{a: .b, c: .v}",
                        #"{""}"#, #"{"a b": .v}"#] {
            let direct = try evaluate(parseFilter(program), on: on)
            let roundTripped = try evaluate(parseFilter(render(parseFilter(program))), on: on)
            XCTAssertEqual(roundTripped, direct, "render round-trip changed meaning of \(program)")
        }
    }

    /// `briefValue` (Operators.swift) renders the offending key value in the
    /// error message; mirror it here for the expected-string assertion.
    private func briefValueForTest(_ json: String) throws -> String {
        briefValue(try parseOneJSON(json).member("k") ?? .null)
    }
}

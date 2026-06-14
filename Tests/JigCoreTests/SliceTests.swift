import XCTest
@testable import JigCore

/// `.[a:b]` array/string slice (docs/plan-wave1.md A). Semantics track jq:
/// negative bounds count from the end, the range is clamped, `low >= high` is
/// the empty slice, and a slice also works on strings (by Unicode scalar).
final class SliceTests: XCTestCase {

    private func run(_ program: String, on json: String) throws -> [String] {
        try evaluate(parseFilter(program), on: parseOneJSON(json))
            .map { writeJSON($0, style: .compact) }
    }

    func testArraySliceBasic() throws {
        XCTAssertEqual(try run(".[1:3]", on: "[1,2,3,4,5]"), ["[2,3]"])
        XCTAssertEqual(try run(".[0:2]", on: "[10,20,30]"), ["[10,20]"])
    }

    func testArraySliceOmittedBounds() throws {
        XCTAssertEqual(try run(".[2:]", on: "[1,2,3,4,5]"), ["[3,4,5]"])
        XCTAssertEqual(try run(".[:2]", on: "[1,2,3,4,5]"), ["[1,2]"])
        XCTAssertEqual(try run(".[:]", on: "[1,2,3]"), ["[1,2,3]"])
    }

    func testArraySliceNegativeIndices() throws {
        XCTAssertEqual(try run(".[-2:]", on: "[1,2,3,4,5]"), ["[4,5]"])
        XCTAssertEqual(try run(".[:-1]", on: "[1,2,3,4,5]"), ["[1,2,3,4]"])
        XCTAssertEqual(try run(".[-3:-1]", on: "[1,2,3,4,5]"), ["[3,4]"])
    }

    func testArraySliceClampAndInverted() throws {
        // Out-of-range clamps; low >= high is the empty slice (not an error).
        XCTAssertEqual(try run(".[1:99]", on: "[1,2,3]"), ["[2,3]"])
        XCTAssertEqual(try run(".[3:1]", on: "[1,2,3,4]"), ["[]"])
        XCTAssertEqual(try run(".[5:9]", on: "[1,2,3]"), ["[]"])
    }

    func testStringSlice() throws {
        XCTAssertEqual(try run(".[1:4]", on: #""hello""#), [#""ell""#])
        XCTAssertEqual(try run(".[-3:]", on: #""hello""#), [#""llo""#])
        XCTAssertEqual(try run(".[:2]", on: #""hello""#), [#""he""#])
        XCTAssertEqual(try run(".[2:1]", on: #""hello""#), [#""""#])
    }

    func testStringSliceByUnicodeScalar() throws {
        // Slicing is by Unicode scalar (consistent with `length`), so a
        // multi-byte char is one position: "aé漢z" → scalars a é 漢 z.
        XCTAssertEqual(try run(".[1:3]", on: #""aé漢z""#), [#""é漢""#])
    }

    func testNullPropagates() throws {
        XCTAssertEqual(try run(".[1:3]", on: "null"), ["null"])
    }

    func testSliceOnScalarErrors() throws {
        XCTAssertThrowsError(try run(".[1:3]", on: "5")) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("cannot slice"), e.message)
            XCTAssertNotNil(e.span)
        }
    }

    func testOptionalSuppressesError() throws {
        XCTAssertEqual(try run(".[1:3]?", on: "5"), [])
        // Mixed stream: only the sliceable inputs survive under `?`.
        XCTAssertEqual(try run(".[] | .[0:1]?", on: #"[5,"hi",[9,8,7]]"#),
                       [#""h""#, "[9]"])
    }

    func testSliceChainsAfterField() throws {
        XCTAssertEqual(try run(".xs[1:3]", on: #"{"xs":[10,20,30,40]}"#), ["[20,30]"])
    }

    // MARK: regressions — `.[]` and `.[n]` must not be captured by the slice path

    func testBracketIterateAndIndexUnaffected() throws {
        XCTAssertEqual(try run("[.[]]", on: "[1,2,3]"), ["[1,2,3]"])
        XCTAssertEqual(try run(".[2]", on: "[1,2,3]"), ["3"])
        XCTAssertEqual(try run(".[-1]", on: "[1,2,3]"), ["3"])
    }

    // An overflowing bound must be a located PARSE error — never silently
    // dropped (which would turn `.[HUGE:]` into `.[:]`, i.e. the whole array).
    func testOverflowingSliceBoundIsAParseError() throws {
        for prog in [".[99999999999999999999:]", ".[:99999999999999999999]",
                     ".[-99999999999999999999:]", ".[99999999999999999999]"] {
            XCTAssertThrowsError(try run(prog, on: "[1,2,3]"), prog) { error in
                guard let e = error as? FilterParseError else { return XCTFail(prog) }
                XCTAssertTrue(e.message.contains("too large"), e.message)
            }
        }
        // The largest valid Int64 bound still parses (and clamps).
        XCTAssertEqual(try run(".[0:9223372036854775807]", on: "[1,2,3]"), ["[1,2,3]"])
    }
}

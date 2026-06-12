import XCTest
@testable import JigCore

/// Generator-semantics contracts. Inputs/expectations are written as JSON
/// text and compared compactly — effectively golden tests of
/// parse → eval → write, the same shape a future jq-conformance harness
/// will use (docs/jq-compat.md).
final class EvaluatorTests: XCTestCase {

    private func run(_ program: String, on json: String) throws -> [String] {
        let input = try parseOneJSON(json)
        let filter = try parseFilter(program)
        return try evaluate(filter, on: input).map { writeJSON($0, style: .compact) }
    }

    func testIdentityPassesInputThrough() throws {
        XCTAssertEqual(try run(".", on: #"{"a":1}"#), [#"{"a":1}"#])
    }

    func testFieldAccess() throws {
        XCTAssertEqual(try run(".name", on: #"{"name":"jig"}"#), [#""jig""#])
    }

    func testMissingFieldYieldsNull() throws {
        XCTAssertEqual(try run(".nope", on: #"{"a":1}"#), ["null"])
    }

    func testFieldOnNullYieldsNull() throws {
        // jq: missing data flows through quietly until iterated.
        XCTAssertEqual(try run(".a.b.c", on: #"{}"#), ["null"])
    }

    func testFieldOnScalarErrorsWithSpanAndHint() throws {
        do {
            _ = try run(".a", on: "42")
            XCTFail("expected EvalError")
        } catch let e as EvalError {
            XCTAssertEqual(e.message, #"cannot index number with "a""#)
            XCTAssertNotNil(e.span)
            XCTAssertTrue(e.hint?.contains(".a?") == true)
        }
    }

    func testOptionalFieldSuppressesTypeError() throws {
        XCTAssertEqual(try run(".a?", on: "42"), [])
    }

    func testIndexInBoundsAndNegativeWrap() throws {
        XCTAssertEqual(try run(".[0]", on: "[10,20,30]"), ["10"])
        XCTAssertEqual(try run(".[-1]", on: "[10,20,30]"), ["30"])
    }

    func testIndexOutOfRangeYieldsNull() throws {
        XCTAssertEqual(try run(".[9]", on: "[1]"), ["null"])
        XCTAssertEqual(try run(".[-9]", on: "[1]"), ["null"])
    }

    func testIterateArrayYieldsElements() throws {
        XCTAssertEqual(try run(".[]", on: "[1,2,3]"), ["1", "2", "3"])
    }

    func testIterateObjectYieldsValuesInKeyOrder() throws {
        XCTAssertEqual(try run(".[]", on: #"{"z":1,"a":2}"#), ["1", "2"])
    }

    func testIterateNullErrorsLoudly() throws {
        XCTAssertThrowsError(try run(".items[]", on: #"{}"#)) { error in
            guard let e = error as? EvalError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("cannot iterate over null"), e.message)
        }
    }

    func testOptionalIterateSuppresses() throws {
        XCTAssertEqual(try run(".items[]?", on: #"{}"#), [])
    }

    func testPipeFeedsEveryOutput() throws {
        XCTAssertEqual(
            try run(".users[] | .name",
                    on: #"{"users":[{"name":"ann"},{"name":"bob"}]}"#),
            [#""ann""#, #""bob""#])
    }

    func testCommaConcatenatesStreamsInOrder() throws {
        XCTAssertEqual(try run(".a, .b", on: #"{"a":1,"b":2}"#), ["1", "2"])
    }

    func testGeneratorCartesianProductOrdering() throws {
        // (.[] , .[]) on [1,2]: left stream fully, then right — jq order.
        XCTAssertEqual(try run(".[], .[]", on: "[1,2]"), ["1", "2", "1", "2"])
    }

    func testFieldChainOnArrayElements() throws {
        XCTAssertEqual(
            try run(".[].id", on: #"[{"id":1},{"id":2}]"#),
            ["1", "2"])
    }

    func testNumberLiteralSurvivesIdentityFilter() throws {
        // End-to-end literal preservation: the flagship correctness fix.
        XCTAssertEqual(try run(".id", on: #"{"id":12345678901234567890}"#),
                       ["12345678901234567890"])
    }
}

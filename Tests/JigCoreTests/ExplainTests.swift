import XCTest
@testable import JigCore

final class ExplainTests: XCTestCase {

    private func explainOf(_ program: String, mode: JigMode = .jq) throws -> String {
        try explain(parseFilter(program), source: program, mode: mode)
    }

    func testHeaderEchoesSourceAndMode() throws {
        let out = try explainOf(".a | .b")
        XCTAssertTrue(out.contains("jig explain (jq mode)"))
        XCTAssertTrue(out.contains("filter: .a | .b"))
    }

    func testStepsAreNumberedPerStage() throws {
        let out = try explainOf(".users[] | .name")
        XCTAssertTrue(out.contains("1. take the \"users\" field"))
        XCTAssertTrue(out.contains("2. iterate"))
        XCTAssertTrue(out.contains("3. take the \"name\" field"))
    }

    func testHumaneIterateWordingAndNote() throws {
        let out = try explainOf(".items[]", mode: .humane)
        XCTAssertTrue(out.contains("humane mode"))
        XCTAssertTrue(out.contains("null emits nothing (humane)"))
        XCTAssertTrue(out.contains("(H2)"))
    }

    // MARK: JavaScript analogy

    func testJsMapProjection() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".users[] | .name")),
                       "input.users.map(x => x.name)")
    }

    func testJsFlatMapWhenNestedIterate() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".a[] | .b[]")),
                       "input.a.flatMap(x => x.b)")
    }

    func testJsNegativeIndexUsesAt() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".items[-1]")),
                       "input.items.at(-1)")
    }

    func testJsCommaIsArray() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".a, .b")),
                       "[input.a, input.b]")
    }

    func testJsBareIterateIsTheArray() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".users[]")), "input.users")
        XCTAssertEqual(jsEquivalent(try! parseFilter(".")), "input")
    }

    // MARK: render (pipe-explicit, faithful)

    func testRenderIsPipeExplicit() {
        XCTAssertEqual(render(try! parseFilter(".a.b")), ".a | .b")
        XCTAssertEqual(render(try! parseFilter(".[]?")), ".[]?")
        XCTAssertEqual(render(try! parseFilter(".x[0]")), ".x | .[0]")
    }
}

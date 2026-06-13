import XCTest
@testable import JigCore

final class ExplainTests: XCTestCase {

    private func explainOf(_ program: String) throws -> String {
        try explain(parseFilter(program), source: program)
    }

    func testHeaderEchoesSource() throws {
        let out = try explainOf(".a | .b")
        XCTAssertTrue(out.contains("jig explain"))
        XCTAssertFalse(out.contains("mode"))  // dual-mode is gone (roadmap §5/3)
        XCTAssertTrue(out.contains("filter: .a | .b"))
    }

    func testStepsAreNumberedPerStage() throws {
        let out = try explainOf(".users[] | .name")
        XCTAssertTrue(out.contains("1. take the \"users\" field"))
        XCTAssertTrue(out.contains("2. iterate"))
        XCTAssertTrue(out.contains("3. take the \"name\" field"))
    }

    func testIterateWordingAndNullNote() throws {
        let out = try explainOf(".items[]")
        XCTAssertTrue(out.contains("null emits nothing"), out)
        XCTAssertTrue(out.contains("iterating a null value emits nothing"), out)
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

    // Regression (roadmap §4 bug ②): select/filter after `.[]` must lower as a
    // SIBLING `.filter(…)`, not nest inside the `.map(…)` callback.
    func testJsSelectAfterIterateHoistsToFilter() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".users[] | select(.active)")),
                       "input.users.filter(x => x.active)")
    }

    func testJsSelectThenProjectionAfterIterate() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".users[] | select(.active) | .name")),
                       "input.users.filter(x => x.active).map(x => x.name)")
    }

    func testJsChainedSelectsAfterIterate() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".users[] | select(.active) | select(.verified)")),
                       "input.users.filter(x => x.active).filter(x => x.verified)")
    }

    func testJsProjectionThenSelectAfterIterate() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".[] | .a | select(.x)")),
                       "input.map(x => x.a).filter(x => x.x)")
    }

    // MARK: canonical presentation (aliases parse, but explain/render show canonical)

    func testExplainStepsUseCanonicalBuiltinName() throws {
        let out = try explainOf("select(.x)")
        XCTAssertTrue(out.contains("call filter"), out)
        XCTAssertFalse(out.contains("call select"), out)
    }

    func testRenderNormalizesAliasesToCanonical() throws {
        // render() is the `jig fmt` seed — it must emit the canonical spelling.
        XCTAssertEqual(render(try parseFilter("select(.x)")), "filter(.x)")
        XCTAssertEqual(render(try parseFilter("type")), "typeof")
        XCTAssertEqual(render(try parseFilter("add")), "sum")
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

    // MARK: increment-2 nodes

    func testRenderLiteralsOpsCalls() {
        XCTAssertEqual(render(try! parseFilter(#".a // "d""#)), #".a // "d""#)
        XCTAssertEqual(render(try! parseFilter(".a ?? 0")), ".a ?? 0")
        XCTAssertEqual(render(try! parseFilter("map(.x)")), "map(.x)")
        XCTAssertEqual(render(try! parseFilter("length")), "length")
    }

    func testJsForOpsAndCalls() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".a ?? 0")), "(input.a ?? 0)")
        XCTAssertEqual(jsEquivalent(try! parseFilter(#".a // "d""#)), #"(input.a || "d")"#)
        XCTAssertEqual(jsEquivalent(try! parseFilter("map(.name)")), "input.map(x => x.name)")
        XCTAssertEqual(jsEquivalent(try! parseFilter("length")), "input.length")
        XCTAssertEqual(jsEquivalent(try! parseFilter("keys")), "Object.keys(input)")
    }

    // MARK: construction (step 2)

    func testRenderConstruction() {
        XCTAssertEqual(render(try! parseFilter("[]")), "[]")
        XCTAssertEqual(render(try! parseFilter("{}")), "{}")
        XCTAssertEqual(render(try! parseFilter("[.a, .b]")), "[.a, .b]")
        XCTAssertEqual(render(try! parseFilter("{a: .b}")), #"{"a": .b}"#)
        XCTAssertEqual(render(try! parseFilter("{(.k): .v}")), "{(.k): .v}")
        // Shorthand-shaped entries render back as shorthand (faithful).
        XCTAssertEqual(render(try! parseFilter("{a, b}")), "{a, b}")
        XCTAssertEqual(render(try! parseFilter("{a: .a}")), "{a}")
    }

    func testRenderEmptyKeyShorthandRoundTrips() {
        // Regression: {""} must not render to `{"": .}` (a different program).
        // The empty-name field would collapse to identity `.` in render.
        XCTAssertEqual(render(try! parseFilter(#"{""}"#)), #"{""}"#)
    }

    func testJsConstructionIsValidExpression() {
        // Object literals are parenthesized so they're valid as an arrow body.
        XCTAssertEqual(jsEquivalent(try! parseFilter("{a: .b}")), "({ a: input.b })")
        XCTAssertEqual(jsEquivalent(try! parseFilter("{(.k): .v}")), "({ [input.k]: input.v })")
        XCTAssertEqual(jsEquivalent(try! parseFilter("[.a, .b]")), "[input.a, input.b]")
        // The canonical map-to-object shape: `x => ({…})`, not `x => {…}`.
        XCTAssertEqual(jsEquivalent(try! parseFilter("[.[] | {id}]")),
                       "input.map(x => ({ id: x.id }))")
        // Non-identifier key → JS bracket access, never `input.`.
        XCTAssertEqual(jsEquivalent(try! parseFilter(#"{"a b"}"#)), #"({ "a b": input["a b"] })"#)
    }
}

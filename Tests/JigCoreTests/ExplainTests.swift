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

    // MARK: Wave 1 — slice (docs/plan-wave1.md)

    func testRenderSliceRoundTrips() {
        XCTAssertEqual(render(try! parseFilter(".[1:3]")), ".[1:3]")
        XCTAssertEqual(render(try! parseFilter(".[2:]")), ".[2:]")
        XCTAssertEqual(render(try! parseFilter(".[:3]")), ".[:3]")
        XCTAssertEqual(render(try! parseFilter(".[:]")), ".[:]")
        XCTAssertEqual(render(try! parseFilter(".[1:3]?")), ".[1:3]?")
        // Pipe-explicit when it follows a term (like `.x[0]` → `.x | .[0]`).
        XCTAssertEqual(render(try! parseFilter(".x[1:3]")), ".x | .[1:3]")
    }

    func testJsSliceUsesSliceMethod() {
        XCTAssertEqual(jsEquivalent(try! parseFilter(".[1:3]")), "input.slice(1, 3)")
        XCTAssertEqual(jsEquivalent(try! parseFilter(".[2:]")), "input.slice(2)")
        XCTAssertEqual(jsEquivalent(try! parseFilter(".[:3]")), "input.slice(0, 3)")
        XCTAssertEqual(jsEquivalent(try! parseFilter(".[:]")), "input.slice()")
        XCTAssertEqual(jsEquivalent(try! parseFilter(".items[1:3]")), "input.items.slice(1, 3)")
    }

    // MARK: Wave 1 — builtins (canonical presentation + JS analogy)

    func testRenderWave1BuiltinsCanonical() {
        // `map_values` is the only jq alias to fold; the rest have no alias.
        XCTAssertEqual(render(try! parseFilter("map_values(.x)")), "mapValues(.x)")
        XCTAssertEqual(render(try! parseFilter("groupBy(.g)")), "groupBy(.g)")
        XCTAssertEqual(render(try! parseFilter("orderBy(.a, .b)")), "orderBy(.a, .b)")
    }

    func testJsWave1Builtins() {
        XCTAssertEqual(jsEquivalent(try! parseFilter("range(5)")),
                       "Array.from({ length: 5 }, (_, i) => i)")
        XCTAssertEqual(jsEquivalent(try! parseFilter("groupBy(.g)")), "Object.groupBy(input, x => x.g)")
        XCTAssertEqual(jsEquivalent(try! parseFilter("mapValues(length)")),
                       "Object.fromEntries(Object.entries(input).map(([k, v]) => [k, v.length]))")
        XCTAssertEqual(jsEquivalent(try! parseFilter("toPairs")), "Object.entries(input)")
        XCTAssertEqual(jsEquivalent(try! parseFilter("fromPairs")), "Object.fromEntries(input)")
    }

    // MARK: Wave 1 aggregation set

    func testRenderAggregationCanonical() {
        // `min_by` / `max_by` are the only jq aliases here; uniq/countBy/keyBy/
        // sumBy are canonical-only.
        XCTAssertEqual(render(try! parseFilter("min_by(.k)")), "minBy(.k)")
        XCTAssertEqual(render(try! parseFilter("max_by(.k)")), "maxBy(.k)")
        XCTAssertEqual(render(try! parseFilter("uniqBy(.t)")), "uniqBy(.t)")
        XCTAssertEqual(render(try! parseFilter("countBy(.g)")), "countBy(.g)")
    }

    func testJsAggregationBuiltins() {
        XCTAssertEqual(jsEquivalent(try! parseFilter("min")), "Math.min(...input)")
        XCTAssertEqual(jsEquivalent(try! parseFilter("max")), "Math.max(...input)")
        // The `/* value-equal (jq ==) */` caveat flags that JS Set is `===` but
        // jig's uniq dedups by jq `==` (deep) — honest for the object case.
        XCTAssertEqual(jsEquivalent(try! parseFilter("uniq")), "[...new Set(input)] /* value-equal (jq ==) */")
        XCTAssertEqual(jsEquivalent(try! parseFilter("keyBy(.id)")),
                       "Object.fromEntries(input.map(x => [x.id, x]))")
        XCTAssertEqual(jsEquivalent(try! parseFilter("sumBy(.x)")),
                       "input.reduce((a, x) => a + x.x, 0)")
    }
}

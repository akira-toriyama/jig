import XCTest
@testable import JigCore

final class FilterParserTests: XCTestCase {

    func testIdentity() throws {
        XCTAssertEqual(try parseFilter("."), .identity)
        XCTAssertEqual(try parseFilter("  .  "), .identity)
    }

    func testFieldChainDesugarsToPipe() throws {
        // `.a.b` ≡ `.a | .b` — one evaluator code path.
        let f = try parseFilter(".a.b")
        guard case .pipe(.field(name: "a", _, _), .field(name: "b", _, _)) = f else {
            return XCTFail("\(f)")
        }
    }

    func testOptionalField() throws {
        guard case .field(name: "a", optional: true, _) = try parseFilter(".a?") else {
            return XCTFail()
        }
    }

    func testIndexAndIterate() throws {
        guard case .pipe(.field(name: "a", _, _), .index(0, optional: false, _)) =
            try parseFilter(".a[0]") else { return XCTFail() }
        guard case .pipe(.field(name: "a", _, _), .index(-1, _, _)) =
            try parseFilter(".a[-1]") else { return XCTFail() }
        guard case .iterate(optional: true, _) = try parseFilter(".[]?") else {
            return XCTFail()
        }
    }

    func testPipeBindsLooserThanComma() throws {
        // jq precedence: `.a,.b|.c` ≡ `(.a,.b)|.c`.
        let f = try parseFilter(".a,.b|.c")
        guard case .pipe(.comma, .field(name: "c", _, _)) = f else {
            return XCTFail("\(f)")
        }
    }

    func testParenthesesOverridePrecedence() throws {
        let f = try parseFilter(".a,(.b|.c)")
        guard case .comma(_, .pipe) = f else { return XCTFail("\(f)") }
    }

    func testWhitespaceSeparatedDotsDoNotChain() {
        // `.a .b` is NOT `.a.b` (matches jq, where it's a syntax error in
        // this position).
        XCTAssertThrowsError(try parseFilter(".a .b"))
    }

    // MARK: diagnostics quality — the reason jig exists

    func testEmptyProgramHintsIdentity() {
        XCTAssertThrowsError(try parseFilter("")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.hint?.contains("identity") == true)
        }
    }

    func testErrorCarriesSpan() {
        XCTAssertThrowsError(try parseFilter(".items[x]")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertEqual(e.span.start, 7) // the "x"
        }
    }

    func testSmartQuoteGetsPasteHint() {
        XCTAssertThrowsError(try parseFilter(".a | “.b”")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("smart quote"), e.message)
        }
    }

    func testDollarGetsShellHint() {
        XCTAssertThrowsError(try parseFilter("$name")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.hint?.contains("shell") == true)
        }
    }

    func testArrowInCallArgsRedirectsToBareFilter() {
        // The JS-arrow reflex `filter(u => u.active)` must redirect to jig's
        // bare-filter form — NOT mis-hint toward `==` (the old bug, roadmap §4).
        XCTAssertThrowsError(try parseFilter("filter(u => u.active)")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("=>"), e.message)
            XCTAssertTrue(e.hint?.contains("bare filter") == true, e.hint ?? "nil")
            XCTAssertFalse(e.hint?.contains("for equality") == true,
                           "arrow must not be mis-hinted as an equality typo")
        }
    }

    func testBareEqualsStillHintsEquality() {
        // A lone `=` (not `=>`) keeps the equality redirect.
        XCTAssertThrowsError(try parseFilter("filter(.a = .b)")) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("\"=\""), e.message)
            XCTAssertTrue(e.hint?.contains("==") == true, e.hint ?? "nil")
        }
    }

    func testDiagnosticRenderPointsAtTheSpan() throws {
        do {
            _ = try parseFilter(".items[x]")
            XCTFail("expected error")
        } catch let e as FilterParseError {
            let rendered = Diagnostic(e).render(program: ".items[x]")
            XCTAssertTrue(rendered.contains(".items[x]"))
            // Caret sits under the x: 2-space indent + 7 chars of ".items[".
            let caretLine = rendered.split(separator: "\n").first { $0.contains("^") }
            XCTAssertEqual(caretLine.map(String.init),
                           String(repeating: " ", count: 9) + "^")
        }
    }

    // MARK: literals, calls, and the // / ?? precedence level

    func testLiteralsParse() throws {
        XCTAssertEqual(try parseFilter("true"), .literal(.bool(true)))
        XCTAssertEqual(try parseFilter("null"), .literal(.null))
        guard case .literal(.string("hi")) = try parseFilter(#""hi""#) else { return XCTFail() }
        guard case .literal(.number) = try parseFilter("42") else { return XCTFail() }
        guard case .literal(.number) = try parseFilter("-3.5e2") else { return XCTFail() }
    }

    func testCallWithAndWithoutArgs() throws {
        guard case .call(name: "length", args: let none, _) = try parseFilter("length"),
              none.isEmpty else { return XCTFail() }
        guard case .call(name: "map", args: let a, _) = try parseFilter("map(.x)"),
              a.count == 1 else { return XCTFail() }
        guard case .call(name: "has", args: let h, _) = try parseFilter(#"has("k")"#),
              h.count == 1 else { return XCTFail() }
    }

    func testCallSuffixChains() throws {
        // keys[0] ≡ keys | .[0]
        guard case .pipe(.call(name: "keys", _, _), .index(0, _, _)) = try parseFilter("keys[0]")
        else { return XCTFail() }
    }

    func testAlternativeAndNullishNodes() throws {
        guard case .alternative(_, _, _) = try parseFilter(#".a // "d""#) else { return XCTFail() }
        guard case .nullish(_, _, _) = try parseFilter(#".a ?? "d""#) else { return XCTFail() }
    }

    func testAltBindsTighterThanCommaAndPipe() throws {
        // .a // .b | .c  ≡  (.a // .b) | .c
        guard case .pipe(.alternative(_, _, _), .field(name: "c", _, _)) =
            try parseFilter(".a // .b | .c") else { return XCTFail() }
        // .a, .b // .c  ≡  .a, (.b // .c)
        guard case .comma(.field(name: "a", _, _), .alternative(_, _, _)) =
            try parseFilter(".a, .b // .c") else { return XCTFail() }
    }

    func testStringInterpolationParsesToANode() throws {
        // Interpolation is implemented (roadmap step 2 complete); the old
        // "not implemented yet" error is gone. Full behavior lives in
        // InterpolationTests; here we just confirm `\(…)` now parses.
        guard case .stringInterp = try parseFilter(#""hi \(.x)""#) else {
            return XCTFail("\(try parseFilter(#""hi \(.x)""#))")
        }
        // An unterminated interpolation still yields a friendly, span-carrying
        // error (never a bison-speak crash).
        XCTAssertThrowsError(try parseFilter(#""hi \(.x""#)) { error in
            guard let e = error as? FilterParseError else { return XCTFail() }
            XCTAssertTrue(e.message.contains("interpolation"), e.message)
        }
    }

    func testUnterminatedStringAndBadCallError() {
        XCTAssertThrowsError(try parseFilter("\"oops"))
        XCTAssertThrowsError(try parseFilter("map(.a"))  // missing )
    }

    func testNoInputCrashesTheParser() {
        // Mini-fuzz: every prefix of a gnarly program must error or parse,
        // never trap. (Real fuzzing is roadmap — docs/jq-compat.md.)
        let gnarly = ".a[-12]?.b | .c, (.d[].e) | .[0] ?? 'x' $v “q”"
        for end in gnarly.indices {
            _ = try? parseFilter(String(gnarly[..<end]))
        }
    }
}

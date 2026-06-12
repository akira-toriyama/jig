import XCTest
@testable import JigCore

final class ModeTests: XCTestCase {

    // MARK: resolveMode precedence (flag > pragma > env > default)

    func testDefaultIsJqMode() {
        XCTAssertEqual(resolveMode(humaneFlag: false, program: ".", env: nil), .jq)
    }

    func testFlagWins() {
        XCTAssertEqual(resolveMode(humaneFlag: true, program: ".", env: "jq"), .humane)
    }

    func testPragmaBeatsEnv() {
        XCTAssertEqual(
            resolveMode(humaneFlag: false, program: "# jig:humane\n.", env: nil),
            .humane)
        // A jq pragma overrides a humane env var.
        XCTAssertEqual(
            resolveMode(humaneFlag: false, program: "# jig:jq\n.", env: "humane"),
            .jq)
    }

    func testEnvUsedWhenNoFlagOrPragma() {
        XCTAssertEqual(resolveMode(humaneFlag: false, program: ".", env: "humane"), .humane)
        XCTAssertEqual(resolveMode(humaneFlag: false, program: ".", env: "jq"), .jq)
    }

    // MARK: detectPragmaMode

    func testPragmaForms() {
        XCTAssertEqual(detectPragmaMode("# jig:humane\n.a"), .humane)
        XCTAssertEqual(detectPragmaMode("#jig:humane"), .humane)
        XCTAssertEqual(detectPragmaMode("# jig: humane"), .humane)
        XCTAssertEqual(detectPragmaMode("# jig:mode=humane\n.a"), .humane)
        XCTAssertEqual(detectPragmaMode("# jig:jq"), .jq)
        XCTAssertNil(detectPragmaMode(".a | .b"))
        XCTAssertNil(detectPragmaMode("# just a normal comment\n.a"))
    }

    func testPragmaCanFollowCode() {
        XCTAssertEqual(detectPragmaMode(".a\n# jig:humane"), .humane)
    }

    // MARK: `#` comments in the filter parser

    func testLeadingCommentIsSkipped() throws {
        guard case .field(name: "a", optional: false, _) = try parseFilter("# pick a\n.a") else {
            return XCTFail()
        }
    }

    func testTrailingCommentIsSkipped() throws {
        guard case .field(name: "a", _, _) = try parseFilter(".a # trailing") else {
            return XCTFail()
        }
    }

    func testPragmaLineParsesAsACommentToo() throws {
        // The pragma is a comment to the parser; it must not break parsing.
        guard case .iterate = try parseFilter("# jig:humane\n.[]") else {
            return XCTFail()
        }
    }
}

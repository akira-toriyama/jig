import XCTest
@testable import JigCore

final class ArgsTests: XCTestCase {

    func testHelpAndVersion() throws {
        XCTAssertEqual(try parseArgs(["--help"]), .showHelp)
        XCTAssertEqual(try parseArgs(["-h"]), .showHelp)
        XCTAssertEqual(try parseArgs(["--version"]), .showVersion)
        XCTAssertEqual(try parseArgs(["-V"]), .showVersion)
    }

    func testBareFilter() throws {
        XCTAssertEqual(try parseArgs(["."]), .run(Args(filter: ".")))
    }

    func testFlagsBeforeAndAfterFilter() throws {
        // jq accepts flags on either side of the program.
        XCTAssertEqual(try parseArgs(["-r", ".a"]),
                       .run(Args(filter: ".a", rawOutput: true)))
        XCTAssertEqual(try parseArgs([".a", "-r"]),
                       .run(Args(filter: ".a", rawOutput: true)))
    }

    func testFilesAfterFilter() throws {
        XCTAssertEqual(
            try parseArgs(["-c", ".", "a.json", "b.json"]),
            .run(Args(filter: ".", files: ["a.json", "b.json"], compactOutput: true)))
    }

    func testNullInput() throws {
        XCTAssertEqual(try parseArgs(["-n", "."]),
                       .run(Args(filter: ".", nullInput: true)))
    }

    func testDoubleDashEndsFlagParsing() throws {
        // A filter that starts with "-" is reachable via --.
        XCTAssertEqual(try parseArgs(["--", "-weird"]),
                       .run(Args(filter: "-weird")))
    }

    func testUnknownFlagRejectedLoudly() {
        // Family rule: no silent fallback on typos.
        XCTAssertThrowsError(try parseArgs(["--comapct-output", "."])) { error in
            XCTAssertEqual(error as? ArgsParseError,
                           .unknownFlag("--comapct-output"))
        }
    }

    func testMissingFilterIsAUsageError() {
        XCTAssertThrowsError(try parseArgs(["-c"])) { error in
            XCTAssertEqual(error as? ArgsParseError, .missingFilter)
        }
    }

    // MARK: --humane flag + subcommands

    func testHumaneFlag() throws {
        XCTAssertEqual(try parseArgs(["--humane", ".a"]),
                       .run(Args(filter: ".a", humane: true)))
    }

    func testExplainSubcommand() throws {
        XCTAssertEqual(try parseArgs(["explain", ".a"]),
                       .explain(Args(filter: ".a")))
        // flags follow the subcommand
        XCTAssertEqual(try parseArgs(["explain", "--humane", ".a"]),
                       .explain(Args(filter: ".a", humane: true)))
    }

    func testCheckSubcommand() throws {
        XCTAssertEqual(try parseArgs(["check", ".a.b"]),
                       .check(Args(filter: ".a.b")))
    }

    func testLeadingDotIsNeverASubcommand() throws {
        // A filter is the filter, even if it spells a subcommand-ish word.
        guard case .run(let a) = try parseArgs([".explain"]) else { return XCTFail() }
        XCTAssertEqual(a.filter, ".explain")
    }
}

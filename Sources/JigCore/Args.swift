// argv parsing — hand-rolled pure function, family style (chord / glance):
// no swift-argument-parser, so JigCore stays dependency-free and the parse
// is a unit-testable value transform.
//
// jq compatibility note: flag NAMES follow jq exactly (-c, -r, -n …) so
// muscle memory and existing scripts carry over. Flags may appear before or
// after the filter, like jq. Combined short flags (-rc) are NOT supported
// for now — jq's own support for them is inconsistent; revisit via
// docs/jq-compat.md. Unknown flags are rejected loudly (family rule:
// no silent fallback).

public struct Args: Sendable, Equatable {
    public var filter: String
    /// Input files in order; empty = read stdin.
    public var files: [String]
    /// -c — one line per output, no indentation.
    public var compactOutput: Bool
    /// -r — top-level strings print without quotes.
    public var rawOutput: Bool
    /// -n — don't read input; run the filter once on null.
    public var nullInput: Bool
    /// --humane — force humane mode (highest-precedence mode selector;
    /// see resolveMode in Mode.swift).
    public var humane: Bool

    public init(filter: String,
                files: [String] = [],
                compactOutput: Bool = false,
                rawOutput: Bool = false,
                nullInput: Bool = false,
                humane: Bool = false) {
        self.filter = filter
        self.files = files
        self.compactOutput = compactOutput
        self.rawOutput = rawOutput
        self.nullInput = nullInput
        self.humane = humane
    }
}

public enum ArgsAction: Sendable, Equatable {
    case showHelp
    case showVersion
    /// `jig [flags] <filter> [files...]` — the default: run the filter.
    case run(Args)
    /// `jig explain [flags] <filter>` — describe the filter in plain language.
    case explain(Args)
    /// `jig check [flags] <filter>` — compile-only (CI gate); no input read.
    case check(Args)
}

public enum ArgsParseError: Error, Equatable {
    case unknownFlag(String)
    case missingFilter
}

public func parseArgs(_ argv: [String]) throws -> ArgsAction {
    var argv = argv

    // Subcommand, if present, is the FIRST token: `jig explain …` /
    // `jig check …`. These are jig-specific (jq has no subcommands); a
    // leading "." or "-flag" is never mistaken for one. Flags follow the
    // subcommand (`jig explain --humane '.x'`).
    var subcommand: String?
    if let first = argv.first, first == "explain" || first == "check" {
        subcommand = first
        argv = Array(argv.dropFirst())
    }

    var filter: String?
    var files: [String] = []
    var compact = false
    var raw = false
    var nullInput = false
    var humane = false
    var flagsDone = false

    var i = 0
    while i < argv.count {
        let a = argv[i]
        i += 1
        if flagsDone || a == "-" || !a.hasPrefix("-") {
            if filter == nil { filter = a } else { files.append(a) }
            continue
        }
        switch a {
        case "--":
            flagsDone = true
        case "-h", "--help":
            return .showHelp
        case "-V", "--version":
            return .showVersion
        case "-c", "--compact-output":
            compact = true
        case "-r", "--raw-output":
            raw = true
        case "-n", "--null-input":
            nullInput = true
        case "--humane":
            humane = true
        default:
            throw ArgsParseError.unknownFlag(a)
        }
    }

    guard let filter else { throw ArgsParseError.missingFilter }
    let args = Args(filter: filter,
                    files: files,
                    compactOutput: compact,
                    rawOutput: raw,
                    nullInput: nullInput,
                    humane: humane)
    switch subcommand {
    case "explain": return .explain(args)
    case "check": return .check(args)
    default: return .run(args)
    }
}

// Dual-mode compatibility (docs/jq-compat.md "the contract"):
//
//   jq mode (default) — observable behavior matches jq 1.7.
//   humane mode       — opt-in; fixes jq's semantic warts. Every divergence
//                       is enumerated in the mode-diff table.
//
// Mode is resolved once at startup and threaded into the evaluator. The
// resolution is a pure function (env is passed in) so it's unit-testable.

public enum JigMode: Sendable, Equatable {
    case jq
    case humane

    public var label: String {
        switch self {
        case .jq: return "jq mode"
        case .humane: return "humane mode"
        }
    }
}

/// Effective mode. Precedence high→low: `--humane` flag, then a
/// `# jig:humane` pragma in the program, then `JIG_MODE=humane`, else jq.
public func resolveMode(humaneFlag: Bool, program: String, env: String?) -> JigMode {
    if humaneFlag { return .humane }
    if let pragma = detectPragmaMode(program) { return pragma }
    if env == "humane" { return .humane }
    return .jq
}

/// Scan a program for a mode pragma comment. jq treats `#` to end-of-line as
/// a comment, so a pragma'd program still parses under jq — it just doesn't
/// get the behavior. Convention: put the pragma on its own line
/// (`# jig:humane`). Returns nil when no mode pragma is present.
///
/// This is a heuristic pre-scan (it doesn't know about string literals yet),
/// which is why the dedicated-line convention matters; a `#` inside a future
/// string literal on the same line as other text won't match the exact
/// token anyway.
public func detectPragmaMode(_ program: String) -> JigMode? {
    for line in program.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let hash = line.firstIndex(of: "#") else { continue }
        // Comment body with all spaces/tabs removed, so `# jig: humane`,
        // `#jig:humane`, `# jig:mode = humane` all normalize the same.
        let body = line[line.index(after: hash)...].filter { $0 != " " && $0 != "\t" }
        switch body {
        case "jig:humane", "jig:mode=humane": return .humane
        case "jig:jq", "jig:mode=jq": return .jq
        default: continue
        }
    }
    return nil
}

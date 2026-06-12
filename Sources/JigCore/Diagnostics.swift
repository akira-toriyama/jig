// Diagnostic rendering: turn an error + the program source into the
// caret-style message the rest of the project is named for.
//
//   jig: error: cannot iterate over null (at input #1)
//     .users[].name
//          ^^^
//     hint: use .[]? to skip non-iterable inputs, or // [] to default missing data
//
// One renderer for both compile (FilterParseError) and runtime (EvalError)
// errors, so output stays uniform.

public struct Diagnostic: Sendable, Equatable {
    public let message: String
    public let span: SourceSpan?
    public let hint: String?

    public init(message: String, span: SourceSpan?, hint: String?) {
        self.message = message
        self.span = span
        self.hint = hint
    }

    public init(_ e: FilterParseError) {
        self.init(message: e.message, span: e.span, hint: e.hint)
    }

    public init(_ e: EvalError) {
        self.init(message: e.message, span: e.span, hint: e.hint)
    }

    /// Render for stderr. `program` is the filter source the spans index
    /// into; `context` (optional) names what was being processed, e.g.
    /// "input #3".
    public func render(program: String, context: String? = nil) -> String {
        var lines: [String] = []
        let ctx = context.map { " (\($0))" } ?? ""
        lines.append("jig: error: \(message)\(ctx)")
        if let span {
            let bytes = Array(program.utf8)
            // Programs are one-liners in the common case; render the whole
            // program with a caret run under the span. (Multi-line programs
            // come with -f file support — roadmap.)
            let display = String(program.map { $0 == "\n" ? " " : $0 })
            lines.append("  \(display)")
            let start = max(0, min(span.start, bytes.count))
            let end = max(start, min(span.end, bytes.count))
            // Caret column = display width up to the span in characters.
            let prefix = String(decoding: bytes[0..<start], as: UTF8.self)
            let spanned = String(decoding: bytes[start..<end], as: UTF8.self)
            let pad = String(repeating: " ", count: prefix.count)
            let carets = String(repeating: "^", count: max(1, spanned.count))
            lines.append("  \(pad)\(carets)")
        }
        if let hint {
            lines.append("  hint: \(hint)")
        }
        return lines.joined(separator: "\n")
    }
}

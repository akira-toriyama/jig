// The filter AST. jig follows jq's semantic model: a filter is a function
// from one input value to a STREAM of output values (generator semantics).
// `.[]` yields many; `,` concatenates streams; `|` composes filters by
// feeding every output of the left side through the right side.
//
// Every node that can fail at runtime carries the SourceSpan of its source
// text, so evaluator errors point at the exact spot in the program — the #1
// jq complaint jig exists to fix (docs/jq-compat.md).

/// Half-open byte range [start, end) into the program source.
public struct SourceSpan: Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }
}

public indirect enum Filter: Sendable, Equatable {
    /// `.` — pass the input through.
    case identity
    /// `.foo` / `.foo?`
    case field(name: String, optional: Bool, span: SourceSpan)
    /// `.[2]` / `.[-1]` / `.[2]?`
    case index(Int, optional: Bool, span: SourceSpan)
    /// `.[]` / `.[]?` — iterate array elements / object values.
    case iterate(optional: Bool, span: SourceSpan)
    /// `lhs | rhs`
    case pipe(Filter, Filter)
    /// `lhs , rhs`
    case comma(Filter, Filter)
}

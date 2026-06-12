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
    /// A constant scalar: `42`, `"text"`, `true`, `false`, `null`. Ignores
    /// its input and emits the value.
    case literal(JigValue)
    /// `a // b` — jq's alternative: emits a's outputs that are neither false
    /// nor null; if there are none, emits b's. In humane mode it drops only
    /// null (H1), matching `??`.
    case alternative(Filter, Filter, span: SourceSpan)
    /// `a ?? b` — nullish coalescing: emits a's non-null outputs; if there
    /// are none, emits b's. Same in both modes (additive; jq rejects `??`).
    case nullish(Filter, Filter, span: SourceSpan)
    /// A builtin/function call: `length`, `map(f)`, `has(k)`. Arguments are
    /// `;`-separated filters.
    case call(name: String, args: [Filter], span: SourceSpan)
}

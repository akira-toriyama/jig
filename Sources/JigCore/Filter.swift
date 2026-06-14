// The filter AST. jig follows jq's semantic model: a filter is a function
// from one input value to a STREAM of output values (generator semantics).
// `.[]` yields many; `,` concatenates streams; `|` composes filters by
// feeding every output of the left side through the right side.
//
// Every node that can fail at runtime carries the SourceSpan of its source
// text, so evaluator errors point at the exact spot in the program — the #1
// jq complaint jig exists to fix (docs/roadmap.md).

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
    /// `.[a:b]` / `.[a:]` / `.[:b]` / `.[:]` / `.[a:b]?` — array/string SLICE.
    /// Both bounds are optional (nil = unbounded: `.[2:]` keeps the tail, `.[:2]`
    /// the head). Negative indices count from the end and the range is clamped,
    /// like jq (`.[-2:]` is the last two; `low >= high` yields the empty
    /// slice). Distinct from `.index`, which is array-only — a slice also works
    /// on strings (by Unicode scalar, matching `length`).
    case slice(low: Int?, high: Int?, optional: Bool, span: SourceSpan)
    /// `.[]` / `.[]?` — iterate array elements / object values.
    case iterate(optional: Bool, span: SourceSpan)
    /// `lhs | rhs`
    case pipe(Filter, Filter)
    /// `lhs , rhs`
    case comma(Filter, Filter)
    /// A constant scalar: `42`, `"text"`, `true`, `false`, `null`. Ignores
    /// its input and emits the value.
    case literal(JigValue)
    /// `a // b` — alternative: emits a's outputs that are neither false nor
    /// null; if there are none, emits b's. (For null-only fallback use `??`.)
    case alternative(Filter, Filter, span: SourceSpan)
    /// `a ?? b` — nullish coalescing: emits a's non-null outputs (keeps
    /// false); if there are none, emits b's. The ECMAScript spelling jq lacks.
    case nullish(Filter, Filter, span: SourceSpan)
    /// A builtin/function call: `length`, `map(f)`, `has(k)`. Arguments are
    /// `;`-separated filters.
    case call(name: String, args: [Filter], span: SourceSpan)
    /// An infix operator: arithmetic (`+ - * / %`), comparison
    /// (`== != < <= > >=`), or logical (`and` / `or`). Both sides are
    /// filters; arithmetic/comparison form a cartesian product of the two
    /// output streams, logical ops short-circuit (docs/roadmap.md step 3).
    case binary(BinOp, Filter, Filter, span: SourceSpan)
    /// Unary minus: `-.x`, `-(…)`. (A `-` directly before digits is folded
    /// into a number literal so its source text is preserved, like jq.)
    case neg(Filter, span: SourceSpan)
    /// `[ f ]` / `[]` — array CONSTRUCTION: collect every output of `f` into
    /// one array value (an absent filter → the empty array). The lone place a
    /// stream becomes an array; distinct from the `.[…]` index/iterate suffix
    /// (`.index` / `.iterate`), which only attaches to a preceding term.
    case arrayConstruct(Filter?)
    /// `{ k: v, … }` — object CONSTRUCTION. Each entry's key and value filters
    /// run on the same input; several outputs form a cartesian product of
    /// objects, ordered like jq's `k1 as $k1 | v1 as $v1 | k2 as $k2 | …`
    /// desugaring — entries vary left-slowest→right-fastest, and within a pair
    /// the key varies slower than the value. Keys must evaluate to strings;
    /// duplicate keys keep the first position with the last value.
    case objectConstruct([ObjectEntry])
    /// `"a\(f)b"` — string INTERPOLATION: an ordered list of literal text
    /// fragments and embedded filters. Each filter's outputs are coerced to
    /// string (a string splices in verbatim, every other value as its compact
    /// JSON form — jq's `tostring` rule) and the fragments concatenate. Several
    /// interpolations make a cartesian product in which the RIGHTMOST varies
    /// SLOWEST, matching jq's left-folded concatenation (so `"\(1,2)-\(3,4)"`
    /// emits 1-3, 2-3, 1-4, 2-4); an empty embedded stream makes the whole
    /// product empty. A string with no interpolation stays a plain `.literal`,
    /// so this node only exists when there is at least one `\(…)` / `${…}`.
    case stringInterp([StringPart])
}

/// One fragment of an interpolated string (`Filter.stringInterp`): a run of
/// literal text, or an embedded filter whose output is spliced in. The `${…}`
/// spelling is an additive ECMAScript alias for jq's `\(…)` — both parse to
/// `.interp` (docs/roadmap.md, "ECMAScript エルゴノミクス"). No `indirect` is
/// needed: `Filter` is already an indirect enum (a pointer-sized value), so
/// nesting it here through the part array is bounded.
public enum StringPart: Sendable, Equatable {
    case literal(String)
    case interp(Filter)
}

/// One `key: value` pair in `{…}` object construction. Both are filters run
/// against the construction's input. `keySpan` locates the offending key for
/// the "cannot use … as object key" runtime error when `key` yields a
/// non-string. Shorthand `{k}` is desugared at parse time to `key = "k"`,
/// `value = .k`, so the evaluator sees one uniform shape.
public struct ObjectEntry: Sendable, Equatable {
    public let key: Filter
    public let value: Filter
    public let keySpan: SourceSpan

    public init(key: Filter, value: Filter, keySpan: SourceSpan) {
        self.key = key
        self.value = value
        self.keySpan = keySpan
    }
}

/// The infix operators. `symbol` is the source spelling, used by `render` /
/// `jig explain` and to keep error messages in jq's vocabulary.
public enum BinOp: Sendable, Equatable {
    case add, subtract, multiply, divide, modulo   // + - * / %
    case eq, ne, lt, le, gt, ge                    // == != < <= > >=
    case and, or                                   // and / or

    public var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .modulo: return "%"
        case .eq: return "=="
        case .ne: return "!="
        case .lt: return "<"
        case .le: return "<="
        case .gt: return ">"
        case .ge: return ">="
        case .and: return "and"
        case .or: return "or"
        }
    }

    /// Logical ops have a different evaluation shape (short-circuit, always
    /// boolean) than arithmetic/comparison (cartesian product).
    public var isLogical: Bool { self == .and || self == .or }
}

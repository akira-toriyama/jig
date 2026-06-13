// Infix operators — roadmap step 3 (docs/roadmap.md): arithmetic
// (`+ - * / %`), comparison (`== != < <= > >=`), and logical (`and` / `or`),
// plus unary minus. Semantics track jq 1.7/1.8 exactly (verified against the
// reference binary); jq mode must not diverge.
//
// Shape of evaluation lives in the Evaluator's `.binary` case:
//   - arithmetic / comparison form a CARTESIAN product of the two output
//     streams, with the RHS as the outer loop (jq desugars `a OP b` to
//     `(b) as $b | (a) as $a | $a OP $b`, so output order follows that).
//   - `and` / `or` SHORT-CIRCUIT on the left and always yield booleans
//     (handled in `evalLogical`, not here).
//
// Numbers use Double arithmetic, matching jq 1.7's observable output: a
// literal survives until math touches it, then decays to a double
// (JigNumber's literal → nil). Arbitrary-precision integer math (gojq's
// approach) would be a *humane* divergence and is deferred — it would need a
// mode-diff entry, since jq mode is double-based.

// MARK: arithmetic / comparison dispatch

/// Apply a non-logical binary operator to one (left, right) pair. Logical
/// operators are handled by `evalLogical` before reaching here.
func applyBinary(_ op: BinOp, _ l: JigValue, _ r: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch op {
    case .add:      return try addValues(l, r, span)
    case .subtract: return try subtractValues(l, r, span)
    case .multiply: return try multiplyValues(l, r, span)
    case .divide:   return try divideValues(l, r, span)
    case .modulo:   return try moduloValues(l, r, span)
    case .eq:       return .bool(l == r)
    case .ne:       return .bool(l != r)
    case .lt:       return .bool(jqCompare(l, r) < 0)
    case .le:       return .bool(jqCompare(l, r) <= 0)
    case .gt:       return .bool(jqCompare(l, r) > 0)
    case .ge:       return .bool(jqCompare(l, r) >= 0)
    case .and, .or:
        // Unreachable: the evaluator routes logical ops to evalLogical. Throw
        // rather than trap (the parser/evaluator must never crash).
        throw EvalError(message: "internal error: \(op.symbol) reached applyBinary", span: span)
    }
}

/// `and` / `or`: left-driven and short-circuiting, always producing booleans.
/// For each left output: a falsy left ends `and` with `false`; a truthy left
/// ends `or` with `true`; otherwise the right side is evaluated and each of
/// its outputs contributes its own truthiness.
func evalLogical(_ op: BinOp, _ lhs: Filter, _ rhs: Filter,
                 on input: JigValue) throws -> [JigValue] {
    let isAnd = (op == .and)
    var out: [JigValue] = []
    for l in try evaluate(lhs, on: input) {
        if truthy(l) == isAnd {
            // `and` + truthy left, or `or` + falsy left → defer to the right.
            for r in try evaluate(rhs, on: input) {
                out.append(.bool(truthy(r)))
            }
        } else {
            // Short-circuit: `and` + falsy → false; `or` + truthy → true.
            out.append(.bool(!isAnd))
        }
    }
    return out
}

// MARK: subtract / multiply / divide / modulo
// (`+` lives in Builtins.swift as `addValues`, shared with the `add` builtin.)

/// `-`: numbers subtract; arrays take set difference (every left element not
/// present in the right array, order and duplicates preserved). Unlike `+`,
/// null is NOT an identity here — jq errors on `1 - null`.
private func subtractValues(_ a: JigValue, _ b: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch (a, b) {
    case (.number(let x), .number(let y)):
        return .number(JigNumber(x.double - y.double))
    case (.array(let x), .array(let y)):
        return .array(x.filter { e in !y.contains(where: { $0 == e }) })
    default:
        throw opError(a, b, "subtracted", span,
                      hint: "- works on numbers (difference) and arrays (remove elements)")
    }
}

/// `*`: numbers multiply; string×number repeats the string (truncated count;
/// a negative count yields null — jq's quirk); object×object deep-merges
/// (recursively, right wins on scalar leaves).
private func multiplyValues(_ a: JigValue, _ b: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch (a, b) {
    case (.number(let x), .number(let y)):
        return .number(JigNumber(x.double * y.double))
    case (.string(let s), .number(let n)), (.number(let n), .string(let s)):
        return repeatString(s, truncToInt(n.double))
    case (.object(let x), .object(let y)):
        return .object(deepMerge(x, y))
    default:
        throw opError(a, b, "multiplied", span,
                      hint: "* works on numbers, string×number (repeat), and object×object (deep merge)")
    }
}

/// `/`: numbers divide (divide-by-zero is an error, like jq); string/string
/// splits the left on the right separator (an empty separator splits into
/// characters).
private func divideValues(_ a: JigValue, _ b: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch (a, b) {
    case (.number(let x), .number(let y)):
        guard y.double != 0 else {
            throw opError(a, b, "divided", span, suffix: "because the divisor is zero", hint: nil)
        }
        return .number(JigNumber(x.double / y.double))
    case (.string(let s), .string(let sep)):
        return .array(splitString(s, sep).map { .string($0) })
    default:
        throw opError(a, b, "divided", span,
                      hint: "/ works on numbers (quotient) and strings (split by separator)")
    }
}

/// `%`: integer remainder. jq truncates both operands toward zero and uses C
/// remainder semantics (sign follows the dividend); a zero divisor errors.
private func moduloValues(_ a: JigValue, _ b: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch (a, b) {
    case (.number(let x), .number(let y)):
        let divisor = truncToInt(y.double)
        guard divisor != 0 else {
            throw opError(a, b, "divided (remainder)", span,
                          suffix: "because the divisor is zero", hint: nil)
        }
        return .number(JigNumber(Double(truncToInt(x.double) % divisor)))
    default:
        throw opError(a, b, "divided (remainder)", span,
                      hint: "% works on numbers (integer remainder)")
    }
}

// MARK: comparison (jq total order)

/// jq's total order over all JSON values, returning -1 / 0 / +1. Across
/// types: null < false < true < numbers < strings < arrays < objects. Within
/// a type: numbers numerically; strings by Unicode code point; arrays
/// lexicographically; objects by their sorted key list first, then by values
/// in that key order.
func jqCompare(_ a: JigValue, _ b: JigValue) -> Int {
    let ra = orderRank(a), rb = orderRank(b)
    if ra != rb { return ra < rb ? -1 : 1 }
    switch (a, b) {
    case (.null, .null), (.bool, .bool):
        // Booleans are already separated by rank (false=1, true=2).
        return 0
    case (.number(let x), .number(let y)):
        if x.double == y.double { return 0 }
        return x.double < y.double ? -1 : 1
    case (.string(let x), .string(let y)):
        return compareStrings(x, y)
    case (.array(let x), .array(let y)):
        for (l, r) in zip(x, y) {
            let c = jqCompare(l, r)
            if c != 0 { return c }
        }
        return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
    case (.object(let x), .object(let y)):
        let kx = x.map(\.key).sorted(by: { compareStrings($0, $1) < 0 })
        let ky = y.map(\.key).sorted(by: { compareStrings($0, $1) < 0 })
        // Compare the sorted key lists first.
        for (l, r) in zip(kx, ky) {
            let c = compareStrings(l, r)
            if c != 0 { return c }
        }
        if kx.count != ky.count { return kx.count < ky.count ? -1 : 1 }
        // Keys match; compare values in sorted-key order.
        for key in kx {
            let c = jqCompare(a.member(key) ?? .null, b.member(key) ?? .null)
            if c != 0 { return c }
        }
        return 0
    default:
        return 0  // unreachable: equal ranks imply matching kinds
    }
}

private func orderRank(_ v: JigValue) -> Int {
    switch v {
    case .null: return 0
    case .bool(false): return 1
    case .bool(true): return 2
    case .number: return 3
    case .string: return 4
    case .array: return 5
    case .object: return 6
    }
}

/// Compare strings by Unicode code point (== UTF-8 byte order for valid
/// UTF-8), matching jq — not Swift's default canonical `String` ordering.
private func compareStrings(_ a: String, _ b: String) -> Int {
    var ai = a.unicodeScalars.makeIterator()
    var bi = b.unicodeScalars.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case (let x?, let y?):
            if x.value != y.value { return x.value < y.value ? -1 : 1 }
        }
    }
}

// MARK: unary minus

/// `-expr`: negate each numeric output; anything else errors (jq: "X cannot
/// be negated").
func negate(_ values: [JigValue], _ span: SourceSpan) throws -> [JigValue] {
    try values.map { v in
        guard case .number(let n) = v else {
            throw EvalError(message: "\(v.typeName) (\(briefValue(v))) cannot be negated",
                            span: span, hint: "unary minus works on numbers")
        }
        return .number(JigNumber(-n.double))
    }
}

// MARK: helpers

/// Recursive object merge for `*`: right wins on scalar leaves, but two object
/// values at the same key merge recursively. Left key order is kept; new keys
/// from the right are appended.
private func deepMerge(_ a: [(key: String, value: JigValue)],
                       _ b: [(key: String, value: JigValue)]) -> [(key: String, value: JigValue)] {
    var merged = a
    for pair in b {
        if let i = merged.firstIndex(where: { $0.key == pair.key }) {
            if case .object(let lv) = merged[i].value, case .object(let rv) = pair.value {
                merged[i] = (pair.key, .object(deepMerge(lv, rv)))
            } else {
                merged[i] = pair
            }
        } else {
            merged.append(pair)
        }
    }
    return merged
}

/// Repeat `s` `count` times. A negative count yields null (jq's behavior);
/// zero yields the empty string.
private func repeatString(_ s: String, _ count: Int) -> JigValue {
    count < 0 ? .null : .string(String(repeating: s, count: count))
}

/// Split `s` on the literal separator `sep`, keeping empty fields (jq
/// semantics). An empty separator splits into individual characters.
/// Foundation-free (JigCore stays importable under the static Linux SDK).
func splitString(_ s: String, _ sep: String) -> [String] {
    // jq special-cases the empty input: "" split by anything is [] (not [""]).
    if s.isEmpty { return [] }
    if sep.isEmpty { return s.map { String($0) } }
    let chars = Array(s)
    let sepChars = Array(sep)
    var result: [String] = []
    var current = ""
    var i = 0
    while i < chars.count {
        if i + sepChars.count <= chars.count && Array(chars[i ..< i + sepChars.count]) == sepChars {
            result.append(current)
            current = ""
            i += sepChars.count
        } else {
            current.append(chars[i])
            i += 1
        }
    }
    result.append(current)
    return result
}

/// Truncate a double toward zero into an Int, clamping out-of-range values to
/// the Int bounds so a huge magnitude can never trap (jq casts to intmax_t).
private func truncToInt(_ d: Double) -> Int {
    if !d.isFinite { return 0 }
    if d >= Double(Int.max) { return Int.max }
    if d <= Double(Int.min) { return Int.min }
    return Int(d.rounded(.towardZero))
}

/// Build a jq-style operator type error: "TYPE (val) and TYPE (val) cannot be
/// VERBed[ suffix]". Keeps jq's wording so muscle memory carries over; the
/// hint is jig's humane addition.
func opError(_ a: JigValue, _ b: JigValue, _ verb: String, _ span: SourceSpan,
             suffix: String? = nil, hint: String?) -> EvalError {
    let tail = suffix.map { " \($0)" } ?? ""
    return EvalError(
        message: "\(a.typeName) (\(briefValue(a))) and \(b.typeName) (\(briefValue(b))) cannot be \(verb)\(tail)",
        span: span, hint: hint)
}

/// A compact value rendering for error messages, truncated so a large value
/// can't flood the diagnostic.
func briefValue(_ v: JigValue) -> String {
    let s = writeJSON(v, style: .compact)
    return s.count <= 20 ? s : String(s.prefix(17)) + "..."
}

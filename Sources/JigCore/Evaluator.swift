// The evaluator: jq's generator semantics, eagerly.
//
// A filter maps ONE input value to a STREAM (array) of outputs. Streams are
// represented as plain [JigValue] for now — correct and simple. Switching to
// lazy generation (for `limit`, `first`, infinite generators like `repeat`)
// is on the roadmap and changes only this file (docs/roadmap.md).
//
// Error contract: every runtime error names the offending part of the
// program (SourceSpan), states the actual type it met — in jq's vocabulary —
// and suggests the `?` form. This is jig's reason to exist; never throw a
// bare string.

public struct EvalError: Error, Equatable {
    public let message: String
    public let span: SourceSpan?
    public let hint: String?

    public init(message: String, span: SourceSpan?, hint: String? = nil) {
        self.message = message
        self.span = span
        self.hint = hint
    }
}

public func evaluate(_ filter: Filter, on input: JigValue) throws -> [JigValue] {
    switch filter {
    case .identity:
        return [input]

    case .field(let name, let optional, let span):
        switch input {
        case .object:
            return [input.member(name) ?? .null]
        case .null:
            // jq: indexing null with a key yields null (missing data flows
            // through quietly).
            return [.null]
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot index \(input.typeName) with \"\(name)\"",
                span: span,
                hint: "use .\(name)? to skip inputs where this isn't an object")
        }

    case .index(let n, let optional, let span):
        switch input {
        case .array(let items):
            var i = n
            if i < 0 { i += items.count }
            guard i >= 0 && i < items.count else { return [.null] }
            return [items[i]]
        case .null:
            return [.null]
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot index \(input.typeName) with number",
                span: span,
                hint: "use [\(n)]? to skip inputs where this isn't an array")
        }

    case .slice(let low, let high, let optional, let span):
        switch input {
        case .array(let items):
            let (l, h) = sliceBounds(low, high, items.count)
            return l >= h ? [.array([])] : [.array(Array(items[l..<h]))]
        case .string(let s):
            // Slice by Unicode scalar, matching `length` (Builtins.lengthOf) and
            // the total order's string comparison — not by grapheme cluster.
            let scalars = Array(s.unicodeScalars)
            let (l, h) = sliceBounds(low, high, scalars.count)
            return l >= h ? [.string("")] : [.string(String(scalars[l..<h].map(Character.init)))]
        case .null:
            // null propagates quietly, like `.foo` / `.[N]`.
            return [.null]
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot slice \(input.typeName)\(preview(input))",
                span: span,
                hint: "use .[a:b]? to skip inputs that aren't arrays or strings")
        }

    case .iterate(let optional, let span):
        switch input {
        case .array(let items):
            return items
        case .object(let pairs):
            return pairs.map(\.value)
        case .null:
            // A null flows through iteration as the empty stream rather than
            // erroring — null already propagates quietly through .foo / .[N],
            // so this makes .[] consistent (jig flavor; see docs/roadmap.md §1).
            // A non-null scalar is still a hard error, with a humane hint.
            return []
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot iterate over \(input.typeName)\(preview(input))",
                span: span,
                hint: "use .[]? to skip inputs that aren't arrays or objects")
        }

    case .pipe(let lhs, let rhs):
        // Feed every output of lhs through rhs, concatenating the streams.
        var out: [JigValue] = []
        for v in try evaluate(lhs, on: input) {
            out.append(contentsOf: try evaluate(rhs, on: v))
        }
        return out

    case .comma(let lhs, let rhs):
        return try evaluate(lhs, on: input) + (try evaluate(rhs, on: input))

    case .literal(let value):
        return [value]

    case .alternative(let lhs, let rhs, _):
        // `//`: keep left outputs that are neither null nor false; otherwise
        // fall back to the right. For null-only fallback (keeping false) use
        // `??` — the two operators are kept distinct on purpose (roadmap §3/§5).
        return try alternative(lhs, rhs, on: input, keepFalse: false)

    case .nullish(let lhs, let rhs, _):
        // `??`: drop only null (keep false) — the JS nullish-coalescing path.
        return try alternative(lhs, rhs, on: input, keepFalse: true)

    case .call(let name, let args, let span):
        return try evalCall(name, args, on: input, span: span)

    case .binary(let op, let lhs, let rhs, let span):
        // `and` / `or` short-circuit on the left and yield booleans.
        if op.isLogical {
            return try evalLogical(op, lhs, rhs, on: input)
        }
        // Arithmetic / comparison: cartesian product of the two streams. jq
        // desugars `a OP b` to `(b) as $b | (a) as $a | $a OP $b`, so the RHS
        // is the outer loop (and is evaluated first — errors there short out
        // before the LHS runs).
        let rs = try evaluate(rhs, on: input)
        let ls = try evaluate(lhs, on: input)
        var out: [JigValue] = []
        out.reserveCapacity(rs.count * ls.count)
        for r in rs {
            for l in ls {
                out.append(try applyBinary(op, l, r, span))
            }
        }
        return out

    case .neg(let inner, let span):
        return try negate(try evaluate(inner, on: input), span)

    case .arrayConstruct(let inner):
        // Collect the inner filter's entire stream into ONE array ([] when
        // absent). The sole point where a stream becomes an array value.
        guard let inner else { return [.array([])] }
        return [.array(try evaluate(inner, on: input))]

    case .objectConstruct(let entries):
        return try buildObjects(entries, on: input)

    case .stringInterp(let parts):
        return try interpolate(parts, on: input)
    }
}

/// String interpolation `"a\(f)b"`: concatenate the literal fragments with each
/// embedded filter's coerced outputs. Several interpolations form a cartesian
/// product where the RIGHTMOST varies SLOWEST — jq builds the string by folding
/// concatenation left-to-right, and jq's `+` makes the right operand the outer
/// loop, so a freshly-added (more-rightward) interpolation cycles slowest. We
/// fold the same way: an accumulator of partial strings, each new value placed
/// on the OUTSIDE of the existing ones. An embedded stream that is empty (e.g.
/// `\(empty)`) collapses the accumulator to nothing, so the whole string emits
/// no output — exactly jq.
private func interpolate(_ parts: [StringPart], on input: JigValue) throws -> [JigValue] {
    var acc: [String] = [""]
    for part in parts {
        switch part {
        case .literal(let text):
            for i in acc.indices { acc[i] += text }
        case .interp(let f):
            let outs = try evaluate(f, on: input)
            var next: [String] = []
            next.reserveCapacity(outs.count * acc.count)
            for v in outs {              // new interpolation — outer (slowest)
                let s = interpCoerce(v)
                for a in acc { next.append(a + s) }   // existing — inner
            }
            acc = next
        }
    }
    return acc.map { .string($0) }
}

/// jq's interpolation coercion (the `tostring` rule): a string splices in
/// verbatim (no surrounding quotes); every other value splices in as its
/// compact JSON encoding. Number-literal preservation rides along — writeJSON
/// keeps an untouched number's source text — so `\(.x)` on an input `1.0`
/// yields "1.0", matching jq.
private func interpCoerce(_ v: JigValue) -> String {
    if case .string(let s) = v { return s }
    return writeJSON(v, style: .compact)
}

/// Object construction `{…}`: each entry's key and value run on the same
/// input, and the result is the cartesian product of every entry's outputs
/// expanded into objects. Order matches jq's `k1 as $k1 | v1 as $v1 | k2 as
/// $k2 | …` desugaring — earlier entries vary slowest, and within a pair the
/// key varies slower than the value. An empty key/value stream makes the whole
/// product empty (jq), and later entries are then not evaluated. Keys must be
/// strings; on a duplicate key the last value wins while the first position is
/// kept (`{a:1,b:2,a:3}` → `{"a":3,"b":2}`).
private func buildObjects(_ entries: [ObjectEntry], on input: JigValue) throws -> [JigValue] {
    var combos: [[(key: String, value: JigValue)]] = [[]]
    for entry in entries {
        if combos.isEmpty { break }  // an earlier entry yielded nothing
        let keys = try evaluate(entry.key, on: input)
        // Don't evaluate the value when there are no keys — jq's `k as $k | v
        // as $v` pipe short-circuits before binding (and thus evaluating) v.
        let values = keys.isEmpty ? [] : try evaluate(entry.value, on: input)
        var next: [[(key: String, value: JigValue)]] = []
        for combo in combos {            // earlier entries — outermost loop
            for k in keys {              // this key — middle (slower than value)
                guard case .string(let ks) = k else {
                    throw EvalError(
                        message: "cannot use \(k.typeName) (\(briefValue(k))) as object key",
                        span: entry.keySpan,
                        hint: "object keys must be strings — a computed (…) key has to evaluate to a string")
                }
                for v in values {        // this value — innermost (fastest)
                    next.append(combo + [(key: ks, value: v)])
                }
            }
        }
        combos = next
    }
    return combos.map { pairs in
        var obj: [(key: String, value: JigValue)] = []
        for (k, v) in pairs {
            if let i = obj.firstIndex(where: { $0.key == k }) {
                obj[i].value = v       // last value wins; first position kept
            } else {
                obj.append((key: k, value: v))
            }
        }
        return .object(obj)
    }
}

/// Shared logic for `//` and `??`: keep the left outputs that survive the
/// filter (always drop null; drop false too unless `keepFalse`); if none
/// survive, fall back to the right side.
private func alternative(_ lhs: Filter, _ rhs: Filter, on input: JigValue,
                         keepFalse: Bool) throws -> [JigValue] {
    let left = try evaluate(lhs, on: input)
    let kept = left.filter { v in
        switch v {
        case .null: return false
        case .bool(false): return keepFalse
        default: return true
        }
    }
    return kept.isEmpty ? try evaluate(rhs, on: input) : kept
}

/// jq truthiness: only `false` and `null` are falsy; everything else
/// (including 0, "", [], {}) is truthy.
func truthy(_ v: JigValue) -> Bool {
    switch v {
    case .null, .bool(false): return false
    default: return true
    }
}

/// A short rendering of the offending value for error messages —
/// " (null)" / " (3)" / "" when too long to help.
private func preview(_ v: JigValue) -> String {
    let s = writeJSON(v, style: .compact)
    return s.count <= 24 ? " (\(s))" : ""
}

/// Normalize a `.[low:high]` slice against a collection of `count` elements,
/// returning a clamped half-open `[l, h)` range. An absent bound is the natural
/// end (low → 0, high → count); a negative bound counts from the end (jq); the
/// result is clamped to `[0, count]` so an out-of-range or inverted slice is the
/// empty range rather than an error.
private func sliceBounds(_ low: Int?, _ high: Int?, _ count: Int) -> (Int, Int) {
    var l = low ?? 0
    var h = high ?? count
    if l < 0 { l += count }
    if h < 0 { h += count }
    l = max(0, min(l, count))
    h = max(0, min(h, count))
    return (l, h)
}

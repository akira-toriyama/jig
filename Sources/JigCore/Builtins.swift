// Builtin functions — wave 1 (docs/roadmap.md §3). The CANONICAL name is the
// es-toolkit / JS spelling (`typeof`, `filter`, `sum`); the jq name is kept as
// an accepted ALIAS (`type`, `select`, `add`) so jq muscle memory still parses,
// but docs / help / `explain` only ever present the canonical form (roadmap §2
// "one obvious way"). Dispatched from Evaluator's `.call`.
//
// Every unknown name produces a located "not defined" error — never a trap.

func evalCall(_ name: String, _ args: [Filter], on input: JigValue,
              span: SourceSpan) throws -> [JigValue] {
    switch (name, args.count) {
    case ("empty", 0):
        return []
    case ("length", 0):
        return [try lengthOf(input, span)]
    case ("keys", 0):
        return [try keysOf(input, sorted: true, span)]
    case ("keys_unsorted", 0):
        return [try keysOf(input, sorted: false, span)]
    case ("typeof", 0), ("type", 0):  // canonical: typeof — `type` is the jq alias
        return [.string(input.typeName)]
    case ("not", 0):
        return [.bool(!truthy(input))]
    case ("reverse", 0):
        return [try reverseOf(input, span)]
    case ("sum", 0), ("add", 0):  // canonical: sum — `add` is the jq alias
        return [try addOf(input, span)]

    case ("map", 1):
        // jq: def map(f): [.[] | f];  — reuses iterate (so map over null is []).
        let elements = try evaluate(.iterate(optional: false, span: span), on: input)
        var out: [JigValue] = []
        for e in elements {
            out.append(contentsOf: try evaluate(args[0], on: e))
        }
        return [.array(out)]

    case ("filter", 1), ("select", 1):  // canonical: filter — `select` is the jq alias
        // one input passes through per truthy output of f
        // (jq spelled this `select`).
        var out: [JigValue] = []
        for v in try evaluate(args[0], on: input) where truthy(v) {
            out.append(input)
        }
        return out

    case ("has", 1):
        var out: [JigValue] = []
        for key in try evaluate(args[0], on: input) {
            out.append(.bool(try hasKey(input, key, span)))
        }
        return out

    case ("range", 1), ("range", 2), ("range", 3):
        return try rangeValues(args, on: input, span)

    case ("groupBy", 1):
        return [try groupByOf(args[0], on: input, span)]

    case ("mapValues", 1), ("map_values", 1):  // canonical: mapValues — `map_values` is the jq alias
        return [try mapValuesOf(args[0], on: input, span)]

    case ("orderBy", 1):
        return [try orderByOf(args[0], on: input, span)]

    case ("toPairs", 0):
        return [try toPairsOf(input, span)]

    case ("fromPairs", 0):
        return [try fromPairsOf(input, span)]

    default:
        throw EvalError(
            message: "\(name)/\(args.count) is not defined",
            span: span,
            hint: "implemented builtins: length, keys, keys_unsorted, typeof, not, "
                + "reverse, sum, empty, map(f), filter(f), has(k), range(n), groupBy(f), "
                + "mapValues(f), orderBy(f), toPairs, fromPairs (plus the .[a:b] slice) — more on the roadmap")
    }
}

private func lengthOf(_ v: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch v {
    case .null: return .number(JigNumber(0))
    case .number(let n): return .number(JigNumber(abs(n.double)))
    case .string(let s): return .number(JigNumber(Double(s.unicodeScalars.count)))
    case .array(let a): return .number(JigNumber(Double(a.count)))
    case .object(let o): return .number(JigNumber(Double(o.count)))
    case .bool(let b):
        throw EvalError(message: "boolean (\(b)) has no length", span: span,
                        hint: "length works on null, strings, numbers, arrays, and objects")
    }
}

private func keysOf(_ v: JigValue, sorted: Bool, _ span: SourceSpan) throws -> JigValue {
    switch v {
    case .object(let pairs):
        let names = pairs.map(\.key)
        return .array((sorted ? names.sorted() : names).map { .string($0) })
    case .array(let a):
        return .array((0..<a.count).map { .number(JigNumber(Double($0))) })
    default:
        throw EvalError(message: "\(v.typeName)\(shortValue(v)) has no keys", span: span,
                        hint: "keys works on objects (returns field names) and arrays (returns indices)")
    }
}

private func reverseOf(_ v: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch v {
    case .null: return .null
    case .array(let a): return .array(a.reversed())
    case .string(let s): return .string(String(s.reversed()))
    default:
        throw EvalError(message: "cannot reverse \(v.typeName)\(shortValue(v))", span: span,
                        hint: "reverse works on arrays and strings")
    }
}

private func addOf(_ v: JigValue, _ span: SourceSpan) throws -> JigValue {
    let elements: [JigValue]
    switch v {
    case .null: return .null
    case .array(let a): elements = a
    case .object(let o): elements = o.map(\.value)
    default:
        throw EvalError(message: "cannot add \(v.typeName)\(shortValue(v))", span: span,
                        hint: "add sums/concatenates the elements of an array (or values of an object)")
    }
    var acc: JigValue = .null
    for e in elements { acc = try addValues(acc, e, span) }
    return acc
}

/// jq `+`: null is identity; numbers add; strings/arrays concatenate;
/// objects merge (right wins). Mixed types error. Shared by the `add` builtin
/// and the `+` operator (Operators.swift).
func addValues(_ a: JigValue, _ b: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch (a, b) {
    case (.null, _): return b
    case (_, .null): return a
    case (.number(let x), .number(let y)): return .number(JigNumber(x.double + y.double))
    case (.string(let x), .string(let y)): return .string(x + y)
    case (.array(let x), .array(let y)): return .array(x + y)
    case (.object(let x), .object(let y)):
        var merged = x
        for pair in y {
            if let i = merged.firstIndex(where: { $0.key == pair.key }) {
                merged[i] = pair
            } else {
                merged.append(pair)
            }
        }
        return .object(merged)
    default:
        throw opError(a, b, "added", span,
                      hint: "+ works on matching types (number, string, array, object), or with null")
    }
}

private func hasKey(_ input: JigValue, _ key: JigValue, _ span: SourceSpan) throws -> Bool {
    switch (input, key) {
    case (.object(let pairs), .string(let k)):
        return pairs.contains { $0.key == k }
    case (.array(let items), .number(let n)):
        let i = Int(n.double)
        return i >= 0 && i < items.count
    case (.object, _):
        throw EvalError(message: "has() on an object needs a string key, got \(key.typeName)", span: span, hint: nil)
    case (.array, _):
        throw EvalError(message: "has() on an array needs a number index, got \(key.typeName)", span: span, hint: nil)
    default:
        throw EvalError(message: "cannot check whether \(input.typeName) has a key", span: span,
                        hint: "has(k) works on objects (string key) and arrays (number index)")
    }
}

// MARK: Wave 1 composition set (docs/plan-wave1.md)

/// The eager-range guard: jq's `range` is a lazy generator, but jig's evaluator
/// holds the whole stream in memory, so an oversized range is a humane error
/// rather than an OOM. Lazy-ification is a scheduled roadmap item.
private let rangeLimit = 10_000_000

/// `range(n)` / `range(from; to)` / `range(from; to; step)` — a finite, EAGER
/// stream of numbers. Each bound is a `;`-separated scalar arg; several outputs
/// per bound form a cartesian product (jq). A zero step is rejected; a negative
/// step counts down.
private func rangeValues(_ args: [Filter], on input: JigValue, _ span: SourceSpan) throws -> [JigValue] {
    let froms: [Double], tos: [Double], steps: [Double]
    if args.count == 1 {
        froms = [0]
        tos = try numericArgs(args[0], on: input, span, role: "count")
        steps = [1]
    } else {
        froms = try numericArgs(args[0], on: input, span, role: "from")
        tos = try numericArgs(args[1], on: input, span, role: "to")
        steps = args.count == 3 ? try numericArgs(args[2], on: input, span, role: "step") : [1]
    }
    var out: [JigValue] = []
    for from in froms {
        for to in tos {
            for step in steps {
                guard step != 0 else {
                    throw EvalError(
                        message: "range step cannot be zero", span: span,
                        hint: "a positive step counts up, a negative one counts down; range(from; to) defaults to step 1")
                }
                var x = from
                while step > 0 ? x < to : x > to {
                    if out.count >= rangeLimit {
                        throw EvalError(
                            message: "range would exceed the \(rangeLimit)-element cap", span: span,
                            hint: "jig's range is eager (held in memory); narrow the bounds — a lazy range is on the roadmap")
                    }
                    out.append(.number(JigNumber(x)))
                    x += step
                }
            }
        }
    }
    return out
}

/// Evaluate one `range` bound to its numeric outputs, erroring on a non-number.
private func numericArgs(_ f: Filter, on input: JigValue, _ span: SourceSpan, role: String) throws -> [Double] {
    try evaluate(f, on: input).map { v in
        guard case .number(let n) = v else {
            throw EvalError(
                message: "range \(role) must be a number, got \(v.typeName)\(shortValue(v))", span: span,
                hint: "range(from; to; step) takes numeric bounds")
        }
        return n.double
    }
}

/// `groupBy(f)` — partition an array into `{key: [items…]}`, keyed by f's first
/// output per element. The result is an OBJECT (the shape people actually want),
/// NOT jq's `group_by` array-of-arrays — deliberately different and not aliased
/// (docs/roadmap.md §3 collision table). Keys keep first-seen order.
private func groupByOf(_ keyer: Filter, on input: JigValue, _ span: SourceSpan) throws -> JigValue {
    guard case .array(let items) = input else {
        throw EvalError(
            message: "cannot groupBy \(input.typeName)\(shortValue(input))", span: span,
            hint: "groupBy partitions the elements of an array into an object keyed by f")
    }
    var groups: [(key: String, value: [JigValue])] = []
    for item in items {
        let key = try groupKeyString(try evaluate(keyer, on: item).first ?? .null, span)
        if let i = groups.firstIndex(where: { $0.key == key }) {
            groups[i].value.append(item)
        } else {
            groups.append((key: key, value: [item]))
        }
    }
    return .object(groups.map { (key: $0.key, value: .array($0.value)) })
}

/// Coerce a groupBy key to a string with the interpolation `tostring` rule: a
/// string stays itself, a number/boolean becomes its compact JSON text (`1` →
/// "1", `true` → "true"). null/array/object can't be object keys → humane error.
private func groupKeyString(_ v: JigValue, _ span: SourceSpan) throws -> String {
    switch v {
    case .string(let s): return s
    case .number, .bool: return writeJSON(v, style: .compact)
    default:
        throw EvalError(
            message: "groupBy key is \(v.typeName)\(shortValue(v)) — keys must be string, number, or boolean", span: span,
            hint: "object keys are strings; map the key to a scalar first (e.g. groupBy(.tag // \"none\"))")
    }
}

/// `mapValues(f)` — apply f to each value of an object (keys kept) or element of
/// an array (order kept), replacing it with f's FIRST output. An empty output
/// DROPS that entry, matching jq's `.[] |= f`. A scalar input is an error.
private func mapValuesOf(_ f: Filter, on input: JigValue, _ span: SourceSpan) throws -> JigValue {
    switch input {
    case .object(let pairs):
        var out: [(key: String, value: JigValue)] = []
        for (k, v) in pairs {
            if let nv = try evaluate(f, on: v).first { out.append((key: k, value: nv)) }
        }
        return .object(out)
    case .array(let items):
        var out: [JigValue] = []
        for v in items {
            if let nv = try evaluate(f, on: v).first { out.append(nv) }
        }
        return .array(out)
    default:
        throw EvalError(
            message: "cannot mapValues over \(input.typeName)\(shortValue(input))", span: span,
            hint: "mapValues transforms the values of an object or the elements of an array")
    }
}

/// `orderBy(f)` — stably sort an array by the key(s) f produces per element.
/// f's whole output stream is the key tuple, compared with jq's total order, so
/// `orderBy(.a, .b)` sorts by `.a` then `.b` (the comma stays a stream; the keys
/// are a tuple — principles §1). Descending is `orderBy(f) | reverse`, never a
/// direction arg (principles §2). A string literal among the keys is the
/// `orderBy(.x, "desc")` footgun and is flagged (principles §5).
private func orderByOf(_ keyer: Filter, on input: JigValue, _ span: SourceSpan) throws -> JigValue {
    if let lit = stringLiteralKey(keyer) {
        throw EvalError(
            message: "orderBy got the string literal \(writeJSON(lit, style: .compact)) as a sort key", span: span,
            hint: "a string literal sorts every element by the same constant (a no-op) — for descending order use `| reverse`, e.g. orderBy(.field) | reverse")
    }
    guard case .array(let items) = input else {
        throw EvalError(
            message: "cannot orderBy \(input.typeName)\(shortValue(input))", span: span,
            hint: "orderBy sorts the elements of an array")
    }
    var decorated: [(keys: [JigValue], index: Int, value: JigValue)] = []
    decorated.reserveCapacity(items.count)
    for (i, item) in items.enumerated() {
        let keys = try evaluate(keyer, on: item)
        // An empty key stream sorts as null (front) — principles/plan §②.
        decorated.append((keys: keys.isEmpty ? [.null] : keys, index: i, value: item))
    }
    decorated.sort { a, b in
        let c = jqCompare(.array(a.keys), .array(b.keys))
        return c != 0 ? c < 0 : a.index < b.index   // index tie-break ⇒ stable
    }
    return .array(decorated.map(\.value))
}

/// Detect a string literal used as a sort key — directly, or among the comma
/// tuple of keys (`orderBy(.x, "desc")`). Only the comma spine is walked; a
/// string produced by a pipe/expression is a legitimate computed key.
private func stringLiteralKey(_ f: Filter) -> JigValue? {
    switch f {
    case .literal(let v):
        if case .string = v { return v }
        return nil
    case .comma(let a, let b):
        return stringLiteralKey(a) ?? stringLiteralKey(b)
    default:
        return nil
    }
}

/// `toPairs` — an object → `[[key, value], …]` in key order. This `[[k,v]]`
/// shape is NOT jq's `to_entries` `[{key,value}]`; different and not aliased
/// (docs/roadmap.md §3).
private func toPairsOf(_ input: JigValue, _ span: SourceSpan) throws -> JigValue {
    guard case .object(let pairs) = input else {
        throw EvalError(
            message: "cannot toPairs \(input.typeName)\(shortValue(input))", span: span,
            hint: "toPairs turns an object into [[key, value], …]")
    }
    return .array(pairs.map { .array([.string($0.key), $0.value]) })
}

/// `fromPairs` — `[[key, value], …]` → an object (the inverse of `toPairs`).
/// Each entry must be a two-element array with a string key; a duplicate key
/// keeps its first position with the last value (like object construction).
private func fromPairsOf(_ input: JigValue, _ span: SourceSpan) throws -> JigValue {
    guard case .array(let entries) = input else {
        throw EvalError(
            message: "cannot fromPairs \(input.typeName)\(shortValue(input))", span: span,
            hint: "fromPairs turns [[key, value], …] into an object")
    }
    var out: [(key: String, value: JigValue)] = []
    for entry in entries {
        guard case .array(let kv) = entry, kv.count == 2 else {
            throw EvalError(
                message: "fromPairs needs [key, value] pairs, got \(entry.typeName)\(shortValue(entry))", span: span,
                hint: "each entry must be a two-element array [key, value] with a string key")
        }
        guard case .string(let k) = kv[0] else {
            throw EvalError(
                message: "fromPairs key must be a string, got \(kv[0].typeName)\(shortValue(kv[0]))", span: span,
                hint: "each entry is [key, value] where key is a string")
        }
        if let i = out.firstIndex(where: { $0.key == k }) {
            out[i].value = kv[1]
        } else {
            out.append((key: k, value: kv[1]))
        }
    }
    return .object(out)
}

/// Short value rendering for diagnostics — " (null)" / " (3)" / "" when long.
func shortValue(_ v: JigValue) -> String {
    let s = writeJSON(v, style: .compact)
    return s.count <= 24 ? " (\(s))" : ""
}

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
        // jq: def map(f): [.[] | f];  — reuses iterate, so it inherits H2.
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

    default:
        throw EvalError(
            message: "\(name)/\(args.count) is not defined",
            span: span,
            hint: "implemented builtins (v0): length, keys, keys_unsorted, typeof, "
                + "not, reverse, sum, empty, map(f), filter(f), has(k) — more on the roadmap")
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

/// Short value rendering for diagnostics — " (null)" / " (3)" / "" when long.
func shortValue(_ v: JigValue) -> String {
    let s = writeJSON(v, style: .compact)
    return s.count <= 24 ? " (\(s))" : ""
}

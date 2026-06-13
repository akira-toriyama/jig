// `jig explain` — describe in plain language what a filter does, using the
// same AST + mode the evaluator runs on. This is jig's flagship "humane"
// surface: a direct answer to jq's famously terse mental model
// (docs/jq-compat.md pain points #15 / #20). Pure (returns a String);
// JigApp prints it.

/// Render a one-line explanation block for `filter`. `source` is the program
/// as the user typed it (echoed in the header); `mode` tailors the wording
/// of behaviors that differ between jq and humane mode.
public func explain(_ filter: Filter, source: String, mode: JigMode) -> String {
    var lines: [String] = []
    lines.append("jig explain (\(mode.label))")
    lines.append("")
    lines.append("  filter: \(source)")
    lines.append("")
    let steps = flattenPipe(filter)
    for (i, step) in steps.enumerated() {
        lines.append("  \(i + 1). \(phrase(step, mode: mode))")
    }
    lines.append("")
    lines.append("  ≈ JS: \(jsEquivalent(filter))")
    lines.append("")
    lines.append("Model: one input value → a stream of output values (generator semantics).")
    if mode == .humane && containsIterate(filter) {
        lines.append("Humane: iterating a null value emits nothing instead of erroring (H2).")
    }
    return lines.joined(separator: "\n")
}

/// A rough JavaScript analogy for the filter — a learnability bridge for
/// JS/TS-native users (the jq stream model has no exact JS twin, so this is
/// idiomatic-but-approximate: `.users[] | .name` → `input.users.map(x => x.name)`).
public func jsEquivalent(_ filter: Filter) -> String {
    jsChain(flattenPipe(filter), subject: "input")
}

private func isIterate(_ filter: Filter) -> Bool {
    if case .iterate = filter { return true }
    return false
}

private func jsChain(_ stages: [Filter], subject: String) -> String {
    var expr = subject
    var i = 0
    while i < stages.count {
        switch stages[i] {
        case .identity:
            break
        case .field(let name, _, _):
            // A non-identifier key (from {"a b"} shorthand) needs JS bracket
            // access — `.foo` only works for barewords; `input.` would be junk.
            expr += isBarewordKey(name) ? ".\(name)" : "[\(writeJSON(.string(name), style: .compact))]"
        case .index(let n, _, _):
            // JS Array.prototype.at handles negative indices like jq.
            expr += ".at(\(n))"
        case .iterate:
            // Everything after `.[]` runs element-wise over the array. Hand the
            // remaining stages to jsStream so a following select/filter hoists
            // OUT as a sibling `.filter(…)` rather than nesting wrongly inside
            // the `.map(…)` callback.
            return jsStream(expr, Array(stages[(i + 1)...]))
        case .comma(let a, let b):
            let ja = jsChain(flattenPipe(a), subject: expr)
            let jb = jsChain(flattenPipe(b), subject: expr)
            return "[\(ja), \(jb)]"
        case .literal(let v):
            // A literal ignores its input — it replaces the running subject.
            expr = writeJSON(v, style: .compact)
        case .alternative(let a, let b, _):
            // jq `//` ≈ JS falsy-`||`; humane `//` and `??` ≈ JS nullish-`??`.
            return "(\(jsChain(flattenPipe(a), subject: expr)) || \(jsChain(flattenPipe(b), subject: expr)))"
        case .nullish(let a, let b, _):
            return "(\(jsChain(flattenPipe(a), subject: expr)) ?? \(jsChain(flattenPipe(b), subject: expr)))"
        case .call(let name, let args, _):
            expr = jsCall(name, args, subject: expr)
        case .binary(let op, let a, let b, _):
            // Both operands run on the same input (the running subject).
            let ja = jsChain(flattenPipe(a), subject: expr)
            let jb = jsChain(flattenPipe(b), subject: expr)
            expr = "(\(ja) \(jsOp(op)) \(jb))"
        case .neg(let inner, _):
            expr = "-\(jsChain(flattenPipe(inner), subject: expr))"
        case .arrayConstruct(let inner):
            guard let inner else { expr = "[]"; break }
            let parts = flattenComma(inner)
            if parts.count == 1, containsIterate(parts[0]) {
                // [ .[] | f ] ≈ subject.map(...) — jsChain already yields an
                // array, so don't wrap it in another pair of brackets.
                expr = jsChain(flattenPipe(parts[0]), subject: expr)
            } else {
                expr = "[" + parts.map { jsChain(flattenPipe($0), subject: expr) }.joined(separator: ", ") + "]"
            }
        case .objectConstruct(let entries):
            let body = entries.map { e -> String in
                let key: String
                if case .literal(.string(let s)) = e.key {
                    key = jsKey(s)
                } else {
                    key = "[\(jsChain(flattenPipe(e.key), subject: expr))]"  // computed property
                }
                return "\(key): \(jsChain(flattenPipe(e.value), subject: expr))"
            }.joined(separator: ", ")
            // Parenthesize the object literal: as an arrow-function body
            // (`x => ({…})`, the common `map({…})` shape) a bare `{…}` would be
            // parsed as a block, not an object — `(…)` makes it valid JS anywhere.
            expr = body.isEmpty ? "({})" : "({ \(body) })"
        case .stringInterp(let parts):
            // jq's `\(…)` interpolation ≈ a JS template literal — the docs'
            // chosen analogy for the ECMAScript `${…}` alias. Each embedded
            // filter runs on the current subject.
            var s = "`"
            for part in parts {
                switch part {
                case .literal(let lit): s += jsTemplateEscape(lit)
                case .interp(let f): s += "${\(jsChain(flattenPipe(f), subject: expr))}"
                }
            }
            expr = s + "`"
        case .pipe:
            break  // already flattened
        }
        i += 1
    }
    return expr
}

/// Lower the stages that run AFTER a `.[]` — the element-wise tail of a
/// pipeline — over the array expression `arrayExpr`. A `select`/`filter`
/// predicate hoists OUT of the projection as a sibling `.filter(x => …)`; a
/// maximal run of projection stages collapses into a single `.map(x => …)`
/// (`.flatMap` when that run iterates again). Empty tail → the array itself
/// stands in for its elements. This is the fix for the old bug where
/// `.users[] | select(.active)` lowered to `input.users.map(x => x.filter(…))`
/// instead of `input.users.filter(x => x.active)`.
private func jsStream(_ arrayExpr: String, _ stages: [Filter]) -> String {
    func isSelect(_ f: Filter) -> Bool {
        if case .call(let name, let args, _) = f,
           name == "select" || name == "filter", args.count == 1 { return true }
        return false
    }
    var expr = arrayExpr
    var i = 0
    while i < stages.count {
        // select/filter — a predicate on the stream → a sibling `.filter(…)`.
        if case .call(_, let args, _) = stages[i], isSelect(stages[i]) {
            expr = "\(expr).filter(x => \(jsChain(flattenPipe(args[0]), subject: "x")))"
            i += 1
            continue
        }
        // Otherwise take the maximal run of projection stages up to the next
        // select/filter and project it in one map / flatMap.
        var j = i
        while j < stages.count && !isSelect(stages[j]) { j += 1 }
        let run = Array(stages[i..<j])
        let op = run.contains(where: isIterate) ? "flatMap" : "map"
        expr = "\(expr).\(op)(x => \(jsChain(run, subject: "x")))"
        i = j
    }
    return expr
}

/// Split a top-level comma chain into its operands — the comma analogue of
/// `flattenPipe`, used to turn `[a, b, c]` into a JS array literal.
private func flattenComma(_ filter: Filter) -> [Filter] {
    if case .comma(let a, let b) = filter {
        return flattenComma(a) + flattenComma(b)
    }
    return [filter]
}

/// A JS object key: bareword when it's a valid identifier, else a quoted
/// string (`{ a: … }` vs `{ "a b": … }`).
private func jsKey(_ s: String) -> String {
    isBarewordKey(s) ? s : writeJSON(.string(s), style: .compact)
}

/// Escape a literal fragment for placement inside a JS backtick template:
/// a backslash, a backtick, and the substitution opener `${` would otherwise
/// be special. Foundation-free (no `replacingOccurrences`) so JigCore stays
/// importable under the static Linux SDK.
private func jsTemplateEscape(_ s: String) -> String {
    var out = ""
    let scalars = Array(s.unicodeScalars)
    for (i, c) in scalars.enumerated() {
        switch c {
        case "\\": out += "\\\\"
        case "`": out += "\\`"
        // Only `${` starts a substitution; a lone `$` is literal.
        case "$" where i + 1 < scalars.count && scalars[i + 1] == "{": out += "\\$"
        default: out.unicodeScalars.append(c)
        }
    }
    return out
}

/// True when `s` is a `[A-Za-z_][A-Za-z0-9_]*` identifier — safe to print as a
/// bareword object key in both jq render and the JS analogy.
func isBarewordKey(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    guard let first = bytes.first else { return false }
    func isLetterOrUnderscore(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || b == UInt8(ascii: "_")
    }
    func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    guard isLetterOrUnderscore(first) else { return false }
    return bytes.dropFirst().allSatisfy { isLetterOrUnderscore($0) || isDigit($0) }
}

/// JS analogy for a builtin call (best-effort; used only by `jig explain`).
private func jsCall(_ name: String, _ args: [Filter], subject: String) -> String {
    func cb(_ f: Filter) -> String { "x => \(jsChain(flattenPipe(f), subject: "x"))" }
    switch (name, args.count) {
    case ("length", 0): return "\(subject).length"
    case ("keys", 0), ("keys_unsorted", 0): return "Object.keys(\(subject))"
    case ("type", 0), ("typeof", 0): return "typeof \(subject)"
    case ("not", 0): return "!\(subject)"
    case ("reverse", 0): return "[...\(subject)].reverse()"
    case ("add", 0): return "\(subject).reduce((a, b) => a + b)"
    case ("map", 1): return "\(subject).map(\(cb(args[0])))"
    case ("select", 1), ("filter", 1): return "\(subject).filter(\(cb(args[0])))"
    case ("has", 1): return "(\(render(args[0])) in \(subject))"
    case ("empty", 0): return "[]"
    default: return "\(subject)/* \(name) */"
    }
}

/// JS operator spelling for a jq operator (best-effort; used by `jig explain`).
/// jq's `==` is value equality and `and`/`or` are boolean, so they map to JS's
/// strict/`&&`/`||` forms.
private func jsOp(_ op: BinOp) -> String {
    switch op {
    case .eq: return "==="
    case .ne: return "!=="
    case .and: return "&&"
    case .or: return "||"
    default: return op.symbol  // + - * / % < <= > >= all match JS
    }
}

/// Flatten a left-nested pipe chain into ordered stages. Non-pipe nodes are
/// a single stage.
func flattenPipe(_ filter: Filter) -> [Filter] {
    if case .pipe(let a, let b) = filter {
        return flattenPipe(a) + flattenPipe(b)
    }
    return [filter]
}

private func containsIterate(_ filter: Filter) -> Bool {
    switch filter {
    case .iterate:
        return true
    case .pipe(let a, let b), .comma(let a, let b),
         .alternative(let a, let b, _), .nullish(let a, let b, _),
         .binary(_, let a, let b, _):
        return containsIterate(a) || containsIterate(b)
    case .neg(let inner, _):
        return containsIterate(inner)
    case .call(_, let args, _):
        return args.contains(where: containsIterate)
    case .arrayConstruct(let inner):
        return inner.map(containsIterate) ?? false
    case .objectConstruct(let entries):
        return entries.contains { containsIterate($0.key) || containsIterate($0.value) }
    case .stringInterp(let parts):
        return parts.contains {
            if case .interp(let f) = $0 { return containsIterate(f) }
            return false
        }
    default:
        return false
    }
}

private func phrase(_ filter: Filter, mode: JigMode) -> String {
    switch filter {
    case .identity:
        return "pass the value through unchanged (.)"
    case .field(let name, let optional, _):
        let base = "take the \"\(name)\" field of the object"
        return optional
            ? base + " — skip inputs that aren't objects (?)"
            : base + " — error if the input isn't an object or null"
    case .index(let n, let optional, _):
        let which = n < 0 ? "the element \(n) from the end" : "the element at index \(n)"
        let base = "take \(which) of the array"
        return optional
            ? base + " — skip inputs that aren't arrays (?)"
            : base + " — error if the input isn't an array or null"
    case .iterate(let optional, _):
        var base = "iterate: emit each array element / object value"
        if optional {
            base += " — skip inputs that aren't iterable (?)"
        } else if mode == .humane {
            base += " — null emits nothing (humane); a scalar errors"
        } else {
            base += " — error if the input isn't an array or object"
        }
        return base
    case .comma(let a, let b):
        return "emit two streams in order: (\(render(a))) then (\(render(b)))"
    case .literal(let v):
        return "produce the constant \(writeJSON(v, style: .compact))"
    case .alternative(let a, let b, _):
        return "alternative (//): use (\(render(a))); if it yields no usable value "
            + "(\(mode == .humane ? "null/empty" : "false/null/empty")), fall back to (\(render(b)))"
    case .nullish(let a, let b, _):
        return "nullish (??): use (\(render(a))); only if that is null/empty, fall back to (\(render(b)))"
    case .call(let name, let args, _):
        return args.isEmpty
            ? "call \(name)"
            : "call \(name) with (\(args.map(render).joined(separator: "; ")))"
    case .binary(let op, let a, let b, _):
        let lead: String
        switch op {
        case .add, .subtract, .multiply, .divide, .modulo:
            lead = "compute"
        case .eq, .ne, .lt, .le, .gt, .ge:
            lead = "test whether"
        case .and, .or:
            lead = "logically combine"
        }
        let note = op.isLogical ? " — short-circuits, yields a boolean" : ""
        return "\(lead): (\(render(a))) \(op.symbol) (\(render(b)))\(note)"
    case .neg(let inner, _):
        return "negate: -(\(render(inner)))"
    case .arrayConstruct(let inner):
        return inner == nil
            ? "build an empty array []"
            : "build an array by collecting a stream into it: \(render(filter))"
    case .objectConstruct(let entries):
        let n = entries.count
        return "build an object (\(n) \(n == 1 ? "entry" : "entries")): \(render(filter))"
    case .stringInterp:
        return "build a string by interpolation: \(render(filter))"
    case .pipe:
        // Unreached after flattenPipe; render defensively.
        return render(filter)
    }
}

/// Render an AST back to semantically faithful, pipe-explicit jq syntax
/// (`.a.b` → ".a | .b"). Used for inline sub-expressions in `explain`; the
/// seed of a future `jig fmt`.
public func render(_ filter: Filter) -> String {
    switch filter {
    case .identity:
        return "."
    case .field(let name, let optional, _):
        return ".\(name)\(optional ? "?" : "")"
    case .index(let n, let optional, _):
        return ".[\(n)]\(optional ? "?" : "")"
    case .iterate(let optional, _):
        return ".[]\(optional ? "?" : "")"
    case .pipe(let a, let b):
        return "\(render(a)) | \(render(b))"
    case .comma(let a, let b):
        return "\(render(a)), \(render(b))"
    case .literal(let v):
        return writeJSON(v, style: .compact)
    case .alternative(let a, let b, _):
        return "\(render(a)) // \(render(b))"
    case .nullish(let a, let b, _):
        return "\(render(a)) ?? \(render(b))"
    case .call(let name, let args, _):
        return args.isEmpty ? name : "\(name)(\(args.map(render).joined(separator: "; ")))"
    case .binary(let op, let a, let b, _):
        // Parenthesize operands that are themselves infix/compound, so the
        // rendered text re-parses to the SAME tree (precedence-faithful).
        return "\(renderAtom(a)) \(op.symbol) \(renderAtom(b))"
    case .neg(let inner, _):
        return "-\(renderAtom(inner))"
    case .arrayConstruct(let inner):
        return inner.map { "[\(render($0))]" } ?? "[]"
    case .objectConstruct(let entries):
        return "{" + entries.map(renderObjectEntry).joined(separator: ", ") + "}"
    case .stringInterp(let parts):
        // Re-emit the `"…\(f)…"` source. Literal fragments are escaped via the
        // canonical string writer (then de-quoted) so the text re-parses to the
        // same node; `${…}` is normalized to the `\(…)` spelling (same tree).
        var s = "\""
        for part in parts {
            switch part {
            case .literal(let lit):
                let quoted = writeJSON(.string(lit), style: .compact)
                s += String(quoted.dropFirst().dropLast())
            case .interp(let f):
                s += "\\(\(render(f)))"
            }
        }
        return s + "\""
    }
}

/// Render one object pair so it re-parses to the same entry. The key is always
/// a quoted string (`"a": …`) for literal-string keys — safe for any key text
/// — or a parenthesized expression for computed keys. The value is rendered as
/// an atom so a `|`/operator value re-parses inside the pair without colliding
/// with the `,` separator.
private func renderObjectEntry(_ e: ObjectEntry) -> String {
    // A shorthand-shaped entry ({k} or the equivalent {k: .k}) renders back as
    // shorthand — bareword `k`, or quoted `"k"` for a non-identifier key. This
    // re-parses to the same tree AND avoids rendering an empty/space key as an
    // unparseable `.field` (e.g. {""} must not collapse to `"": .`).
    if case .literal(.string(let k)) = e.key,
       case .field(name: let vname, optional: false, _) = e.value, vname == k {
        return isBarewordKey(k) ? k : writeJSON(.string(k), style: .compact)
    }
    let key: String
    if case .literal(.string(let s)) = e.key {
        key = writeJSON(.string(s), style: .compact)
    } else {
        key = "(\(render(e.key)))"
    }
    return "\(key): \(renderAtom(e.value))"
}

/// Render a sub-expression, wrapping it in parentheses when it is a loose
/// (infix/compound) node — otherwise `render` would drop the grouping and the
/// text would mis-associate (e.g. `(2 + 3) * 4` flattening to `2 + 3 * 4`).
private func renderAtom(_ filter: Filter) -> String {
    switch filter {
    case .identity, .field, .index, .iterate, .literal, .call,
         .arrayConstruct, .objectConstruct, .stringInterp:
        // A `"…"` (interpolated or not) is self-delimiting — an atom that needs
        // no parentheses, like a literal.
        return render(filter)
    case .pipe, .comma, .alternative, .nullish, .binary, .neg:
        return "(\(render(filter)))"
    }
}

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
            expr += ".\(name)"
        case .index(let n, _, _):
            // JS Array.prototype.at handles negative indices like jq.
            expr += ".at(\(n))"
        case .iterate:
            let rest = Array(stages[(i + 1)...])
            if rest.isEmpty { return expr }  // the array stands in for its elements
            // map projects 1:1; flatMap when a further iterate flattens.
            let op = rest.contains(where: isIterate) ? "flatMap" : "map"
            return "\(expr).\(op)(x => \(jsChain(rest, subject: "x")))"
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
        case .pipe:
            break  // already flattened
        }
        i += 1
    }
    return expr
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
    }
}

/// Render a sub-expression, wrapping it in parentheses when it is a loose
/// (infix/compound) node — otherwise `render` would drop the grouping and the
/// text would mis-associate (e.g. `(2 + 3) * 4` flattening to `2 + 3 * 4`).
private func renderAtom(_ filter: Filter) -> String {
    switch filter {
    case .identity, .field, .index, .iterate, .literal, .call:
        return render(filter)
    case .pipe, .comma, .alternative, .nullish, .binary, .neg:
        return "(\(render(filter)))"
    }
}

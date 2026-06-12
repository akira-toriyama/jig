// The evaluator: jq's generator semantics, eagerly.
//
// A filter maps ONE input value to a STREAM (array) of outputs. Streams are
// represented as plain [JigValue] for now — correct and simple. Switching to
// lazy generation (for `limit`, `first`, infinite generators like `repeat`)
// is on the roadmap and changes only this file (docs/jq-compat.md).
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

public func evaluate(_ filter: Filter, on input: JigValue, mode: JigMode = .jq) throws -> [JigValue] {
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

    case .iterate(let optional, let span):
        switch input {
        case .array(let items):
            return items
        case .object(let pairs):
            return pairs.map(\.value)
        case .null where mode == .humane:
            // H2 (docs/jq-compat.md mode-diff table): in humane mode a null
            // flows through iteration as the empty stream instead of
            // erroring — null already propagates through .foo / .[N], so
            // this makes .[] consistent.
            return []
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot iterate over \(input.typeName)\(preview(input))",
                span: span,
                hint: input == .null
                    ? "use .[]? , // [] , or run in humane mode (--humane) to treat null as empty"
                    : "use .[]? to skip non-iterable inputs, or // [] to default missing data")
        }

    case .pipe(let lhs, let rhs):
        // Feed every output of lhs through rhs, concatenating the streams.
        var out: [JigValue] = []
        for v in try evaluate(lhs, on: input, mode: mode) {
            out.append(contentsOf: try evaluate(rhs, on: v, mode: mode))
        }
        return out

    case .comma(let lhs, let rhs):
        return try evaluate(lhs, on: input, mode: mode) + (try evaluate(rhs, on: input, mode: mode))

    case .literal(let value):
        return [value]

    case .alternative(let lhs, let rhs, _):
        // jq `//`: drop false+null on the left; humane (H1): drop only null.
        return try alternative(lhs, rhs, on: input, mode: mode, keepFalse: mode == .humane)

    case .nullish(let lhs, let rhs, _):
        // `??`: drop only null, both modes.
        return try alternative(lhs, rhs, on: input, mode: mode, keepFalse: true)

    case .call(let name, let args, let span):
        return try evalCall(name, args, on: input, mode: mode, span: span)
    }
}

/// Shared logic for `//` and `??`: keep the left outputs that survive the
/// filter (always drop null; drop false too unless `keepFalse`); if none
/// survive, fall back to the right side.
private func alternative(_ lhs: Filter, _ rhs: Filter, on input: JigValue,
                         mode: JigMode, keepFalse: Bool) throws -> [JigValue] {
    let left = try evaluate(lhs, on: input, mode: mode)
    let kept = left.filter { v in
        switch v {
        case .null: return false
        case .bool(false): return keepFalse
        default: return true
        }
    }
    return kept.isEmpty ? try evaluate(rhs, on: input, mode: mode) : kept
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

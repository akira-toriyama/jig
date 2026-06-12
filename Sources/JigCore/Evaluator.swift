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

    case .iterate(let optional, let span):
        switch input {
        case .array(let items):
            return items
        case .object(let pairs):
            return pairs.map(\.value)
        default:
            if optional { return [] }
            throw EvalError(
                message: "cannot iterate over \(input.typeName)\(preview(input))",
                span: span,
                hint: "use .[]? to skip non-iterable inputs, or // [] to default missing data")
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
    }
}

/// A short rendering of the offending value for error messages —
/// " (null)" / " (3)" / "" when too long to help.
private func preview(_ v: JigValue) -> String {
    let s = writeJSON(v, style: .compact)
    return s.count <= 24 ? " (\(s))" : ""
}

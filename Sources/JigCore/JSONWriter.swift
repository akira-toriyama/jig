// JSON serialization, jq-flavored:
//
//   - pretty (default) = 2-space indent, like jq without flags
//   - compact (-c)     = no whitespace
//   - object key order = insertion order (never re-sorted here; -S is a
//     separate, future concern)
//   - numbers: the source literal wins when preserved; computed integral
//     doubles print without a decimal point (2+2 → 4, not 4.0);
//     NaN prints as null and ±infinity clamps to ±DBL_MAX — all jq behavior.

public enum JSONStyle: Sendable, Equatable {
    case compact
    case pretty(indent: Int)

    public static let pretty = JSONStyle.pretty(indent: 2)
}

public func writeJSON(_ value: JigValue, style: JSONStyle = .pretty) -> String {
    var out = ""
    write(value, style: style, depth: 0, into: &out)
    return out
}

private func write(_ value: JigValue, style: JSONStyle, depth: Int, into out: inout String) {
    switch value {
    case .null:
        out += "null"
    case .bool(let b):
        out += b ? "true" : "false"
    case .number(let n):
        out += formatNumber(n)
    case .string(let s):
        writeString(s, into: &out)
    case .array(let items):
        if items.isEmpty { out += "[]"; return }
        switch style {
        case .compact:
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, style: style, depth: depth + 1, into: &out)
            }
            out += "]"
        case .pretty(let indent):
            let inner = String(repeating: " ", count: indent * (depth + 1))
            let outer = String(repeating: " ", count: indent * depth)
            out += "[\n"
            for (i, item) in items.enumerated() {
                if i > 0 { out += ",\n" }
                out += inner
                write(item, style: style, depth: depth + 1, into: &out)
            }
            out += "\n" + outer + "]"
        }
    case .object(let pairs):
        if pairs.isEmpty { out += "{}"; return }
        switch style {
        case .compact:
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                writeString(pair.key, into: &out)
                out += ":"
                write(pair.value, style: style, depth: depth + 1, into: &out)
            }
            out += "}"
        case .pretty(let indent):
            let inner = String(repeating: " ", count: indent * (depth + 1))
            let outer = String(repeating: " ", count: indent * depth)
            out += "{\n"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += ",\n" }
                out += inner
                writeString(pair.key, into: &out)
                out += ": "
                write(pair.value, style: style, depth: depth + 1, into: &out)
            }
            out += "\n" + outer + "}"
        }
    }
}

private func formatNumber(_ n: JigNumber) -> String {
    // Literal preservation (jq 1.7): an untouched input number prints
    // exactly as it was written.
    if let literal = n.literal { return literal }
    let d = n.double
    if d.isNaN { return "null" }  // jq prints nan as null
    if d.isInfinite {
        // jq clamps infinities to the largest finite double.
        return d > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308"
    }
    // Computed integral doubles print as integers (jq: 2+2 → 4).
    if d == d.rounded(), abs(d) < 1e15 {
        return String(Int64(d))
    }
    return "\(d)"
}

private func writeString(_ s: String, into out: inout String) {
    out += "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += "\\u" + hexString(scalar.value, pad: 4)
            } else {
                // Non-ASCII passes through as UTF-8 (jq default; -a is a
                // future flag).
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

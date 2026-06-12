// jig's own JSON document model. Foundation's JSONSerialization is unusable
// here on three counts that are jq *semantics*, not nice-to-haves:
//
//   1. Object key ORDER must be preserved (jq keeps insertion order; sorting
//      is opt-in via -S).
//   2. Number LITERALS must survive a parse → print round-trip (jq 1.7
//      semantics; a bare Double mangles 64-bit ids like 12345678901234567890).
//   3. Values must be plain value types so the evaluator can fork streams
//      without reference aliasing.

/// A JSON value as jig sees it.
public enum JigValue: Sendable {
    case null
    case bool(Bool)
    case number(JigNumber)
    case string(String)
    case array([JigValue])
    /// Insertion-ordered key/value pairs. Keys are unique — the parser keeps
    /// the LAST occurrence of a duplicate key, matching jq.
    case object([(key: String, value: JigValue)])

    /// Type name as used in diagnostics — matches jq's wording
    /// ("Cannot index number with …") so error-message muscle memory carries
    /// over.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Object member lookup (insertion order preserved elsewhere; lookup is
    /// by key). Returns nil when self is not an object or the key is absent.
    public func member(_ key: String) -> JigValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }
}

extension JigValue: Equatable {
    /// jq equality: objects compare as key→value maps (order-insensitive);
    /// arrays compare element-wise; numbers compare numerically.
    public static func == (lhs: JigValue, rhs: JigValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            let sa = a.sorted { $0.key < $1.key }
            let sb = b.sorted { $0.key < $1.key }
            return zip(sa, sb).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }
}

/// Lowercase hex rendering without Foundation (`String(format:)`) — JigCore
/// stays importable under the Swift Static Linux SDK, where trimming
/// Foundation matters (CLAUDE.md "Non-obvious constraints").
func hexString(_ value: UInt32, pad: Int) -> String {
    let digits = Array("0123456789abcdef")
    var v = value
    var out: [Character] = []
    repeat {
        out.append(digits[Int(v & 0xF)])
        v >>= 4
    } while v > 0
    while out.count < pad { out.append("0") }
    return String(out.reversed())
}

/// A JSON number that remembers how it was written.
///
/// jq 1.7 preserves the source text of a number until arithmetic touches it
/// (then it decays to a double). jig does the same: `literal` is the exact
/// source text from the input, dropped (nil) as soon as the value is the
/// result of computation. Printing prefers the literal.
public struct JigNumber: Sendable, Equatable {
    /// Exact source text (e.g. "1.0", "12345678901234567890"), or nil for
    /// computed values.
    public let literal: String?
    /// The numeric value used for arithmetic and comparison.
    public let double: Double

    public init(literal: String, double: Double) {
        self.literal = literal
        self.double = double
    }

    /// A computed number — no source literal to preserve.
    public init(_ double: Double) {
        self.literal = nil
        self.double = double
    }

    /// Numbers compare numerically; the literal is a printing concern only.
    /// (Full big-decimal comparison à la jq 1.7 is future work —
    /// docs/jq-compat.md.)
    public static func == (lhs: JigNumber, rhs: JigNumber) -> Bool {
        lhs.double == rhs.double
    }
}

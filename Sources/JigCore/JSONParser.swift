// Hand-rolled JSON parser. Byte-level (UTF-8), tracks line/column for
// diagnostics, preserves number literals and object key order — the three
// requirements that rule out JSONSerialization (see JSON.swift).
//
// Inputs are STREAMS: like jq, a single stdin/file may carry any number of
// whitespace-separated JSON documents ("1 2 3", NDJSON, …). Use
// JSONStreamParser.next() until it returns nil.
//
// Robustness rule (jq pain point: parser crashes/asserts on bad input): any
// byte sequence must produce either a value or a JSONParseError — never a
// trap. Recursion depth is bounded by `maxDepth`.

public struct JSONParseError: Error, Equatable {
    public let message: String
    /// 1-based position in the input the parser was looking at.
    public let line: Int
    public let column: Int
    public let hint: String?

    public init(message: String, line: Int, column: Int, hint: String? = nil) {
        self.message = message
        self.line = line
        self.column = column
        self.hint = hint
    }

    public var description: String {
        var s = "input:\(line):\(column): \(message)"
        if let hint { s += "\n  hint: \(hint)" }
        return s
    }
}

public struct JSONStreamParser {
    private let bytes: [UInt8]
    private var pos = 0
    private var line = 1
    private var lineStart = 0
    /// Bound on nesting so pathological inputs error instead of overflowing
    /// the stack.
    private let maxDepth = 512

    public init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    /// Next document in the stream, or nil at clean end of input.
    public mutating func next() throws -> JigValue? {
        skipWhitespace()
        guard pos < bytes.count else { return nil }
        return try parseValue(depth: 0)
    }

    // MARK: - Scanning primitives

    private var column: Int { pos - lineStart + 1 }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0D:
                pos += 1
            case 0x0A:
                pos += 1
                line += 1
                lineStart = pos
            default:
                return
            }
        }
    }

    private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private func fail(_ message: String, hint: String? = nil) -> JSONParseError {
        JSONParseError(message: message, line: line, column: column, hint: hint)
    }

    private mutating func expect(_ byte: UInt8, _ what: String) throws {
        guard peek() == byte else {
            throw fail("expected \(what)\(describeCurrentByte())")
        }
        pos += 1
    }

    private func describeCurrentByte() -> String {
        guard let b = peek() else { return ", got end of input" }
        if b >= 0x21 && b < 0x7F { return ", got \"\(Character(UnicodeScalar(b)))\"" }
        return ", got byte 0x\(hexString(UInt32(b), pad: 2))"
    }

    // MARK: - Values

    private mutating func parseValue(depth: Int) throws -> JigValue {
        guard depth < maxDepth else {
            throw fail("nesting deeper than \(maxDepth) levels",
                       hint: "jig bounds recursion to keep malformed input from crashing; this is configurable in a future release")
        }
        skipWhitespace()
        guard let b = peek() else { throw fail("expected a value, got end of input") }
        switch b {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try parseKeyword("true"); return .bool(true)
        case UInt8(ascii: "f"): try parseKeyword("false"); return .bool(false)
        case UInt8(ascii: "n"): try parseKeyword("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        case UInt8(ascii: "'"):
            throw fail("unexpected \"'\" — JSON strings use double quotes",
                       hint: "'foo' is not valid JSON; write \"foo\"")
        default:
            throw fail("unexpected character\(describeCurrentByte())")
        }
    }

    private mutating func parseKeyword(_ word: String) throws {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else {
            throw fail("invalid literal — expected \"\(word)\"")
        }
        pos += w.count
    }

    private mutating func parseObject(depth: Int) throws -> JigValue {
        pos += 1 // {
        var pairs: [(key: String, value: JigValue)] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { pos += 1; return .object([]) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw fail("expected object key (a string)\(describeCurrentByte())")
            }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"), "\":\" after object key")
            let value = try parseValue(depth: depth + 1)
            // Duplicate keys: keep the LAST occurrence (jq behavior).
            if let i = pairs.firstIndex(where: { $0.key == key }) {
                pairs[i] = (key, value)
            } else {
                pairs.append((key, value))
            }
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): pos += 1
            case UInt8(ascii: "}"): pos += 1; return .object(pairs)
            default: throw fail("expected \",\" or \"}\" in object\(describeCurrentByte())")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> JigValue {
        pos += 1 // [
        var items: [JigValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { pos += 1; return .array([]) }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): pos += 1
            case UInt8(ascii: "]"): pos += 1; return .array(items)
            default: throw fail("expected \",\" or \"]\" in array\(describeCurrentByte())")
            }
        }
    }

    private mutating func parseString() throws -> String {
        pos += 1 // opening quote
        var scalars = String.UnicodeScalarView()
        while true {
            guard let b = peek() else { throw fail("unterminated string") }
            pos += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(scalars)
            case UInt8(ascii: "\\"):
                guard let e = peek() else { throw fail("unterminated escape in string") }
                pos += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    scalars.append(try parseUnicodeEscape())
                default:
                    throw fail("invalid escape \"\\\(Character(UnicodeScalar(e)))\"")
                }
            case 0x00...0x1F:
                throw fail("raw control character 0x\(hexString(UInt32(b), pad: 2)) in string",
                           hint: "control characters must be escaped (\\n, \\u0000, …)")
            default:
                // Re-assemble UTF-8 multi-byte sequences.
                if b < 0x80 {
                    scalars.append(UnicodeScalar(b))
                } else {
                    var buf: [UInt8] = [b]
                    let extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1
                    for _ in 0..<extra {
                        guard let c = peek(), c & 0xC0 == 0x80 else {
                            throw fail("invalid UTF-8 sequence in string")
                        }
                        buf.append(c)
                        pos += 1
                    }
                    guard let decoded = String(bytes: buf, encoding: .utf8) else {
                        throw fail("invalid UTF-8 sequence in string")
                    }
                    scalars.append(contentsOf: decoded.unicodeScalars)
                }
            }
            if b == 0x0A { line += 1; lineStart = pos }
        }
    }

    private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
        let high = try parseHex4()
        // Surrogate pair?
        if (0xD800...0xDBFF).contains(high) {
            guard peek() == UInt8(ascii: "\\") else {
                throw fail("unpaired UTF-16 high surrogate \\u\(String(high, radix: 16))")
            }
            pos += 1
            guard peek() == UInt8(ascii: "u") else {
                throw fail("unpaired UTF-16 high surrogate \\u\(String(high, radix: 16))")
            }
            pos += 1
            let low = try parseHex4()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw fail("invalid UTF-16 surrogate pair")
            }
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = UnicodeScalar(combined) else {
                throw fail("invalid UTF-16 surrogate pair")
            }
            return scalar
        }
        if (0xDC00...0xDFFF).contains(high) {
            throw fail("unpaired UTF-16 low surrogate \\u\(String(high, radix: 16))")
        }
        guard let scalar = UnicodeScalar(high) else {
            throw fail("invalid \\u escape")
        }
        return scalar
    }

    private mutating func parseHex4() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            guard let b = peek() else { throw fail("truncated \\u escape") }
            let digit: Int
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(b - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(b - UInt8(ascii: "A")) + 10
            default: throw fail("invalid hex digit in \\u escape\(describeCurrentByte())")
            }
            value = value * 16 + digit
            pos += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JigNumber {
        let start = pos
        if peek() == UInt8(ascii: "-") { pos += 1 }
        // Integer part: 0 | [1-9][0-9]*
        guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
            throw fail("invalid number — expected a digit\(describeCurrentByte())")
        }
        if first == UInt8(ascii: "0") {
            pos += 1
        } else {
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { pos += 1 }
        }
        // Fraction
        if peek() == UInt8(ascii: ".") {
            pos += 1
            guard let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) else {
                throw fail("invalid number — expected a digit after \".\"")
            }
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { pos += 1 }
        }
        // Exponent
        if let b = peek(), b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
            pos += 1
            if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { pos += 1 }
            guard let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) else {
                throw fail("invalid number — expected a digit in exponent")
            }
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { pos += 1 }
        }
        let literal = String(decoding: bytes[start..<pos], as: UTF8.self)
        guard let d = Double(literal) else {
            throw fail("invalid number \"\(literal)\"")
        }
        return JigNumber(literal: literal, double: d)
    }
}

/// Convenience: parse a complete input that must contain EXACTLY one JSON
/// document (used by tests and --argjson-style features later).
public func parseOneJSON(_ text: String) throws -> JigValue {
    var parser = JSONStreamParser(text)
    guard let v = try parser.next() else {
        throw JSONParseError(message: "expected a value, got end of input", line: 1, column: 1)
    }
    if try parser.next() != nil {
        throw JSONParseError(message: "trailing content after JSON value", line: 1, column: 1)
    }
    return v
}

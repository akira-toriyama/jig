// Filter (jq program) lexer + recursive-descent parser.
//
// Design contract (docs/jq-compat.md, "diagnostics"):
//   - hand-written, never crashes: any input produces a Filter or a
//     FilterParseError (fuzzing is the eventual proof)
//   - errors are HUMAN: position, what was found, what was expected, and a
//     hint when we recognize a familiar mistake (smart quotes pasted from a
//     chat app, shell quoting that swallowed the quotes, …) — never
//     bison-speak like "unexpected INVALID_CHARACTER, expecting $end"
//
// Grammar (v0 — the supported subset; growth roadmap in docs/jq-compat.md):
//
//   program  := pipe
//   pipe     := comma ( "|" comma )*          # | binds loosest, like jq
//   comma    := postfix ( "," postfix )*
//   postfix  := primary suffix*
//   primary  := "." ( IDENT "?"? )?           # . | .foo
//            |  "(" pipe ")"
//   suffix   := "." IDENT "?"?                # .foo.bar chains
//            |  "[" INT? "]" "?"?             # .[0] index / .[] iterate

public struct FilterParseError: Error, Equatable {
    public let message: String
    public let span: SourceSpan
    public let hint: String?

    public init(message: String, span: SourceSpan, hint: String? = nil) {
        self.message = message
        self.span = span
        self.hint = hint
    }
}

public func parseFilter(_ program: String) throws -> Filter {
    var parser = FilterParser(program)
    return try parser.parseProgram()
}

private struct FilterParser {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ program: String) {
        self.bytes = Array(program.utf8)
    }

    mutating func parseProgram() throws -> Filter {
        skipWhitespace()
        guard pos < bytes.count else {
            throw FilterParseError(
                message: "empty program",
                span: SourceSpan(0, 0),
                hint: "the simplest filter is . (identity): jig '.'")
        }
        let f = try parsePipe()
        skipWhitespace()
        if pos < bytes.count {
            throw unexpected("after a complete filter")
        }
        return f
    }

    // MARK: grammar

    private mutating func parsePipe() throws -> Filter {
        var lhs = try parseComma()
        while true {
            skipWhitespace()
            if peek() == UInt8(ascii: "|") {
                pos += 1
                let rhs = try parseComma()
                lhs = .pipe(lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private mutating func parseComma() throws -> Filter {
        var lhs = try parsePostfix()
        while true {
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                pos += 1
                let rhs = try parsePostfix()
                lhs = .comma(lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    private mutating func parsePostfix() throws -> Filter {
        var f = try parsePrimary()
        while let suffix = try parseSuffix() {
            // Suffixes chain onto the current filter via pipe — `.a.b` is
            // exactly `.a | .b`, which keeps the evaluator a single code
            // path. Identity is elided (`. | .[]` ≡ `.[]`), so `.[]` parses
            // as a bare iterate node, not pipe(identity, iterate).
            f = (f == .identity) ? suffix : .pipe(f, suffix)
        }
        return f
    }

    private mutating func parsePrimary() throws -> Filter {
        skipWhitespace()
        guard let b = peek() else {
            throw FilterParseError(
                message: "expected a filter, got end of program",
                span: SourceSpan(pos, pos))
        }
        switch b {
        case UInt8(ascii: "."):
            let dotStart = pos
            pos += 1
            // `.foo` — field access directly after the dot.
            if let name = scanIdent() {
                let optional = scanQuestion()
                return .field(name: name, optional: optional, span: SourceSpan(dotStart, pos))
            }
            return .identity
        case UInt8(ascii: "("):
            pos += 1
            let inner = try parsePipe()
            skipWhitespace()
            guard peek() == UInt8(ascii: ")") else {
                throw unexpected("inside parentheses — expected \")\"")
            }
            pos += 1
            return inner
        default:
            throw unexpected("at the start of a filter")
        }
    }

    /// nil = no suffix here (caller stops chaining).
    private mutating func parseSuffix() throws -> Filter? {
        // NOTE: no skipWhitespace() before a suffix — `.a .b` is two
        // filters in jq, not a chain. Suffixes must touch.
        guard let b = peek() else { return nil }
        switch b {
        case UInt8(ascii: "."):
            let start = pos
            // Only a suffix if an identifier follows (`.a.b`); a lone
            // trailing dot is an error, and `.. ` (recurse) is future work.
            let save = pos
            pos += 1
            guard let name = scanIdent() else {
                pos = save
                throw FilterParseError(
                    message: "expected a field name after \".\"",
                    span: SourceSpan(start, start + 1),
                    hint: "write .foo, or just . for identity")
            }
            let optional = scanQuestion()
            return .field(name: name, optional: optional, span: SourceSpan(start, pos))
        case UInt8(ascii: "["):
            let start = pos
            pos += 1
            skipWhitespace()
            if peek() == UInt8(ascii: "]") {
                pos += 1
                let optional = scanQuestion()
                return .iterate(optional: optional, span: SourceSpan(start, pos))
            }
            guard let n = scanInt() else {
                throw unexpected("inside [ ] — expected an index number or \"]\"")
            }
            skipWhitespace()
            guard peek() == UInt8(ascii: "]") else {
                throw unexpected("after the index — expected \"]\"")
            }
            pos += 1
            let optional = scanQuestion()
            return .index(n, optional: optional, span: SourceSpan(start, pos))
        default:
            return nil
        }
    }

    // MARK: lexing helpers

    private func peek() -> UInt8? { pos < bytes.count ? bytes[pos] : nil }

    private mutating func skipWhitespace() {
        while let b = peek() {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                pos += 1
            } else if b == UInt8(ascii: "#") {
                // jq-style comment: `#` to end of line. Doubles as the
                // carrier for the `# jig:humane` mode pragma (Mode.swift
                // pre-scans for it; here we just skip it).
                while let c = peek(), c != 0x0A { pos += 1 }
            } else {
                return
            }
        }
    }

    private mutating func scanIdent() -> String? {
        let start = pos
        while let b = peek(), isIdentByte(b, first: pos == start) {
            pos += 1
        }
        guard pos > start else { return nil }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private func isIdentByte(_ b: UInt8, first: Bool) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "_"):
            return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return !first
        default:
            return false
        }
    }

    private mutating func scanInt() -> Int? {
        let start = pos
        if peek() == UInt8(ascii: "-") { pos += 1 }
        let digitsStart = pos
        while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) {
            pos += 1
        }
        guard pos > digitsStart else { pos = start; return nil }
        return Int(String(decoding: bytes[start..<pos], as: UTF8.self))
    }

    private mutating func scanQuestion() -> Bool {
        if peek() == UInt8(ascii: "?") { pos += 1; return true }
        return false
    }

    // MARK: errors

    /// Build an "unexpected X <context>" error, with hints for the mistakes
    /// everyone makes once.
    private func unexpected(_ context: String) -> FilterParseError {
        guard let b = peek() else {
            return FilterParseError(
                message: "unexpected end of program \(context)",
                span: SourceSpan(pos, pos))
        }
        let span = SourceSpan(pos, pos + 1)

        // Smart quotes: pasted from a chat app / word processor.
        let smartQuotes: [[UInt8]] = [
            [0xE2, 0x80, 0x98], [0xE2, 0x80, 0x99],  // ‘ ’
            [0xE2, 0x80, 0x9C], [0xE2, 0x80, 0x9D],  // “ ”
        ]
        for q in smartQuotes where bytes.count >= pos + 3 && Array(bytes[pos..<pos + 3]) == q {
            return FilterParseError(
                message: "unexpected smart quote \(context)",
                span: SourceSpan(pos, pos + 3),
                hint: "this looks pasted from a chat app or document — replace “ ” ‘ ’ with straight quotes")
        }

        switch b {
        case UInt8(ascii: "'"), UInt8(ascii: "\""):
            return FilterParseError(
                message: "unexpected \(b == UInt8(ascii: "'") ? "\"'\"" : "'\"'") \(context)",
                span: span,
                hint: "string literals are not implemented yet (docs/jq-compat.md roadmap) — if this quote was meant to wrap the whole filter, your shell may have swallowed the outer quotes: jig '.foo'")
        case UInt8(ascii: "$"):
            return FilterParseError(
                message: "unexpected \"$\" \(context)",
                span: span,
                hint: "$variables are not implemented yet (docs/jq-compat.md roadmap) — also check the shell didn't expand $name before jig saw it (use single quotes)")
        default:
            let display: String
            if b >= 0x21 && b < 0x7F {
                display = "\"\(Character(UnicodeScalar(b)))\""
            } else {
                display = String(format: "byte 0x%02X", b)
            }
            return FilterParseError(
                message: "unexpected \(display) \(context)",
                span: span)
        }
    }
}

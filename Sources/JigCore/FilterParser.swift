// Filter (jq program) lexer + recursive-descent parser.
//
// Design contract (docs/roadmap.md, "diagnostics"):
//   - hand-written, never crashes: any input produces a Filter or a
//     FilterParseError (fuzzing is the eventual proof)
//   - errors are HUMAN: position, what was found, what was expected, and a
//     hint when we recognize a familiar mistake (smart quotes pasted from a
//     chat app, shell quoting that swallowed the quotes, …) — never
//     bison-speak like "unexpected INVALID_CHARACTER, expecting $end"
//
// Grammar (v0 — the supported subset; growth roadmap in docs/roadmap.md).
// Precedence runs loosest→tightest down the chain, mirroring jq's parser.y:
//
//   program  := pipe
//   pipe     := comma ( "|" comma )*          # | binds loosest, like jq
//   comma    := alt ( "," alt )*
//   alt      := or ( ("//" | "??") or )*      # // ??  (additive ?? alongside)
//   or       := and ( "or" and )*
//   and      := cmp ( "and" cmp )*
//   cmp      := add ( ("==" "!=" "<=" ">=" "<" ">") add )?   # NONASSOC: at most one
//   add      := mul ( ("+" | "-") mul )*
//   mul      := unary ( ("*" | "/" | "%") unary )*
//   unary    := "-" unary | postfix           # unary minus (NEG)
//   postfix  := primary suffix*
//   primary  := "." ( IDENT "?"? )?           # . | .foo
//            |  "(" pipe ")"                   # grouping
//            |  literal | call                 # 42 "s" true null / length, map(f)
//            |  "[" pipe? "]"                  # array construction: [.a,.b] / []
//            |  "{" entries? "}"               # object construction
//   entries  := entry ( "," entry )* ","?      # one trailing comma is allowed
//   entry    := key ( ":" objval )?            # value omitted = shorthand {k}≡{k:.k}
//   key      := IDENT | KEYWORD | STRING | "(" pipe ")"   # bareword/keyword/string/computed
//   objval   := alt ( "|" alt )*               # comma-free: "," separates pairs (jq)
//   suffix   := "." IDENT "?"?                # .foo.bar chains
//            |  "[" INT? "]" "?"?             # .[0] index / .[] iterate
//   STRING   := '"' ( CHAR | ESC | "\(" pipe ")" | "${" pipe "}" )* '"'
//                                              # \(…) interpolation; ${…} is an
//                                              # additive ECMAScript alias for it

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
        var lhs = try parseAlt()
        while true {
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                pos += 1
                let rhs = try parseAlt()
                lhs = .comma(lhs, rhs)
            } else {
                return lhs
            }
        }
    }

    // `//` (alternative) and `??` (nullish) bind tighter than `,` and `|`,
    // looser than `or` / `and` / comparison / arithmetic — jq precedence for
    // `//`.
    private mutating func parseAlt() throws -> Filter {
        var lhs = try parseOr()
        while true {
            skipWhitespace()
            let opStart = pos
            if matchOperator("//") {
                let rhs = try parseOr()
                lhs = .alternative(lhs, rhs, span: SourceSpan(opStart, opStart + 2))
            } else if matchOperator("??") {
                let rhs = try parseOr()
                lhs = .nullish(lhs, rhs, span: SourceSpan(opStart, opStart + 2))
            } else {
                return lhs
            }
        }
    }

    private mutating func parseOr() throws -> Filter {
        var lhs = try parseAnd()
        while true {
            skipWhitespace()
            let opStart = pos
            if matchKeyword("or") {
                let rhs = try parseAnd()
                lhs = .binary(.or, lhs, rhs, span: SourceSpan(opStart, opStart + 2))
            } else {
                return lhs
            }
        }
    }

    private mutating func parseAnd() throws -> Filter {
        var lhs = try parseComparison()
        while true {
            skipWhitespace()
            let opStart = pos
            if matchKeyword("and") {
                let rhs = try parseComparison()
                lhs = .binary(.and, lhs, rhs, span: SourceSpan(opStart, opStart + 3))
            } else {
                return lhs
            }
        }
    }

    // Comparison is NONASSOC in jq: `1 < 2 < 3` is an error, so we accept at
    // most one comparison operator and let any trailing one fall through to a
    // clean "unexpected" diagnostic.
    private mutating func parseComparison() throws -> Filter {
        let lhs = try parseAdditive()
        skipWhitespace()
        let opStart = pos
        let op: BinOp?
        // Two-char operators first so `<=`/`>=`/`==`/`!=` win over `<`/`>`/`=`.
        if matchOperator("==") { op = .eq }
        else if matchOperator("!=") { op = .ne }
        else if matchOperator("<=") { op = .le }
        else if matchOperator(">=") { op = .ge }
        else if matchOperator("<") { op = .lt }
        else if matchOperator(">") { op = .gt }
        else { op = nil }
        guard let op else { return lhs }
        let rhs = try parseAdditive()
        return .binary(op, lhs, rhs, span: SourceSpan(opStart, opStart + op.symbol.utf8.count))
    }

    private mutating func parseAdditive() throws -> Filter {
        var lhs = try parseMultiplicative()
        while true {
            skipWhitespace()
            let opStart = pos
            if matchOperator("+") {
                let rhs = try parseMultiplicative()
                lhs = .binary(.add, lhs, rhs, span: SourceSpan(opStart, opStart + 1))
            } else if peek() == UInt8(ascii: "-") {
                pos += 1
                let rhs = try parseMultiplicative()
                lhs = .binary(.subtract, lhs, rhs, span: SourceSpan(opStart, opStart + 1))
            } else {
                return lhs
            }
        }
    }

    private mutating func parseMultiplicative() throws -> Filter {
        var lhs = try parseUnary()
        while true {
            skipWhitespace()
            let opStart = pos
            if matchOperator("*") {
                let rhs = try parseUnary()
                lhs = .binary(.multiply, lhs, rhs, span: SourceSpan(opStart, opStart + 1))
            } else if peek() == UInt8(ascii: "/") && peekAhead(1) != UInt8(ascii: "/") {
                // A lone `/` is division; `//` is the alternative operator
                // (handled higher up, so we must not eat its first slash).
                pos += 1
                let rhs = try parseUnary()
                lhs = .binary(.divide, lhs, rhs, span: SourceSpan(opStart, opStart + 1))
            } else if matchOperator("%") {
                let rhs = try parseUnary()
                lhs = .binary(.modulo, lhs, rhs, span: SourceSpan(opStart, opStart + 1))
            } else {
                return lhs
            }
        }
    }

    // Unary minus binds tighter than `*`/`/`/`%` (jq's NEG). `-3` is a number
    // literal (so its source text round-trips); `-.x` / `-(…)` negate.
    private mutating func parseUnary() throws -> Filter {
        skipWhitespace()
        if peek() == UInt8(ascii: "-") {
            let next = peekAhead(1)
            // `-` immediately before a digit stays a negative number literal.
            if let n = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(n) {
                return try parsePostfix()
            }
            let opStart = pos
            pos += 1
            let operand = try parseUnary()
            return .neg(operand, span: SourceSpan(opStart, pos))
        }
        return try parsePostfix()
    }

    /// Consume `op` if it's exactly next. Used for symbolic operators
    /// (`//`, `??`, `==`, `+`, …).
    private mutating func matchOperator(_ op: String) -> Bool {
        let want = Array(op.utf8)
        guard pos + want.count <= bytes.count else { return false }
        for (i, b) in want.enumerated() where bytes[pos + i] != b { return false }
        pos += want.count
        return true
    }

    /// Consume a word operator (`and` / `or`) only on a word boundary, so
    /// `order` / `android` are NOT mistaken for the keyword.
    private mutating func matchKeyword(_ kw: String) -> Bool {
        let want = Array(kw.utf8)
        guard pos + want.count <= bytes.count else { return false }
        for (i, b) in want.enumerated() where bytes[pos + i] != b { return false }
        let after = pos + want.count
        if after < bytes.count && isIdentByte(bytes[after], first: false) { return false }
        pos += want.count
        return true
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
            // `.5` is the number 0.5 (jq's leading-dot decimal), not `.`
            // (identity) followed by a stray digit.
            if let d = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(d) {
                pos = dotStart
                return .literal(.number(try parseNumberLiteral()))
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
        case UInt8(ascii: "\""):
            return try parseStringLiteral()
        case UInt8(ascii: "["):
            return try parseArrayConstruct()
        case UInt8(ascii: "{"):
            return try parseObjectConstruct()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .literal(.number(try parseNumberLiteral()))
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "_"):
            return try parseIdentifierPrimary()
        default:
            throw unexpected("at the start of a filter")
        }
    }

    /// A bare identifier: the keywords `true`/`false`/`null`, otherwise a
    /// function call (`length`, or `map(f)` / `has(k)` with `;`-separated
    /// args).
    private mutating func parseIdentifierPrimary() throws -> Filter {
        let start = pos
        guard let name = scanIdent() else { throw unexpected("at the start of a filter") }
        switch name {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "null": return .literal(.null)
        default: break
        }
        var args: [Filter] = []
        if peek() == UInt8(ascii: "(") {
            pos += 1
            while true {
                args.append(try parsePipe())
                skipWhitespace()
                if peek() == UInt8(ascii: ";") { pos += 1; continue }
                break
            }
            skipWhitespace()
            guard peek() == UInt8(ascii: ")") else {
                throw unexpected("in \(name)(...) arguments — expected \";\" or \")\"")
            }
            pos += 1
        }
        return .call(name: name, args: args, span: SourceSpan(start, pos))
    }

    // MARK: construction

    /// `[ Exp ]` / `[]` — array construction: collect the inner pipe
    /// expression's whole stream into one array. This is the PREFIX `[`
    /// (a primary); the SUFFIX `[…]` (index/iterate) is parseSuffix and only
    /// attaches to a preceding term — so `[1,2][0]` is index-0 of a built
    /// array, exactly like jq.
    private mutating func parseArrayConstruct() throws -> Filter {
        pos += 1 // consume "["
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            pos += 1
            return .arrayConstruct(nil)
        }
        let inner = try parsePipe()
        skipWhitespace()
        guard peek() == UInt8(ascii: "]") else {
            throw unexpected("inside [ … ] array construction — expected \"]\"")
        }
        pos += 1
        return .arrayConstruct(inner)
    }

    /// `{ … }` — object construction. Pairs are `,`-separated with one
    /// optional trailing comma (jq allows `{a:1,}`; `[1,2,]` is still an error,
    /// because array elements ride the comma OPERATOR which needs an operand).
    private mutating func parseObjectConstruct() throws -> Filter {
        pos += 1 // consume "{"
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            pos += 1
            return .objectConstruct([])
        }
        var entries: [ObjectEntry] = []
        while true {
            entries.append(try parseObjectEntry())
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                pos += 1
                skipWhitespace()
                if peek() == UInt8(ascii: "}") { pos += 1; return .objectConstruct(entries) }
                continue
            }
            if peek() == UInt8(ascii: "}") {
                pos += 1
                return .objectConstruct(entries)
            }
            throw unexpected("in object construction — expected \",\" between pairs or \"}\" to close")
        }
    }

    /// One object pair: a computed `(expr)` key (value required), or a
    /// bareword/keyword/string key (value optional — bare `{k}` is shorthand
    /// for `{k: .k}`). `$var` keys need variables (roadmap step 5).
    private mutating func parseObjectEntry() throws -> ObjectEntry {
        skipWhitespace()
        let keyStart = pos
        // Computed key: ( Exp ) — never a shorthand, a value must follow.
        if peek() == UInt8(ascii: "(") {
            pos += 1
            let keyExpr = try parsePipe()
            skipWhitespace()
            guard peek() == UInt8(ascii: ")") else {
                throw unexpected("inside a computed ( … ) object key — expected \")\"")
            }
            pos += 1
            let keySpan = SourceSpan(keyStart, pos)
            try expectColon(after: "a computed (…) key")
            return ObjectEntry(key: keyExpr, value: try parseObjectValue(), keySpan: keySpan)
        }
        // String key. A plain literal key keeps the shorthand form
        // ({"a b"} ≡ {"a b": .["a b"]}); an INTERPOLATED key ({"\(.n)": …}) is
        // a computed key, so — like a (expr) key — it requires an explicit
        // value. (The shorthand would need a `.[interpolated]` value node,
        // which jig has no representation for yet; roadmap step 5.)
        if peek() == UInt8(ascii: "\"") {
            let keyFilter = try parseStringLiteral()
            let keySpan = SourceSpan(keyStart, pos)
            if case .literal(.string(let s)) = keyFilter {
                return try objectEntryTail(key: s, keySpan: keySpan)
            }
            try expectColon(after: "an interpolated string key")
            return ObjectEntry(key: keyFilter, value: try parseObjectValue(), keySpan: keySpan)
        }
        // Bareword / keyword key (may be shorthand). Reserved words
        // (true/false/null/and/if/…) are plain string keys here, matching jq.
        if let name = scanIdent() {
            return try objectEntryTail(key: name, keySpan: SourceSpan(keyStart, pos))
        }
        throw objectKeyExpected()
    }

    /// After a string/bareword key: a `:` introduces an explicit value;
    /// otherwise it's the shorthand `{k}` whose value is `.k` (field access by
    /// that exact string, so `{"a b"}` reads `.["a b"]`).
    private mutating func objectEntryTail(key: String, keySpan: SourceSpan) throws -> ObjectEntry {
        skipWhitespace()
        let keyFilter = Filter.literal(.string(key))
        if peek() == UInt8(ascii: ":") {
            pos += 1
            return ObjectEntry(key: keyFilter, value: try parseObjectValue(), keySpan: keySpan)
        }
        return ObjectEntry(key: keyFilter,
                           value: .field(name: key, optional: false, span: keySpan),
                           keySpan: keySpan)
    }

    private mutating func expectColon(after what: String) throws {
        skipWhitespace()
        guard peek() == UInt8(ascii: ":") else {
            throw unexpected("after \(what) — expected \":\"")
        }
        pos += 1
    }

    /// The VALUE side of an object pair: a pipe-chain of comma-free
    /// expressions. `,` is the pair separator (so `{a:1,2}` is two pairs — a
    /// jq syntax error at `2`), but everything tighter than comma — `|`, `//`,
    /// `??`, `or`/`and`, comparison, arithmetic, unary minus — is allowed
    /// unparenthesized (verified against jq 1.8: `{a: 1+2, b: .x // 0}` works).
    private mutating func parseObjectValue() throws -> Filter {
        var lhs = try parseAlt()
        while true {
            skipWhitespace()
            if peek() == UInt8(ascii: "|") {
                pos += 1
                lhs = .pipe(lhs, try parseAlt())
            } else {
                return lhs
            }
        }
    }

    private func objectKeyExpected() -> FilterParseError {
        if peek() == UInt8(ascii: "$") {
            return FilterParseError(
                message: "unexpected \"$\" in object construction",
                span: SourceSpan(pos, pos + 1),
                hint: "$variable keys need variables (on the roadmap); for now use {name: …}, {\"name\": …}, or {(expr): …}")
        }
        return unexpected("in object construction — expected a key: a name, \"string\", or (expression)")
    }

    /// Parse a `"…"` string. The common case (no interpolation) returns a
    /// `.literal(.string)`; a string containing `\(…)` — or its additive
    /// ECMAScript alias `${…}` — returns a `.stringInterp` whose parts are the
    /// literal fragments and the embedded full-pipe filters, in source order.
    /// The embedded filter is a complete `parsePipe`, so `"\(.x | length)"`
    /// and nested strings `"\("inner \(.x)")"` parse naturally.
    private mutating func parseStringLiteral() throws -> Filter {
        let openQuote = pos
        pos += 1 // opening "
        var parts: [StringPart] = []
        var scalars = String.UnicodeScalarView()
        // Push the accumulated literal run as a fragment (if any), then reset.
        func flushLiteral() {
            if !scalars.isEmpty {
                parts.append(.literal(String(scalars)))
                scalars = String.UnicodeScalarView()
            }
        }
        while true {
            guard let b = peek() else {
                throw FilterParseError(message: "unterminated string literal",
                                       span: SourceSpan(openQuote, pos))
            }
            pos += 1
            switch b {
            case UInt8(ascii: "\""):
                // No interpolation seen → a plain string literal (the hot path,
                // and what object-key shorthand / render rely on detecting).
                if parts.isEmpty { return .literal(.string(String(scalars))) }
                flushLiteral()
                return .stringInterp(parts)
            case UInt8(ascii: "\\"):
                guard let e = peek() else {
                    throw FilterParseError(message: "unterminated escape in string",
                                           span: SourceSpan(pos - 1, pos))
                }
                if e == UInt8(ascii: "(") {
                    // `\(…)` interpolation: a full pipe up to the matching ")".
                    flushLiteral()
                    pos += 1 // consume "("
                    parts.append(.interp(try parseInterpolation(close: ")", form: "\\( … )")))
                    continue
                }
                pos += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                default:
                    throw FilterParseError(
                        message: "invalid escape \"\\\(Character(UnicodeScalar(e)))\" in string",
                        span: SourceSpan(pos - 2, pos))
                }
            case UInt8(ascii: "$") where peek() == UInt8(ascii: "{"):
                // `${…}` — additive ECMAScript alias for `\(…)`. jq treats
                // `${` as literal text, so this is the one spot where an
                // additive form gives meaning to (rare) valid jq string text;
                // it is documented in docs/roadmap.md. A bare `$` not before
                // `{` stays literal (falls through to the default below).
                flushLiteral()
                pos += 1 // consume "{"
                parts.append(.interp(try parseInterpolation(close: "}", form: "${ … }")))
            default:
                if b < 0x80 {
                    scalars.append(UnicodeScalar(b))
                } else {
                    // Re-assemble a UTF-8 multibyte sequence.
                    var buf: [UInt8] = [b]
                    let extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1
                    for _ in 0..<extra {
                        guard let c = peek(), c & 0xC0 == 0x80 else { break }
                        buf.append(c); pos += 1
                    }
                    if let s = String(bytes: buf, encoding: .utf8) {
                        scalars.append(contentsOf: s.unicodeScalars)
                    }
                }
            }
        }
    }

    /// The body of one interpolation — a full pipe expression up to its closing
    /// delimiter (`)` for `\(…)`, `}` for `${…}`). The opening `(` / `{` is
    /// already consumed. `form` names the spelling for the diagnostic.
    private mutating func parseInterpolation(close: Character, form: String) throws -> Filter {
        let f = try parsePipe()
        skipWhitespace()
        guard peek() == close.asciiValue else {
            throw unexpected("inside \(form) string interpolation — expected \"\(close)\"")
        }
        pos += 1 // consume the closing delimiter
        return f
    }

    private mutating func parseNumberLiteral() throws -> JigNumber {
        let start = pos
        if peek() == UInt8(ascii: "-") { pos += 1 }
        @discardableResult
        func digits() -> Bool {
            let s = pos
            while let d = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(d) { pos += 1 }
            return pos > s
        }
        // An integer part, a fractional part, or both — jq accepts the
        // leading-dot form `.5` (= 0.5), so neither is individually required.
        let hadInt = digits()
        var hadFrac = false
        if peek() == UInt8(ascii: ".") { pos += 1; hadFrac = digits() }
        guard hadInt || hadFrac else {
            throw unexpected("in a number — expected a digit")
        }
        if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            pos += 1
            if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { pos += 1 }
            digits()
        }
        let raw = String(decoding: bytes[start..<pos], as: UTF8.self)
        // Normalize a leading-dot decimal so Double can parse it and the
        // printed form matches jq (`.5` → `0.5`).
        var text = raw
        if text.hasPrefix(".") { text = "0" + text }
        else if text.hasPrefix("-.") { text = "-0" + text.dropFirst() }
        guard let value = Double(text) else {
            throw FilterParseError(message: "invalid number \"\(raw)\"",
                                   span: SourceSpan(start, pos))
        }
        return JigNumber(literal: text, double: value)
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

    /// The byte `n` positions ahead of the cursor without moving it.
    private func peekAhead(_ n: Int) -> UInt8? {
        let i = pos + n
        return i < bytes.count ? bytes[i] : nil
    }

    private mutating func skipWhitespace() {
        while let b = peek() {
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                pos += 1
            } else if b == UInt8(ascii: "#") {
                // jq-style comment: `#` to end of line, skipped here. (jig has
                // one semantics — there is no `# jig:humane` mode pragma.)
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
                hint: b == UInt8(ascii: "'")
                    ? "jq strings use double quotes (\"…\"), not '…' — and a lone quote here often means your shell swallowed the filter's outer quotes: jig '.foo'"
                    : "a string can't start here; if your shell swallowed the filter's outer quotes, wrap it in single quotes: jig '.foo'")
        case UInt8(ascii: "$"):
            return FilterParseError(
                message: "unexpected \"$\" \(context)",
                span: span,
                hint: "$variables are not implemented yet (on the roadmap) — also check the shell didn't expand $name before jig saw it (use single quotes)")
        case UInt8(ascii: "="):
            // `=>` is the JS arrow — a near-universal reflex for JS/TS users
            // (and LLMs) reaching for `filter(u => u.active)`. jig's builtins
            // take a BARE filter (the element is the implicit `.`), so redirect
            // there instead of mis-hinting toward `==`.
            if peekAhead(1) == UInt8(ascii: ">") {
                return FilterParseError(
                    message: "unexpected \"=>\" \(context)",
                    span: SourceSpan(pos, pos + 2),
                    hint: "jig has no => arrow — builtins take a bare filter: filter(.active) "
                        + "(the element is the implicit .); arrows and variables are on the roadmap")
            }
            return FilterParseError(
                message: "unexpected \"=\" \(context)",
                span: span,
                hint: "for equality use == (assignment / path-update is on the roadmap)")
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

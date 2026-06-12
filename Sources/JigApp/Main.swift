import Foundation
import JigCore

/// `@main enum JigApp` — named file, never top-level main.swift, so
/// `@testable import JigApp` keeps working from XCTest. Same pattern as
/// facet / chord / glance / perch.
@main
enum JigApp {
    @MainActor
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        // Verbose logging is env-var-triggered (JIG_DEBUG=1) — there is no
        // --debug flag (family rule).
        debugMode = ProcessInfo.processInfo.environment["JIG_DEBUG"] != nil

        let action: ArgsAction
        do {
            action = try parseArgs(argv)
        } catch let e as ArgsParseError {
            stderrLine("jig: \(describe(e))")
            stderrLine("jig: try --help")
            exit(2)
        } catch {
            stderrLine("jig: \(error)")
            exit(2)
        }

        switch action {
        case .showHelp: printHelp(); exit(0)
        case .showVersion: print("jig \(JigVersion.current)"); exit(0)
        case .run(let args): run(args)
        case .explain(let args): explainFilter(args)
        case .check(let args): checkFilter(args)
        }
    }

    /// Resolve the effective mode from flag / pragma / env (Mode.swift).
    static func mode(for args: Args) -> JigMode {
        resolveMode(humaneFlag: args.humane,
                    program: args.filter,
                    env: ProcessInfo.processInfo.environment["JIG_MODE"])
    }

    /// Compile `args.filter` or print a diagnostic and exit(3).
    @MainActor
    static func compileOrExit(_ args: Args) -> Filter {
        do {
            return try parseFilter(args.filter)
        } catch let e as FilterParseError {
            stderrLine(Diagnostic(e).render(program: args.filter))
            exit(3)
        } catch {
            stderrLine("jig: \(error)")
            exit(3)
        }
    }

    /// `jig explain <filter>` — describe the filter in plain language + a
    /// rough JavaScript analogy. Compile-only; reads no input.
    @MainActor
    static func explainFilter(_ args: Args) {
        let filter = compileOrExit(args)
        print(explain(filter, source: args.filter, mode: mode(for: args)))
        exit(0)
    }

    /// `jig check <filter>` — CI gate: compile-only, silent stdout on
    /// success (exit 0), diagnostic + exit 3 on a compile error.
    @MainActor
    static func checkFilter(_ args: Args) {
        let filter = compileOrExit(args)
        _ = filter
        stderrLine("jig: filter ok (\(mode(for: args).label))")
        exit(0)
    }

    /// Exit codes mirror jq: 0 ok, 2 usage/system error, 3 program compile
    /// error, 5 a runtime error occurred (later inputs still processed).
    @MainActor
    static func run(_ args: Args) {
        let filter = compileOrExit(args)
        let mode = mode(for: args)
        Log.debug("filter parsed: \(args.filter) [\(mode.label)]")

        let style: JSONStyle = args.compactOutput ? .compact : .pretty
        var hadRuntimeError = false
        var inputIndex = 0

        forEachInput(args) { input in
            inputIndex += 1
            do {
                for output in try evaluate(filter, on: input, mode: mode) {
                    if args.rawOutput, case .string(let s) = output {
                        print(s)
                    } else {
                        print(writeJSON(output, style: style))
                    }
                }
            } catch let e as EvalError {
                // jq behavior: a runtime error kills this input's outputs,
                // processing continues with the next input; exit 5 at end.
                stderrLine(Diagnostic(e).render(
                    program: args.filter, context: "input #\(inputIndex)"))
                hadRuntimeError = true
            } catch {
                stderrLine("jig: \(error)")
                hadRuntimeError = true
            }
        }

        exit(hadRuntimeError ? 5 : 0)
    }

    /// Feed each JSON document from -n / files / stdin to `body`.
    /// Exits(2) on unreadable files or malformed JSON — input errors are
    /// fatal in jq too.
    @MainActor
    static func forEachInput(_ args: Args, body: (JigValue) -> Void) {
        if args.nullInput {
            body(.null)
            return
        }
        let sources: [(name: String, text: String)]
        if args.files.isEmpty {
            // clig.dev: don't hang on an interactive terminal — if nothing
            // is piped in, guide the user instead of blocking on read().
            if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
                stderrLine("jig: no input — pipe JSON in, pass a file, or use -n")
                stderrLine("jig: e.g.  echo '{\"a\":1}' | jig '.a'   •   jig '.a' file.json   •   jig -n '1'")
                exit(2)
            }
            sources = [("<stdin>", readStdinText())]
        } else {
            sources = args.files.map { file in
                // clig.dev: `-` means stdin.
                if file == "-" { return ("<stdin>", readStdinText()) }
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                    stderrLine("jig: cannot read \(file)")
                    exit(2)
                }
                return (file, text)
            }
        }
        for source in sources {
            Log.debug("input \(source.name): \(source.text.utf8.count) bytes")
            var parser = JSONStreamParser(source.text)
            while true {
                do {
                    guard let value = try parser.next() else { break }
                    body(value)
                } catch let e as JSONParseError {
                    stderrLine("jig: \(source.name):\(e.line):\(e.column): \(e.message)")
                    if let hint = e.hint { stderrLine("  hint: \(hint)") }
                    exit(2)
                } catch {
                    stderrLine("jig: \(source.name): \(error)")
                    exit(2)
                }
            }
        }
    }

    static func readStdinText() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            stderrLine("jig: stdin is not valid UTF-8")
            exit(2)
        }
        return text
    }

    static func stderrLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func describe(_ e: ArgsParseError) -> String {
        switch e {
        case .unknownFlag(let f):
            return "unknown flag: \(f)"
        case .missingFilter:
            return "no filter given (usage: jig [flags] <filter> [files...])"
        }
    }

    static func printHelp() {
        print("""
        jig \(JigVersion.current) — a jq-compatible JSON processor with humane errors

        USAGE
          some-cmd | jig [flags] <filter> [files...]
          jig explain [flags] <filter>     describe the filter (+ JS analogy)
          jig check   [flags] <filter>     compile-only CI gate (exit 0 / 3)

        FILTER (v0 subset — full jq language is the roadmap, docs/jq-compat.md)
          .                identity
          .foo.bar         field access (append ? to ignore type errors)
          .[0]  .[-1]      array index
          .[]              iterate array elements / object values
          f | g            pipe: outputs of f feed g
          f , g            both: outputs of f, then outputs of g
          ( ... )          grouping
          42 "s" true null literals
          a // b           alternative (b unless a is truthy)
          a ?? b           nullish (b only if a is null/empty)   [ECMAScript]
          a+b a-b a*b      arithmetic + - * / %  (also "s"*n, arr-arr,
          a/b a%b  -a        obj+obj merge / obj*obj deep-merge, str/str split)
          a==b a<b …       comparison == != < <= > >=  (jq's cross-type order)
          a and b  a or b  logical (short-circuit, boolean result)
          # ...            comment to end of line

        BUILTINS (v0)
          length keys keys_unsorted type not reverse add empty
          map(f) select(f) has(k)
          ECMAScript aliases: typeof (=type), filter (=select)

        FLAGS
          -c, --compact-output   one line per output (default: 2-space pretty)
          -r, --raw-output       print top-level strings without quotes
          -n, --null-input       don't read input; run the filter once on null
          --humane               humane mode: fix jq's semantic warts
                                 (also: # jig:humane pragma, or JIG_MODE=humane)
          -h, --help             this help
          -V, --version          version

        EXIT CODES (mirrors jq)
          0  success
          2  usage error / unreadable or malformed input
          3  filter compile error
          5  a runtime error occurred while filtering

        EXAMPLES
          curl -s https://api.example.com/users | jig '.[] | .name'
          jig -r '.items[0].id' data.json
          JIG_DEBUG=1 jig '.' <<< '{"a":1}'     # verbose trace (stderr + /tmp/jig.log)

        See: https://github.com/akira-toriyama/jig
        """)
    }
}

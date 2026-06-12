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
        }
    }

    /// Exit codes mirror jq: 0 ok, 2 usage/system error, 3 program compile
    /// error, 5 a runtime error occurred (later inputs still processed).
    @MainActor
    static func run(_ args: Args) {
        let filter: Filter
        do {
            filter = try parseFilter(args.filter)
        } catch let e as FilterParseError {
            stderrLine(Diagnostic(e).render(program: args.filter))
            exit(3)
        } catch {
            stderrLine("jig: \(error)")
            exit(3)
        }
        Log.debug("filter parsed: \(args.filter)")

        let style: JSONStyle = args.compactOutput ? .compact : .pretty
        var hadRuntimeError = false
        var inputIndex = 0

        forEachInput(args) { input in
            inputIndex += 1
            do {
                for output in try evaluate(filter, on: input) {
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
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                stderrLine("jig: stdin is not valid UTF-8")
                exit(2)
            }
            sources = [("<stdin>", text)]
        } else {
            sources = args.files.map { file in
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

        FILTER (v0 subset — full jq language is the roadmap, docs/jq-compat.md)
          .                identity
          .foo.bar         field access (append ? to ignore type errors)
          .[0]  .[-1]      array index
          .[]              iterate array elements / object values
          f | g            pipe: outputs of f feed g
          f , g            both: outputs of f, then outputs of g
          ( ... )          grouping

        FLAGS
          -c, --compact-output   one line per output (default: 2-space pretty)
          -r, --raw-output       print top-level strings without quotes
          -n, --null-input       don't read input; run the filter once on null
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

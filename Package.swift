// swift-tools-version:6.0
//
// jig — a jq-compatible JSON processor with humane errors.
//
// A jig is the workshop fixture that holds the stock and guides the cutting
// tool — which is exactly what a query program does to JSON. jig aims for
// practical compatibility with jq (github.com/jqlang/jq) while fixing the
// parts users trip over: diagnostics with source spans + hints, consistent
// number handling, no parser crashes. Compatibility policy:
// docs/jq-compat.md.
//
// Architecture is hexagonal (Ports & Adapters), mirroring facet / chord /
// glance / perch — but as a pure stdin/stdout filter jig has NO AppKit
// adapter layer; the App target IS the I/O adapter:
//
//   JigCore   pure logic: JSON value model + parser/writer, filter
//             lexer/parser (AST), evaluator (generator semantics), argv
//             parsing, diagnostics rendering. Foundation only. XCTest-able.
//   JigApp    executable: @main, stdin/file reading, stdout/stderr writing,
//             exit codes.

import PackageDescription

let package = Package(
    name: "jig",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "jig", targets: ["JigApp"]),
        .library(name: "JigCore", targets: ["JigCore"]),
    ],
    targets: [
        // Zero dependencies, like chord. The JSON parser/writer and the
        // filter compiler are the project itself — pulling a JSON library
        // would defeat the point (and break key order + literal
        // preservation, which jq semantics require).
        .target(name: "JigCore"),
        .executableTarget(
            name: "JigApp",
            dependencies: ["JigCore"]),
        .testTarget(name: "JigCoreTests", dependencies: ["JigCore"]),
    ]
)

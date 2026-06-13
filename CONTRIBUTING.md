# Contributing to jig

Welcome — this is a small, focused project, so the bar is "your change
should still feel like *jig*". The points below help that.

> 日本語の説明が必要な場合は [README.ja.md](README.ja.md) を参照。

## What this is

`jig` is an ergonomic, jq-inspired JSON processor with humane diagnostics. It
no longer chases byte-for-byte jq compatibility — direction lives in
[docs/roadmap.md](docs/roadmap.md). Two principles drive everything:

1. **One semantics, predictable for AI and humans** — there is no jq/humane
   mode toggle. jig keeps the jq spellings that have no better idiom and adopts
   a saner default where one clearly exists (e.g. `.[]` over null → empty;
   `//` drops false+null, `??` is nullish). Vocabulary is es-toolkit-canonical
   (jq names accepted as aliases). New behavior is reflected in the roadmap.
2. **Diagnostics are the product** — every error carries a source span, a
   type name, and a hint. If a change makes an error message vaguer, it's a
   regression even when the behavior is right.

If a feature would violate either, it probably belongs in a different tool.

## Project layout

SwiftPM, hexagonal (same family as
[glance](https://github.com/akira-toriyama/glance) /
[chord](https://github.com/akira-toriyama/chord) /
[facet](https://github.com/akira-toriyama/facet)) — minus the AppKit
adapter, because a pure stdin/stdout CLI doesn't have one:

```
Sources/
  JigCore/             pure logic: JSON model/parser/writer, filter
                       parser, evaluator, args, diagnostics. Zero deps;
                       no Foundation (exception: Log.swift).
  JigApp/              @main. stdin/files, stdout/stderr, exit codes.
Tests/
  JigCoreTests/        contract tests for all of the above.
```

## Dev setup

```sh
git clone https://github.com/akira-toriyama/jig.git
cd jig
git config core.hooksPath scripts/hooks   # commit-msg lint

./build.sh                 # → bin/jig (codesigned)
./run.sh                   # demo filters with JIG_DEBUG=1
swift test                 # requires full Xcode — see below
```

### Tests need full Xcode

`swift test` requires the **XCTest framework**, which ships with the full
Xcode bundle — **Command Line Tools alone is not enough** (you'll see
`no such module 'XCTest'`). Locally `swift build` plus a
`printf '<json>' | ./bin/jig '<filter>'` smoke is the bar; CI
(`build.yml`, macos-15) runs the full test suite on every PR.

## Conventions

- Commits / PR titles: gitmoji + Conventional Commits —
  [docs/commit-convention.md](docs/commit-convention.md).
- Terminology: use the canonical names in
  [docs/glossary.md](docs/glossary.md); new terms land in the same PR.
- Dependencies: the package is deliberately zero-dependency. Adding one
  needs an MIT/Apache-2-compatible license, a WHY comment in Package.swift,
  and justification in the PR description.
